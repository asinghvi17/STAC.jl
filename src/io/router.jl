"""
    STAC.StreamRouterIO(routes::Tuple)
    STAC.StreamRouterIO("https" => STAC.HTTPIO(), "" => STAC.PathIO())

The [`AbstractIO`](@ref STAC.AbstractIO) that picks a child by the href's scheme, with `""`
meaning a local path. Routing per href rather than per catalog is what lets a catalog on
`https://` own items on `s3://`, or a `next` link point at another host.

The routes are a tuple, so each `read` resolves to one child's method at compile time, which
is what `--trim=safe` needs.

```julia
io = STAC.StreamRouterIO("https" => STAC.HTTPIO(), "" => STAC.PathIO())
STAC.read("test/fixtures/stac-spec/catalog.json"; io)      # the "" route
STAC.read("https://stac.itslive.cloud/"; io)               # the "https" one
```

An href whose scheme no route matches raises a [`STAC.NoRoute`](@ref) naming it.
"""
struct StreamRouterIO{T<:Tuple} <: AbstractIO
    routes::T
end

StreamRouterIO(routes::Pair...) = StreamRouterIO(routes)

@noinline _noroute(scheme, href) = throw(NoRoute(String(scheme), String(href)))

# One unrolled comparison per route: every branch calls a concrete child's method, so the
# whole fetch path stays statically dispatched.
@generated function read(r::StreamRouterIO{T}, href::AbstractString) where {T}
    ex = Expr(:block, :(scheme = urischeme(href)))
    for i in 1:fieldcount(T)
        push!(ex.args, :(@inbounds(r.routes[$i]).first == scheme &&
                         return read(@inbounds(r.routes[$i]).second, href)))
    end
    push!(ex.args, :(_noroute(scheme, href)))
    return ex
end

request(r::StreamRouterIO, method::AbstractString, href::AbstractString;
        headers = NO_HEADERS, body = nothing) = _routerequest(r, method, href, headers, body)

# Positional, because a generated function may not take keyword arguments.
@generated function _routerequest(r::StreamRouterIO{T}, method, href, headers, body) where {T}
    ex = Expr(:block, :(scheme = urischeme(href)))
    for i in 1:fieldcount(T)
        push!(ex.args, :(@inbounds(r.routes[$i]).first == scheme &&
                         return request(@inbounds(r.routes[$i]).second, method, href; headers, body)))
    end
    push!(ex.args, :(_noroute(scheme, href)))
    return ex
end

# The same unrolled scheme match `read` uses, so the auth reported is the one the child that
# would fetch this href carries.
@generated function authfor(r::StreamRouterIO{T}, href::AbstractString) where {T}
    ex = Expr(:block, :(scheme = urischeme(href)))
    for i in 1:fieldcount(T)
        push!(ex.args, :(@inbounds(r.routes[$i]).first == scheme &&
                         return authfor(@inbounds(r.routes[$i]).second, href)))
    end
    push!(ex.args, :(return NoAuth()))
    return ex
end
