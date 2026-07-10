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
    token_headers(device_id, session_id, profile)

Build shared OAuth request headers for token-related endpoints.
"""
function token_headers(device_id, session_id, profile)
    return [
        "Content-Type" => "application/json",
        "x-wealthsimple-client" => "@wealthsimple/wealthsimple",
        "x-ws-profile" => profile,
        "x-ws-device-id" => string(device_id),
        "x-ws-session-id" => string(session_id),
    ]
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
        token_headers(client.device_id, client.session_id, "invest"),
        JSON.json((
            grant_type = "refresh_token",
            refresh_token = refresh_token,
            client_id = client.client_id,
        ));
        status_exception = false,
    )
    status = response.status
    payload = isempty(response.body) ? Dict{String, Any}() : JSON.parse(response.body)
    if status >= 400
        return false
    end

    write(client.token_file, payload["refresh_token"])
    client.access_token_ref[] = AccessToken(payload["access_token"], payload["created_at"], payload["expires_in"])
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
        client_id = client.client_id,
    )
    response = HTTP.request(
        "POST",
        client.oauth_token_url,
        token_headers(client.device_id, client.session_id, "undefined"),
        JSON.json(login_payload);
        status_exception = false,
    )
    status = response.status
    payload = isempty(response.body) ? Dict{String, Any}() : JSON.parse(response.body)

    if status >= 400 && get(payload, "error", "") == "invalid_grant"
        otp = Base.shred!(readchomp, Base.getpass("Wealthsimple OTP code"))
        println()
        otp_headers = token_headers(client.device_id, client.session_id, "undefined")
        push!(otp_headers, "x-wealthsimple-otp" => "$(otp);remember=true")
        response = HTTP.request(
            "POST",
            client.oauth_token_url,
            otp_headers,
            JSON.json(login_payload);
            status_exception = false,
        )
        status = response.status
        payload = isempty(response.body) ? Dict{String, Any}() : JSON.parse(response.body)
    end

    if status >= 400
        error("Wealthsimple login failed.")
    end

    client.access_token_ref[] = AccessToken(payload["access_token"], payload["created_at"], payload["expires_in"])
    write(client.token_file, payload["refresh_token"])
    return nothing
end

"""
    initialize_access_token!(client)

Initialize client authentication by trying refresh first, then falling back to
interactive login.
"""
function initialize_access_token!(client)
    if refresh_access_token!(client)
        return nothing
    end
    interactive_login!(client)
    return nothing
end

"""
    should_refresh(client) -> Bool

Return `true` when the current access token expires within 30 seconds.
"""
function should_refresh(client)
    return client.access_token_ref[].expiry <= (Dates.now(Dates.UTC) + Dates.Second(30))
end

"""
    maybe_refresh_nonblocking!(client)

Attempt a best-effort token refresh without blocking if another thread is
already handling refresh.
"""
function maybe_refresh_nonblocking!(client)
    should_refresh(client) || return nothing
    trylock(client.refresh_lock) || return nothing
    try
        should_refresh(client) || return nothing
        refresh_access_token!(client)
    finally
        unlock(client.refresh_lock)
    end
    return nothing
end
