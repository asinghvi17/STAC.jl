"""
    STAC.USER_AGENT[]

The `User-Agent` every request carries, `"STAC.jl/<version>"`. Assign to it to identify your
own tool to an endpoint that asks.

It is a `Ref` filled when the module is compiled rather than in `__init__`: formatting a
`VersionNumber` is not a `--trim=safe` call, and the `--trim` programs share this code path.
"""
const USER_AGENT = Ref(let v = pkgversion(@__MODULE__)
    v === nothing ? "STAC.jl" : "STAC.jl/" * string(v)
end)

"""
    HTTPIO(auth = NoAuth(); client = nothing, retries = 3, connect_timeout = 30, request_timeout = 300)

The HTTP [`AbstractIO`](@ref STAC.AbstractIO), over HTTP.jl. `auth` supplies per-href headers
and href rewriting; every request carries a `STAC.jl/<version>` `User-Agent`.

| Keyword | Meaning |
|---|---|
| `client` | an `HTTP.Client` to pool connections through; `nothing` uses HTTP.jl's shared default |
| `retries` | attempts after the first, for transient failures and retryable 4xx/5xx statuses |
| `connect_timeout` | seconds to establish a connection; `0` disables |
| `request_timeout` | seconds for the whole request; `0` disables |

`client` defaults to `nothing` because [`STAC.DEFAULT_IO`](@ref) is built when the module
loads: a live connection pool cannot go into a precompile cache, and HTTP.jl's implicit
client already pools.
"""
struct HTTPIO{A<:AbstractAuth} <: AbstractIO
    auth::A
    client::Union{HTTP.Client,Nothing}
    retries::Int
    connect_timeout::Float64
    request_timeout::Float64
end

HTTPIO(auth::AbstractAuth = NoAuth(); client = nothing, retries::Integer = 3,
       connect_timeout::Real = 30, request_timeout::Real = 300) =
    HTTPIO(auth, client, Int(retries), Float64(connect_timeout), Float64(request_timeout))

"""
    STAC.requestheaders(auth, href, extra) -> STAC.RequestHeaders

The headers one request sends: the `User-Agent`, then what `auth` adds for `href`, then the
caller's own. Later entries win at the server, so a caller can override either.
"""
function requestheaders(auth::AbstractAuth, href::AbstractString, extra)
    hs = RequestHeaders(["User-Agent" => USER_AGENT[]])
    append!(hs, headers(auth, href))
    for (k, v) in extra
        push!(hs, String(k) => String(v))
    end
    return hs
end

function _http(io::HTTPIO, method::AbstractString, href::AbstractString, extra, body)
    target = rewrite(io.auth, href)
    resp = HTTP.request(method, target, requestheaders(io.auth, target, extra), body;
                        client = io.client, retries = io.retries, status_exception = true,
                        connect_timeout = io.connect_timeout,
                        request_timeout = io.request_timeout)
    return resp.body::Vector{UInt8}
end

read(io::HTTPIO, href::AbstractString) = _http(io, "GET", href, NO_HEADERS, nothing)

request(io::HTTPIO, method::AbstractString, href::AbstractString;
        headers = NO_HEADERS, body = nothing) = _http(io, method, href, headers, body)
