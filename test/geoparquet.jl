using STAC, Test, Dates, JSON, Tables
using DuckDB, GeoParquet
using DuckDB: DBInterface
using STAC: Asset, Item, Metadata, NoMetadata, NoDriverPackage, read_geoparquet,
            write_geoparquet

include("fixtures.jl")

const GEOPARQUET_DIR = joinpath(FIXTURES, "geoparquet")
const ITEMS_PARQUET = joinpath(GEOPARQUET_DIR, "items.parquet")
const FOOTPRINTS_PARQUET = joinpath(GEOPARQUET_DIR, "footprints.parquet")

"""
    sourceitems() -> Vector{Item}

The four items `fixtures/geoparquet/items.parquet` was built from, read from their JSON with
no origin, which is what the file's rows have to come back equal to.
"""
sourceitems() =
    sort([STAC.sethref(STAC.read(p), nothing)
          for p in jsonfiles(joinpath(STATIC_DIR, "absolute-published"))
          if JSON.parse(read(p, String))["type"] == "Feature"]; by = i -> i.id)

byid(items) = sort(items; by = i -> i.id)

kvmetadata(path) = begin
    con = DBInterface.connect(DuckDB.DB, ":memory:")
    rows = Tables.columntable(DBInterface.execute(con,
        string("SELECT key, value FROM parquet_kv_metadata('", path, "')")))
    DBInterface.close!(con)
    Dict(String(copy(k)) => String(copy(v)) for (k, v) in zip(rows.key, rows.value))
end

@testset "the vendored file reads back as the items it was written from" begin
    items = read_geoparquet(ITEMS_PARQUET)
    @test items isa Vector{<:Item}
    @test [i.id for i in byid(items)] ==
          ["collectionless-item", "core-item", "extended-item", "simple-item"]
    # Every field, not just the three the phase names: the format's null padding, its hoisted
    # properties, and its WKB geometry all have to come back the way the producer wrote them.
    @test byid(items) == sourceitems()
end

@testset "the fields the format takes apart come back where they belong" begin
    items = Dict(i.id => i for i in read_geoparquet(ITEMS_PARQUET))
    extended = items["extended-item"]
    @test extended.properties.datetime == DateTime("2020-12-14T18:02:31.437")
    @test extended.extensions.eo.cloud_cover == 1.2
    @test extended.extensions.proj.code == "EPSG:32659"
    @test extended.collection == "simple-collection"
    @test extended.geometry isa STAC.GeoJSON.Polygon{2,Float64}
    @test length(extended.bbox) == 4

    core = items["core-item"]
    @test core.properties.datetime === nothing
    @test core.properties.start_datetime == DateTime("2020-12-11T22:38:32.125")

    # The `assets` column names every key any row uses; an item comes back with its own.
    @test collect(keys(items["simple-item"].assets)) == ["thumbnail", "visual"]
    @test items["collectionless-item"].collection === nothing
    @test [l.rel for l in items["simple-item"].links] ==
          ["self", "root", "parent", "collection"]
end

@testset "the parse keywords reach the items" begin
    plain = read_geoparquet(ITEMS_PARQUET; extensions = ())
    @test eltype(plain) == Item{Any,STAC.DEFAULT_GEOMETRY,Metadata}
    extended = only(i for i in plain if i.id == "extended-item")
    @test extended.properties.other["eo:cloud_cover"] == 1.2

    bare = read_geoparquet(ITEMS_PARQUET; metadata = false)
    @test eltype(bare) == STAC.itemtype(STAC.ParseOptions(; metadata = false))
    @test all(i.metadata isa NoMetadata for i in bare)
end

@testset "writing then reading is the same corpus" begin
    path = joinpath(mktempdir(), "out.parquet")
    items = sourceitems()
    @test write_geoparquet(path, items) == path
    @test byid(read_geoparquet(path)) == items
end

@testset "the file carries the metadata the format is read by" begin
    path = joinpath(mktempdir(), "out.parquet")
    write_geoparquet(path, sourceitems())
    kv = kvmetadata(path)
    @test haskey(kv, "stac-geoparquet")
    @test JSON.parse(kv["stac-geoparquet"])["version"] == "1.0.0"
    geo = JSON.parse(kv["geo"])
    @test geo["primary_column"] == "geometry"
    @test geo["columns"]["geometry"]["encoding"] == "WKB"
end

@testset "the vendored file's own metadata says what it is" begin
    kv = kvmetadata(ITEMS_PARQUET)
    @test haskey(kv, "stac-geoparquet")
    @test JSON.parse(kv["geo"])["columns"]["geometry"]["encoding"] == "WKB"
end

@testset "an item with no footprint writes and reads as one" begin
    path = joinpath(mktempdir(), "nogeom.parquet")
    item = STAC.sethref(STAC.read(joinpath(SPEC_DIR, "core-item.json")), nothing)
    loose = STAC.rebuild(STAC.rebuild(item, Val(:geometry), nothing), Val(:bbox), nothing)
    write_geoparquet(path, [loose])
    back = only(read_geoparquet(path))
    @test back.geometry === nothing
    @test back.bbox === nothing
    @test back.id == item.id
end

@testset "every WKB geometry type survives the round trip" begin
    G = STAC.ANY_GEOMETRY
    ring = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 0.0)]
    geometries = [STAC.GeoJSON.Point{2,Float64}(nothing, (1.5, 2.5)),
                  STAC.GeoJSON.MultiPoint{2,Float64}(nothing, [(1.0, 2.0), (3.0, 4.0)]),
                  STAC.GeoJSON.LineString{2,Float64}(nothing, [(0.0, 0.0), (1.0, 1.0)]),
                  STAC.GeoJSON.MultiLineString{2,Float64}(nothing, [[(0.0, 0.0), (1.0, 1.0)]]),
                  STAC.GeoJSON.Polygon{2,Float64}(nothing, [ring]),
                  STAC.GeoJSON.MultiPolygon{2,Float64}(nothing, [[ring]])]
    template = STAC.read(joinpath(SPEC_DIR, "core-item.json"); geometry = G)
    for (i, geom) in enumerate(geometries)
        item = STAC.rebuild(STAC.rebuild(STAC.sethref(template, nothing), Val(:geometry), geom),
                            Val(:id), string("geom-", i))
        path = joinpath(mktempdir(), "g.parquet")
        write_geoparquet(path, [item])
        back = only(read_geoparquet(path; geometry = G))
        @test back.geometry == geom
    end
end

@testset "a geometry outside the declared union says which one it is" begin
    path = joinpath(mktempdir(), "point.parquet")
    template = STAC.read(joinpath(SPEC_DIR, "core-item.json"); geometry = STAC.ANY_GEOMETRY)
    point = STAC.GeoJSON.Point{2,Float64}(nothing, (1.0, 2.0))
    write_geoparquet(path, [STAC.rebuild(STAC.sethref(template, nothing), Val(:geometry), point)])
    err = try
        read_geoparquet(path)
        nothing
    catch e
        e
    end
    @test err isa STAC.UnknownGeometryType
    @test occursin("Point", sprint(showerror, err))
end

@testset "a flat GeoParquet asset opens through the driver table" begin
    asset = Asset(FOOTPRINTS_PARQUET, "application/vnd.apache.parquet", nothing, nothing,
                  ["data"], nothing, NoMetadata())
    @test STAC.driver(asset) == STAC.GeoParquetDriver()
    r = STAC.route(asset, STAC.defaultstack())
    @test r.filename == FOOTPRINTS_PARQUET
    @test r.source === :geoparquet
    table = STAC.read(asset)
    @test collect(Tables.columnnames(table)) == [:id, :datetime, :geometry]
    @test collect(skipmissing(Tables.getcolumn(table, :id))) ==
          ["collectionless-item", "core-item", "extended-item", "simple-item"]
end

@testset "the fallbacks name the package that defines the route" begin
    # The loaded extension owns `DuckDBDriver`; every other driver still reports the
    # `import` line a caller would need.
    err = try
        read_geoparquet(STAC.GDALDriver(), "x.parquet")
        nothing
    catch e
        e
    end
    @test err isa NoDriverPackage
    @test occursin("Rasters, ArchGDAL", sprint(showerror, err))
    @test_throws NoDriverPackage write_geoparquet(STAC.GDALDriver(), "x.parquet", ())
end
