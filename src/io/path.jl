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
    path = URIs.unescapeuri(URIs.URI(href).path)
    # `file:///C:/data/catalog.json` parses to the path `/C:/data/catalog.json`. That leading
    # slash is the URL's root, and a Windows path is rooted in its drive instead.
    @static if Sys.iswindows()
        (ncodeunits(path) >= 3 && codeunit(path, 1) == UInt8('/') &&
         codeunit(path, 3) == UInt8(':')) && return path[2:end]
    end
    return path
end

read(::PathIO, href::AbstractString) = Base.read(localpath(href))
