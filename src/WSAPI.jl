module WSAPI

using HTTP
using JSON
using Dates
using URIs: URI, resolvereference
using UUIDs

export WSClient

const LOGIN_PAGE_URL = URI("https://my.wealthsimple.com/app/login")
const OAUTH_TOKEN_URL = URI("https://api.production.wealthsimple.com/v1/oauth/v2/token")
const GRAPHQL_URL = URI("https://my.wealthsimple.com/graphql")
const APP_JS_REGEX = r"""<script[^>]*src="([^"]*/app-[a-f0-9]+\.js)"""
const CLIENT_ID_REGEX = r"\"production\"[^}]*clientId:\"([a-f0-9]+)\""

struct AccessToken
    value::String
    expiry::DateTime
end

function AccessToken(value, created_at, expires_in)
    return AccessToken(
        String(value),
        Dates.unix2datetime(created_at) + Dates.Second(expires_in),
    )
end

struct WSClient
    token_file::String
    client_id::String
    device_id::UUID
    session_id::UUID
    refresh_lock::ReentrantLock
    login_page_url::URI
    oauth_token_url::URI
    graphql_url::URI
    access_token_ref::Base.RefValue{AccessToken}
end

function WSClient(
    token_file;
    login_page_url = LOGIN_PAGE_URL,
    oauth_token_url = OAUTH_TOKEN_URL,
    graphql_url = GRAPHQL_URL,
)
    device_id, client_id = bootstrap_device_and_client(login_page_url)
    session_id = uuid4()
    access_token = initialize_access_token(token_file, client_id, device_id, session_id, oauth_token_url)
    api = WSClient(
        token_file,
        client_id,
        device_id,
        session_id,
        ReentrantLock(),
        URI(login_page_url),
        URI(oauth_token_url),
        URI(graphql_url),
        Ref(access_token),
    )
    return api
end

function bootstrap_device_and_client(login_page_url)
    login_response = HTTP.request("GET", login_page_url; cookies = false)
    device_id = extract_device_id(login_response)
    script_match = match(APP_JS_REGEX, String(login_response.body))
    script_match === nothing && error("Unable to locate Wealthsimple app JavaScript URL.")
    app_js_url = resolvereference(login_page_url, script_match.captures[1])

    app_js_response = HTTP.request("GET", app_js_url; cookies = false)
    client_match = match(CLIENT_ID_REGEX, String(app_js_response.body))
    client_match === nothing && error("Unable to locate Wealthsimple OAuth client id.")

    return device_id, client_match.captures[1]
end

function extract_device_id(response)
    for cookie in HTTP.Cookies.cookies(response)
        cookie.name == "wssdi" && return UUID(cookie.value)
    end
    error("Unable to locate Wealthsimple device id (wssdi cookie).")
end

function token_headers(device_id, session_id, profile)
    return [
        "Content-Type" => "application/json",
        "x-wealthsimple-client" => "@wealthsimple/wealthsimple",
        "x-ws-profile" => profile,
        "x-ws-device-id" => string(device_id),
        "x-ws-session-id" => string(session_id),
    ]
end

function request_json(method, url; headers = Pair{String, String}[], body = nothing)
    response = body === nothing ?
        HTTP.request(method, url, headers; status_exception = false) :
        HTTP.request(method, url, headers, JSON.json(body); status_exception = false)
    payload = isempty(response.body) ? JSON.parse("{}") : JSON.parse(response.body)
    return response.status, payload
end

function refresh_access_token(token_file, client_id, device_id, session_id, oauth_token_url)
    isfile(token_file) || return nothing
    refresh_token = read(token_file, String)
    isempty(refresh_token) && return nothing

    status, payload = request_json(
        "POST",
        oauth_token_url;
        headers = token_headers(device_id, session_id, "invest"),
        body = (
            grant_type = "refresh_token",
            refresh_token = refresh_token,
            client_id = client_id,
        ),
    )
    if status >= 400
        return nothing
    end

    write(token_file, payload["refresh_token"])
    return AccessToken(payload["access_token"], payload["created_at"], payload["expires_in"])
end

function refresh_access_token!(api)
    access_token = refresh_access_token(
        api.token_file,
        api.client_id,
        api.device_id,
        api.session_id,
        api.oauth_token_url,
    )
    isnothing(access_token) && return false
    api.access_token_ref[] = access_token
    return true
end

function interactive_login(client_id, device_id, session_id, oauth_token_url)
    print("Wealthsimple username: ")
    username = chomp(readline(stdin))
    password = Base.shred!(readchomp, Base.getpass("Wealthsimple password"))
    println()
    login_payload = (
        grant_type = "password",
        skip_provision = "true",
        username = username,
        password = password,
        scope = "read write",
        client_id = client_id
    )
    status, payload = request_json(
        "POST",
        oauth_token_url;
        headers = token_headers(device_id, session_id, "undefined"),
        body = login_payload,
    )

    if status >= 400 && get(payload, "error", "") == "invalid_grant"
        otp = Base.shred!(readchomp, Base.getpass("Wealthsimple OTP code"))
        println()
        otp_headers = token_headers(device_id, session_id, "undefined")
        push!(otp_headers, "x-wealthsimple-otp" => "$(otp);remember=true")
        status, payload = request_json(
            "POST",
            oauth_token_url;
            headers = otp_headers,
            body = login_payload,
        )
    end

    if status >= 400
        error("Wealthsimple login failed.")
    end

    access_token = AccessToken(payload["access_token"], payload["created_at"], payload["expires_in"])
    new_refresh_token = payload["refresh_token"]
    return access_token, new_refresh_token
end

function interactive_login!(api)
    access_token, refresh_token = interactive_login(
        api.client_id,
        api.device_id,
        api.session_id,
        api.oauth_token_url,
    )
    api.access_token_ref[] = access_token
    write(api.token_file, refresh_token)
    return nothing
end

function initialize_access_token(token_file, client_id, device_id, session_id, oauth_token_url)
    access_token = refresh_access_token(token_file, client_id, device_id, session_id, oauth_token_url)
    if !isnothing(access_token)
        return access_token
    end
    access_token, refresh_token = interactive_login(client_id, device_id, session_id, oauth_token_url)
    write(token_file, refresh_token)
    return access_token
end

access_token_value(api) = (api.access_token_ref[]::AccessToken).value
access_token_expiry(api) = (api.access_token_ref[]::AccessToken).expiry

function should_refresh(api)
    return access_token_expiry(api) <= (Dates.now(Dates.UTC) + Dates.Second(30))
end

function maybe_refresh_nonblocking!(api)
    should_refresh(api) || return nothing
    trylock(api.refresh_lock) || return nothing
    try
        should_refresh(api) || return nothing
        refresh_access_token!(api)
    finally
        unlock(api.refresh_lock)
    end
    return nothing
end

function build_variables(variables, kwargs)
    merged = Dict{String, Any}()
    if !isnothing(variables)
        for (key, value) in pairs(variables)
            merged[String(key)] = value
        end
    end
    for (key, value) in kwargs
        merged[String(key)] = value
    end
    return merged
end

function graphql_headers(api::WSClient)
    headers = Pair{String, String}[
        "Content-Type" => "application/json",
        "x-ws-profile" => "trade",
        "x-ws-api-version" => "12",
        "x-ws-locale" => "en-CA",
        "x-platform-os" => "web",
        "x-ws-device-id" => string(api.device_id),
        "x-ws-session-id" => string(api.session_id),
        "Authorization" => "Bearer $(access_token_value(api))",
    ]
    return headers
end

function (api::WSClient)(query, operation_name, variables = nothing; kwargs...)
    maybe_refresh_nonblocking!(api)
    payload = (
        query = query,
        operationName = operation_name,
        variables = build_variables(variables, kwargs),
    )
    status, response = request_json("POST", api.graphql_url; headers = graphql_headers(api), body = payload)
    status >= 400 && error("GraphQL request failed with HTTP status $(status).")
    return response
end

end
