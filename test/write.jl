using STAC, Test, JSON, Dates

include("fixtures.jl")

@testset "the written document carries the source document's keys, at every depth" begin
    # The writer invents no key, and drops only keys whose source value is null.
    for path in [jsonfiles(SPEC_DIR); jsonfiles(HAND_DIR)]
        source = JSON.parse(read(path))
        written = JSON.parse(STAC.json(STAC.read(path)))
        @test isempty(setdiff(keypaths(written), keypaths(source)))
        @test issubset(setdiff(keypaths(source), keypaths(written)), nullkeypaths(source))
    end
end

@testset "reparsing a written document gives the same object" begin
    for path in [jsonfiles(SPEC_DIR); jsonfiles(HAND_DIR)]
        obj = STAC.sethref(STAC.read(path), nothing)
        @test STAC.parse(STAC.json(obj)) == obj
    end
end

@testset "the writer restores `type` and `stac_version`" begin
    for path in jsonfiles(SPEC_DIR)
        written = JSON.parse(STAC.json(STAC.read(path)))
        source = JSON.parse(read(path))
        @test written["type"] == source["type"]
        @test written["stac_version"] == source["stac_version"]
    end
end

@testset "meaningful nulls survive and absent values stay absent" begin
    item = STAC.read(joinpath(SPEC_DIR, "core-item.json"))
    written = JSON.parse(STAC.json(item))
    @test written["properties"]["datetime"] === nothing
    @test haskey(written, "geometry")

    hand = JSON.parse(STAC.json(STAC.read(joinpath(HAND_DIR, "hand-item.json"))))
    @test !haskey(hand, "collection")
    @test !haskey(hand["properties"], "gsd")
end

@testset "declared extensions are written back under their prefixes" begin
    item = STAC.read(joinpath(SPEC_DIR, "extended-item.json"))
    props = JSON.parse(STAC.json(item))["properties"]
    @test props["eo:cloud_cover"] == 1.2
    @test props["proj:code"] == "EPSG:32659"
    @test !haskey(props, "proj:epsg")
end

@testset "keywords reach JSON.jl" begin
    item = STAC.read(joinpath(SPEC_DIR, "simple-item.json"))
    @test occursin("\n", STAC.json(item; pretty = 2))
    io = IOBuffer()
    STAC.json(io, item)
    @test JSON.parse(String(take!(io)))["id"] == item.id
end

@testset "an in-memory object writes without a source document" begin
    link = STAC.Link("./child.json", "child", nothing, nothing, nothing, nothing,
                     nothing, nothing, STAC.Metadata())
    cat = STAC.Catalog{STAC.NoMetadata}("root", nothing, "Root", "a catalog", [link],
                                        STAC.NoMetadata(), nothing)
    written = JSON.parse(STAC.json(cat))
    @test written["type"] == "Catalog"
    @test written["stac_version"] == STAC.STAC_VERSION
    @test written["links"][1]["rel"] == "child"
    @test !haskey(written["links"][1], "type")
end
