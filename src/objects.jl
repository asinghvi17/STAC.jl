"""
    Band

One band description from a `bands` array. The spectral and statistical keys extensions add
(`eo:common_name`, `raster:scale`, …) stay in `metadata`.
"""
struct Band
    name::Union{String,Nothing}
    description::Union{String,Nothing}
    data_type::Union{String,Nothing}
    unit::Union{String,Nothing}
    metadata::Metadata
end

"""
    Provider

An organization that captured, produced, processed, or hosts the data. `roles` draws from
`licensor`, `producer`, `processor`, and `host`.
"""
struct Provider
    name::String
    description::Union{String,Nothing}
    roles::Union{Vector{String},Nothing}
    url::Union{String,Nothing}
    metadata::Metadata
end

"""
    Link

One entry of a STAC object's `links` array. `href` is kept exactly as the producer wrote it;
resolution against the owning object's origin happens at traversal time.

`method`, `headers`, `body`, and `merge` turn a link into a request template, which is how
STAC API pagination describes the next page. `headers` is a [`Metadata`](@ref) map, since a
header value is either a string or a list of strings.
"""
struct Link
    href::String
    rel::String
    type::Union{String,Nothing}
    title::Union{String,Nothing}
    method::Union{String,Nothing}
    headers::Union{Metadata,Nothing}
    body::Any
    merge::Union{Bool,Nothing}
    metadata::Metadata
end

"""
    Asset

A file that belongs to an [`Item`](@ref) or [`Collection`](@ref): where it lives (`href`),
what it is (`type`, `roles`, `bands`), and every other key the producer set (`metadata`).
"""
struct Asset
    href::String
    type::Union{String,Nothing}
    title::Union{String,Nothing}
    description::Union{String,Nothing}
    roles::Union{Vector{String},Nothing}
    bands::Union{Vector{Band},Nothing}
    metadata::Metadata
end

"""
    SpatialExtent

The `extent.spatial` of a [`Collection`](@ref): one overall bounding box followed by
optional finer boxes, each of 4 or 6 numbers in longitude/latitude order.
"""
struct SpatialExtent
    bbox::Vector{Vector{Float64}}
    metadata::Metadata
end

"""
    TemporalExtent

The `extent.temporal` of a [`Collection`](@ref): one overall interval followed by optional
finer intervals. Each interval is two values, and an open end is `nothing`.
"""
struct TemporalExtent
    interval::Vector{Vector{Union{DateTime,Nothing}}}
    metadata::Metadata
end

"""
    CollectionExtent

The space and time a [`Collection`](@ref) covers.
"""
struct CollectionExtent
    spatial::SpatialExtent
    temporal::TemporalExtent
    metadata::Metadata
end

"""
    Properties{M}

The common metadata of an [`Item`](@ref). Every field the STAC commons name has a typed
slot; keys from extensions with no struct and producer-specific keys land in `other`, whose
type `M` is [`Metadata`](@ref) or [`NoMetadata`](@ref).
"""
struct Properties{M}
    datetime::Union{DateTime,Nothing}
    start_datetime::Union{DateTime,Nothing}
    end_datetime::Union{DateTime,Nothing}
    created::Union{DateTime,Nothing}
    updated::Union{DateTime,Nothing}
    title::Union{String,Nothing}
    description::Union{String,Nothing}
    platform::Union{String,Nothing}
    instruments::Union{Vector{String},Nothing}
    constellation::Union{String,Nothing}
    mission::Union{String,Nothing}
    gsd::Union{Float64,Nothing}
    license::Union{String,Nothing}
    providers::Union{Vector{Provider},Nothing}
    keywords::Union{Vector{String},Nothing}
    bands::Union{Vector{Band},Nothing}
    other::M
end

"""
    Catalog{M}

A STAC Catalog: an id, a description, and the `links` that form the tree. `href` holds the
absolute location the document was read from, and is `nothing` for catalogs built in memory.
"""
struct Catalog{M}
    id::String
    stac_extensions::Union{Vector{String},Nothing}
    title::Union{String,Nothing}
    description::String
    links::Vector{Link}
    metadata::M
    href::Union{String,Nothing}
end

"""
    Collection{M}

A STAC Collection: a [`Catalog`](@ref) that also states what it covers (`extent`), under
what terms (`license`), and who made it (`providers`).
"""
struct Collection{M}
    id::String
    stac_extensions::Union{Vector{String},Nothing}
    title::Union{String,Nothing}
    description::String
    license::String
    extent::CollectionExtent
    keywords::Union{Vector{String},Nothing}
    providers::Union{Vector{Provider},Nothing}
    summaries::Union{Metadata,Nothing}
    assets::Union{OrderedDict{String,Asset},Nothing}
    links::Vector{Link}
    metadata::M
    href::Union{String,Nothing}
end

"""
    Item{E,G,M}

A STAC Item, and the type everything else in this package is built on. Three parse keywords
become the three parameters, so a vector of items has one element type.

| Parameter | Keyword | Holds |
|---|---|---|
| `E` | `extensions` | a `NamedTuple` keyed by extension prefix, e.g. `@NamedTuple{eo::Union{EO,Nothing}, proj::Union{Projection,Nothing}}` |
| `G` | `geometry` | the geometry types this catalog can produce, e.g. `Union{Nothing, GeoJSON.Polygon{2,Float64}, GeoJSON.MultiPolygon{2,Float64}}` |
| `M` | `metadata` | [`Metadata`](@ref) or [`NoMetadata`](@ref), for both the item's own tail and `properties.other` |

`stac_extensions` is the list of schema URIs the producer declared, which is what
[`STAC.declares`](@ref) answers from. It has a field of its own rather than a place in the
metadata tail so that `metadata = false` neither loses it on a write nor makes `declares`
report an extension the document does declare as absent.
"""
struct Item{E,G,M}
    id::String
    stac_extensions::Union{Vector{String},Nothing}
    geometry::G
    bbox::Union{Nothing,NTuple{4,Float64},NTuple{6,Float64}}
    properties::Properties{M}
    links::Vector{Link}
    assets::OrderedDict{String,Asset}
    collection::Union{String,Nothing}
    extensions::E
    metadata::M
    href::Union{String,Nothing}
end

"""
    ItemCollection{E,G,M}
    ItemCollection(features; links, numberMatched, numberReturned, metadata, href)

One page of a search, or any GeoJSON FeatureCollection of STAC items. `numberMatched` and
`numberReturned` are filled by the endpoints that report them.

The keyword form wraps a vector of items — `ItemCollection(items)` is a page of them and
nothing else. Each keyword defaults to what a hand-built collection carries:

| keyword | default |
| --- | --- |
| `links` | `Link[]` |
| `numberMatched` | `nothing`, since only the endpoint that ran the query knows the total |
| `numberReturned` | `length(features)` |
| `metadata` | the empty tail of `M`, so [`STAC.json`](@ref) writes no extra keys |
| `href` | `nothing` |
"""
struct ItemCollection{E,G,M}
    features::Vector{Item{E,G,M}}
    links::Vector{Link}
    numberMatched::Union{Int,Nothing}
    numberReturned::Union{Int,Nothing}
    metadata::M
    href::Union{String,Nothing}
end

function ItemCollection(features::AbstractVector{Item{E,G,M}}; links::Vector{Link} = Link[],
                        numberMatched::Union{Int,Nothing} = nothing,
                        numberReturned::Union{Int,Nothing} = length(features),
                        metadata::M = M(), href::Union{String,Nothing} = nothing) where {E,G,M}
    return ItemCollection{E,G,M}(features, links, numberMatched, numberReturned, metadata,
                                 href)
end

"""
    STAC.STACObject

The four document kinds [`STAC.read`](@ref) produces.
"""
const STACObject = Union{Catalog,Collection,Item,ItemCollection}

# Field-by-field comparison: two parses of the same bytes hold equal but distinct vectors,
# which Base's `===` fallback for immutable structs reports as unequal.
for T in (:Link, :Asset, :Band, :Provider, :SpatialExtent, :TemporalExtent,
          :CollectionExtent, :Properties, :Catalog, :Collection, :Item, :ItemCollection)
    @eval function Base.:(==)(a::$T, b::$T)
        typeof(a) === typeof(b) || return false
        for i in 1:fieldcount(typeof(a))
            isequal(getfield(a, i), getfield(b, i)) || return false
        end
        return true
    end
end
