# Link resolution. A STAC object keeps every `href` exactly as the producer wrote it, so a
# relative link only becomes fetchable against the origin of the object it came from.

@inline _isschemestart(c::UInt8) = UInt8('a') <= c <= UInt8('z') || UInt8('A') <= c <= UInt8('Z')

@inline _isschemechar(c::UInt8) =
    _isschemestart(c) || UInt8('0') <= c <= UInt8('9') ||
    c == UInt8('+') || c == UInt8('-') || c == UInt8('.')

"""
    STAC.urischeme(href) -> SubString

The scheme of `href` without its colon (`"https"`, `"s3"`), or an empty string when `href`
carries none, which is how a local path presents itself. This is what
[`StreamRouterIO`](@ref STAC.StreamRouterIO) matches a route on.

A single letter before the colon is read as a Windows drive rather than as the one-character
scheme RFC 3986 would allow, so `"C:/data/catalog.json"` stays a path.
"""
function urischeme(href::AbstractString)
    b = codeunits(href)
    n = length(b)
    (n < 3 || !_isschemestart(@inbounds b[1]) || !_isschemechar(@inbounds b[2])) &&
        return SubString(href, 1, 0)
    for i in 3:n
        c = @inbounds b[i]
        c == UInt8(':') && return SubString(href, 1, i - 1)
        _isschemechar(c) || break
    end
    return SubString(href, 1, 0)
end

"""
    STAC.isabsolutehref(href) -> Bool

Whether `href` can be fetched on its own: it carries a scheme, or it is an absolute path on
this filesystem.
"""
isabsolutehref(href::AbstractString) = !isempty(urischeme(href)) || isabspath(href)

@noinline _nobase(href) =
    throw(ArgumentError("cannot resolve the relative href " * repr(href) *
                        ": the object it came from has no origin. Read it from a path or a " *
                        "URL, or set one with `STAC.sethref`."))

"""
    STAC.resolve(link::Link, base) -> String
    STAC.resolve(href::AbstractString, base) -> String

`href` made absolute against `base`, the origin of the object whose `links` it came from.

| `href` | `base` | Result |
|---|---|---|
| carries a scheme | anything | `href`, unchanged |
| any | a href with a scheme | RFC 3986 reference resolution |
| an absolute path | a local path, or none | `href`, unchanged |
| relative | a local path | `normpath(joinpath(dirname(base), href))` |
| relative | `nothing` | an `ArgumentError` |

A trailing slash on `base` is significant either way: `"./item.json"` against `"/a/b"` is
`"/a/item.json"`, and against `"/a/b/"` it is `"/a/b/item.json"`.

A root-relative `"/collections/x.json"` is a path when the base is one and a host-rooted URL
when the base is a URL, which is what RFC 3986 says and what an API that publishes such links
means.
"""
function resolve(href::AbstractString, base::Union{AbstractString,Nothing})
    isempty(urischeme(href)) || return String(href)
    (base !== nothing && !isempty(urischeme(base))) &&
        return string(URIs.resolvereference(base, href))
    isabspath(href) && return String(href)
    base === nothing && _nobase(href)
    return normpath(joinpath(dirname(base), href))
end

resolve(link::Link, base::Union{AbstractString,Nothing}) = resolve(link.href, base)

"""
    STAC.absolutehref(href) -> String

`href` as an origin worth recording: a local path becomes absolute, anything with a scheme is
left alone.
"""
absolutehref(href::AbstractString) = isempty(urischeme(href)) ? abspath(href) : String(href)
