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
    build_graphql_payload(query, operation_name, variables)

Build a GraphQL request payload tuple.
"""
function build_graphql_payload(query, operation_name, variables)
    return (
        query = query,
        operationName = operation_name,
        variables = variables,
    )
end

"""
    send_graphql_request(client, query, operation_name, variables)

Execute one GraphQL request with pre-built variables.
"""
function send_graphql_request(client, query, operation_name, variables)
    payload = build_graphql_payload(query, operation_name, variables)
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

"""
    merge_graphql_variables(variables, kwargs)

Merge positional variables and keyword variables into a mutable symbol-keyed map.
Keyword variables override duplicates.
"""
function merge_graphql_variables(variables, kwargs)
    merged = Dict{Symbol, Any}()
    for (key, value) in variables
        key isa Symbol || error("GraphQL variables must use Symbol keys.")
        merged[key] = value
    end
    for (key, value) in pairs(kwargs)
        merged[key] = value
    end
    return merged
end

"""
    normalize_graphql_path(path)

Normalize a user-provided key path to a `Vector{String}`.
"""
function normalize_graphql_path(path)
    keys = String[]
    for key in path
        if key isa Symbol
            push!(keys, String(key))
        elseif key isa AbstractString
            push!(keys, String(key))
        else
            error("GraphQL connection path keys must be Symbol or String.")
        end
    end
    isempty(keys) && error("GraphQL connection path cannot be empty.")
    return keys
end

"""
    resolve_graphql_connection_path(explicit_path)

Resolve a caller-provided connection path for pagination.
"""
function resolve_graphql_connection_path(explicit_path)
    explicit_path === nothing && return nothing
    return normalize_graphql_path(explicit_path)
end

function graphql_value_at_path(root, path)
    value = root
    for key in path
        value = value[key]
    end
    return value
end

function graphql_connection_at_path(root, path)
    return graphql_value_at_path(root, path)
end

function append_graphql_page!(combined_connection, next_connection)
    combined_edges = combined_connection["edges"]
    next_edges = next_connection["edges"]
    append!(combined_edges, next_edges)
    combined_connection["pageInfo"] = deepcopy(next_connection["pageInfo"])
    return nothing
end

"""
    paginate_graphql_response!(client, query, operation_name, variables, response; wsapi_connection_path, wsapi_cursor_variable)

Fetch subsequent GraphQL pages and merge them into `response`.
"""
function paginate_graphql_response!(
    client,
    query,
    operation_name,
    variables,
    response;
    wsapi_connection_path,
    wsapi_cursor_variable,
)
    connection_path = resolve_graphql_connection_path(wsapi_connection_path)
    connection_path === nothing && return response

    cursor_key = wsapi_cursor_variable isa Symbol ? wsapi_cursor_variable : Symbol(wsapi_cursor_variable)
    combined_connection = graphql_connection_at_path(response, connection_path)

    while true
        page_info = combined_connection["pageInfo"]
        has_next_page = page_info["hasNextPage"]
        has_next_page || break

        end_cursor = page_info["endCursor"]
        page_variables = copy(variables)
        page_variables[cursor_key] = end_cursor
        page_response = send_graphql_request(client, query, operation_name, page_variables)
        next_connection = graphql_connection_at_path(page_response, connection_path)
        append_graphql_page!(combined_connection, next_connection)
    end

    return response
end

"""
    client(query, operation_name, variables=(;); wsapi_single_page=false, wsapi_connection_path=nothing, wsapi_cursor_variable=:cursor, kwargs...)

Execute a GraphQL request with the authenticated `client`.

`variables` and keyword arguments are merged with NamedTuple splatting, with
keyword arguments taking precedence for duplicate keys. `variables` may be any
symbol-keyed pairs iterable.

Calls `ensure_fresh!(client)` before sending the request. Throws an error when
the response status is 400 or higher.

Pagination is path-driven: pass `wsapi_connection_path` to enable pagination for
that connection. Without `wsapi_connection_path`, this method returns a single
response page. Use `wsapi_single_page=true` to force single-page behavior.
"""
function (client::WSClient)(
    query,
    operation_name,
    variables = (;);
    wsapi_single_page::Bool = false,
    wsapi_connection_path = nothing,
    wsapi_cursor_variable = :cursor,
    kwargs...,
)
    ensure_fresh!(client)
    merged_variables = merge_graphql_variables(variables, kwargs)
    response = send_graphql_request(client, query, operation_name, merged_variables)
    wsapi_single_page && return response
    return paginate_graphql_response!(
        client,
        query,
        operation_name,
        merged_variables,
        response;
        wsapi_connection_path = wsapi_connection_path,
        wsapi_cursor_variable = wsapi_cursor_variable,
    )
end
