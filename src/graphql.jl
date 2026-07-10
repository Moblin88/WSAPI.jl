"""
    set_merged_value!(merged, entry)

Insert a `(key, value)` pair into `merged`, normalizing keys to strings.
"""
function set_merged_value!(merged::Dict{String, Any}, (key, value))
    merged[String(key)] = value
    return nothing
end

"""
    build_variables(variables, kwargs)

Merge GraphQL variables from `variables` and `kwargs`, with keyword arguments
overriding duplicate keys.
"""
function build_variables(variables, kwargs)
    merged = Dict{String, Any}()
    if !isnothing(variables)
        for entry in pairs(variables)
            set_merged_value!(merged, entry)
        end
    end
    for entry in kwargs
        set_merged_value!(merged, entry)
    end
    return merged
end

"""
    graphql_headers(client)

Build GraphQL request headers for the authenticated client.
"""
function graphql_headers(client)
    headers = [
        "Content-Type" => "application/json",
        "x-ws-profile" => "trade",
        "x-ws-api-version" => "12",
        "x-ws-locale" => "en-CA",
        "x-platform-os" => "web",
        "x-ws-device-id" => string(client.device_id),
        "x-ws-session-id" => string(client.session_id),
        "Authorization" => "Bearer $(client.access_token_ref[].value)",
    ]
    return headers
end

"""
    client(query, operation_name, variables=nothing; kwargs...)

Execute a GraphQL request with the authenticated `client`.

`variables` and keyword arguments are merged, with keyword arguments taking
precedence for duplicate keys.
"""
function (client::WSClient)(query, operation_name, variables = nothing; kwargs...)
    maybe_refresh_nonblocking!(client)
    payload = (
        query = query,
        operationName = operation_name,
        variables = build_variables(variables, kwargs),
    )
    response = HTTP.request(
        "POST",
        client.graphql_url,
        graphql_headers(client),
        JSON.json(payload);
        status_exception = false,
    )
    response.status >= 400 && error("GraphQL request failed with HTTP status $(response.status).")
    return isempty(response.body) ? Dict{String, Any}() : JSON.parse(response.body)
end
