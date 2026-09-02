```@meta
CurrentModule = STAC
DocTestSetup = quote
    using STAC
end
```

# Reading a catalog

[`STAC.read`](@ref) is the one entry point. It takes a local path, an `https://` URL, or any
href the [IO stack](io.md) has a route for, reads the document's `type` key, and builds the
struct that key names.

| `type` | Struct | Is |
|---|---|---|
| `"Catalog"` | [`Catalog`](@ref) | an id, a description, and the links that form a tree |
| `"Collection"` | [`Collection`](@ref) | a catalog that also states its extent, license, and providers |
| `"Feature"` | [`Item`](@ref) | one scene: a footprint, an instant, and the files that hold it |
| `"FeatureCollection"` | [`ItemCollection`](@ref) | a page of items |

The examples on this page read the catalog the package ships under `test/fixtures/static/`,
so they run with nothing fetched.

```jldoctest objects
julia> examples = joinpath(pkgdir(STAC), "test", "fixtures", "static", "self-contained");

julia> cat = STAC.read(joinpath(examples, "catalog.json"))
Catalog "examples" — Example Catalog
  links       root, child ×2, item
  metadata    1 key: "stac_version"

julia> cat.id
"examples"
```

## Where the fields are

Every field the spec names is a field on the struct. `?STAC.Item` in the REPL prints one line
per field; the summary is:

| On an [`Item`](@ref) | Holds |
|---|---|
| `id`, `collection`, `stac_extensions` | the identifiers |
| `geometry` | the footprint, a `Float64` GeoJSON.jl geometry in longitude/latitude |
| `bbox` | the same footprint as 4 or 6 numbers |
| `properties` | [`Properties`](@ref): `datetime`, `platform`, `gsd`, and the rest of common metadata |
| `properties.other` | the property keys no field names — extension keys and the producer's own |
| `links` | [`Link`](@ref)s, hrefs kept exactly as the producer wrote them |
| `assets` | [`Asset`](@ref)s, keyed as the producer keyed them |
| `extensions` | the extensions parsed into fields; see [Extensions](extensions.md) |
| `metadata` | the top-level keys no field names, `stac_version` among them |
| `href` | where the document was read from |

```jldoctest objects
julia> item = STAC.read(joinpath(examples, "simple-collection", "extended-item.json"));

julia> item.id, item.collection
("extended-item", "simple-collection")

julia> item.properties.datetime
2020-12-14T18:02:31.437

julia> item.properties.platform, item.properties.gsd
("cool_sat2", 0.66)

julia> keys(item.assets)
KeySet for a OrderedCollections.OrderedDict{String, Asset} with 6 entries. Keys:
  "analytic"
  "thumbnail"
  "visual"
  "udm"
  "json-metadata"
  "ephemeris"

julia> item.assets["visual"].type
"image/tiff; application=geotiff; profile=cloud-optimized"
```

A [`Collection`](@ref) adds what it covers, under what terms, and who made it:

```jldoctest objects
julia> col = STAC.read(joinpath(examples, "simple-collection", "collection.json"))
Collection "simple-collection" — Simple Example Collection
  extent      bbox (172.9117, 1.3439, 172.9547, 1.369)  2020-12-11T22:38:32.125Z … 2020-12-14T18:02:31.437Z
  license     CC-BY-4.0
  links       root, parent, item ×3
  metadata    1 key: "stac_version"

julia> col.extent.spatial.bbox[1]
4-element Vector{Float64}:
 172.91173669923782
   1.3438851951615003
 172.95469614953714
   1.3690476620161975

julia> [p.name for p in col.providers]
1-element Vector{String}:
 "Remote Data, Inc"
```

### The metadata tail

Keys the spec does not name are kept in document order rather than dropped, so a document
reads in and writes back out with the same keys. [`Metadata`](@ref) is where they land, and it
answers the `AbstractDict` interface:

```jldoctest objects
julia> collect(keys(item.metadata))
1-element Vector{String}:
 "stac_version"

julia> collect(keys(item.properties.other))
6-element Vector{String}:
 "statistics"
 "rd:type"
 "rd:anomalous_pixels"
 "rd:earth_sun_distance"
 "rd:sat_id"
 "rd:product_level"

julia> item.properties.other["rd:sat_id"]
"cool_sat2"

julia> get(item.properties.other, "not:a-key", nothing) === nothing
true
```

`rd:` is the Remote Data extension, which this package ships no struct for. Its keys are on
the tail, they round-trip through [`STAC.json`](@ref), and a struct of your own turns them
into fields — see [Extensions](extensions.md).

## Walking the tree

[`children`](@ref), [`items`](@ref), [`parent`](@ref STAC.parent), and [`STAC.root`](@ref)
are lazy iterators over `rel`-filtered links. Nothing is fetched until an element is reached,
so `length` costs no request and `first` costs exactly one.

```jldoctest objects
julia> length(children(cat))            # from the link count, before any request
2

julia> [c.id for c in children(cat)]
2-element Vector{String}:
 "simple-collection"
 "empty-collection"

julia> [i.id for i in items(cat)]       # the catalog's own `item` links
1-element Vector{String}:
 "collectionless-item"

julia> [i.id for i in items(cat; recursive = true)]   # and every descendant's
4-element Vector{String}:
 "collectionless-item"
 "simple-item"
 "core-item"
 "extended-item"

julia> parent(col).id, STAC.root(col).id
("examples", "examples")
```

A relative href resolves against the origin of the object whose `links` it came from, per
RFC 3986, which is what makes the spec's publishing layouts read the same way. Two of the
three are local trees and read from a path:

```jldoctest objects
julia> layouts = joinpath(pkgdir(STAC), "test", "fixtures", "static");

julia> [length(collect(items(STAC.read(joinpath(layouts, l, "catalog.json")); recursive = true)))
        for l in ("self-contained", "relative-published")]
2-element Vector{Int64}:
 4
 4
```

The third, `absolute-published`, states every link as a URL on the host it will be served
from, so reading it from a path reaches for the network. That is the layout's point, and
[Bulk formats](formats.md) is where the three are written.

Links keep the href exactly as written, so a catalog read from disk can be re-rooted or
written back verbatim. [`STAC.resolve`](@ref) is the function that makes one absolute, and
[`STAC.selfhref`](@ref) reads the absolute `self` link an object publishes.

## What the parse produces

Three keywords fix the concrete types a read produces, and they are the three type parameters
of [`Item`](@ref). They travel together as [`ParseOptions`](@ref), and they reach
[`children`](@ref), [`items`](@ref), and [`search`](@ref) as well, so one walk produces one
element type all the way down.

| Keyword | Default | Choose another when |
|---|---|---|
| `extensions` | the six shipped structs | you have your own extension, or want none parsed eagerly ([Extensions](extensions.md)) |
| `geometry` | `Polygon`, `MultiPolygon`, or `nothing` | the catalog holds points or lines: `geometry = STAC.ANY_GEOMETRY` |
| `metadata` | `true` | the unnamed keys are not worth keeping: `metadata = false` |

```jldoctest objects
julia> bare = STAC.read(joinpath(examples, "simple-collection", "core-item.json");
                        extensions = (), metadata = false);

julia> typeof(bare).parameters[1], typeof(bare).parameters[3]
(Any, NoMetadata)

julia> isempty(bare.metadata)
true
```

`Item{Any}` is the exploration form: nothing is parsed eagerly, and every prefixed key stays
in `properties.other` where [`get`](@ref) still finds it.

## Writing a document back

[`STAC.json`](@ref) is the inverse of the parse. `type` and `stac_version` are put back,
extensions are written under their prefixes inside `properties`, and every tail key returns
where the producer put it.

```jldoctest objects
julia> back = STAC.parse(STAC.json(item));

julia> back.id == item.id && back.properties.datetime == item.properties.datetime
true

julia> back.properties.other["rd:sat_id"]
"cool_sat2"

julia> STAC.json(item; pretty = 2)[1:38]
"{\n  \"type\": \"Feature\",\n  \"stac_version"
```

[`STAC.write`](@ref) writes one document to a path ending in `.json` and a whole tree to any
other path; see [Bulk formats](formats.md).

## When something is missing

Every failure raises a [`STAC.STACError`](@ref), so one `catch` clause covers the package, and
the exception carries the values its message names as fields rather than only in text.

```jldoctest objects
julia> STAC.asset(item, "B04")
ERROR: this item has no asset named "B04"; it has analytic, thumbnail, visual, udm, json-metadata, ephemeris
[...]

julia> STAC.parse("{\"type\": \"Banana\"}")
ERROR: not a STAC document: `type` is "Banana", expected "Feature", "FeatureCollection", "Catalog", or "Collection"
[...]
```

The four groups under [`STAC.STACError`](@ref) — [`STAC.DocumentError`](@ref),
[`STAC.LookupError`](@ref), [`STAC.ArgumentShapeError`](@ref), and
[`STAC.EndpointError`](@ref) — say which kind of thing went wrong without naming the
concrete type.
