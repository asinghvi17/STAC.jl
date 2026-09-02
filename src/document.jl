# The document layer: the `type` key choosing which struct to build, and the origin stamped
# onto what comes back.

@noinline _notstac(t) = throw(NotSTACDocument(String(t)))

@noinline _notyped() = throw(NotSTACDocument(nothing))

struct DocTypeSink{S}
    style::S
end

(f::DocTypeSink)(k::Integer, v) = nothing

function (f::DocTypeSink)(k, v)
    k == "type" || return nothing
    return StructUtils.EarlyReturn(JSON.parse(v, String; style = f.style))
end

"""
    STAC.doctype(doc::JSON.LazyValue) -> String

The value of a document's `type` key, which is what selects the struct a parse targets.

The scan is a callable sink for the reason the parse sinks are: `applyeach` forwards its
function argument, and a closure there compiles unspecialized.
"""
function doctype(doc::JSON.LazyValue)
    style = STACStyle()
    ret = StructUtils.applyeach(style, DocTypeSink(style), doc)
    ret isa StructUtils.EarlyReturn || _notyped()
    return ret.value::String
end

"""
    STAC.parse(bytes; extensions, geometry, metadata) -> Catalog | Collection | Item | ItemCollection
    STAC.parse(bytes, T::Type)
    STAC.parse(bytes, opts::ParseOptions)

A STAC document from JSON bytes, a `String`, or a `JSON.LazyValue` sub-document. The one-
argument form reads the document's `type` key and dispatches on it; passing `T` names the
target type instead and is inferable.

The keywords are [`ParseOptions`](@ref)'s.
"""
parse(bytes; kw...) = parse(bytes, ParseOptions(; kw...))

parse(bytes, ::Type{T}) where {T} = JSON.parse(bytes, T; style = STACStyle())

parse(bytes, opts::ParseOptions) = parse(JSON.lazy(bytes), opts)

function parse(doc::JSON.LazyValue, opts::ParseOptions)
    t = doctype(doc)
    style = STACStyle()
    if t == "Feature"
        return JSON.parse(doc, itemtype(opts); style)
    elseif t == "FeatureCollection"
        return JSON.parse(doc, itemcollectiontype(opts); style)
    elseif t == "Catalog"
        return JSON.parse(doc, catalogtype(opts); style)
    elseif t == "Collection"
        return JSON.parse(doc, collectiontype(opts); style)
    else
        _notstac(t)
    end
end

"""
    STAC.sethref(obj, href) -> obj

`obj` with its origin set to `href`. Only the outer struct is rebuilt; every field is shared
with the original.
"""
@generated function sethref(obj::T, href::Union{String,Nothing}) where {T<:STACObject}
    n = fieldcount(T)
    args = Any[i == n ? :href : :(getfield(obj, $i)) for i in 1:n]
    return Expr(:call, T, args...)
end

"""
    STAC.read(href; io = STAC.default_io(), extensions, geometry, metadata)
        -> Catalog | Collection | Item | ItemCollection

The STAC document at `href`, with its origin recorded so [`children`](@ref) and
[`items`](@ref) can resolve its relative links. `href` is a local path, an `https://` URL, or
anything else the `io` stack routes; a local path is made absolute first.

The document's `type` key selects the struct; the keywords are [`ParseOptions`](@ref)'s.

```julia
item = STAC.read("test/fixtures/stac-spec/extended-item.json")
item.id                             # "20201211_223832_CS2"
item.extensions.eo.cloud_cover      # 1.2
item.properties.datetime            # DateTime("2020-12-14T18:02:31.437")

cat = STAC.read("test/fixtures/static/self-contained/catalog.json")
[c.id for c in children(cat)]       # ["simple-collection", "empty-collection"]
```
"""
function read(href::AbstractString; io::AbstractIO = default_io(), kw...)
    origin = absolutehref(href)
    return sethref(parse(read(io, origin), ParseOptions(; kw...)), origin)
end
