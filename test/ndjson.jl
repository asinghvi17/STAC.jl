using STAC, Test, Dates
using STAC: Item, Metadata, NoMetadata, read_ndjson, write_ndjson

include("fixtures.jl")

catalog() = STAC.read(joinpath(STATIC_DIR, "self-contained", "catalog.json"))

specitems() = [STAC.sethref(STAC.read(joinpath(SPEC_DIR, f)), nothing)
               for f in ("simple-item.json", "core-item.json", "extended-item.json",
                         "collectionless-item.json")]

@testset "the spec items written and read back are the same items" begin
    items = specitems()
    path = joinpath(mktempdir(), "items.ndjson")
    @test write_ndjson(path, items) == 4
    @test countlines(path) == 4
    back = collect(read_ndjson(path))
    @test back isa Vector{eltype(items)}
    @test back == items
end

@testset "the reader is lazy" begin
    path = joinpath(mktempdir(), "items.ndjson")
    write_ndjson(path, specitems())
    # A line the reader never reaches is never parsed, so a corrupt one costs nothing until
    # the iteration arrives at it.
    open(path, "a") do io
        println(io, "{ this is not JSON")
    end
    lines = read_ndjson(path)
    @test first(lines).id == "20201211_223832_CS2"
    @test length(collect(Iterators.take(lines, 4))) == 4
    @test_throws Exception collect(lines)
end

@testset "the parse keywords reach the items" begin
    path = joinpath(mktempdir(), "items.ndjson")
    write_ndjson(path, specitems())
    plain = first(read_ndjson(path; extensions = (), metadata = false))
    @test plain isa Item{Any,STAC.DEFAULT_GEOMETRY,NoMetadata}
    @test plain.metadata isa NoMetadata
    typed = first(read_ndjson(path))
    @test typed.extensions.eo === nothing || typed.extensions.eo isa STAC.EO
end

@testset "an IO reads the same lines a path does" begin
    path = joinpath(mktempdir(), "items.ndjson")
    write_ndjson(path, specitems())
    ids = open(io -> [i.id for i in read_ndjson(io)], path)
    @test ids == [i.id for i in read_ndjson(path)]
end

@testset "blank lines are skipped" begin
    path = joinpath(mktempdir(), "items.ndjson")
    open(path, "w") do io
        print(io, "\n")
        write_ndjson(io, specitems()[1:2])
        print(io, "\n   \n")
    end
    @test length(collect(read_ndjson(path))) == 2
end

@testset "a traversal streams into a file without being collected first" begin
    path = joinpath(mktempdir(), "walk.ndjson")
    @test write_ndjson(path, items(catalog(); recursive = true)) == 4
    @test [i.id for i in read_ndjson(path)] == STATIC_ITEM_IDS
end

@testset "extension keys survive the round trip" begin
    path = joinpath(mktempdir(), "one.ndjson")
    item = STAC.sethref(STAC.read(joinpath(SPEC_DIR, "extended-item.json")), nothing)
    write_ndjson(path, [item])
    back = first(read_ndjson(path))
    @test back.extensions.eo.cloud_cover == 1.2
    @test back.extensions.proj.code == "EPSG:32659"
    @test back == item
end
