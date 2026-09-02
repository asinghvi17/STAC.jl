"""
    STAC.AbstractIO

Supertype of everything that fetches bytes. A STAC object holds only its own origin, never a
transport, so every fetch goes through an `AbstractIO` that a caller passes in or that
[`STAC.default_io`](@ref) supplies.

| Method | Contract |
|---|---|
| `STAC.read(io, href)` | the bytes at `href`, as a `Vector{UInt8}` |
| `STAC.request(io, method, href; headers, body)` | the body of one request, as a `Vector{UInt8}` |

`request` defaults to `read` for `GET` and errors otherwise, which is the whole
implementation for a read-only transport such as [`PathIO`](@ref STAC.PathIO). Wrappers
([`CachingIO`](@ref STAC.CachingIO), [`StreamRouterIO`](@ref STAC.StreamRouterIO)) hold an
inner IO and forward both calls.

Every method declares `Vector{UInt8}`, so the one dynamic dispatch a scoped default costs is
confined to the call itself and everything downstream of it is inferred.
"""
abstract type AbstractIO end

"""
    STAC.RequestHeaders

The header list a request carries: `name => value` pairs in the order they are sent.
"""
const RequestHeaders = Vector{Pair{String,String}}

const NO_HEADERS = RequestHeaders()

@noinline _nomethod(io, method) =
    throw(ArgumentError(string(nameof(typeof(io)), " answers GET only, not ", method)))

"""
    STAC.request(io, method, href; headers = STAC.NO_HEADERS, body = nothing) -> Vector{UInt8}

The response body of one request through `io`. This is the call a STAC API search and its
`next` links use; `method`, `headers`, and `body` come from the link the endpoint sent.

The fallback answers `GET` with [`STAC.read`](@ref) and rejects every other method, which is
the right behaviour for a transport that can only fetch.
"""
function request(io::AbstractIO, method::AbstractString, href::AbstractString;
                 headers = NO_HEADERS, body = nothing)
    method == "GET" || _nomethod(io, method)
    return read(io, href)
end
