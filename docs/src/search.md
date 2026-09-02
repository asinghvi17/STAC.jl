```@meta
CurrentModule = STAC
DocTestSetup = quote
    import STAC
    using Dates, Extents
end
```

# Searching

One function, two backends. [`search`](@ref) on a [`Client`](@ref) sends a STAC API item
search; [`search`](@ref) on a [`Catalog`](@ref) or [`Collection`](@ref) walks the tree and
filters in memory. Both return something that answers the same three calls:

| Call | Gives |
|---|---|
| iterating the search | one [`Item`](@ref) at a time, fetching pages as it reaches them |
| [`STAC.pages(s)`](@ref pages) | one [`ItemCollection`](@ref) per request |
| [`STAC.matched(s)`](@ref matched) | the total, or `nothing` where the endpoint publishes none |

Nothing is fetched until the result is iterated, so building a search costs no request.

## Opening an endpoint

A [`Client`](@ref) reads the landing page once and keeps three things from it: the root
catalog, the `conformsTo` list, and the [`STAC.HostDefaults`](@ref) recorded for that host.

```julia
import STAC
using Dates, Extents

client = STAC.Client("https://earth-search.aws.element84.com/v1")
# Client "https://earth-search.aws.element84.com/v1"
#   root        "earth-search-aws" — Earth Search by Element 84
#   conforms    14 classes
#   host        limit ≤ 499, default 100, reports numberMatched

STAC.conforms(client, "item-search")            # true
STAC.conforms(client, "item-search#filter")     # false: this endpoint has no CQL2

STAC.collections(client)   # every collection the `data` link lists, each with its own href
# 9-element Vector{STAC.Collection{STAC.Metadata}}: sentinel-2-l2a, landsat-c2-l2, naip, …
```

`import STAC` and `STAC.<name>` is how every example here is written: one spelling for
everything the package owns, exported or not.

`conforms` matches a short name against any version, since endpoints publish the same class
under `v1.0.0`, `v1.0.0-rc.2`, and the OGC URIs side by side. A full URI must match exactly.

A credentialed endpoint takes one keyword — see [Fetching and credentials](io.md):

```julia
client = STAC.Client("https://planetarycomputer.microsoft.com/api/stac/v1";
                     auth = STAC.PlanetaryComputerSAS())
```

## One search

```julia
s = STAC.search(client;
                collections = ["sentinel-2-l2a"],
                intersects  = Extent(X = (-123.0, -122.0), Y = (37.0, 38.0)),
                datetime    = (DateTime(2024, 6, 1), DateTime(2024, 6, 30)),
                limit       = 5)
# APIItemSearch POST https://earth-search.aws.element84.com/v1/search
#   body        {"collections":["sentinel-2-l2a"],"bbox":[-123.0,37.0,-122.0,38.0],"datetime":"2024-06-01T00:00:00Z/2024-06-30T00:00:00Z","limit":5}
#   items       Item{eo, proj, raster, sat, view, sci}
#   matched     one request away

STAC.matched(s)                     # 66, one request
first(s).id                         # "S2B_10SDF_20240627_0_L2A"
length(collect(Iterators.take(s, 7)))   # 7 items, which is two pages of 5
```

Printing a search shows the request it would make and makes none. The full keyword list is on
[`search`](@ref); the three that need care are below.

### `datetime`

A `Date` is read as the whole day, because four of the five endpoints probed reject a
date-only string. [`STAC.normalize_datetime`](@ref) is the function, and it is worth calling
directly when an endpoint disagrees with what was sent.

```jldoctest search
julia> STAC.normalize_datetime(DateTime(2024, 6, 1))
"2024-06-01T00:00:00Z"

julia> STAC.normalize_datetime(Date(2024, 6, 1))
"2024-06-01T00:00:00Z/2024-06-01T23:59:59.999Z"

julia> STAC.normalize_datetime((DateTime(2024, 6, 1), nothing))
"2024-06-01T00:00:00Z/.."

julia> STAC.normalize_datetime("2024-06-01/2024-06-30")     # a string goes as written
"2024-06-01/2024-06-30"
```

### `intersects`

One keyword carries both of the spec's spatial parameters, because sending both is a 400 at
every endpoint. Its type decides which one goes.

```jldoctest search
julia> STAC.classify(Extent(X = (-123, -122), Y = (37, 38)))
(:bbox, [-123.0, 37.0, -122.0, 38.0])

julia> STAC.classify((-123, 37, -122, 38))                  # four numbers, the same thing
(:bbox, [-123.0, 37.0, -122.0, 38.0])

julia> kind, geom = STAC.classify(STAC.read(joinpath(pkgdir(STAC), "test", "fixtures",
                                                     "hand", "antimeridian-catalog",
                                                     "mid", "greenwich.json")).geometry);

julia> kind, typeof(geom)
(:intersects, GeoJSON.Polygon{2, Float64})
```

A geometry from any GeoInterface package is accepted and rebuilt in `Float64`: GeoJSON.jl
reads positions as `Float32` by default, and a longitude rounded to seven digits searches a
different place than the caller asked for.

A [DE9IM.jl](https://github.com/JuliaGeo/DE9IM.jl) predicate — `Within(poly)`,
`Covers(extent)`, `Disjoint(poly)` — travels to the server as the `intersects` of the
geometry it wraps, and the exact predicate is then run over every page that comes back, on
the sphere. See [Spatial selection](spatial.md).

### `limit`

`limit` is clamped to the host's cap, so a request that would have been rejected is sent at
the largest size that works. Earth Search answers 500 with a 502 from its gateway, Planetary
Computer answers 1001 with a 400, and the spec's own ceiling is 10 000:

```jldoctest search
julia> STAC.host_defaults("https://earth-search.aws.element84.com/v1")
STAC.HostDefaults(499, 100, true, true)

julia> STAC.host_defaults("https://example.com/stac")   # STAC.GENERIC_HOST
STAC.HostDefaults(10000, 100, true, true)
```

Pass your own with `host =` to teach one call about an endpoint the table does not know.

## Paging

[`pages`](@ref) is the protocol every backend implements; iteration, `Iterators.take`, and
`collect` all derive from it. One element is one request.

```julia
page = first(STAC.pages(s))
# ItemCollection{eo, proj, raster, sat, view, sci} with 5 items of 66 matched
#   items       S2B_10SDF_20240627_0_L2A, S2B_10SEF_20240627_0_L2A, …
#   links       next, root
#   metadata    3 keys: "stac_version", "stac_extensions", "context"

page.numberMatched      # 66
page.numberReturned     # 5
STAC.nextlink(page)     # the whole request template for the page after this one
```

A `next` link is a request template rather than a URL: `method`, `headers`, `body`, and
`merge` all describe how to ask for the page after this one. Honouring all four is what makes
the same code page through every public endpoint, which fill the spec's gap three different
ways:

| Backend | Endpoints | `next` looks like |
|---|---|---|
| pgstac | Planetary Computer, CDSE, ITS_LIVE | a `POST` of the whole body plus a `token`, with no `merge` key |
| stac-server | Earth Search, LandsatLook | a `POST` with `merge: false` and a body of its own |
| CMR | LPCLOUD | a `GET` carrying `cursor=` |

[`matched`](@ref) costs one request and answers `nothing` on Planetary Computer and CDSE,
which publish `numberReturned` alone. Branch on `n === nothing` rather than comparing the
result — `STAC.matched(s) > 100` on those two endpoints is a `MethodError` a long way from
its cause. [`STAC.reportsmatched`](@ref) answers the same question before the request, and
printing a search says so on its `matched` line:

```julia
n = STAC.matched(s)
n === nothing ? "an unknown number of items" : string(n, " items")
```

[`STAC.numbermatched`](@ref) also reads the deprecated `context.matched` the CMR endpoints
still send.

## Failing at the call site

[`search`](@ref) checks its arguments against `conformsTo` before it builds anything, so a
request an endpoint cannot answer raises where it was written rather than 400ing pages later.

```julia
STAC.search(client; collections = ["sentinel-2-l2a"], filter = Dict("op" => "=", "args" => []))
# ERROR: https://earth-search.aws.element84.com/v1 does not advertise the conformance class
# `item-search#filter`, which `filter =` needs. Its landing page lists 14 classes.
```

| Argument | Class it needs |
|---|---|
| any search | `item-search` |
| `filter` | `item-search#filter` |
| `query` | `item-search#query` |
| `sortby` | `item-search#sort` |
| `fields` | `item-search#fields` |

## One collection at a time

[`STAC.collection`](@ref) reads one collection by id, and
[`STAC.items(client, collection)`](@ref items) is the `GET` twin of `STAC.search` against the
OGC API - Features endpoint the collection publishes. It takes the same spatial and temporal
keywords, minus the ones the path already fixes.

```julia
col = STAC.collection(client, "sentinel-2-l2a")
col.extent.spatial.bbox[1]                  # the collection's footprint
first(STAC.items(client, col)).id           # through /collections/sentinel-2-l2a/items
```

## Searching a catalog that is not an API

The same keywords work on a directory or on a plain web server. The walk, the filters, and
the spatial index run once, on the first page asked for, and the result is kept.

```jldoctest search
julia> edges = joinpath(pkgdir(STAC), "test", "fixtures", "hand", "antimeridian-catalog");

julia> cat = STAC.read(joinpath(edges, "catalog.json"));

julia> s = STAC.search(cat; collections = "edges",
                            intersects = Extent(X = (170, -170), Y = (60, 70)))
StaticItemSearch over Catalog "antimeridian"
  collections edges
  intersects  Extent(X = (170, -170), Y = (60, 70))
  limit       100
  matched     not run yet

julia> STAC.matched(s)  # exact here: the filtered set is in memory
1

julia> first(s).id
"straddle"
```

Two things differ from the API backend, and both follow from the filtering being local:

- `STAC.matched` is exact, and after a `collect` it costs nothing.
- `intersects` also accepts a `SphericalCap`, which no endpoint takes as a request parameter.

`limit` still pages, with the spec's default of 100, so `STAC.pages`, `Iterators.take`, and
`collect` behave the same on both backends.
