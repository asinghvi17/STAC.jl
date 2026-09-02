"""
    CachingIO(inner; maxsize = 128)
    CachingIO(inner, cache::LRU{String,Vector{UInt8}})

An [`AbstractIO`](@ref STAC.AbstractIO) that answers a repeated `read` from an LRU of
fetched bytes. A catalog walk reaches the same `root` and `parent` documents from every
object it visits, so the cache is what keeps that from being one request each.

`request` passes straight through: a search POST is not addressed by its href alone, and a
`next` link is meant to be fetched exactly once.
"""
struct CachingIO{I<:AbstractIO} <: AbstractIO
    inner::I
    cache::LRU{String,Vector{UInt8}}
end

CachingIO(inner::AbstractIO; maxsize::Integer = 128) =
    CachingIO(inner, LRU{String,Vector{UInt8}}(maxsize = Int(maxsize)))

read(io::CachingIO, href::AbstractString) =
    get!(() -> read(io.inner, href), io.cache, convert(String, href))

request(io::CachingIO, method::AbstractString, href::AbstractString;
        headers = NO_HEADERS, body = nothing) =
    request(io.inner, method, href; headers, body)

"""
    empty!(io::CachingIO)

Drop every cached body, so the next `read` of each href goes back to the inner IO.
"""
Base.empty!(io::CachingIO) = (empty!(io.cache); io)
