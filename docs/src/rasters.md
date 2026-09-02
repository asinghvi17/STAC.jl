```@meta
CurrentModule = STAC
DocTestSetup = quote
    import STAC
end
```

# Opening assets as rasters

[Rasters.jl](https://rafaqz.github.io/Rasters.jl/stable) does the reading. What STAC adds is
the three things Rasters cannot know: which file an asset means once its href is signed,
which backend reads that file, and which GDAL options the fetch needs.

```julia
import STAC
using Dates, Extents, Rasters, ArchGDAL

client = STAC.Client("https://earth-search.aws.element84.com/v1")
item = first(STAC.search(client; collections = ["sentinel-2-l2a"],
                         intersects = Extent(X = (-123.0, -122.0), Y = (37.0, 38.0)),
                         datetime = (DateTime(2024, 6, 1), DateTime(2024, 6, 30))))

red = Raster(client, STAC.asset(item, "red"); lazy = true)
size(red)                       # (10980, 10980)
red[3000:3002, 3000:3002]       # one window, one HTTP range request
# 3×3 Matrix{Union{Missing, UInt16}}:
#  0x0125  0x0127  0x012f
#  0x0153  0x0147  0x012a
#  0x013a  0x010d  0x00dd
```

`ArchGDAL` is a trigger of the bridge beside `Rasters`, because both jobs need GDAL in the
process: Rasters opens a GeoTIFF through ArchGDAL, and the credentials go to GDAL's virtual
filesystem rather than to Rasters.

Three constructors, one asset each, one item, and one time series:

| Call | Gives |
|---|---|
| `Raster(asset; io)` | one asset's pixels |
| `Raster(client, asset)` | the same, opened with the credentials the search ran under |
| `RasterStack(item, keys; io)` | one layer per asset key of one item |
| `RasterSeries(items, key; io)` | one asset of every item, stacked along `Ti` |

These four are methods on Rasters.jl's own constructors, so they take no `STAC.` prefix —
unlike everything this package names of its own, which every example here qualifies.

```julia
st = RasterStack(item, ["red", "green", "blue"]; io = client.io, lazy = true)
keys(st)        # (:red, :green, :blue)
size(st)        # (10980, 10980)

found = collect(Iterators.take(STAC.search(client; collections = ["sentinel-2-l2a"],
                                           datetime = Date(2024, 6, 27)), 4))
series = RasterSeries(found, "red"; io = client.io, lazy = true)
dims(series, Ti)    # the four items' datetimes
```

`Ti` holds the items in the order they arrive, which is the endpoint's rather than sorted.
Most endpoints answer newest first, giving a descending axis that `Ti(a .. b)` selects on as
well as an ascending one; a search with no ordering gives an unordered axis, where `At` and
`Near` still work and a range does not. Sort the items, or pass `sortby` to the search, when
the axis has to be ordered.

## Which backend, and which path

[`STAC.driver`](@ref) chooses from the asset's media type first and its file extension
second; [`STAC.route`](@ref) then turns the pair into the `(; filename, source, config)` the
opener takes.

```jldoctest rasters
julia> asset(href, type) = STAC.Asset(href, type, nothing, nothing, ["data"], nothing,
                                      STAC.NoMetadata());

julia> STAC.route(asset("https://example.com/B04.tif", "image/tiff; application=geotiff"),
                  STAC.defaultstack())
(filename = "/vsicurl/https://example.com/B04.tif", source = :gdal, config = Pair{String, String}[])

julia> STAC.route(asset("s3://usgs-landsat/c02/B4.TIF", nothing), STAC.defaultstack()).filename
"/vsis3/usgs-landsat/c02/B4.TIF"

julia> STAC.driver(asset("/data/x.nc", nothing))
STAC.NetCDFDriver()

julia> STAC.driver(asset("s3://bucket/x.nc", "application/x-netcdf"))
STAC.GDALDriver()
```

The whole table:

| Media type, then extension | Scheme | `filename` | `source` |
|---|---|---|---|
| GeoTIFF, JPEG 2000, anything else GDAL reads | local | as written | `:gdal` |
| | `https`, `http` | `/vsicurl/<signed href>` | `:gdal` |
| | `s3` | `/vsis3/<bucket>/<key>` | `:gdal` |
| | `gs` | `/vsigs/<bucket>/<key>` | `:gdal` |
| | `az`, `abfs`, `abfss` | `/vsiaz/<container>/<blob>` | `:gdal` |
| NetCDF, HDF5 | local | as written | `:netcdf` |
| | any remote scheme | the `/vsi*/` path above | `:gdal` |
| Zarr | local, `https`, `gs`, `s3` | as written | `:zarr` |
| GeoJSON | any | through the IO stack | `:geojson` |
| GeoParquet | any | as written | `:geoparquet` |

Two rules make this more than a lookup. **The media type wins over the extension**, because
producers publish `.tif` assets that are really `application/x-netcdf` subdatasets. And **a
remote NetCDF or HDF5 asset goes to GDAL**, which range-reads it, where the NetCDF library
would download the file whole.

A driver whose package the session has not loaded says which one to load:

```jldoctest rasters
julia> STAC.route(asset("https://example.com/f.parquet", "application/vnd.apache.parquet"),
                  STAC.defaultstack())
ERROR: opening https://example.com/f.parquet goes through GeoParquetDriver, whose route another package defines. Run `import GeoParquet` to add it.
[...]

julia> STAC.package(STAC.ZarrDriver())      # the `import` line to paste
"Rasters, ZarrDatasets"
```

Add a row for a format or a scheme this table misses with one method of
[`STAC.route`](@ref).

## Credentials, per path prefix

The auth the catalog was opened with reaches GDAL as options set against the bucket,
container, or host prefix of the file — never against the process, so a token for one
Planetary Computer container stays out of every request to every other host.

```julia
client = STAC.Client("https://planetarycomputer.microsoft.com/api/stac/v1";
                     auth = STAC.PlanetaryComputerSAS())
item = first(STAC.search(client; collections = ["sentinel-2-l2a"], limit = 1))

Raster(client, STAC.asset(item, "B04"); lazy = true)
# the href is signed with a SAS token, minted per storage container and cached until it expires
```

[`STAC.vsi_prefix`](@ref) is what the options are set against, and
[`STAC.isvsinetwork`](@ref) is what decides whether a route needs credentials at all:

```jldoctest rasters
julia> STAC.vsi_prefix("/vsis3/usgs-landsat/collection02/B4.TIF")
"/vsis3/usgs-landsat/"

julia> STAC.vsi_prefix("/vsicurl/https://example.com/a/B4.tif?sig=abc")
"/vsicurl/https://example.com/"

julia> STAC.isvsinetwork("/data/B4.tif")
false
```

A network route also gets a certificate store, and gets it first, so an option the route
carries under the same name still wins. GDAL_jll ships a curl with no CA bundle compiled in,
and without this a `/vsicurl/` fetch on macOS ends in "unable to get local issuer
certificate" with no pixels at all. A `CURL_CA_BUNDLE` already in the environment is the
caller's answer and is left alone.

## Assets that do not share a grid

`RasterStack` refuses assets whose `proj:shape` differ, and says which and by how much,
rather than resampling behind `lazy = true`:

```julia
RasterStack(item, ["B04", "B11"]; io = client.io, lazy = true)
# ERROR: these assets are on grids of different sizes, so they stack only after resampling:
#   B04: 10980×10980
#   B11: 5490×5490
# Bring them to one grid with `Rasters.resample`, choosing the method the data calls for, and stack the results.
```

Which resampling brings a 10 m band and a 20 m band onto one grid is a choice the data makes,
not the stack. An asset that states no shape is left out of the comparison: unstated is
unknown, not different.

## Assets that are not rasters

A GeoJSON asset — a footprint file, a set of field boundaries — is read in core, with no
weak dependency, through the same IO stack the catalog was read with:

```julia
fc = STAC.read(STAC.asset(item, "footprints"))   # a GeoJSON.jl FeatureCollection
```

A flat GeoParquet asset reads the same way once `import GeoParquet` has given
[`STAC.route`](@ref) that row; the nested stac-geoparquet a *catalog* is stored as is a
different thing, and lives on [Bulk formats](formats.md).
