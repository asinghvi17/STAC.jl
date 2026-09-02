"""
    STAC.DEFAULT_EXTENSIONS

The extension structs parsed eagerly when a caller names none.
"""
const DEFAULT_EXTENSIONS = (EO, Projection)

"""
    STAC.DEFAULT_GEOMETRY

The geometry types an item can hold when a caller names none: the two STAC item geometries
that occur in practice, in `Float64` longitude/latitude, plus `nothing` for the items whose
footprint is unknown.
"""
const DEFAULT_GEOMETRY =
    Union{Nothing,GeoJSON.Polygon{2,Float64},GeoJSON.MultiPolygon{2,Float64}}

"""
    STAC.STAC_VERSION

The `stac_version` written on objects whose tail carries none.
"""
const STAC_VERSION = "1.1.0"

metadatatype(keep::Bool) = keep ? Metadata : NoMetadata
metadatatype(::Type{M}) where {M} = M

"""
    ParseOptions(; extensions = DEFAULT_EXTENSIONS, geometry = DEFAULT_GEOMETRY, metadata = true)

The three choices that fix the concrete types a parse produces, carried as type parameters so
[`STAC.itemtype`](@ref) is known at compile time.

| Keyword | Accepts | Becomes |
|---|---|---|
| `extensions` | a tuple of [`STAC.Extension`](@ref) structs; `()` for none | `E` |
| `geometry` | a geometry type or a union of them | `G` |
| `metadata` | `true` to keep unnamed keys, `false` to skip them | `M` |
"""
struct ParseOptions{E,G,M} end

ParseOptions(; extensions = DEFAULT_EXTENSIONS, geometry = DEFAULT_GEOMETRY, metadata = true) =
    ParseOptions{extensiontype(extensions),geometry,metadatatype(metadata)}()

# Each of these takes the options either as a value or as their type, so a container
# parametrised on `ParseOptions` (an item search) can name its element type from `O` alone.
"""
    STAC.itemtype(opts::ParseOptions) -> Type{<:Item}

The `Item{E,G,M}` these options name.
"""
itemtype(::Type{ParseOptions{E,G,M}}) where {E,G,M} = Item{E,G,M}

"""
    STAC.itemcollectiontype(opts::ParseOptions) -> Type{<:ItemCollection}

The `ItemCollection{E,G,M}` these options name.
"""
itemcollectiontype(::Type{ParseOptions{E,G,M}}) where {E,G,M} = ItemCollection{E,G,M}

"""
    STAC.catalogtype(opts::ParseOptions) -> Type{<:Catalog}

The `Catalog{M}` these options name.
"""
catalogtype(::Type{ParseOptions{E,G,M}}) where {E,G,M} = Catalog{M}

"""
    STAC.collectiontype(opts::ParseOptions) -> Type{<:Collection}

The `Collection{M}` these options name.
"""
collectiontype(::Type{ParseOptions{E,G,M}}) where {E,G,M} = Collection{M}

"""
    STAC.childtype(opts::ParseOptions) -> Type

What a `child`, `parent`, or `root` link resolves to: `Union{Catalog{M}, Collection{M}}`,
narrowed to one of the two by the document's own `type` key.
"""
childtype(::Type{ParseOptions{E,G,M}}) where {E,G,M} = Union{Catalog{M},Collection{M}}

for f in (:itemtype, :itemcollectiontype, :catalogtype, :collectiontype, :childtype)
    @eval $f(opts::ParseOptions) = $f(typeof(opts))
end
