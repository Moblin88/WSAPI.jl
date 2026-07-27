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

"""
    fetch_identity_canonical_id!(client)

Fetch the identity canonical id from the OAuth token-info endpoint and cache it
on `client`.
"""
function fetch_identity_canonical_id!(client)
    token = client.access_token
    token === nothing && error("WSClient is not authenticated. Call ensure_fresh!(client) first.")
    response = HTTP.request(
        "GET",
        client.token_info_url,
        [
            "Authorization" => "Bearer $token",
            "x-wealthsimple-client" => "@wealthsimple/wealthsimple",
        ];
        status_exception = false,
    )
    response.status >= 400 && error("Unable to fetch token info from Wealthsimple (HTTP $(response.status)).")

    payload = JSON.parse(response.body)
    client.identity_canonical_id = payload["identity_canonical_id"]
    return nothing
end

"""
    apply_auth_response!(client, payload)

Apply OAuth login/refresh response payload to `client`, persist the returned
refresh token, and refresh the cached identity canonical id.
"""
function apply_auth_response!(client, (; access_token, refresh_token, created_at, expires_in))
    write(client.token_file, refresh_token)
    client.access_token = access_token
    client.access_token_expiry = Dates.unix2datetime(created_at + expires_in)
    fetch_identity_canonical_id!(client)
    return nothing
end

"""
    isstale(client) -> Bool

Return `true` when `client` has no access-token expiry or when the token is
within `TOKEN_EXPIRY_BUFFER` of expiring.
"""
function isstale((;access_token_expiry))
    access_token_expiry === nothing && return true
    return access_token_expiry <= now(Dates.UTC) + TOKEN_EXPIRY_BUFFER
end


"""
    refresh_access_token!(client) -> Bool

Try refreshing the access token from the refresh token stored on disk. Returns
`true` on success and `false` when no usable refresh token is available or the
refresh request fails.

On success, this overwrites `client.token_file` with the new refresh token and
updates `client.access_token` and `client.access_token_expiry`.
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

    apply_auth_response!(
        client,
        (
            access_token = payload["access_token"],
            refresh_token = payload["refresh_token"],
            created_at = payload["created_at"],
            expires_in = payload["expires_in"],
        ),
    )
    return true
end

"""
    interactive_login!(client)

Prompt for credentials (and OTP when needed), exchange them for tokens, and
persist the returned refresh token.

This function prompts on stdin/stdout, updates `client.access_token` and
`client.access_token_expiry`, and overwrites `client.token_file`.
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
        status_exception = false,
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

    status >= 400 && error("Wealthsimple login failed.")
    apply_auth_response!(
        client,
        (
            access_token = payload["access_token"],
            refresh_token = payload["refresh_token"],
            created_at = payload["created_at"],
            expires_in = payload["expires_in"],
        ),
    )
    return nothing
end

"""
    ensure_fresh!(client)

Ensure `client` has a fresh access token using only refresh-token flow.
"""
function ensure_fresh!(client)
    if isstale(client)
        refresh_access_token!(client) || error("Unable to refresh Wealthsimple access token from token_file.")
        return nothing
    end
    if client.identity_canonical_id === nothing
        fetch_identity_canonical_id!(client)
    end
    return nothing
end
