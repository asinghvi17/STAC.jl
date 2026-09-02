# Which package opens an asset, and the path and credentials it needs. Nothing here opens a
# file: `route` is a pure function of the asset and of the auth the IO stack carries for its
# href, and the packages that do the opening add their methods from `ext/`.

"""
    STAC.AbstractDriver

Supertype of the openers an [`Asset`](@ref) can be read through. [`STAC.driver`](@ref) picks
one from the asset's media type and href, and [`STAC.route`](@ref) turns the pair into the
`(; filename, source, config)` the opener takes.

| Driver | Opens | Package |
|---|---|---|
| [`STAC.GDALDriver`](@ref) | GeoTIFF, JPEG 2000, and everything else GDAL reads, local or remote | Rasters, ArchGDAL |
| [`STAC.NetCDFDriver`](@ref) | a local NetCDF or HDF5 file | Rasters, NCDatasets |
| [`STAC.ZarrDriver`](@ref) | a Zarr store | Rasters, ZarrDatasets |
| [`STAC.GeoJSONDriver`](@ref) | GeoJSON, through [`STAC.read`](@ref) and the IO stack | STAC itself |
| [`STAC.GeoParquetDriver`](@ref) | a flat GeoParquet file | GeoParquet |
| [`STAC.DuckDBDriver`](@ref) | a stac-geoparquet file, whose nested columns need SQL | DuckDB |
"""
abstract type AbstractDriver end

"""
    STAC.GDALDriver()

GDAL reads the asset, over `/vsicurl/`, `/vsis3/`, `/vsigs/`, or `/vsiaz/` when it lives
somewhere other than this filesystem. This is the driver for every raster media type that has
no more specific reader, and for remote NetCDF and HDF5, which GDAL range-reads where the
NetCDF library would have to download the file whole.
"""
struct GDALDriver <: AbstractDriver end

"""
    STAC.NetCDFDriver()

The NetCDF library reads the asset. Local files only: a NetCDF or HDF5 asset behind a URL
goes to [`STAC.GDALDriver`](@ref).
"""
struct NetCDFDriver <: AbstractDriver end

"""
    STAC.ZarrDriver()

A Zarr store, read from its URL as it stands. Public stores over `https` and `s3` work
anonymously; a private one needs the store object the bridge for its cloud builds.
"""
struct ZarrDriver <: AbstractDriver end

"""
    STAC.GeoParquetDriver()

A flat GeoParquet file, one row per feature with a WKB geometry column.
"""
struct GeoParquetDriver <: AbstractDriver end

"""
    STAC.DuckDBDriver()

A stac-geoparquet file, whose `links` and `assets` columns are nested structs that SQL reads
and a flat parquet reader does not.
"""
struct DuckDBDriver <: AbstractDriver end

"""
    STAC.GeoJSONDriver()

GeoJSON, read as bytes through the IO stack and parsed by GeoJSON.jl. This is the one driver
core carries: [`STAC.read(asset)`](@ref STAC.read) needs no weak dependency.
"""
struct GeoJSONDriver <: AbstractDriver end

"""
    STAC.package(driver) -> String

The packages that open what this driver routes, spelled as the `import` list that loads them:
`import ` * `package(d)` is a statement a user can paste.

```jldoctest
julia> STAC.package(STAC.GDALDriver())
"Rasters, ArchGDAL"
```
"""
package(::GDALDriver) = "Rasters, ArchGDAL"
package(::NetCDFDriver) = "Rasters, NCDatasets"
package(::ZarrDriver) = "Rasters, ZarrDatasets"
package(::GeoParquetDriver) = "GeoParquet"
package(::DuckDBDriver) = "DuckDB"
package(::GeoJSONDriver) = "STAC"

# ---------------------------------------------------------------------------------------
# Choosing a driver

const GDAL_TYPES = ("image/tiff", "image/vnd.stac.geotiff", "image/geotiff", "image/jp2",
                    "image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp",
                    "application/x-vrt", "image/x-vrt")

const NETCDF_TYPES = ("application/x-netcdf", "application/netcdf", "application/x-hdf",
                      "application/x-hdf5", "application/hdf5")

const ZARR_TYPES = ("application/vnd+zarr", "application/x-zarr", "application/vnd.zarr")

const GEOJSON_TYPES = ("application/geo+json", "application/json", "application/vnd.geo+json")

const PARQUET_TYPES = ("application/vnd.apache.parquet", "application/x-parquet",
                       "application/parquet")

const NETCDF_EXTENSIONS = (".nc", ".nc4", ".cdf", ".h5", ".hdf", ".hdf5", ".he5")

const ZARR_EXTENSIONS = (".zarr",)

const GEOJSON_EXTENSIONS = (".geojson", ".json")

const PARQUET_EXTENSIONS = (".parquet", ".pq")

"""
    STAC.basemediatype(type) -> String

A media type without its parameters, lowercased: `"image/tiff; application=geotiff;
profile=cloud-optimized"` is `"image/tiff"`. The parameters distinguish a plain GeoTIFF from
a cloud-optimized one, which the same driver opens either way.
"""
function basemediatype(type::AbstractString)
    i = findfirst(';', type)
    return lowercase(strip(i === nothing ? type : SubString(type, 1, prevind(type, i))))
end

"""
    STAC.hrefextension(href) -> String

The lowercased file extension of an href, with its query string and fragment removed first,
so a signed `.../B04.tif?st=…&sig=…` still reads as a GeoTIFF.
"""
function hrefextension(href::AbstractString)
    stop = findfirst(c -> c == '?' || c == '#', href)
    path = stop === nothing ? SubString(href, 1) : SubString(href, 1, prevind(href, stop))
    return lowercase(last(splitext(rstrip(path, '/'))))
end

"""
    STAC.driver(asset) -> AbstractDriver

The driver that opens `asset`: its media type when that names one, and its file extension
otherwise. GDAL is the fallback, as it is in Rasters.jl, because GDAL reads more formats than
any table can list.

Two rules make the choice more than a lookup:

| Rule | Why |
|---|---|
| a NetCDF or HDF5 asset behind a URL goes to [`STAC.GDALDriver`](@ref) | GDAL range-reads it; the NetCDF library downloads the file whole |
| the media type wins over the extension | producers publish `.tif` assets that are really `application/x-netcdf` subdatasets |

```jldoctest
julia> STAC.driver(Asset("s3://b/x.nc", "application/x-netcdf", nothing, nothing, nothing, nothing, NoMetadata()))
STAC.GDALDriver()

julia> STAC.driver(Asset("/data/x.nc", nothing, nothing, nothing, nothing, nothing, NoMetadata()))
STAC.NetCDFDriver()
```
"""
function driver(asset::Asset)
    d = mediadriver(asset.type)
    d === nothing && (d = extensiondriver(hrefextension(asset.href)))
    return islocalhref(asset.href) ? d : remotedriver(d)
end

mediadriver(::Nothing) = nothing

function mediadriver(type::AbstractString)
    base = basemediatype(type)
    base in GDAL_TYPES && return GDALDriver()
    base in NETCDF_TYPES && return NetCDFDriver()
    base in ZARR_TYPES && return ZarrDriver()
    base in GEOJSON_TYPES && return GeoJSONDriver()
    base in PARQUET_TYPES && return GeoParquetDriver()
    return nothing
end

function extensiondriver(ext::AbstractString)
    ext in NETCDF_EXTENSIONS && return NetCDFDriver()
    ext in ZARR_EXTENSIONS && return ZarrDriver()
    ext in GEOJSON_EXTENSIONS && return GeoJSONDriver()
    ext in PARQUET_EXTENSIONS && return GeoParquetDriver()
    return GDALDriver()
end

islocalhref(href::AbstractString) = (s = urischeme(href); s == "" || s == "file")

remotedriver(::NetCDFDriver) = GDALDriver()
remotedriver(d::AbstractDriver) = d

# ---------------------------------------------------------------------------------------
# Paths GDAL understands

const VSI_SCHEMES = ("s3" => "/vsis3/", "gs" => "/vsigs/", "az" => "/vsiaz/",
                     "abfs" => "/vsiaz/", "abfss" => "/vsiaz/", "adl" => "/vsiadls/",
                     "oss" => "/vsioss/", "swift" => "/vsiswift/")

"""
    STAC.vsi_path(scheme, href) -> String

`href` as GDAL's virtual filesystem names it.

| Scheme | Path |
|---|---|
| `""` | `href`, which is already a path on this filesystem |
| `"file"` | the path the `file://` URL names |
| `"http"`, `"https"` | `/vsicurl/` and the URL whole, query string included |
| `"s3"` | `/vsis3/<bucket>/<key>` |
| `"gs"` | `/vsigs/<bucket>/<key>` |
| `"az"`, `"abfs"`, `"abfss"` | `/vsiaz/<container>/<blob>` |
| anything else | `href` unchanged, for GDAL's own prefixes such as `NETCDF:` |

```jldoctest
julia> STAC.vsi_path("s3", "s3://usgs-landsat/collection02/B4.TIF")
"/vsis3/usgs-landsat/collection02/B4.TIF"

julia> STAC.vsi_path("https", "https://example.com/B4.tif?sig=abc")
"/vsicurl/https://example.com/B4.tif?sig=abc"
```
"""
function vsi_path(scheme::AbstractString, href::AbstractString)
    scheme == "" && return String(href)
    scheme == "file" && return localpath(href)
    (scheme == "https" || scheme == "http") && return "/vsicurl/" * href
    for (s, prefix) in VSI_SCHEMES
        scheme == s && return prefix * afterscheme(href)
    end
    return String(href)
end

"""
    STAC.afterscheme(href) -> SubString{String}

What follows `<scheme>://` in an href: the bucket and key of an `s3://` URL, the container and
blob of an `az://` one.
"""
function afterscheme(href::AbstractString)
    i = findfirst("://", href)
    return i === nothing ? SubString(href, 1) : SubString(href, nextind(href, last(i)))
end

"""
    STAC.VSI_NETWORK

The GDAL virtual filesystem prefixes that fetch over the network, which is what decides
whether a route needs credentials and a certificate store. `/vsizip/` and its siblings read
local bytes and are absent from this list.
"""
const VSI_NETWORK = ("/vsicurl/", "/vsis3/", "/vsigs/", "/vsiaz/", "/vsiadls/", "/vsioss/",
                     "/vsiswift/")

"""
    STAC.isvsinetwork(filename) -> Bool

Whether GDAL would fetch this path over the network.

```jldoctest
julia> STAC.isvsinetwork("/vsis3/usgs-landsat/c2/B4.TIF")
true

julia> STAC.isvsinetwork("/data/B4.tif")
false
```
"""
isvsinetwork(filename::AbstractString) = any(p -> startswith(filename, p), VSI_NETWORK)

"""
    STAC.vsi_prefix(filename) -> String

The longest prefix of a GDAL virtual path that names a whole bucket, container, or host, so
one set of credentials covers every file under it. Path-specific options are set against this
rather than against each file.

```jldoctest
julia> STAC.vsi_prefix("/vsis3/usgs-landsat/collection02/B4.TIF")
"/vsis3/usgs-landsat/"

julia> STAC.vsi_prefix("/vsicurl/https://example.com/a/B4.tif?sig=abc")
"/vsicurl/https://example.com/"
```
"""
function vsi_prefix(filename::AbstractString)
    for (_, prefix) in VSI_SCHEMES
        startswith(filename, prefix) || continue
        i = findnext('/', filename, sizeof(prefix) + 1)
        return i === nothing ? String(filename) : String(SubString(filename, 1, i))
    end
    if startswith(filename, "/vsicurl/")
        url = SubString(filename, sizeof("/vsicurl/") + 1)
        i = findnext('/', url, sizeof(urischeme(url)) + 4)
        return i === nothing ? String(filename) :
               "/vsicurl/" * String(SubString(url, 1, i))
    end
    return String(filename)
end

# ---------------------------------------------------------------------------------------
# Routing an asset

@noinline _nodriverpackage(d::AbstractDriver, href) =
    throw(NoDriverPackage(string(nameof(typeof(d))), package(d), String(href)))

@noinline _notgeojsonasset(d::AbstractDriver, asset::Asset) =
    throw(NotGeoJSONAsset(string(nameof(typeof(d))), package(d), String(asset.href)))

@noinline _notarasterasset(d::AbstractDriver, asset::Asset) =
    throw(NotARasterAsset(string(nameof(typeof(d))), String(asset.href)))

@noinline _noasset(item::Item, key) =
    throw(MissingAsset(String(key), join(keys(item.assets), ", ")))

"""
    STAC.assethref(asset) -> String

The absolute href of an asset. A producer that wrote a relative one raises a
[`STAC.NoOrigin`](@ref), since an [`Asset`](@ref) carries no origin of its own to resolve
against.
"""
assethref(asset::Asset) = resolve(asset.href, nothing)

"""
    STAC.asset(item, key) -> Asset

The asset `item` publishes under `key`, which is a `String` or a `Symbol`. An absent key
raises a [`STAC.MissingAsset`](@ref) listing the keys the item does carry, because producers
name the same band `"B04"`, `"red"`, and `"B4"` on three different endpoints.
"""
function asset(item::Item, key::Union{AbstractString,Symbol})
    a = get(item.assets, String(key), nothing)
    a === nothing && _noasset(item, key)
    return a
end

"""
    STAC.route(driver, asset, io) -> (; filename, source, config)
    STAC.route(asset, io)

What the opener needs to read `asset`, as three values:

| Field | Holds |
|---|---|
| `filename` | the path or URL the opener takes, signed and in GDAL's virtual filesystem spelling |
| `source` | the Rasters.jl backend symbol: `:gdal`, `:netcdf`, `:zarr`, or `:geojson` for the core reader |
| `config` | the GDAL options the fetch needs, from [`STAC.gdal_config`](@ref) |

The credentials come from `io`: [`STAC.authfor`](@ref) reports the auth that stack would fetch
this href with, and that auth both signs the href and names the options.

```julia
asset = Asset("https://sentinel2l2a01.blob.core.windows.net/sentinel2-l2/x/B04.tif",
              "image/tiff; application=geotiff; profile=cloud-optimized",
              nothing, nothing, ["data"], nothing, NoMetadata())
r = STAC.route(STAC.driver(asset), asset, STAC.defaultstack(PlanetaryComputerSAS()))
r.filename   # "/vsicurl/https://sentinel2l2a01.blob.core.windows.net/…?st=…&sig=…"
r.source     # :gdal
```

The two-argument form picks the driver with [`STAC.driver`](@ref) first.

A driver whose route comes from a package the session has not loaded raises a
[`STAC.NoDriverPackage`](@ref) naming that package.
"""
route(d::AbstractDriver, asset::Asset, ::AbstractIO) = _nodriverpackage(d, asset.href)

function route(::GDALDriver, asset::Asset, io::AbstractIO)
    href = assethref(asset)
    auth = authfor(io, href)
    target = rewrite(auth, href)
    return (filename = vsi_path(urischeme(target), target), source = :gdal,
            config = gdal_config(auth, target))
end

function route(::NetCDFDriver, asset::Asset, ::AbstractIO)
    return (filename = localpath(assethref(asset)), source = :netcdf, config = NO_OPTIONS)
end

function route(::ZarrDriver, asset::Asset, io::AbstractIO)
    href = assethref(asset)
    auth = authfor(io, href)
    return (filename = rewrite(auth, href), source = :zarr, config = NO_OPTIONS)
end

function route(::GeoJSONDriver, asset::Asset, io::AbstractIO)
    href = assethref(asset)
    return (filename = rewrite(authfor(io, href), href), source = :geojson,
            config = NO_OPTIONS)
end

route(asset::Asset, io::AbstractIO) = route(driver(asset), asset, io)
