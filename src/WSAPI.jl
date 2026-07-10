module WSAPI

using HTTP
using JSON
using Dates
using URIs: URI, resolvereference
using UUIDs

export WSClient

const LOGIN_PAGE_URL = URI("https://my.wealthsimple.com/app/login")
const OAUTH_TOKEN_URL = URI("https://api.production.wealthsimple.com/v1/oauth/v2/token")
const GRAPHQL_URL = URI("https://my.wealthsimple.com/graphql")
const APP_JS_REGEX = r"""<script[^>]*src="([^"]*/app-[a-f0-9]+\.js)"""
const CLIENT_ID_REGEX = r"\"production\"[^}]*clientId:\"([a-f0-9]+)\""

struct AccessToken
    value::String
    expiry::DateTime
end

"""
    AccessToken(value, created_at, expires_in)

Create an `AccessToken` from OAuth token fields where `created_at` is a Unix
timestamp and `expires_in` is in seconds.
"""
function AccessToken(value, created_at, expires_in)
    return AccessToken(
        String(value),
        Dates.unix2datetime(created_at) + Dates.Second(expires_in),
    )
end

struct WSClient
    token_file::String
    client_id::String
    device_id::UUID
    session_id::UUID
    refresh_lock::ReentrantLock
    login_page_url::URI
    oauth_token_url::URI
    graphql_url::URI
    access_token_ref::Base.RefValue{AccessToken}
end

include("authentication.jl")
include("graphql.jl")

"""
    WSClient(token_file; login_page_url=LOGIN_PAGE_URL, oauth_token_url=OAUTH_TOKEN_URL, graphql_url=GRAPHQL_URL)

Create an authenticated Wealthsimple client.

The constructor first tries to refresh using the token in `token_file`. If that
fails, it falls back to interactive login and persists the new refresh token.
"""
function WSClient(
    token_file;
    login_page_url = LOGIN_PAGE_URL,
    oauth_token_url = OAUTH_TOKEN_URL,
    graphql_url = GRAPHQL_URL,
)
    device_id, client_id = bootstrap_device_and_client(login_page_url)
    session_id = uuid4()
    client = WSClient(
        token_file,
        client_id,
        device_id,
        session_id,
        ReentrantLock(),
        URI(login_page_url),
        URI(oauth_token_url),
        URI(graphql_url),
        Ref{AccessToken}(),
    )
    initialize_access_token!(client)
    return client
end

end
