"""
    Band

One band description from an [`Asset`](@ref)'s or [`Item`](@ref)'s `bands` array. The
spectral and statistical keys extensions add (`eo:common_name`, `raster:scale`, …) stay in
`metadata`, where `get(band, EO)` reads them from.

$(FIELDS)
"""
struct Band
    """
    The name of the band (`"B01"`, `"band2"`, `"red"`), unique across the bands of the
    object that lists it.
    """
    name::Union{String,Nothing}
    """
    A description that fully explains the band, in CommonMark.
    """
    description::Union{String,Nothing}
    """
    The data type of the band's values, spelled as the raster data types are: `"uint8"`,
    `"int16"`, `"float32"`, `"cfloat64"`, and the rest.
    """
    data_type::Union{String,Nothing}
    """
    The unit of measurement of the values, preferably a UDUNITS-2 unit.
    """
    unit::Union{String,Nothing}
    """
    The keys of this band that no field above names, in document order.
    """
    metadata::Metadata
end

"""
    Provider

An organization that captured, produced, processed, or hosts the data.

$(FIELDS)
"""
struct Provider
    """
    The name of the organization or the individual.
    """
    name::String
    """
    Further provider information, in CommonMark: processing details for a processor or
    producer, hosting details for a host, contact information for anyone.
    """
    description::Union{String,Nothing}
    """
    What the provider did, drawn from `"licensor"`, `"producer"`, `"processor"`, and
    `"host"`. The last element is the one that supplied the data at this location.
    """
    roles::Union{Vector{String},Nothing}
    """
    The homepage on which the provider describes the dataset and publishes contact
    information.
    """
    url::Union{String,Nothing}
    """
    The keys of this provider that no field above names, in document order.
    """
    metadata::Metadata
end

"""
    Link

One entry of a STAC object's `links` array. `href` is kept exactly as the producer wrote it;
resolution against the owning object's origin happens at traversal time, in
[`STAC.resolve`](@ref).

`method`, `headers`, `body`, and `merge` turn a link into a request template, which is how
STAC API pagination describes the next page.

$(FIELDS)
"""
struct Link
    """
    The link itself, either absolute or relative to the document that carries it. A trailing
    slash is significant.
    """
    href::String
    """
    The relationship between the linked document and this one: `"self"`, `"root"`,
    `"parent"`, `"child"`, `"item"`, `"next"`, and whatever else the producer uses.
    """
    rel::String
    """
    The media type of the linked document.
    """
    type::Union{String,Nothing}
    """
    A human readable title for the link, for rendered displays of it.
    """
    title::Union{String,Nothing}
    """
    The HTTP method the next request uses, `"GET"` or `"POST"`; `nothing` means `"GET"`.
    """
    method::Union{String,Nothing}
    """
    The headers to send with the request, as a [`Metadata`](@ref) map, since a header value
    is either a string or a list of strings.
    """
    headers::Union{Metadata,Nothing}
    """
    The body to send with a `POST`, as the parsed JSON value.
    """
    body::Any
    """
    Whether the body merges into the original request body (`true`) or replaces it
    (`false`, the default a `nothing` stands for).
    """
    merge::Union{Bool,Nothing}
    """
    The keys of this link that no field above names, in document order.
    """
    metadata::Metadata
end

"""
    Asset

A file that belongs to an [`Item`](@ref) or [`Collection`](@ref): where it lives (`href`),
what it is (`type`, `roles`, `bands`), and every other key the producer set (`metadata`).

$(FIELDS)
"""
struct Asset
    """
    The URI of the file, either absolute or relative to the document that carries it.
    """
    href::String
    """
    The media type of the file, which is what picks the driver that opens it.
    """
    type::Union{String,Nothing}
    """
    The displayed title, for clients and users.
    """
    title::Union{String,Nothing}
    """
    A description of the asset in CommonMark, giving details such as how it was processed or
    created.
    """
    description::Union{String,Nothing}
    """
    The semantic roles of the asset — `"thumbnail"`, `"overview"`, `"data"`, `"metadata"` —
    used as `rel` is on a link.
    """
    roles::Union{Vector{String},Nothing}
    """
    The bands the file holds, one [`Band`](@ref) each, in file order.
    """
    bands::Union{Vector{Band},Nothing}
    """
    The keys of this asset that no field above names, in document order. Common metadata
    that overrides the item's (`datetime`, `gsd`, `platform`) and extension keys
    (`eo:cloud_cover`, `proj:code`) both land here.
    """
    metadata::Metadata
end

"""
    SpatialExtent

Where a [`Collection`](@ref) has data.

$(FIELDS)
"""
struct SpatialExtent
    """
    The bounding boxes the collection covers, each of 4 numbers
    (`[west, south, east, north]`) or 6 (`[west, south, min elevation, east, north,
    max elevation]`) in WGS 84. The first box is the overall extent; any that follow describe
    it more precisely. A box that crosses the antimeridian has a `west` greater than its
    `east`.
    """
    bbox::Vector{Vector{Float64}}
    """
    The keys of this extent that no field above names, in document order.
    """
    metadata::Metadata
end

"""
    TemporalExtent

When a [`Collection`](@ref) has data.

$(FIELDS)
"""
struct TemporalExtent
    """
    The intervals the collection covers, each of two instants in UTC. The first interval is
    the overall extent; any that follow describe it more precisely. An open end is
    `nothing`.
    """
    interval::Vector{Vector{Union{DateTime,Nothing}}}
    """
    The keys of this extent that no field above names, in document order.
    """
    metadata::Metadata
end

"""
    CollectionExtent

The space and time a [`Collection`](@ref) covers.

$(FIELDS)
"""
struct CollectionExtent
    """
    Where the collection has data.
    """
    spatial::SpatialExtent
    """
    When the collection has data.
    """
    temporal::TemporalExtent
    """
    The keys of this extent that no field above names, in document order.
    """
    metadata::Metadata
end

"""
    Properties{M}

The common metadata of an [`Item`](@ref): the `properties` object, with a typed slot for
every field the STAC common metadata names. Keys from extensions with no struct and
producer-specific keys land in `other`, whose type `M` is [`Metadata`](@ref) or
[`NoMetadata`](@ref).

$(FIELDS)
"""
struct Properties{M}
    """
    The searchable instant of the item's assets, in UTC. `nothing` says the item covers a
    span instead, which `start_datetime` and `end_datetime` give.
    """
    datetime::Union{DateTime,Nothing}
    """
    The first instant of the span the item covers, in UTC.
    """
    start_datetime::Union{DateTime,Nothing}
    """
    The last instant of the span the item covers, in UTC.
    """
    end_datetime::Union{DateTime,Nothing}
    """
    When the metadata was created, in UTC.
    """
    created::Union{DateTime,Nothing}
    """
    When the metadata was last updated, in UTC.
    """
    updated::Union{DateTime,Nothing}
    """
    A human-readable one-line title for the item.
    """
    title::Union{String,Nothing}
    """
    A description of the item in CommonMark, long enough to fully explain it.
    """
    description::Union{String,Nothing}
    """
    The name of the specific platform the instrument rides on, such as `"landsat-8"`.
    """
    platform::Union{String,Nothing}
    """
    The instruments or sensors the data came from, such as `["oli", "tirs"]`.
    """
    instruments::Union{Vector{String},Nothing}
    """
    The constellation the platform belongs to, such as `"sentinel-2"`.
    """
    constellation::Union{String,Nothing}
    """
    The mission the data was collected for.
    """
    mission::Union{String,Nothing}
    """
    The ground sample distance at the sensor, in metres, greater than zero.
    """
    gsd::Union{Float64,Nothing}
    """
    The license of the data, as an SPDX identifier, an SPDX expression, or `"other"`.
    """
    license::Union{String,Nothing}
    """
    The organizations that captured, produced, processed, or host the data, in that order.
    """
    providers::Union{Vector{Provider},Nothing}
    """
    Keywords describing the item.
    """
    keywords::Union{Vector{String},Nothing}
    """
    The bands the item's assets hold, one [`Band`](@ref) each.
    """
    bands::Union{Vector{Band},Nothing}
    """
    The property keys that no field above names, in document order: extension keys with no
    eager slot, and everything the producer invented.
    """
    other::M
end

"""
    Catalog{M}

A STAC Catalog: an id, a description, and the `links` that form the tree. `M` is
[`Metadata`](@ref) or [`NoMetadata`](@ref), and says whether the parse kept the keys no field
names.

$(FIELDS)
"""
struct Catalog{M}
    """
    The identifier of the catalog.
    """
    id::String
    """
    The schema URIs of the extensions the catalog declares, which is what
    [`STAC.declares`](@ref) answers from.
    """
    stac_extensions::Union{Vector{String},Nothing}
    """
    A short descriptive one-line title for the catalog.
    """
    title::Union{String,Nothing}
    """
    A description of the catalog in CommonMark, long enough to fully explain it.
    """
    description::String
    """
    The references to other documents: the `child` and `item` links a traversal walks, and
    the `self`, `root`, and `parent` links that place this one.
    """
    links::Vector{Link}
    """
    The top-level keys that no field above names, in document order, `stac_version` among
    them.
    """
    metadata::M
    """
    The absolute location the document was read from, which every relative link resolves
    against. A catalog built in memory has `nothing`.
    """
    href::Union{String,Nothing}
end

"""
    Collection{M}

A STAC Collection: a [`Catalog`](@ref) that also states what it covers (`extent`), under
what terms (`license`), and who made it (`providers`).

$(FIELDS)
"""
struct Collection{M}
    """
    The identifier of the collection, unique within the catalog that holds it, and what
    [`STAC.collection`](@ref) and a search's `collections` filter name.
    """
    id::String
    """
    The schema URIs of the extensions the collection declares, which is what
    [`STAC.declares`](@ref) answers from.
    """
    stac_extensions::Union{Vector{String},Nothing}
    """
    A short descriptive one-line title for the collection.
    """
    title::Union{String,Nothing}
    """
    A description of the collection in CommonMark, long enough to fully explain it.
    """
    description::String
    """
    The license of the data, as an SPDX identifier, an SPDX expression, or `"other"`.
    """
    license::String
    """
    The space and time the collection covers.
    """
    extent::CollectionExtent
    """
    Keywords describing the collection.
    """
    keywords::Union{Vector{String},Nothing}
    """
    The organizations that captured, produced, processed, or host the data, in that order.
    """
    providers::Union{Vector{Provider},Nothing}
    """
    What the collection's items hold, one entry per property: a set of values, a range, or a
    JSON Schema. Producers use it to drive faceted search interfaces.
    """
    summaries::Union{Metadata,Nothing}
    """
    The files that belong to the collection as a whole — an overview thumbnail, a license
    document — keyed as the producer keyed them.
    """
    assets::Union{OrderedDict{String,Asset},Nothing}
    """
    The references to other documents: the `child` and `item` links a traversal walks, and
    the `self`, `root`, and `parent` links that place this one.
    """
    links::Vector{Link}
    """
    The top-level keys that no field above names, in document order, `stac_version` and
    `item_assets` among them.
    """
    metadata::M
    """
    The absolute location the document was read from, which every relative link resolves
    against. A collection built in memory has `nothing`.
    """
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

$(FIELDS)
"""
struct Item{E,G,M}
    """
    The provider's identifier for the item, unique within the collection that holds it.
    """
    id::String
    """
    The schema URIs of the extensions the item declares, which is what
    [`STAC.declares`](@ref) answers from. It has a field of its own rather than a place in
    the metadata tail so that `metadata = false` neither loses it on a write nor makes
    `declares` report an extension the document does declare as absent.
    """
    stac_extensions::Union{Vector{String},Nothing}
    """
    The footprint of the item's assets in WGS 84 longitude/latitude, as the GeoJSON.jl
    geometry `G` names. An item that states no location has `nothing`, and the STAC API's
    spatial filters skip it.
    """
    geometry::G
    """
    The bounding box of the footprint, 4 numbers (`(west, south, east, north)`) or 6
    (`(west, south, min elevation, east, north, max elevation)`). It is `nothing` exactly
    when `geometry` is.
    """
    bbox::Union{Nothing,NTuple{4,Float64},NTuple{6,Float64}}
    """
    The item's common metadata, and the tail of property keys no field of it names.
    """
    properties::Properties{M}
    """
    The references to other documents: the `collection`, `parent`, and `root` links a
    traversal walks up, and the `self` link that places this one.
    """
    links::Vector{Link}
    """
    The files the item describes, keyed as the producer keyed them (`"B01"`, `"visual"`,
    `"thumbnail"`), in document order.
    """
    assets::OrderedDict{String,Asset}
    """
    The id of the [`Collection`](@ref) the item belongs to, which the `collection` link
    points at.
    """
    collection::Union{String,Nothing}
    """
    The extensions parsed eagerly into fields, one per prefix the `extensions` keyword
    named: `item.extensions.eo.cloud_cover` is a concrete field read. An extension whose
    keys the item carries none of reports `nothing`.
    """
    extensions::E
    """
    The top-level keys that no field above names, in document order, `stac_version` among
    them. An item's *extension* keys sit one level down, in `properties.other`.
    """
    metadata::M
    """
    The absolute location the document was read from, which every relative link and asset
    href resolves against. An item built in memory has `nothing`.
    """
    href::Union{String,Nothing}
end

"""
    ItemCollection{E,G,M}
    ItemCollection(features; links, numberMatched, numberReturned, metadata, href)

One page of a search, or any GeoJSON FeatureCollection of STAC items.

The keyword form wraps a vector of items — `ItemCollection(items)` is a page of them and
nothing else. Each keyword defaults to what a hand-built collection carries:

| keyword | default |
| --- | --- |
| `links` | `Link[]` |
| `numberMatched` | `nothing`, since only the endpoint that ran the query knows the total |
| `numberReturned` | `length(features)` |
| `metadata` | the empty tail of `M`, so [`STAC.json`](@ref) writes no extra keys |
| `href` | `nothing` |

$(FIELDS)
"""
struct ItemCollection{E,G,M}
    """
    The items on this page, in the order the producer returned them.
    """
    features::Vector{Item{E,G,M}}
    """
    The references related to the page, `next` among them, which is how
    [`STAC.pages`](@ref) asks for the one after it.
    """
    links::Vector{Link}
    """
    How many items met the search parameters, over every page, as the endpoint counted or
    estimated them. Endpoints that decline to count report `nothing`.
    """
    numberMatched::Union{Int,Nothing}
    """
    How many items this page holds.
    """
    numberReturned::Union{Int,Nothing}
    """
    The top-level keys that no field above names, in document order.
    """
    metadata::M
    """
    The absolute location the page was read from, which every relative link resolves
    against. A page built in memory has `nothing`.
    """
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

# ---------------------------------------------------------------------------------------
# Equality and hashing

"""
    STAC.ComparedByFields

The object types that compare field by field: everything a parse builds. They hold vectors
and dictionaries, which Base's `===` fallback for immutable structs reports as unequal across
two parses of the same bytes.
"""
const ComparedByFields = Union{Link,Asset,Band,Provider,SpatialExtent,TemporalExtent,
                               CollectionExtent,Properties,Catalog,Collection,Item,
                               ItemCollection}

"""
    STAC.fieldsequal(a::T, b::T) -> Bool
    STAC.fieldsisequal(a::T, b::T) -> Bool
    STAC.fieldshash(x, h::UInt) -> UInt

Field-by-field `==`, `isequal`, and `hash` for an immutable struct, unrolled over its fields
at compile time: `getfield(x, i)` over a runtime `i` infers as `Any` and boxes every field.

The three keep the semantics their names promise, which for a struct holding `Float64` fields
means `==` and `isequal` part ways on `NaN`, exactly as they do on the numbers themselves:

| `x` | `x == x` | `isequal(x, x)` |
|---|---|---|
| an item whose `bbox` is finite | `true` | `true` |
| an item whose `bbox` holds a `NaN` | `false` | `true` |

`isequal` and `fieldshash` agree, so an object is usable as a `Dict` key and `unique` over a
vector of them means what it says.
"""
@generated function fieldsequal(a::T, b::T) where {T}
    expr = :(true)
    for i in fieldcount(T):-1:1
        expr = :(getfield(a, $i) == getfield(b, $i) && $expr)
    end
    return expr
end

@generated function fieldsisequal(a::T, b::T) where {T}
    expr = :(true)
    for i in fieldcount(T):-1:1
        expr = :(isequal(getfield(a, $i), getfield(b, $i)) && $expr)
    end
    return expr
end

@generated function fieldshash(x::T, h::UInt) where {T}
    expr = :(hash($T, h))
    for i in 1:fieldcount(T)
        expr = :(fieldhash(getfield(x, $i), $expr))
    end
    return expr
end

# GeoJSON compares two geometries by their type and coordinates and defines no `hash`, so
# Base's identity fallback gives two equal footprints different hashes.
fieldhash(g::GeoJSON.AbstractGeometry, h::UInt) =
    hash(GeoJSON.coordinates(g), hash(typeof(g), h))
fieldhash(x, h::UInt) = hash(x, h)

# `T` in two covariant slots is restricted to concrete types by the diagonal rule, so
# `Item{Any,G,M} == Item{E,G,M}` matches no method here and falls through to Base's `===`.
Base.:(==)(a::T, b::T) where {T<:ComparedByFields} = fieldsequal(a, b)
Base.isequal(a::T, b::T) where {T<:ComparedByFields} = fieldsisequal(a, b)
Base.hash(x::ComparedByFields, h::UInt) = fieldshash(x, h)
