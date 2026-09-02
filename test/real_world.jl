# The vendored responses of five public STAC APIs plus the ITS_LIVE catalog: the parser's
# honesty check, because producers put `stac_version: "1.0.0"` on roots, nest arbitrary
# objects in `summaries`, and use extension keys no struct knows about.

using STAC, Test, JSON, Dates
using STAC: Item, Catalog, Collection, ItemCollection, STACStyle, ParseOptions, itemtype

include("fixtures.jl")

const TYPEOF_DOCTYPE = Dict(
    "Feature" => Item,
    "FeatureCollection" => ItemCollection,
    "Catalog" => Catalog,
    "Collection" => Collection,
)

@testset "every recorded document parses into the type its `type` key names" begin
    for path in jsonfiles(REAL_DIR)
        raw = JSON.parse(read(path))
        obj = STAC.read(path)
        @test obj isa TYPEOF_DOCTYPE[raw["type"]]
    end
end

@testset "any stac_version is accepted and written back unchanged" begin
    root = STAC.read(joinpath(REAL_DIR, "itslive.root.json"))
    @test root isa Catalog
    @test get(root.metadata, "stac_version", nothing) == "1.0.0"
    @test JSON.parse(STAC.json(root))["stac_version"] == "1.0.0"

    newer = STAC.read(joinpath(REAL_DIR, "usgs.root.json"))
    @test JSON.parse(STAC.json(newer))["stac_version"] == "1.1.0"
end

@testset "search pages parse as ItemCollections with typed extension fields" begin
    for path in filter(p -> occursin("search", p), jsonfiles(REAL_DIR))
        page = STAC.read(path)
        @test page isa ItemCollection
        raw = JSON.parse(read(path))
        @test length(page.features) == length(raw["features"])
        for (item, rawitem) in zip(page.features, raw["features"])
            props = rawitem["properties"]
            declared = haskey(props, "proj:code") || haskey(props, "proj:epsg") ||
                       haskey(props, "proj:shape") || haskey(props, "proj:transform")
            @test (item.extensions.proj !== nothing) == declared
            haskey(props, "proj:code") && @test item.extensions.proj.code == props["proj:code"]
            haskey(props, "eo:cloud_cover") &&
                @test item.extensions.eo.cloud_cover == props["eo:cloud_cover"]
        end
    end
end

@testset "a producer that sets proj:code fills extensions.proj.code" begin
    page = STAC.read(joinpath(REAL_DIR, "itslive.search.json"))
    codes = [item.extensions.proj.code for item in page.features]
    @test all(!isnothing, codes)
    @test all(c -> startswith(c, "EPSG:"), codes)
end

@testset "the key-set round trip holds for every recorded document" begin
    for path in jsonfiles(REAL_DIR)
        obj = STAC.read(path)
        source = JSON.parse(read(path))
        written = JSON.parse(STAC.json(obj))
        @test isempty(setdiff(keypaths(written), keypaths(source)))
        @test issubset(setdiff(keypaths(source), keypaths(written)), nullkeypaths(source))
        @test STAC.parse(STAC.json(obj)) == STAC.sethref(obj, nothing)
    end
end

@testset "a Planetary Computer item parses inferably" begin
    page = JSON.parse(read(joinpath(REAL_DIR, "pc.search.json")))
    bytes = Vector{UInt8}(JSON.json(page["features"][1]))
    T = itemtype(ParseOptions())
    @test @inferred(JSON.parse(bytes, T; style = STACStyle())) isa T
end

@testset "producer-specific collection keys land on the tails" begin
    pc = STAC.read(joinpath(REAL_DIR, "pc.collection.json"))
    @test pc isa Collection
    @test haskey(pc.metadata, "msft:storage_account")
    @test haskey(pc.metadata, "item_assets")
    @test pc.summaries !== nothing
    @test !isempty(pc.summaries)

    cdse = STAC.read(joinpath(REAL_DIR, "cdse.collection.json"))
    @test haskey(cdse.metadata, "sci:doi")
    @test cdse.assets !== nothing
end
