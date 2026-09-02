"""
    StreamRouterIO(routes::Tuple)
    StreamRouterIO("https" => HTTPIO(), "" => PathIO())

The [`AbstractIO`](@ref STAC.AbstractIO) that picks a child by the href's scheme, with `""`
meaning a local path. Routing per href rather than per catalog is what lets a catalog on
`https://` own items on `s3://`, or a `next` link point at another host.

The routes are a tuple, so each `read` resolves to one child's method at compile time, which
is what `--trim=safe` needs.
"""
struct StreamRouterIO{T<:Tuple} <: AbstractIO
    routes::T
end

StreamRouterIO(routes::Pair...) = StreamRouterIO(routes)

@noinline _noroute(scheme, href) =
    throw(ArgumentError("no route for scheme " * repr(String(scheme)) * " (" * String(href) *
                        "). Build a `StreamRouterIO` with one, or load the bridge that adds it."))

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
