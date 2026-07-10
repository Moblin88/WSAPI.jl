# WSAPI

[![Build Status](https://github.com/Moblin88/WSAPI.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/Moblin88/WSAPI.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/Moblin88/WSAPI.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/Moblin88/WSAPI.jl)

Basic usage:

```julia
using WSAPI

api = WSClient("~/.config/wsapi-token.json")
response = api(
    "query FetchAccounts(\$first: Int!) { accounts(first: \$first) { edges { node { id } } } }",
    "FetchAccounts",
    Dict("first" => 25),
)
```

Notes:
- `WSClient(token_file)` reads `refresh_token` from the file, refreshes access if possible, and otherwise prompts for username/password (and OTP when required).
- For integration-style testing, you can point `WSClient` at a localhost server via `login_page_url`, `oauth_token_url`, and `graphql_url`.
- Rotated/new refresh tokens are persisted back to the same file as plain token text.
- GraphQL calls accept an optional `pairs`-iterable variables object plus keyword arguments, where keyword arguments override duplicate keys.
- Access tokens are refreshed automatically when they are within 30 seconds of expiry using a non-blocking, thread-safe refresh strategy.
