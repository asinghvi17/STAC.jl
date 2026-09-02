using STAC, Test, JSON
using AWSS3
using STAC: Asset, GDALDriver, GeoJSONDriver, GeoParquetDriver, NetCDFDriver, ZarrDriver,
            NoMetadata, PlanetaryComputerSAS, defaultstack, driver, route, vsi_path,
            vsi_prefix

include("fixtures.jl")
include("FixtureIO.jl")

asset(href, type = nothing) =
    Asset(href, type, nothing, nothing, nothing, nothing, NoMetadata())

const COG = "image/tiff; application=geotiff; profile=cloud-optimized"

# One row per line of the driver table: what the producer wrote, what opens it, and the
# filename and backend the opener is handed. Nothing here reaches the network.
const ROUTES = [
    ("/data/B4.tif", COG, GDALDriver(), "/data/B4.tif", :gdal),
    ("file:///data/B4.tif", COG, GDALDriver(), "/data/B4.tif", :gdal),
    ("https://example.com/B4.tif", COG, GDALDriver(), "/vsicurl/https://example.com/B4.tif", :gdal),
    ("http://example.com/B4.tif", nothing, GDALDriver(), "/vsicurl/http://example.com/B4.tif", :gdal),
    ("s3://usgs-landsat/c2/B4.TIF", COG, GDALDriver(), "/vsis3/usgs-landsat/c2/B4.TIF", :gdal),
    ("gs://gcp-public-data/B4.tif", nothing, GDALDriver(), "/vsigs/gcp-public-data/B4.tif", :gdal),
    ("az://container/B4.tif", nothing, GDALDriver(), "/vsiaz/container/B4.tif", :gdal),
    ("abfs://container/B4.tif", nothing, GDALDriver(), "/vsiaz/container/B4.tif", :gdal),
    ("/data/air.nc", "application/x-netcdf", NetCDFDriver(), "/data/air.nc", :netcdf),
    ("/data/air.nc", nothing, NetCDFDriver(), "/data/air.nc", :netcdf),
    ("/data/granule.h5", nothing, NetCDFDriver(), "/data/granule.h5", :netcdf),
    # A NetCDF behind a URL goes to GDAL, which range-reads it.
    ("s3://bucket/air.nc", "application/x-netcdf", GDALDriver(), "/vsis3/bucket/air.nc", :gdal),
    ("https://example.com/air.nc", nothing, GDALDriver(), "/vsicurl/https://example.com/air.nc", :gdal),
    ("https://example.com/store.zarr", "application/vnd+zarr", ZarrDriver(),
     "https://example.com/store.zarr", :zarr),
    ("/data/store.zarr", nothing, ZarrDriver(), "/data/store.zarr", :zarr),
    ("/data/footprint.geojson", nothing, GeoJSONDriver(), "/data/footprint.geojson", :geojson),
    ("https://example.com/f.json", "application/geo+json", GeoJSONDriver(),
     "https://example.com/f.json", :geojson),
    # GDAL is the fallback for a format no table lists.
    ("/data/dem.bil", nothing, GDALDriver(), "/data/dem.bil", :gdal),
]

@testset "every row of the driver table routes to the file and backend it names" begin
    io = defaultstack()
    for (href, type, want, filename, source) in ROUTES
        a = asset(href, type)
        @test driver(a) == want
        r = route(a, io)
        @test r.filename == filename
        @test r.source === source
        @test isempty(r.config)
    end
end

@testset "the media type wins over the file extension" begin
    # Producers publish subdatasets as `.tif` and NetCDF granules as `.dat`.
    @test driver(asset("/data/x.tif", "application/x-netcdf")) == NetCDFDriver()
    @test driver(asset("/data/x.dat", COG)) == GDALDriver()
    @test driver(asset("/data/x.tif", "application/geo+json")) == GeoJSONDriver()
end

@testset "a signed href keeps its extension and its query string" begin
    signed = "https://example.com/B4.tif?st=2026-01-01&sig=abc"
    @test STAC.hrefextension(signed) == ".tif"
    @test driver(asset(signed)) == GDALDriver()
    @test route(asset(signed), defaultstack()).filename ==
          "/vsicurl/https://example.com/B4.tif?st=2026-01-01&sig=abc"
end

@testset "a Planetary Computer blob href carries its token into the vsicurl path" begin
    url = "https://token.test/token"
    io = answering(url * "/sentinel2l2a01/sentinel2-l2" =>
                   joinpath(TOKEN_DIR, "pc-sas-fresh.json"))
    auth = PlanetaryComputerSAS(; url, io)
    blob = "https://sentinel2l2a01.blob.core.windows.net/sentinel2-l2/x/B04.tif"
    r = route(asset(blob, COG), defaultstack(auth))
    @test startswith(r.filename, "/vsicurl/" * blob * "?")
    @test occursin("sig=handwrittenfixture", r.filename)
    # The signature rides in the URL, so GDAL is told nothing.
    @test isempty(r.config)

    # An href on another host is not this auth's business.
    @test route(asset("s3://usgs-landsat/c2/B4.TIF", COG), defaultstack(auth)).filename ==
          "/vsis3/usgs-landsat/c2/B4.TIF"
end

@testset "an auth that signs with headers hands GDAL the same header" begin
    io = defaultstack(BearerToken("s3cret"))
    r = route(asset("https://example.com/B4.tif", COG), io)
    @test r.config == ["GDAL_HTTP_HEADERS" => "Authorization: Bearer s3cret"]
    # The router picks the child by scheme, so a local asset stays anonymous.
    @test isempty(route(asset("/data/B4.tif", COG), io).config)
end

@testset "the network prefixes are the ones that need credentials" begin
    @test STAC.isvsinetwork("/vsis3/usgs-landsat/c2/B4.TIF")
    @test STAC.isvsinetwork("/vsicurl/https://example.com/B4.tif")
    @test STAC.isvsinetwork("/vsiaz/container/B4.tif")
    @test !STAC.isvsinetwork("/data/B4.tif")
    @test !STAC.isvsinetwork("/vsizip//data/archive.zip/B4.tif")
end

@testset "vsi_path and vsi_prefix spell what GDAL expects" begin
    @test vsi_path("", "/data/B4.tif") == "/data/B4.tif"
    @test vsi_path("s3", "s3://b/k/B4.tif") == "/vsis3/b/k/B4.tif"
    @test vsi_path("gs", "gs://b/k/B4.tif") == "/vsigs/b/k/B4.tif"
    @test vsi_path("abfss", "abfss://c/b.tif") == "/vsiaz/c/b.tif"
    # An unknown scheme is GDAL's own connection string, passed through.
    @test vsi_path("netcdf", "NETCDF:/data/air.nc:tas") == "NETCDF:/data/air.nc:tas"

    @test vsi_prefix("/vsis3/usgs-landsat/c2/B4.TIF") == "/vsis3/usgs-landsat/"
    @test vsi_prefix("/vsigs/b/k/B4.tif") == "/vsigs/b/"
    @test vsi_prefix("/vsiaz/container/x/B4.tif") == "/vsiaz/container/"
    @test vsi_prefix("/vsicurl/https://example.com/a/B4.tif?sig=abc") ==
          "/vsicurl/https://example.com/"
    @test vsi_prefix("/data/B4.tif") == "/data/B4.tif"
end

@testset "a driver whose package is unloaded names it" begin
    a = asset("/data/items.parquet")
    @test driver(a) == GeoParquetDriver()
    err = try
        route(a, defaultstack())
    catch e
        e
    end
    @test err isa STAC.NoDriverPackage
    @test err isa STAC.STACError
    m = sprint(showerror, err)
    @test occursin("GeoParquetDriver", m)
    @test occursin("import GeoParquet", m)
end

@testset "a relative asset href says it has no origin" begin
    @test_throws STAC.NoOrigin route(asset("./B4.tif", COG), defaultstack())
end

@testset "AWSS3 adds the `s3` route" begin
    io = S3IO()
    @test io isa STAC.AbstractIO
    @test S3IO(; config = nothing) isa STAC.AbstractIO
    @test STAC.authfor(io, "s3://bucket/k") == NoAuth()
    @test StreamRouterIO("s3" => io, "" => PathIO()) isa StreamRouterIO
    @test isempty(Test.detect_ambiguities(Base.get_extension(STAC, :STACAWSS3Ext);
                                          recursive = true))

    # With AWSS3 unloaded there is no method at all, and this is the message that call
    # produces.
    m = sprint(showerror, MethodError(STAC.S3IO, ("s3://bucket/k",)))
    @test occursin("AWSS3", m)
    @test occursin("import AWSS3", m)
end

@testset "a GeoJSON asset reads through the IO stack" begin
    dir = mktempdir()
    path = joinpath(dir, "footprint.geojson")
    write(path, """
        {"type": "FeatureCollection", "features": [
          {"type": "Feature", "properties": {"id": 1},
           "geometry": {"type": "Polygon",
                        "coordinates": [[[0.0,0.0],[1.0,0.0],[1.0,1.0],[0.0,0.0]]]}}]}""")
    fc = STAC.read(asset(path, "application/geo+json"))
    @test length(fc) == 1

    err = try
        STAC.read(asset("/data/B4.tif", COG))
    catch e
        e
    end
    @test err isa STAC.NotGeoJSONAsset
    @test occursin("import Rasters, ArchGDAL", sprint(showerror, err))
end

@testset "an item names its assets and says so when it has none by that name" begin
    item = STAC.read(joinpath(SPEC_DIR, "core-item.json"))
    @test STAC.asset(item, "thumbnail") === item.assets["thumbnail"]
    @test STAC.asset(item, :thumbnail) === item.assets["thumbnail"]
    err = try
        STAC.asset(item, "B04")
    catch e
        e
    end
    @test err isa STAC.MissingAsset
    @test occursin("thumbnail", sprint(showerror, err))
end
