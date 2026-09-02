using STAC, Test, Dates, JSON
using ArchGDAL, Rasters
using Rasters: Ti
using STAC: Asset, NoMetadata

include("fixtures.jl")
include("FixtureIO.jl")

const RASTERSEXT = Base.get_extension(STAC, :STACRastersExt)

"""
    geotiff(path, values; res) -> path

One single-band GeoTIFF on a UTM 10N grid, written with ArchGDAL. The fixtures are produced
here rather than vendored: a GeoTIFF is bytes GDAL wrote, and the version that wrote them is
the one reading them back.
"""
function geotiff(path, values::Matrix{UInt16}; res::Float64 = 10.0)
    ArchGDAL.create(path; driver = ArchGDAL.getdriver("GTiff"), width = size(values, 1),
                    height = size(values, 2), nbands = 1, dtype = UInt16) do ds
        ArchGDAL.write!(ds, values, 1)
        ArchGDAL.setgeotransform!(ds, [4.0e5, res, 0.0, 4.6e6, 0.0, -res])
        ArchGDAL.setproj!(ds, ArchGDAL.toWKT(ArchGDAL.importEPSG(32610)))
    end
    return path
end

grid(n, offset) = UInt16[offset + 10i + j for i in 1:n, j in 1:n]

# One item per date, four assets: two bands on the same 8×8 grid, one on a 4×4 grid, and a
# GeoJSON footprint. `proj:shape` is stated per asset, which is what the stack checks.
function writeitem(dir, id, datetime, offset)
    a = geotiff(joinpath(dir, id * "-a.tif"), grid(8, offset))
    b = geotiff(joinpath(dir, id * "-b.tif"), grid(8, offset + 1000))
    c = geotiff(joinpath(dir, id * "-c.tif"), grid(4, offset); res = 20.0)
    f = joinpath(dir, id * "-footprint.geojson")
    write(f, """
        {"type": "FeatureCollection", "features": [
          {"type": "Feature", "properties": {"id": "$id"},
           "geometry": {"type": "Polygon",
                        "coordinates": [[[0.0,0.0],[1.0,0.0],[1.0,1.0],[0.0,0.0]]]}}]}""")
    cog = "image/tiff; application=geotiff; profile=cloud-optimized"
    doc = """
        {"type": "Feature", "stac_version": "1.1.0", "id": "$id", "collection": "grids",
         "stac_extensions": ["https://stac-extensions.github.io/projection/v2.0.0/schema.json"],
         "geometry": {"type": "Polygon",
                      "coordinates": [[[0.0,0.0],[1.0,0.0],[1.0,1.0],[0.0,1.0],[0.0,0.0]]]},
         "bbox": [0.0, 0.0, 1.0, 1.0],
         "properties": {"datetime": "$datetime", "proj:code": "EPSG:32610",
                        "proj:shape": [8, 8]},
         "links": [],
         "assets": {
           "a": {"href": "$a", "type": "$cog", "roles": ["data"]},
           "b": {"href": "$b", "type": "$cog", "roles": ["data"]},
           "c": {"href": "$c", "type": "$cog", "roles": ["data"], "proj:shape": [4, 4]},
           "footprint": {"href": "$f", "type": "application/geo+json"}}}"""
    return STAC.parse(doc), (; a, b, c, f)
end

const DIR = mktempdir()
const ITEM, PATHS = writeitem(DIR, "grid-1", "2024-06-01T00:00:00Z", 0)
const ITEM2, PATHS2 = writeitem(DIR, "grid-2", "2024-06-05T00:00:00Z", 5000)

@testset "the bridge adds no ambiguous method" begin
    # `RasterStack(item, keys)` and Rasters' own `RasterStack(table, dims::Tuple)` are the
    # pair that needs watching: a tuple of keys matches both.
    @test isempty(Test.detect_ambiguities(RASTERSEXT; recursive = true))
end

@testset "an asset opens as the raster its file holds" begin
    r = Raster(STAC.asset(ITEM, "a"))
    @test r == Rasters.Raster(PATHS.a)
    @test size(r) == (8, 8)
    @test r[1, 1] == grid(8, 0)[1, 1]

    # Every other keyword reaches Rasters untouched, `lazy` the one that matters most.
    lazily = Raster(STAC.asset(ITEM, "a"); lazy = true)
    @test lazily == r
    @test !(parent(lazily) isa Array)
end

@testset "a client opens an asset with the auth its search ran under" begin
    io = FixtureIO(STATIC_BASE * "self-contained/" => joinpath(STATIC_DIR, "self-contained"))
    client = Client(STATIC_BASE * "self-contained/catalog.json"; io)
    @test Raster(client, STAC.asset(ITEM, "a")) == Rasters.Raster(PATHS.a)
end

@testset "a GeoJSON asset is read, not opened" begin
    err = try
        Raster(STAC.asset(ITEM, "footprint"))
    catch e
        e
    end
    @test err isa STAC.NotARasterAsset
    @test err isa STAC.STACError
    m = sprint(showerror, err)
    @test occursin("GeoJSONDriver", m)
    @test occursin("STAC.read(asset)", m)
end

@testset "the named assets of one item become the layers of one stack" begin
    st = RasterStack(ITEM, ["a", "b"])
    @test keys(st) == (:a, :b)
    @test size(st[:a]) == (8, 8)
    @test st[:a] == Rasters.Raster(PATHS.a)
    @test st[:b] == Rasters.Raster(PATHS.b)
    @test keys(RasterStack(ITEM, [:a, :b])) == (:a, :b)
    # A tuple of keys resolves too: `RasterStack(table, dims::Tuple)` would otherwise be an
    # equally good match for it.
    @test keys(RasterStack(ITEM, (:a, :b))) == (:a, :b)
    @test keys(RasterStack(ITEM, ("a", "b"))) == (:a, :b)

    err = try
        RasterStack(ITEM, ["a", "nosuchband"])
    catch e
        e
    end
    @test err isa STAC.MissingAsset
end

@testset "assets on grids of different sizes name the keys and their shapes" begin
    err = try
        RasterStack(ITEM, ["a", "c"])
    catch e
        e
    end
    @test err isa STAC.MixedResolution
    @test err isa STAC.STACError
    @test err.keys == ["a", "c"]
    @test err.shapes == ["8×8", "4×4"]
    m = sprint(showerror, err)
    @test occursin("8×8", m)
    @test occursin("4×4", m)
    @test occursin("Rasters.resample", m)

    # An asset that states no shape is unknown, not different, so it does not raise.
    plain = Asset(PATHS.b, "image/tiff", nothing, nothing, nothing, nothing, NoMetadata())
    @test RASTERSEXT.projshape(ITEM, plain) == [8, 8]
end

@testset "one asset of many items becomes a series along Ti" begin
    series = RasterSeries([ITEM, ITEM2], "a")
    @test length(series) == 2
    @test collect(lookup(series, Ti)) ==
          [DateTime(2024, 6, 1), DateTime(2024, 6, 5)]
    @test series[1] == Rasters.Raster(PATHS.a)
    @test series[2] == Rasters.Raster(PATHS2.a)
    @test RasterSeries([ITEM, ITEM2], :a)[1] == series[1]
end

@testset "an item with no instant has no place on a time axis" begin
    spanning = STAC.parse("""
        {"type": "Feature", "stac_version": "1.1.0", "id": "span", "geometry": null,
         "properties": {"datetime": null, "start_datetime": "2024-06-02T00:00:00Z",
                        "end_datetime": "2024-06-03T00:00:00Z"},
         "links": [], "assets": {"a": {"href": "$(PATHS.a)", "type": "image/tiff"}}}""")
    @test RASTERSEXT.itemtime(spanning) == DateTime(2024, 6, 2)

    undated = STAC.parse("""
        {"type": "Feature", "stac_version": "1.1.0", "id": "undated", "geometry": null,
         "properties": {"datetime": null},
         "links": [], "assets": {"a": {"href": "$(PATHS.a)", "type": "image/tiff"}}}""")
    err = try
        RasterSeries([undated], "a")
    catch e
        e
    end
    @test err isa STAC.MissingDatetime
    @test occursin("undated", sprint(showerror, err))
end

@testset "credentials reach GDAL for one path prefix and no other" begin
    option(path, name) = ArchGDAL.GDAL.vsigetpathspecificoption(path, name, "")
    ncerts = length(RASTERSEXT.certificates())
    before = length(RASTERSEXT.APPLIED)

    r = (filename = "/vsis3/stac-jl-test/x/B4.tif", source = :gdal,
         config = ["STAC_JL_TEST_OPTION" => "applied"])
    @test RASTERSEXT.apply_config!(r) === r
    @test length(RASTERSEXT.APPLIED) == before + 1 + ncerts

    @test option("/vsis3/stac-jl-test/x/B4.tif", "STAC_JL_TEST_OPTION") == "applied"
    @test option("/vsis3/stac-jl-test/other/B8.tif", "STAC_JL_TEST_OPTION") == "applied"
    @test option("/vsis3/another-bucket/B4.tif", "STAC_JL_TEST_OPTION") == ""

    # A triple already given to GDAL is not given again; a new value is.
    RASTERSEXT.apply_config!(r)
    @test length(RASTERSEXT.APPLIED) == before + 1 + ncerts
    RASTERSEXT.apply_config!((; r.filename, r.source,
                              config = ["STAC_JL_TEST_OPTION" => "rotated"]))
    @test length(RASTERSEXT.APPLIED) == before + 2 + ncerts
    @test option("/vsis3/stac-jl-test/x/B4.tif", "STAC_JL_TEST_OPTION") == "rotated"

    # A local route touches GDAL not at all: no credentials, no certificates.
    empty = (filename = PATHS.a, source = :gdal, config = Pair{String,String}[])
    @test RASTERSEXT.apply_config!(empty) === empty
    @test length(RASTERSEXT.APPLIED) == before + 2 + ncerts
end

@testset "a network route is given a certificate store GDAL's curl can read" begin
    # GDAL_jll ships a curl with no CA bundle compiled in, so a `/vsicurl/` fetch fails on
    # macOS with "unable to get local issuer certificate" until one is named.
    certs = RASTERSEXT.certificates()
    if haskey(ENV, "CURL_CA_BUNDLE")
        @test isempty(certs)
    else
        @test first(only(certs)) == "CURL_CA_BUNDLE"
        @test isfile(last(only(certs)))

        RASTERSEXT.apply_config!((filename = "/vsicurl/https://certs.test/B4.tif",
                                  source = :gdal, config = Pair{String,String}[]))
        @test ArchGDAL.GDAL.vsigetpathspecificoption("/vsicurl/https://certs.test/B4.tif",
                                                     "CURL_CA_BUNDLE", "") ==
              last(only(certs))
    end
end
