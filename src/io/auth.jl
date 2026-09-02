"""
    STAC.AbstractAuth

Supertype of the credentials an [`HTTPIO`](@ref STAC.HTTPIO) carries. An auth answers two
questions, both per href, so one stack can hold a token for a catalog's own host and stay
anonymous for the buckets its assets live in:

| Method | Answers |
|---|---|
| `STAC.headers(auth, href)` | the request headers to add |
| `STAC.rewrite(auth, href)` | the href a reader should see, e.g. one carrying a signed token |

`rewrite` defaults to the identity, so an auth that only adds headers implements `headers`
alone.

```julia
struct QueryToken <: STAC.AbstractAuth
    token::String
end
STAC.headers(::QueryToken, ::AbstractString) = STAC.NO_HEADERS
STAC.rewrite(a::QueryToken, href::AbstractString) = href * "?token=" * a.token

STAC.rewrite(QueryToken("abc"), "https://example.com/catalog.json")
# "https://example.com/catalog.json?token=abc"

HTTPIO(QueryToken("abc"))       # the transport that signs every href
```
"""
abstract type AbstractAuth end

"""
    STAC.headers(auth, href) -> STAC.RequestHeaders

The headers `auth` adds to a request for `href`, empty when it does not apply to that host.
"""
function headers end

"""
    STAC.rewrite(auth, href) -> String

`href` as a reader should see it. An auth that signs a URL returns the signed form; every
other auth returns `href` unchanged.
"""
rewrite(::AbstractAuth, href::AbstractString) = String(href)

"""
    NoAuth()

Anonymous access: no headers, no rewriting. The default of every stack
[`STAC.default_io`](@ref) builds.

```julia
STAC.headers(NoAuth(), "https://example.com")   # Pair{String,String}[]
```
"""
struct NoAuth <: AbstractAuth end

headers(::NoAuth, ::AbstractString) = NO_HEADERS

"""
    BearerToken(token)

`Authorization: Bearer <token>` on every request. [`STAC.Headers`](@ref) covers an endpoint
that wants a differently named header.

```julia
STAC.headers(BearerToken("s3cret"), "https://example.com")
# ["Authorization" => "Bearer s3cret"]
```

A [`Client`](@ref) takes one through `auth =`, and every later call carries it.
"""
struct BearerToken <: AbstractAuth
    token::String
end

headers(a::BearerToken, ::AbstractString) = RequestHeaders(["Authorization" => "Bearer " * a.token])

"""
    Headers(pairs)
    Headers("X-Api-Key" => "…", …)

A fixed header list added to every request, for the endpoints whose credential is neither a
bearer token nor a signed URL.

```julia
auth = STAC.Headers("X-Api-Key" => "k", "X-Tenant" => "acme")
STAC.headers(auth, "https://example.com")   # ["X-Api-Key" => "k", "X-Tenant" => "acme"]
HTTPIO(auth)                                # the transport that sends them
```
"""
struct Headers <: AbstractAuth
    headers::RequestHeaders
end

Headers(pairs::Pair...) = Headers(RequestHeaders([String(first(p)) => String(last(p)) for p in pairs]))

headers(a::Headers, ::AbstractString) = a.headers
