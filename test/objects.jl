using STAC, Test, Dates, JSON, OrderedCollections
using STAC: Metadata, NoMetadata, Link, Asset, Band, Provider, Properties,
            SpatialExtent, TemporalExtent, CollectionExtent, Catalog, Collection,
            Item, ItemCollection, sethref

include("fixtures.jl")

@testset "Metadata answers the mapping accessors" begin
    m = Metadata(JSON.Object{String,Any}("b" => 1, "a" => 2))
    @test collect(keys(m)) == ["b", "a"]        # document order, not sorted
    @test haskey(m, "a")
    @test m["a"] == 2
    @test get(m, "missing", :fallback) === :fallback
    @test length(m) == 2
    @test !isempty(m)
    @test collect(m) == ["b" => 1, "a" => 2]
    @test Metadata() == Metadata(JSON.Object{String,Any}())
end

@testset "NoMetadata answers them as an empty mapping" begin
    n = NoMetadata()
    @test keys(n) == ()
    @test !haskey(n, "a")
    @test get(n, "a", :fallback) === :fallback
    @test length(n) == 0
    @test isempty(n)
    @test collect(n) == Any[]
end

@testset "objects compare field by field" begin
    a = Link("h", "self", nothing, nothing, nothing, nothing, nothing, nothing, Metadata())
    b = Link("h", "self", nothing, nothing, nothing, nothing, nothing, nothing, Metadata())
    @test a == b
    @test a != Link("g", "self", nothing, nothing, nothing, nothing, nothing, nothing, Metadata())

    # Vectors of equal contents are distinct objects, which `===` would reject.
    @test Asset("h", nothing, nothing, nothing, ["data"], nothing, Metadata()) ==
          Asset("h", nothing, nothing, nothing, ["data"], nothing, Metadata())
end

@testset "sethref rebuilds only the outer struct" begin
    item = STAC.read(joinpath(SPEC_DIR, "simple-item.json"))
    moved = sethref(item, "https://example.com/simple-item.json")
    @test moved.href == "https://example.com/simple-item.json"
    @test moved.links === item.links
    @test moved.assets === item.assets
    @test sethref(item, nothing).href === nothing

    for path in jsonfiles(SPEC_DIR)
        obj = STAC.read(path)
        @test sethref(obj, nothing).href === nothing
    end
end

@testset "the parsed field types are the declared ones" begin
    item = STAC.read(joinpath(SPEC_DIR, "extended-item.json"))
    @test item.id isa String
    @test item.links isa Vector{Link}
    @test item.assets isa OrderedDict{String,Asset}
    @test item.properties isa Properties{Metadata}
    @test item.properties.gsd isa Union{Float64,Nothing}
    @test item.bbox isa NTuple{4,Float64}

    col = STAC.read(joinpath(SPEC_DIR, "collection.json"))
    @test col.extent isa CollectionExtent
    @test col.extent.spatial isa SpatialExtent
    @test col.extent.spatial.bbox isa Vector{Vector{Float64}}
    @test col.extent.temporal isa TemporalExtent
    @test col.extent.temporal.interval[1][1] isa DateTime
    @test col.extent.temporal.interval[1][2] isa DateTime
    @test col.providers isa Vector{Provider}
    @test col.summaries isa Metadata
    @test col.license isa String

    # An open interval end is `nothing`, which the element type admits.
    openended = STAC.read(joinpath(SPEC_DIR, "collection-only", "collection.json"))
    @test openended.extent.temporal.interval[1][1] == DateTime(2015, 6, 23)
    @test openended.extent.temporal.interval[1][2] === nothing
end

@testset "assets keep the producer's key order" begin
    item = STAC.read(joinpath(SPEC_DIR, "extended-item.json"))
    raw = JSON.parse(read(joinpath(SPEC_DIR, "extended-item.json")))
    @test collect(keys(item.assets)) == collect(keys(raw["assets"]))
end

@testset "an ItemCollection holds one concrete item type" begin
    fc = STAC.read(joinpath(REAL_DIR, "es.search.json"))
    @test fc isa ItemCollection
    @test eltype(fc.features) == typeof(first(fc.features))
    @test fc.numberReturned == length(fc.features)
end

@testset "an ItemCollection wraps a vector of items" begin
    fc = STAC.read(joinpath(REAL_DIR, "es.search.json"))
    page = ItemCollection(fc.features)
    @test page.features === fc.features
    @test page.links == Link[]
    @test page.numberMatched === nothing
    @test page.numberReturned == length(fc.features)
    @test page.metadata == Metadata()
    @test page.href === nothing

    # The metadata default is the empty tail of the item type's `M`, not `Metadata` always.
    bare = STAC.read(joinpath(REAL_DIR, "es.search.json"); metadata = false)
    @test ItemCollection(bare.features).metadata === NoMetadata()

    full = ItemCollection(fc.features; links = fc.links, numberMatched = 42,
                          numberReturned = 1, metadata = fc.metadata, href = "h")
    @test full.links == fc.links
    @test full.numberMatched == 42
    @test full.numberReturned == 1
    @test full.href == "h"
end
