"""
    bootstrap_device_and_client(login_page_url)

Fetch the login page and bundled app script to extract the Wealthsimple device
id cookie and OAuth client id.
"""
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

"""
    extract_device_id(response)

Extract the `wssdi` cookie from an HTTP response and parse it as a UUID.
"""
function extract_device_id(response)
    for cookie in HTTP.Cookies.cookies(response)
        cookie.name == "wssdi" && return UUID(cookie.value)
    end
    error("Unable to locate Wealthsimple device id (wssdi cookie).")
end

"""
    token_headers(client, profile)

Build shared OAuth request headers for token-related endpoints.
"""
function token_headers((;device_id, session_id), profile)
    return [
        "Content-Type" => "application/json",
        "x-wealthsimple-client" => "@wealthsimple/wealthsimple",
        "x-ws-profile" => profile,
        "x-ws-device-id" => string(device_id),
        "x-ws-session-id" => string(session_id),
    ]
end

function isstale((;access_token_expiry))
    access_token_expiry === nothing && return true
    return access_token_expiry <= now(Dates.UTC) + TOKEN_EXPIRY_BUFFER
end


"""
    refresh_access_token!(client) -> Bool

Try refreshing the access token from the refresh token stored on disk. Returns
`true` on success and `false` when no usable refresh token is available or the
refresh request fails.
"""
function refresh_access_token!(client)
    isfile(client.token_file) || return false
    refresh_token = read(client.token_file, String)
    isempty(refresh_token) && return false

    response = HTTP.request(
        "POST",
        client.oauth_token_url,
        token_headers(client, "undefined"),
        JSON.json((
            grant_type = "refresh_token",
            refresh_token = refresh_token,
            client_id = client.client_id,
        ));
        status_exception = false,
    )
    response.status >= 400 && return false

    payload = JSON.parse(response.body)

    write(client.token_file, payload["refresh_token"])
    client.access_token = payload["access_token"]
    client.access_token_expiry = Dates.unix2datetime(payload["created_at"] + payload["expires_in"])
    return true
end

"""
    interactive_login!(client)

Prompt for credentials (and OTP when needed), exchange them for tokens, and
persist the returned refresh token.
"""
function interactive_login!(client)
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
        client_id = client.client_id
    )
    login_json = JSON.json(login_payload)
    response = HTTP.request(
        "POST",
        client.oauth_token_url,
        token_headers(client, "undefined"),
        login_json;
        status_exception = false
    )
    status = response.status
    payload = JSON.parse(response.body)

    if status >= 400 && get(payload, "error", "") == "invalid_grant"
        otp = Base.shred!(readchomp, Base.getpass("Wealthsimple OTP code"))
        println()
        otp_headers = token_headers(client, "undefined")
        push!(otp_headers, "x-wealthsimple-otp" => "$(otp);remember=true")
        response = HTTP.request(
            "POST",
            client.oauth_token_url,
            otp_headers,
            login_json;
            status_exception = false,
        )
        status = response.status
        payload = JSON.parse(response.body)
    end

    if status >= 400
        error("Wealthsimple login failed.")
    end

    write(client.token_file, payload["refresh_token"])
    client.access_token = payload["access_token"]
    client.access_token_expiry = Dates.unix2datetime(payload["created_at"] + payload["expires_in"])
    return nothing
end

"""
    ensure_fresh!(client)

Ensure `client` has a fresh access token. Tries refresh-token flow first, then
falls back to interactive login when refresh is unavailable or fails.
"""
function ensure_fresh!(client)
    !isstale(client) && return nothing
    lock(client.refresh_lock)
    try
        !isstale(client) && return nothing
        refresh_access_token!(client) || interactive_login!(client)
    finally
        unlock(client.refresh_lock)
    end
    return nothing
end
