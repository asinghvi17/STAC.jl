# STAC.jl

[![Documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://asinghvi17.github.io/STAC.jl/dev)
[![CI](https://github.com/asinghvi17/STAC.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/asinghvi17/STAC.jl/actions/workflows/CI.yml)

A typed Julia client for [SpatioTemporal Asset Catalogs](https://stacspec.org). A catalog URL,
a local directory, an `s3://` path, or a STAC API endpoint becomes `Catalog`, `Collection`,
and `Item` values that behave as GeoInterface features, answer one set of search keywords,
index and query on the sphere, and open as Rasters.

```julia
julia> using Pkg; Pkg.add("STAC")
```

## Quickstart

Five things the package is for. Every block runs as written; the ones that talk to
[Earth Search](https://earth-search.aws.element84.com/v1) need a network connection and no
credentials.

### 1. Search a STAC API

The same keywords work on every endpoint, and paging follows each one's `next` link
whichever of the three shapes it takes.

```julia
using STAC, Extents, Dates

client = Client("https://earth-search.aws.element84.com/v1")

s = search(client;
           collections = ["sentinel-2-l2a"],
           intersects  = Extent(X = (-123.0, -122.0), Y = (37.0, 38.0)),   # lon/lat
           datetime    = (DateTime(2024, 6, 1), DateTime(2024, 6, 30)),
           query       = Dict("eo:cloud_cover" => Dict("lt" => 10)),
           limit       = 20)

matched(s)          # 28: the endpoint's own count, one request
found = collect(s)  # 28 items, over the two pages that takes

found[1]
# Item{eo, proj, raster, sat, view, sci} "S2B_10SDF_20240627_0_L2A" 2024-06-27
#   datetime    2024-06-27T19:04:31.210Z
#   collection  sentinel-2-l2a
#   geometry    Polygon{2, Float64} (5 vertices), bbox (-124.0333, 36.0523, -122.8903, 37.0465)
#   assets      aot, blue, coastal, granule_metadata, … (35)
#   extensions  eo (cloud_cover = 0.000567)  proj (epsg = 32610)  view (sun_azimuth = 125.208652176, sun_elevation = 69.4543113286947)
#   metadata    1 key: "stac_version"

found[1].extensions.eo.cloud_cover      # 0.000567, a Float64 field read
```

`search` checks its arguments against the endpoint's `conformsTo` before sending anything, so
a `filter` an endpoint cannot answer raises at the call site rather than 400ing pages later.

### 2. Walk a static catalog with the same keywords

`STAC.read` takes a local path, an `https://` URL, or an `S3Path`, and `search` on what comes
back takes the keywords the API search takes. This one reads the catalog that ships with the
package.

```julia
using STAC

examples = joinpath(pkgdir(STAC), "test", "fixtures", "static", "self-contained")
cat = STAC.read(joinpath(examples, "catalog.json"))

[c.id for c in children(cat)]                       # ["simple-collection", "empty-collection"]
its = collect(items(cat; recursive = true))         # 4 items, one request per document

matched(search(cat; collections = "simple-collection"))     # 3
```

### 3. Items are features and tables

An `Item` is a GeoInterface feature with a `Float64` longitude/latitude geometry; a vector of
them is a feature collection and a Tables.jl table. That is the whole integration story with
GeometryOps, Makie, GeoDataFrames, and DataFrames.

```julia
using GeoInterface, Extents, DataFrames

GeoInterface.geometry(found[1])     # GeoJSON.Polygon{2, Float64}, the item's footprint
Extents.extent(found[1])            # Extent(X = (west, east), Y = (south, north)), from the bbox

df = DataFrame(found)               # 28 rows, 81 columns: properties and extensions lifted out
df[!, ["id", "datetime", "eo:cloud_cover"]]
```

### 4. Select on the sphere

The index is a GeometryOps R-tree built on the unit sphere by default, so a box that crosses
the antimeridian is one box and a footprint over a pole prunes correctly. `Planar()` is the
opt-in for a region well away from both.

```julia
using DE9IM, Extents

idx  = spatialindex(found)                                  # RTree on Spherical()
hits = STAC.query(idx, Extent(X = (-122.6, -122.3), Y = (37.7, 37.9)))
sel  = found[hits]

# A DE-9IM predicate adds an exact second pass over the survivors, on the sphere.
STAC.query(idx, Within(GeoInterface.geometry(found[1])))
```

### 5. Open the assets as rasters

Each asset is routed to a backend by its media type first and its href's scheme second, and
the credentials the catalog was opened with reach GDAL around every read.

```julia
using Rasters, ArchGDAL

red = Raster(client, STAC.asset(found[1], "red"); lazy = true)
size(red)                                       # (10980, 10980)
red[3000:3002, 3000:3002]                       # one window, one range request

st = RasterStack(found[1], ["red", "green", "blue"]; io = client.io, lazy = true)
series = RasterSeries(found[1:4], "red"; io = client.io, lazy = true)   # a Ti axis of datetimes
```

A credentialed endpoint takes one keyword, and it serves both the catalog requests and the
pixels:

```julia
client = Client("https://planetarycomputer.microsoft.com/api/stac/v1";
                auth = PlanetaryComputerSAS())
item = first(search(client; collections = ["sentinel-2-l2a"], limit = 1))
Raster(client, STAC.asset(item, "B04"); lazy = true)    # SAS-signed, opened through /vsicurl/
```

## Beyond the quickstart

| Also here | Where |
|---|---|
| `eo:cloud_cover` three ways, and your own extension in five lines | [Extensions](https://asinghvi17.github.io/STAC.jl/dev/extensions) |
| ndjson, stac-geoparquet, and publishing a catalog as a directory tree | [Bulk formats](https://asinghvi17.github.io/STAC.jl/dev/formats) |
| Bearer tokens, Planetary Computer SAS, Earthdata Login, and the IO stack under them | [Fetching and credentials](https://asinghvi17.github.io/STAC.jl/dev/io) |
| Programs that build under `juliac --trim=safe` | [Static compilation](https://asinghvi17.github.io/STAC.jl/dev/compilation) |

## Contributing

`AGENTS.md` is the house style: one job per file, errors through `src/errors.jl`, fixtures
vendored and never fetched at test time. Tests run offline —
`julia --project=. -e 'using Pkg; Pkg.test()'` reaches no network.

## License

MIT.
