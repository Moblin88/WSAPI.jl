"""
    graphql_headers(client)

Build GraphQL request headers for the authenticated client.

Throws an error when `client.access_token` is `nothing`.
"""
function graphql_headers(client)
    token = client.access_token
    token === nothing && error("WSClient is not authenticated. Call ensure_fresh!(client) before making GraphQL requests.")
    headers = [
        "Content-Type" => "application/json",
        "x-ws-profile" => "trade",
        "x-ws-api-version" => "12",
        "x-ws-locale" => "en-CA",
        "x-platform-os" => "web",
        "x-ws-device-id" => string(client.device_id),
        "x-ws-session-id" => string(client.session_id),
        "Authorization" => "Bearer $(token)",
    ]
    return headers
end

"""
    client(query, operation_name, variables=(;); kwargs...)

Execute a GraphQL request with the authenticated `client`.

`variables` and keyword arguments are merged with NamedTuple splatting, with
keyword arguments taking precedence for duplicate keys. `variables` may be any
symbol-keyed pairs iterable.

Calls `ensure_fresh!(client)` before sending the request. Throws an error when
the response status is 400 or higher.
"""
function (client::WSClient)(query, operation_name, variables = (;); kwargs...)
    ensure_fresh!(client)
    payload = (
        query = query,
        operationName = operation_name,
        variables = (; variables..., kwargs...),
    )
    response = HTTP.request(
        "POST",
        client.graphql_url,
        graphql_headers(client),
        JSON.json(payload);
        status_exception = false,
    )
    response.status >= 400 && error("GraphQL request failed with HTTP status $(response.status).")
    return JSON.parse(response.body)
end
