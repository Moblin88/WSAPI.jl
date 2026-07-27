# WSAPI

[![Build Status](https://github.com/Moblin88/WSAPI.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/Moblin88/WSAPI.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/Moblin88/WSAPI.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/Moblin88/WSAPI.jl)

Basic usage:

```julia
using WSAPI

client = WSClient()  # reads ENV["WSAPI_TOKEN_FILE"] by default
WSAPI.ensure_fresh!(client)
identity_id = client.identity_canonical_id
identity_id === nothing && error("Unable to resolve identity_canonical_id.")

response = client(
    "query FetchAccounts(\$identityId: ID!, \$pageSize: Int = 25, \$cursor: String) { identity(id: \$identityId) { accounts(filter: {}, first: \$pageSize, after: \$cursor) { edges { node { id } } pageInfo { hasNextPage endCursor } } } }",
    "FetchAccounts",
    (identityId = identity_id, pageSize = 25),
)
```

Environment setup (recommended):

```sh
export WSAPI_TOKEN_FILE="/path/to/token.txt"
```

Then either:
- add it to your shell startup file (for terminal sessions), or
- set `"terminal.integrated.env.osx"` in VS Code settings so integrated terminals and REPL-launched sessions inherit it.

Notes:
- `WSClient()` reads the refresh token path from `ENV["WSAPI_TOKEN_FILE"]` by default. You can also pass `WSClient(token_file)` explicitly.
- `WSAPI.ensure_fresh!(client)` also populates and caches `client.identity_canonical_id`.
- The token file contains only the raw refresh token string — not JSON.
- For integration-style testing, you can point `WSClient` at a localhost server via `login_page_url`, `oauth_token_url`, `token_info_url`, and `graphql_url`.
- Rotated/new refresh tokens are persisted back to the same file as plain token text.
- GraphQL calls accept an optional symbol-keyed pairs iterable (e.g. NamedTuple or `Dict{Symbol,Any}`) plus keyword arguments, where keyword arguments override duplicate keys.
- Access tokens are refreshed automatically when they are within 30 seconds of expiry.

Inspired by:
- https://github.com/gboudreau/ws-api-php

Disclaimer:
- This project was developed with the assistance of AI tools.
