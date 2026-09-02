using STAC, Test, Dates, Extents
using STAC: Item, Catalog, Collection, ItemCollection, spatialindex

include("fixtures.jl")
include("FixtureIO.jl")

plain(x) = repr(MIME"text/plain"(), x)

const ITEM = STAC.read(joinpath(SPEC_DIR, "extended-item.json"))
const HAND = STAC.read(joinpath(HAND_DIR, "hand-item.json"))

@testset "an item's one-line form is its type, id, and date" begin
    line = repr(ITEM)
    @test line == "Item{eo, proj, raster, sat, view, sci} \"20201211_223832_CS2\" 2020-12-14"
    @test !occursin('\n', line)

    # A vector shows one line per item, which is that same form.
    listing = plain([ITEM, HAND])
    @test occursin(repr(ITEM), listing)
    @test occursin(repr(HAND), listing)
    @test !occursin("datetime", listing)

    # Without declared extensions the prefixes are gone, not empty braces.
    bare = STAC.read(joinpath(SPEC_DIR, "extended-item.json"); extensions = ())
    @test startswith(repr(bare), "Item \"20201211_223832_CS2\"")
end

@testset "an item's block form answers what it is" begin
    block = plain(ITEM)
    lines = split(block, '\n')
    @test lines[1] == repr(ITEM)
    labels = [strip(split(l, "  ")[2]) for l in lines[2:end]]
    @test labels == ["datetime", "collection", "geometry", "assets", "extensions", "metadata"]

    @test occursin("datetime    2020-12-14T18:02:31.437Z", block)
    @test occursin("collection  simple-collection", block)
    @test occursin("geometry    Polygon{2, Float64} (5 vertices), bbox (172.9117,", block)
    @test occursin("assets      analytic, thumbnail, visual, udm, … (6)", block)
    @test occursin("eo (cloud_cover = 1.2, snow_cover = 0.0)", block)
    @test occursin("proj (code = \"EPSG:32659\"", block)
    @test occursin("metadata    1 key: \"stac_version\"", block)

    # A long field value is cut down rather than filling the line.
    @test occursin("transform = [0.5, 0.0, 712710.0, … (9)]", block)
end

@testset "the block form leaves out what the item does not carry" begin
    core = plain(STAC.read(joinpath(SPEC_DIR, "core-item.json")))
    # `datetime: null` with a range beside it prints the range.
    @test occursin("datetime    2020-12-11T22:38:32.125Z … 2020-12-11T22:38:32.327Z", core)
    @test !occursin("extensions", core)          # it declares none of the shipped six

    collectionless = plain(STAC.read(joinpath(SPEC_DIR, "collectionless-item.json")))
    @test !occursin("collection", collectionless)

    # A six-number bbox and an item with no geometry both read as themselves.
    @test occursin("bbox (0.0, 0.0, -1.0, 1.0, 1.0, 5.0)", plain(HAND))
    unlocated = STAC.read(joinpath(HAND_DIR, "antimeridian-catalog", "mid", "unlocated.json"))
    @test occursin("geometry    no geometry", plain(unlocated))
end

@testset "a catalog and a collection lead with id and title" begin
    cat = STAC.read(joinpath(SPEC_DIR, "catalog.json"))
    @test repr(cat) == "Catalog \"examples\" — Example Catalog"
    @test occursin("links       root, child ×3, item, self", plain(cat))

    col = STAC.read(joinpath(SPEC_DIR, "collection.json"))
    block = plain(col)
    @test startswith(block, "Collection \"simple-collection\" — Simple Example Collection")
    @test occursin("extent      bbox (172.9117, 1.3439, 172.9547, 1.369)", block)
    @test occursin("license     CC-BY-4.0", block)
    @test occursin("metadata    1 key: \"stac_version\"", block)
end

@testset "a page says how many items it holds and how many matched" begin
    page = STAC.read(joinpath(REAL_DIR, "es.search.json"))
    @test occursin("ItemCollection{eo, proj, raster, sat, view, sci} with 3 items of 50336 matched",
                   repr(page))
    @test occursin("items       S2B_59UNT_20240604_0_L2A", plain(page))
    @test occursin("links       next, root", plain(page))

    # A page built in memory reports no total, because nothing counted one.
    @test repr(ItemCollection(page.features[1:2])) ==
          "ItemCollection{eo, proj, raster, sat, view, sci} with 2 items"
end

@testset "an index says what it indexes and in which space" begin
    items = STAC.read(joinpath(REAL_DIR, "es.search.json")).features
    @test repr(spatialindex(items)) == "SpatialIndex(Spherical()) over 3 items"
    @test repr(spatialindex(STAC.GO.Planar(), items)) == "SpatialIndex(Planar()) over 3 items"
    unlocated = [STAC.read(joinpath(HAND_DIR, "antimeridian-catalog", "mid", "unlocated.json"))]
    @test occursin("none of them located", repr(spatialindex(unlocated)))
end

@testset "a client and a search print without fetching anything" begin
    dir = endpointdir("planetary-computer")
    io = recordedio(dir)
    client = Client(endpointurl(dir); io)
    reads!(io)

    block = plain(client)
    @test startswith(block, "Client \"" * client.url * "\"")
    @test occursin("conforms    " * string(length(client.conformsTo)) * " classes", block)
    @test occursin("limit ≤ 1000, default 250, no numberMatched", block)

    s = search(client; collections = ["sentinel-2-l2a"], limit = 5)
    searchblock = plain(s)
    @test startswith(searchblock, "APIItemSearch POST ")
    @test occursin("\"collections\":[\"sentinel-2-l2a\"]", searchblock)
    @test occursin("items       Item{eo, proj, raster, sat, view, sci}", searchblock)

    # Neither `show` made a request: the client's landing page was the last one.
    @test reads!(io) == 0
end

@testset "a static search prints its filters, not its results" begin
    cat = STAC.read(joinpath(HAND_DIR, "antimeridian-catalog", "catalog.json"))
    s = search(cat; collections = "edges", datetime = (DateTime(2024, 1, 1), nothing),
               intersects = Extents.Extent(X = (170.0, -170.0), Y = (60.0, 70.0)))
    block = plain(s)
    @test startswith(block, "StaticItemSearch over Catalog \"antimeridian\"")
    @test occursin("collections edges", block)
    @test occursin("datetime    2024-01-01T00:00:00Z … none", block)
    @test occursin("intersects  Extent(X = (170.0, -170.0), Y = (60.0, 70.0))", block)
    @test occursin("matched     not run yet", block)

    collect(s)
    @test occursin("matched     1", plain(s))
end
