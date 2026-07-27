# WSAPI

[![Build Status](https://github.com/Moblin88/WSAPI.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/Moblin88/WSAPI.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/Moblin88/WSAPI.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/Moblin88/WSAPI.jl)

Basic usage:

```julia
using WSAPI

client = WSClient(expanduser("~/.config/wsapi-token"))
WSAPI.ensure_fresh!(client)
identity_id = client.identity_canonical_id
identity_id === nothing && error("Unable to resolve identity_canonical_id.")

response = client(
    "query FetchAccounts(\$identityId: ID!, \$pageSize: Int = 25, \$cursor: String) { identity(id: \$identityId) { accounts(filter: {}, first: \$pageSize, after: \$cursor) { edges { node { id } } pageInfo { hasNextPage endCursor } } } }",
    "FetchAccounts",
    Dict("identityId" => identity_id, "pageSize" => 25),
)
```

Notes:
- `WSClient(token_file)` reads the refresh token as plain text from the file and uses it to obtain access tokens automatically.
- `WSAPI.ensure_fresh!(client)` also populates and caches `client.identity_canonical_id`.
- The token file contains only the raw refresh token string — not JSON.
- For integration-style testing, you can point `WSClient` at a localhost server via `login_page_url`, `oauth_token_url`, `token_info_url`, and `graphql_url`.
- Rotated/new refresh tokens are persisted back to the same file as plain token text.
- GraphQL calls accept an optional `pairs`-iterable variables object plus keyword arguments, where keyword arguments override duplicate keys.
- Access tokens are refreshed automatically when they are within 30 seconds of expiry.
