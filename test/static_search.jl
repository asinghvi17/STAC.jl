using STAC, Test, Extents, Dates, DE9IM, GeoJSON
using STAC: Item, ItemCollection, ParseOptions, StaticItemSearch, datetime_interval,
            intimerange, itemtype
import GeoInterface as GI
import GeometryOps as GO

include("fixtures.jl")
include("FixtureIO.jl")

const CATDIR = joinpath(HAND_DIR, "antimeridian-catalog")
const CATALOG = joinpath(CATDIR, "catalog.json")

# The window `api/requests.json` recorded, which keeps the first five items.
const WINDOW = (DateTime(2024, 6, 1), DateTime(2024, 6, 5))

catalog() = STAC.read(CATALOG)

ids(s) = [i.id for i in s]

const REGION =
    GI.Polygon([GI.LinearRing([(-2.0, -2.0), (2.0, -2.0), (2.0, 2.0), (-2.0, 2.0), (-2.0, -2.0)])])

@testset "a static search takes the same keywords as an API search" begin
    cat = catalog()

    @test ids(search(cat)) == ["straddle", "north-pole", "south-pole", "greenwich",
                               "bay-area", "outside-corner", "unlocated"]
    @test ids(search(cat; collections = "edges")) == ["straddle", "north-pole", "south-pole"]
    @test ids(search(cat; collections = ["edges", "mid"])) == ids(search(cat))
    @test ids(search(cat; ids = ["greenwich", "bay-area"])) == ["greenwich", "bay-area"]
    @test ids(search(cat; datetime = WINDOW)) ==
          ["straddle", "north-pole", "south-pole", "greenwich", "bay-area"]
    @test ids(search(cat; intersects = Extent(X = (170, -170), Y = (60, 70)))) == ["straddle"]
    @test ids(search(cat; intersects = Within(REGION))) == ["greenwich"]
    @test ids(search(cat; intersects = (-123, 37, -122, 38))) == ["bay-area"]

    # Filters compose, and a search that matches nothing is empty rather than an error.
    @test ids(search(cat; collections = "mid", datetime = WINDOW)) == ["greenwich", "bay-area"]
    @test isempty(collect(search(cat; ids = "nobody")))
end

@testset "a geometry read as Float32 searches the same place as one read as Float64" begin
    cat = catalog()

    # GeoJSON.jl reads positions as Float32 unless told otherwise, and the spherical pass a
    # static search runs takes Float64 alone.
    region32 = GeoJSON.read(GeoJSON.write(REGION))
    @test region32 isa GeoJSON.Polygon{2,Float32}

    @test ids(search(cat; intersects = Within(region32))) == ["greenwich"]
    @test ids(search(cat; intersects = region32)) == ["greenwich", "outside-corner"]
    @test ids(search(cat; intersects = Disjoint(region32))) ==
          ids(search(cat; intersects = Disjoint(REGION)))
end

@testset "an open-sided window keeps everything on the open side" begin
    cat = catalog()

    @test ids(search(cat; datetime = (nothing, DateTime(2024, 6, 2)))) ==
          ["straddle", "north-pole"]
    @test ids(search(cat; datetime = (DateTime(2024, 6, 6), nothing))) ==
          ["outside-corner", "unlocated"]
    @test ids(search(cat; datetime = Date(2024, 6, 4))) == ["greenwich"]
    @test ids(search(cat; datetime = "2024-06-04/..")) ==
          ["greenwich", "bay-area", "outside-corner", "unlocated"]

    @test datetime_interval(nothing) == (nothing, nothing)
    @test datetime_interval(Date(2024, 1, 1)) ==
          (DateTime(2024, 1, 1), DateTime(2024, 1, 1, 23, 59, 59, 999))
    @test datetime_interval("2024-01-01/2024-01-02") ==
          (DateTime(2024, 1, 1), DateTime(2024, 1, 2, 23, 59, 59, 999))
    @test datetime_interval("../2024-01-02T06:00:00Z") == (nothing, DateTime(2024, 1, 2, 6))
    @test datetime_interval([DateTime(2024, 6, 1), DateTime(2024, 6, 5)]) == WINDOW
    @test_throws STAC.BadInterval(1) datetime_interval([DateTime(2024, 6, 1)])
end

@testset "an item with only a start and an end matches an overlapping window" begin
    cat = catalog()
    item = first(search(cat; ids = "greenwich"))
    span = Item(item.id, item.stac_extensions, item.geometry, item.bbox,
                STAC.Properties(nothing, DateTime(2024, 6, 1), DateTime(2024, 6, 10),
                                ntuple(_ -> nothing, 13)..., STAC.Metadata()),
                item.links, item.assets, item.collection, item.extensions, item.metadata,
                item.href)

    @test intimerange(span, (DateTime(2024, 6, 5), DateTime(2024, 6, 6)))
    @test intimerange(span, (nothing, DateTime(2024, 6, 2)))
    @test !intimerange(span, (DateTime(2024, 6, 11), nothing))
    @test intimerange(span, (nothing, nothing))

    # An item that carries no time at all is outside every closed window.
    @test !intimerange(first(search(cat; ids = "greenwich")),
                       (DateTime(2020, 1, 1), DateTime(2020, 1, 2)))
end

@testset "a static search pages by limit and reports the exact total" begin
    cat = catalog()
    s = search(cat; datetime = WINDOW, limit = 2)

    @test matched(s) == 5
    ps = collect(pages(s))
    @test length(ps) == 3
    @test [p.numberReturned for p in ps] == [2, 2, 1]
    @test all(p -> p.numberMatched == 5, ps)
    @test reduce(vcat, [[i.id for i in p.features] for p in ps]) == ids(s)
    @test eltype(ps) == ItemCollection{STAC.extensiontype(STAC.DEFAULT_EXTENSIONS),
                                       STAC.DEFAULT_GEOMETRY,STAC.Metadata}

    # A search that matches nothing still answers one empty page.
    empty = collect(pages(search(cat; ids = "nobody")))
    @test length(empty) == 1
    @test empty[1].numberMatched == 0
end

@testset "the catalog is walked once, when the first page is asked for" begin
    base = "https://hand.example.com/catalog/"
    io = FixtureIO(base => CATDIR)
    cat = STAC.read(base * "catalog.json"; io)
    reads!(io)

    s = search(cat; io, datetime = WINDOW)
    @test reads!(io) == 0                       # building a search fetches nothing

    first(s)
    # Two collections and seven items, each read exactly once.
    @test reads!(io) == 9

    collect(s)
    matched(s)
    @test reads!(io) == 0                       # the walk is kept
end

@testset "the same keywords answer the same on a catalog and on an API" begin
    dir = joinpath(CATDIR, "api")
    io = recordedio(dir)
    client = Client(endpointurl(dir); io)
    api = search(client; datetime = WINDOW, limit = 10)

    @test ids(api) == ids(search(catalog(); datetime = WINDOW))
    @test matched(api) == matched(search(catalog(); datetime = WINDOW))

    # The exact pass is the same on both backends: the API returns the whole window and the
    # predicate removes what it must.
    predicated = search(client; datetime = WINDOW, limit = 10, intersects = Within(REGION))
    @test ids(predicated) == ids(search(catalog(); datetime = WINDOW, intersects = Within(REGION)))
    @test ids(predicated) == ["greenwich"]
    @test first(pages(predicated)).numberReturned == 1
    @test first(pages(predicated)).numberMatched == 2    # what the endpoint reported
end

@testset "a static search is an AbstractItemSearch like any other" begin
    cat = catalog()
    s = search(cat; limit = 2)

    @test s isa StaticItemSearch
    @test s isa STAC.AbstractItemSearch
    @test eltype(s) == itemtype(ParseOptions())
    @test Base.IteratorSize(typeof(s)) == Base.SizeUnknown()
    @test [i.id for i in Iterators.take(s, 3)] == ["straddle", "north-pole", "south-pole"]

    # The parse options reach every item the walk reads.
    plain = search(cat; extensions = (), metadata = false)
    @test first(plain) isa Item{Any,STAC.DEFAULT_GEOMETRY,STAC.NoMetadata}
end
