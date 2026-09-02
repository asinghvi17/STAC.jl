# Link resolution. A STAC object keeps every `href` exactly as the producer wrote it, so a
# relative link only becomes fetchable against the origin of the object it came from.

const NO_SCHEME = SubString("", 1, 0)

"""
    STAC.urischeme(href) -> SubString{String}

The scheme of `href` without its colon (`"https"`, `"s3"`), or an empty string when `href`
carries none, which is how a local path presents itself. This is what
[`StreamRouterIO`](@ref STAC.StreamRouterIO) matches a route on.

URIs.jl does the RFC 3986 parse; two answers are this package's own.

| `href` | Scheme | Why |
|---|---|---|
| `"C:/data/catalog.json"` | `""` | a lone letter before the colon is a Windows drive, not the one-character scheme RFC 3986 allows |
| `"/my catalogs/c.json"` | `""` | a raw space makes it no URI reference at all, which is to say a local path |

```jldoctest
julia> STAC.urischeme("https://example.com/catalog.json")
"https"

julia> STAC.urischeme("./item.json")
""
```
"""
function urischeme(href::AbstractString)
    scheme = try
        URIs.URI(href).scheme
    catch e
        e isa URIs.ParseError || rethrow()
        return NO_SCHEME
    end
    return length(scheme) > 1 ? scheme : NO_SCHEME
end

"""
    STAC.isabsolutehref(href) -> Bool

Whether `href` can be fetched on its own: it carries a scheme, or it is an absolute path on
this filesystem.
"""
isabsolutehref(href::AbstractString) = !isempty(urischeme(href)) || isabspath(href)

@noinline _nobase(href) = throw(NoOrigin(String(href)))

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
| relative | `nothing` | a [`STAC.NoOrigin`](@ref) |

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
