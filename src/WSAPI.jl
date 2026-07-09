module WSAPI

using HTTP
using JSON
using Dates
using UUIDs

export WSClient

const LOGIN_PAGE_URL = "https://my.wealthsimple.com/app/login"
const OAUTH_TOKEN_URL = "https://api.production.wealthsimple.com/v1/oauth/v2/token"
const GRAPHQL_URL = "https://my.wealthsimple.com/graphql"
const APP_JS_REGEX = r"""<script[^>]*src="([^"]*/app-[a-f0-9]+\.js)"""
const CLIENT_ID_REGEX = r"\"production\"[^}]*clientId:\"([a-f0-9]+)\""

mutable struct WSClient
    token_file::String
    client_id::String
    device_id::String
    session_id::String
    access_token::Union{Nothing, String}
    access_token_expires_at::Union{Nothing, DateTime}
    refresh_lock::ReentrantLock
    request_fn
end

function WSClient(token_file::AbstractString; request_fn = HTTP.request)
    device_id, client_id = bootstrap_device_and_client(request_fn)
    api = WSClient(
        String(token_file),
        client_id,
        device_id,
        string(uuid4()),
        nothing,
        nothing,
        ReentrantLock(),
        request_fn,
    )
    ensure_authorized!(api)
    return api
end

function bootstrap_device_and_client(request_fn)
    login_response = request_fn("GET", LOGIN_PAGE_URL)
    login_body = String(login_response.body)
    device_id = extract_device_id(login_response)
    script_match = match(APP_JS_REGEX, login_body)
    script_match === nothing && error("Unable to locate Wealthsimple app JavaScript URL.")
    app_js_url = absolutize_wealthsimple_url(script_match.captures[1])

    app_js_response = request_fn("GET", app_js_url)
    app_js = String(app_js_response.body)
    client_match = match(CLIENT_ID_REGEX, app_js)
    client_match === nothing && error("Unable to locate Wealthsimple OAuth client id.")

    return device_id, client_match.captures[1]
end

function extract_device_id(response::HTTP.Response)
    cookies = HTTP.Cookies.cookies(response)
    for cookie in cookies
        cookie.name == "wssdi" && return String(cookie.value)
    end
    error("Unable to locate Wealthsimple device id (wssdi cookie).")
end

function absolutize_wealthsimple_url(url::AbstractString)
    startswith(url, "http://") && return String(url)
    startswith(url, "https://") && return String(url)
    startswith(url, "/") && return "https://my.wealthsimple.com$(url)"
    return "https://my.wealthsimple.com/$(url)"
end

function read_refresh_token(path::AbstractString)
    isfile(path) || return nothing
    content = read(path, String)
    isempty(content) && return nothing
    return content
end

function persist_refresh_token!(path::AbstractString, refresh_token::AbstractString)
    write(path, refresh_token)
    return nothing
end

function ensure_authorized!(api::WSClient)
    if refresh_access_token!(api)
        return api
    end

    interactive_login!(api)
    return api
end

function token_headers(api::WSClient, profile::AbstractString)
    return Pair{String, String}[
        "Content-Type" => "application/json",
        "x-wealthsimple-client" => "@wealthsimple/wealthsimple",
        "x-ws-profile" => profile,
        "x-ws-device-id" => api.device_id,
        "x-ws-session-id" => api.session_id,
    ]
end

function request_json(api::WSClient, method::AbstractString, url::AbstractString; headers = Pair{String, String}[], body = nothing)
    response = body === nothing ? api.request_fn(method, url, headers) : api.request_fn(method, url, headers, JSON.json(body))
    text = String(response.body)
    payload = isempty(text) ? Dict{String, Any}() : JSON.parse(text)
    return response.status, payload
end

function refresh_access_token!(api::WSClient)
    refresh_token = read_refresh_token(api.token_file)
    isnothing(refresh_token) && return false

    status, payload = request_json(
        api,
        "POST",
        OAUTH_TOKEN_URL;
        headers = token_headers(api, "invest"),
        body = (
            grant_type = "refresh_token",
            refresh_token = refresh_token,
            client_id = api.client_id,
        ),
    )
    if status >= 400 || !has_token_payload(payload)
        return false
    end

    apply_token_payload!(api, payload)
    persist_refresh_token!(api.token_file, String(payload["refresh_token"]))
    return true
end

function interactive_login!(api::WSClient)
    print("Wealthsimple username: ")
    username = chomp(readline(stdin))
    password = String(Base.getpass("Wealthsimple password: "))
    login_payload = (
        grant_type = "password",
        skip_provision = "true",
        username = username,
        password = password,
        scope = "openid profile email offline_access",
        client_id = api.client_id,
        otp_claim = nothing,
    )
    status, payload = request_json(
        api,
        "POST",
        OAUTH_TOKEN_URL;
        headers = token_headers(api, "undefined"),
        body = login_payload,
    )

    if status >= 400 && get(payload, "error", "") == "invalid_grant"
        otp = String(Base.getpass("Wealthsimple OTP code: "))
        otp_headers = token_headers(api, "undefined")
        push!(otp_headers, "x-wealthsimple-otp" => "$(otp);remember=true")
        status, payload = request_json(
            api,
            "POST",
            OAUTH_TOKEN_URL;
            headers = otp_headers,
            body = login_payload,
        )
    end

    if status >= 400 || !has_token_payload(payload)
        error("Wealthsimple login failed.")
    end

    apply_token_payload!(api, payload)
    persist_refresh_token!(api.token_file, String(payload["refresh_token"]))
    return nothing
end

function has_token_payload(payload::Dict{String, Any})
    haskey(payload, "access_token") || return false
    haskey(payload, "refresh_token") || return false
    return payload["access_token"] isa AbstractString &&
           payload["refresh_token"] isa AbstractString &&
           !isempty(payload["access_token"]) &&
           !isempty(payload["refresh_token"])
end

function apply_token_payload!(api::WSClient, payload::Dict{String, Any})
    api.access_token = String(payload["access_token"])
    expires_in = get(payload, "expires_in", 300)
    expiry_seconds = expires_in isa Number ? round(Int, Float64(expires_in)) : 300
    api.access_token_expires_at = Dates.now(Dates.UTC) + Dates.Second(expiry_seconds)
    return nothing
end

function should_refresh(api::WSClient)
    return !isnothing(api.access_token) &&
           !isnothing(api.access_token_expires_at) &&
           (api.access_token_expires_at::DateTime) <= (Dates.now(Dates.UTC) + Dates.Second(30))
end

function maybe_refresh_nonblocking!(api::WSClient)
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

function build_variables(variables, kwargs::Base.Iterators.Pairs)
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
        "x-ws-device-id" => api.device_id,
        "x-ws-session-id" => api.session_id,
    ]
    if !isnothing(api.access_token)
        push!(headers, "Authorization" => "Bearer $(api.access_token)")
    end
    return headers
end

function (api::WSClient)(query::AbstractString, operation_name::AbstractString, variables = nothing; kwargs...)
    maybe_refresh_nonblocking!(api)
    payload = (
        query = query,
        operationName = operation_name,
        variables = build_variables(variables, kwargs),
    )
    status, response = request_json(api, "POST", GRAPHQL_URL; headers = graphql_headers(api), body = payload)
    status >= 400 && error("GraphQL request failed with HTTP status $(status).")
    return response
end

end
