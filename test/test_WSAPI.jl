@testitem "WSAPI helper behavior" begin
    using WSAPI
    using Dates
    using UUIDs

    client = WSAPI.WSClient(
        "tokens.txt",
        "cid",
        uuid4(),
        uuid4(),
        WSAPI.LOGIN_PAGE_URL,
        WSAPI.OAUTH_TOKEN_URL,
        WSAPI.TOKEN_INFO_URL,
        WSAPI.GRAPHQL_URL,
        "access",
        Dates.now(Dates.UTC) + Dates.Second(15),
        nothing,
    )
    @test WSAPI.isstale(client)
    client.access_token_expiry = Dates.now(Dates.UTC) + Dates.Second(300)
    @test !WSAPI.isstale(client)
end

@testitem "WSAPI localhost HTTP flow (caller-managed auth init)" begin
    using WSAPI
    using Dates
    using HTTP
    using JSON
    using UUIDs

    mutable struct RequestLog
        requests::Vector{NamedTuple}
    end

    mktempdir() do dir
        token_path = joinpath(dir, "token.txt")
        write(token_path, "old_refresh")
        created_at = round(Int, Dates.datetime2unix(Dates.now(Dates.UTC)))
        log = RequestLog(NamedTuple[])
        handler = function (request)
            push!(log.requests, (
                method = request.method,
                target = request.target,
                headers = copy(request.headers),
                body = String(request.body),
            ))
            if request.method == "GET" && request.target == "/app/login"
                login_body = "<html><head><script src=\"/assets/app-1234abcd.js\"></script></head></html>"
                return HTTP.Response(
                    200,
                    ["Set-Cookie" => "wssdi=a1b2c3d4-e5f6-7890-abcd-ef1234567890; Path=/; HttpOnly"],
                    login_body,
                )
            elseif request.method == "GET" && request.target == "/assets/app-1234abcd.js"
                app_js_body = "\"production\"...,clientId:\"fedcba9876543210fedcba9876543210\""
                return HTTP.Response(200, app_js_body)
            elseif request.method == "POST" && request.target == "/v1/oauth/v2/token"
                payload = Dict(
                    "access_token" => "new_access",
                    "refresh_token" => "new_refresh",
                    "expires_in" => 3600,
                    "created_at" => created_at,
                )
                return HTTP.Response(200, JSON.json(payload))
            elseif request.method == "GET" && request.target == "/v1/oauth/v2/token/info"
                return HTTP.Response(200, JSON.json(Dict("identity_canonical_id" => "identity-123")))
            elseif request.method == "POST" && request.target == "/graphql"
                payload = JSON.parse(String(request.body))
                operation_name = get(payload, "operationName", "")
                if operation_name == "FetchAccounts"
                    variables = get(payload, "variables", Dict{String, Any}())
                    cursor = get(variables, "cursor", nothing)
                    if cursor === nothing
                        return HTTP.Response(
                            200,
                            JSON.json(Dict(
                                "data" => Dict(
                                    "identity" => Dict(
                                        "accounts" => Dict(
                                            "edges" => [
                                                Dict("node" => Dict("id" => "acct-1")),
                                                Dict("node" => Dict("id" => "acct-2")),
                                            ],
                                            "pageInfo" => Dict(
                                                "hasNextPage" => true,
                                                "endCursor" => "cursor-2",
                                            ),
                                        ),
                                    ),
                                ),
                            )),
                        )
                    elseif cursor == "cursor-2"
                        return HTTP.Response(
                            200,
                            JSON.json(Dict(
                                "data" => Dict(
                                    "identity" => Dict(
                                        "accounts" => Dict(
                                            "edges" => [
                                                Dict("node" => Dict("id" => "acct-3")),
                                                Dict("node" => Dict("id" => "acct-4")),
                                            ],
                                            "pageInfo" => Dict(
                                                "hasNextPage" => false,
                                                "endCursor" => "cursor-4",
                                            ),
                                        ),
                                    ),
                                ),
                            )),
                        )
                    end
                    return HTTP.Response(400, JSON.json(Dict("error" => "unexpected cursor")))
                end
                return HTTP.Response(200, JSON.json(Dict("data" => Dict("ok" => true))))
            end
            return HTTP.Response(404)
        end

        server = HTTP.serve!(handler, "127.0.0.1", 0; verbose = false)
        base_url = "http://127.0.0.1:$(server.bound_port)"

        try
            client = WSAPI.WSClient(
                token_path;
                login_page_url = "$(base_url)/app/login",
                oauth_token_url = "$(base_url)/v1/oauth/v2/token",
                token_info_url = "$(base_url)/v1/oauth/v2/token/info",
                graphql_url = "$(base_url)/graphql",
            )
            @test client.device_id == UUID("a1b2c3d4-e5f6-7890-abcd-ef1234567890")
            @test client.client_id == "fedcba9876543210fedcba9876543210"
            @test client.access_token === nothing
            @test client.access_token_expiry === nothing

            WSAPI.ensure_fresh!(client)
            @test client.access_token == "new_access"
            @test client.access_token_expiry == Dates.unix2datetime(created_at) + Dates.Second(3600)
            @test client.identity_canonical_id == "identity-123"
            @test read(token_path, String) == "new_refresh"

            result = client("query Q{ok}", "Q")
            @test result["data"]["ok"] == true
            result2 = client("query Q2(\$a:Int,\$b:Int,\$c:Int){ok}", "Q2", Dict(:a => 1, :b => 2); b = 4, c = 5)
            @test result2["data"]["ok"] == true

            paged_query = "query FetchAccounts(\$cursor: String) { identity(id: \"identity-123\") { accounts(first: 2, after: \$cursor) { edges { node { id } } pageInfo { hasNextPage endCursor } } } }"
            no_path_result = client(paged_query, "FetchAccounts")
            no_path_edges = no_path_result["data"]["identity"]["accounts"]["edges"]
            @test length(no_path_edges) == 2
            @test [edge["node"]["id"] for edge in no_path_edges] == ["acct-1", "acct-2"]
            @test no_path_result["data"]["identity"]["accounts"]["pageInfo"] == Dict(
                "hasNextPage" => true,
                "endCursor" => "cursor-2",
            )

            paged_result = client(paged_query, "FetchAccounts"; wsapi_connection_path = ("data", "identity", "accounts"))
            account_edges = paged_result["data"]["identity"]["accounts"]["edges"]
            @test length(account_edges) == 4
            @test [edge["node"]["id"] for edge in account_edges] == ["acct-1", "acct-2", "acct-3", "acct-4"]
            @test paged_result["data"]["identity"]["accounts"]["pageInfo"] == Dict(
                "hasNextPage" => false,
                "endCursor" => "cursor-4",
            )

            single_page_result = client(
                paged_query,
                "FetchAccounts";
                wsapi_connection_path = ("data", "identity", "accounts"),
                wsapi_single_page = true,
            )
            single_page_edges = single_page_result["data"]["identity"]["accounts"]["edges"]
            @test length(single_page_edges) == 2
            @test [edge["node"]["id"] for edge in single_page_edges] == ["acct-1", "acct-2"]
            @test single_page_result["data"]["identity"]["accounts"]["pageInfo"] == Dict(
                "hasNextPage" => true,
                "endCursor" => "cursor-2",
            )

            @test length(log.requests) == 10
            @test log.requests[1].method == "GET"
            @test log.requests[1].target == "/app/login"
            @test log.requests[2].method == "GET"
            @test log.requests[2].target == "/assets/app-1234abcd.js"
            @test log.requests[3].method == "POST"
            @test log.requests[3].target == "/v1/oauth/v2/token"
            refresh_payload = JSON.parse(log.requests[3].body)
            @test refresh_payload["grant_type"] == "refresh_token"
            @test refresh_payload["refresh_token"] == "old_refresh"
            @test log.requests[4].method == "GET"
            @test log.requests[4].target == "/v1/oauth/v2/token/info"
            @test log.requests[5].method == "POST"
            @test log.requests[5].target == "/graphql"
            graphql_payload = JSON.parse(log.requests[5].body)
            @test graphql_payload["operationName"] == "Q"
            @test graphql_payload["variables"] == Dict{String, Any}()
            auth_headers = filter(h -> lowercase(String(h[1])) == "authorization", log.requests[5].headers)
            @test length(auth_headers) == 1
            @test log.requests[6].method == "POST"
            @test log.requests[6].target == "/graphql"
            graphql_payload2 = JSON.parse(log.requests[6].body)
            @test graphql_payload2["operationName"] == "Q2"
            @test graphql_payload2["variables"] == Dict("a" => 1, "b" => 4, "c" => 5)
            @test log.requests[7].method == "POST"
            @test log.requests[7].target == "/graphql"
            graphql_payload3 = JSON.parse(log.requests[7].body)
            @test graphql_payload3["operationName"] == "FetchAccounts"
            @test graphql_payload3["variables"] == Dict{String, Any}()
            @test log.requests[8].method == "POST"
            @test log.requests[8].target == "/graphql"
            graphql_payload4 = JSON.parse(log.requests[8].body)
            @test graphql_payload4["operationName"] == "FetchAccounts"
            @test graphql_payload4["variables"] == Dict{String, Any}()
            @test log.requests[9].method == "POST"
            @test log.requests[9].target == "/graphql"
            graphql_payload5 = JSON.parse(log.requests[9].body)
            @test graphql_payload5["operationName"] == "FetchAccounts"
            @test graphql_payload5["variables"] == Dict("cursor" => "cursor-2")
            @test log.requests[10].method == "POST"
            @test log.requests[10].target == "/graphql"
            graphql_payload6 = JSON.parse(log.requests[10].body)
            @test graphql_payload6["operationName"] == "FetchAccounts"
            @test graphql_payload6["variables"] == Dict{String, Any}()
            @test !isempty(String(auth_headers[1][2]))
        finally
            close(server)
            wait(server.serve_task)
        end
    end
end
