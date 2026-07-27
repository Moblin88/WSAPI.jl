module WSAPI

using HTTP
using JSON
using Dates
using URIs: URI, resolvereference
using UUIDs

export WSClient

const LOGIN_PAGE_URL = URI("https://my.wealthsimple.com/app/login")
const OAUTH_TOKEN_URL = URI("https://api.production.wealthsimple.com/v1/oauth/v2/token")
const TOKEN_INFO_URL = URI("https://api.production.wealthsimple.com/v1/oauth/v2/token/info")
const GRAPHQL_URL = URI("https://my.wealthsimple.com/graphql")
const APP_JS_REGEX = r"""<script[^>]*src="([^"]*/app-[a-f0-9]+\.js)"""
const CLIENT_ID_REGEX = r"\"production\"[^}]*clientId:\"([a-f0-9]+)\""
const TOKEN_EXPIRY_BUFFER = Dates.Second(30)  # Refresh 30 seconds before expiry
mutable struct WSClient
    const token_file::String
    const client_id::String
    const device_id::UUID
    const session_id::UUID
    const login_page_url::URI
    const oauth_token_url::URI
    const token_info_url::URI
    const graphql_url::URI
    access_token::Union{String, Nothing}
    access_token_expiry::Union{DateTime, Nothing}
    identity_canonical_id::Union{String, Nothing}
end

include("authentication.jl")
include("graphql.jl")

"""
    WSClient(
        token_file=get(ENV, "WSAPI_TOKEN_FILE", nothing);
        login_page_url=LOGIN_PAGE_URL,
        oauth_token_url=OAUTH_TOKEN_URL,
        token_info_url=TOKEN_INFO_URL,
        graphql_url=GRAPHQL_URL,
    )

Create a Wealthsimple client without authenticating.

Call `ensure_fresh!(client)` before requests that require authentication.
"""
function WSClient(
    token_file = get(ENV, "WSAPI_TOKEN_FILE", nothing);
    login_page_url = LOGIN_PAGE_URL,
    oauth_token_url = OAUTH_TOKEN_URL,
    token_info_url = TOKEN_INFO_URL,
    graphql_url = GRAPHQL_URL,
)
    (token_file isa String && !isempty(token_file)) || error("token_file is required. Pass WSClient(token_file) or set WSAPI_TOKEN_FILE.")
    device_id, client_id = bootstrap_device_and_client(login_page_url)
    session_id = uuid4()
    client = WSClient(
        token_file,
        client_id,
        device_id,
        session_id,
        URI(login_page_url),
        URI(oauth_token_url),
        URI(token_info_url),
        URI(graphql_url),
        nothing,
        nothing,
        nothing,
    )
    return client
end

end
