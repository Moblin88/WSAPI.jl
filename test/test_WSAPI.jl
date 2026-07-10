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

    noop_request = (args...) -> error("noop request should not be called")
    api = WSAPI.WSClient(
        "tokens.txt",
        "cid",
        "did",
        "sid",
        ReentrantLock(),
        noop_request,
        Ref{Union{Nothing, WSAPI.AccessToken}}(WSAPI.AccessToken("access", Dates.now(Dates.UTC) + Dates.Second(15))),
    )
    @test WSAPI.should_refresh(api)
    api.access_token_ref[] = WSAPI.AccessToken("access", Dates.now(Dates.UTC) + Dates.Second(300))
    @test !WSAPI.should_refresh(api)
    api.access_token_ref[] = nothing
    @test !WSAPI.should_refresh(api)
end

@testitem "WSAPI mocked HTTP flow (reference-style)" begin
    using WSAPI
    using Dates
    using HTTP
    using JSON

    mutable struct MockTransport
        responses::Vector{HTTP.Response}
        requests::Vector{NamedTuple}
    end

    function (mock::MockTransport)(method, url, headers = Pair{String, String}[], body = nothing; kwargs...)
        push!(mock.requests, (method = method, url = string(url), headers = collect(headers), body = body, kwargs = NamedTuple(kwargs)))
        isempty(mock.responses) && error("No mock responses remaining for $(method) $(url)")
        return popfirst!(mock.responses)
    end

    plain_response(status::Integer, body::AbstractString; headers = Pair{String, String}[]) = HTTP.Response(status, headers, body)
    json_response(status::Integer, payload::AbstractDict; headers = Pair{String, String}[]) = HTTP.Response(status, headers, JSON.json(payload))

    mktempdir() do dir
        token_path = joinpath(dir, "token.txt")
        write(token_path, "old_refresh")
        created_at = round(Int, Dates.datetime2unix(Dates.now(Dates.UTC)))

        login_body = "<html><head><script src=\"https://cdn.wealthsimple.com/app-1234abcd.js\"></script></head></html>"
        app_js_body = "\"production\"...,clientId:\"fedcba9876543210fedcba9876543210\""

        transport = MockTransport(
            [
                plain_response(200, login_body; headers = ["Set-Cookie" => "wssdi=a1b2c3d4-e5f6-7890-abcd-ef1234567890; Path=/;"]),
                plain_response(200, app_js_body),
                json_response(200, Dict("access_token" => "new_access", "refresh_token" => "new_refresh", "expires_in" => 3600, "created_at" => created_at)),
                json_response(200, Dict("data" => Dict("ok" => true))),
            ],
            NamedTuple[],
        )

        client = WSAPI.WSClient(token_path; request_fn = transport)
        @test client.device_id == "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        @test client.client_id == "fedcba9876543210fedcba9876543210"
        @test client.access_token_ref[].value == "new_access"
        @test client.access_token_ref[].expiry == Dates.unix2datetime(created_at) + Dates.Second(3600)
        @test read(token_path, String) == "new_refresh"

        result = client("query Q{ok}", "Q")
        @test result["data"]["ok"] == true

        @test length(transport.requests) == 4
        @test transport.requests[1].method == "GET"
        @test transport.requests[1].url == "https://my.wealthsimple.com/app/login"
        @test get(transport.requests[1].kwargs, :cookies, true) == false
        @test transport.requests[2].method == "GET"
        @test occursin("app-1234abcd.js", transport.requests[2].url)
        @test transport.requests[3].method == "POST"
        refresh_payload = JSON.parse(String(transport.requests[3].body))
        @test refresh_payload["grant_type"] == "refresh_token"
        @test refresh_payload["refresh_token"] == "old_refresh"
        @test transport.requests[4].method == "POST"
        graphql_payload = JSON.parse(String(transport.requests[4].body))
        @test graphql_payload["operationName"] == "Q"
    end
end
