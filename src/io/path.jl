"""
    STAC.PathIO()

The local-filesystem [`AbstractIO`](@ref STAC.AbstractIO). `read` is `Base.read` on the path
the href names; a `file://` href is accepted and reduced to its path first, so a catalog
published with `file` URLs traverses without a separate route.

```julia
STAC.parse(STAC.read(STAC.PathIO(), "test/fixtures/stac-spec/catalog.json")).id  # "examples"
STAC.read("test/fixtures/stac-spec/catalog.json"; io = STAC.PathIO())            # the same, typed
```
"""
struct PathIO <: AbstractIO end

"""
    STAC.localpath(href) -> String

The filesystem path `href` names, whether it was written as a plain path or as a `file://`
URL.
"""
function localpath(href::AbstractString)
    urischeme(href) == "file" || return String(href)
    return URIs.unescapeuri(URIs.URI(href).path)
end

read(::PathIO, href::AbstractString) = Base.read(localpath(href))
