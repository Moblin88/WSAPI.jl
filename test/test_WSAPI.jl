@testitem "WSAPI helper behavior" begin
    using WSAPI
    using Dates

    @test WSAPI.build_variables(Dict(:a => 1, "b" => 2), pairs((c = 3, b = 4))) == Dict("a" => 1, "b" => 4, "c" => 3)
    @test WSAPI.build_variables(nothing, pairs((x = 1,))) == Dict("x" => 1)

    mktempdir() do dir
        token_path = joinpath(dir, "token.txt")
        write(token_path, "from-plain")
        @test WSAPI.read_refresh_token(token_path) == "from-plain"

        write(token_path, "")
        @test isnothing(WSAPI.read_refresh_token(token_path))

        missing_path = joinpath(dir, "missing-token.txt")
        @test isnothing(WSAPI.read_refresh_token(missing_path))

        WSAPI.persist_refresh_token!(token_path, "persisted-refresh")
        @test read(token_path, String) == "persisted-refresh"
    end

    @test !hasfield(WSAPI.WSClient, :refresh_token)

    api = WSAPI.WSClient(
        "tokens.txt",
        "cid",
        "did",
        "sid",
        ReentrantLock(),
        WSAPI.LOGIN_PAGE_URL,
        WSAPI.OAUTH_TOKEN_URL,
        WSAPI.GRAPHQL_URL,
        Ref{Union{Nothing, WSAPI.AccessToken}}(WSAPI.AccessToken("access", Dates.now(Dates.UTC) + Dates.Second(15))),
    )
    @test WSAPI.should_refresh(api)
    api.access_token_ref[] = WSAPI.AccessToken("access", Dates.now(Dates.UTC) + Dates.Second(300))
    @test !WSAPI.should_refresh(api)
    api.access_token_ref[] = nothing
    @test !WSAPI.should_refresh(api)

    created_at = round(Int, Dates.datetime2unix(Dates.now(Dates.UTC)))
    access_token = WSAPI.AccessToken("constructed", created_at, 120)
    @test access_token.value == "constructed"
    @test access_token.expiry == Dates.unix2datetime(created_at) + Dates.Second(120)
end

@testitem "WSAPI localhost HTTP flow (configurable endpoints)" begin
    using WSAPI
    using Dates
    using HTTP
    using JSON

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
            elseif request.method == "POST" && request.target == "/graphql"
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
                graphql_url = "$(base_url)/graphql",
            )
            @test client.device_id == "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
            @test client.client_id == "fedcba9876543210fedcba9876543210"
            @test client.access_token_ref[].value == "new_access"
            @test client.access_token_ref[].expiry == Dates.unix2datetime(created_at) + Dates.Second(3600)
            @test read(token_path, String) == "new_refresh"

            result = client("query Q{ok}", "Q")
            @test result["data"]["ok"] == true

            @test length(log.requests) == 4
            @test log.requests[1].method == "GET"
            @test log.requests[1].target == "/app/login"
            @test log.requests[2].method == "GET"
            @test log.requests[2].target == "/assets/app-1234abcd.js"
            @test log.requests[3].method == "POST"
            @test log.requests[3].target == "/v1/oauth/v2/token"
            refresh_payload = JSON.parse(log.requests[3].body)
            @test refresh_payload["grant_type"] == "refresh_token"
            @test refresh_payload["refresh_token"] == "old_refresh"
            @test log.requests[4].method == "POST"
            @test log.requests[4].target == "/graphql"
            graphql_payload = JSON.parse(log.requests[4].body)
            @test graphql_payload["operationName"] == "Q"
        finally
            close(server)
            wait(server.serve_task)
        end
    end
end
