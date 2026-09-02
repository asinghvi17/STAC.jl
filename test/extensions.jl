using STAC, Test, JSON
using STAC: EO, Projection, Extension, prefix, schema, extensiontype, Item

include("fixtures.jl")

@testset "an extension is a struct, a prefix, and a schema" begin
    @test EO <: Extension
    @test Projection <: Extension
    @test prefix(EO) == "eo"
    @test prefix(Projection) == "proj"
    @test startswith(schema(EO), "https://stac-extensions.github.io/eo/")
    @test startswith(schema(Projection), "https://stac-extensions.github.io/projection/")
end

@testset "extensiontype keys the NamedTuple by prefix" begin
    E = extensiontype((EO, Projection))
    @test fieldnames(E) == (:eo, :proj)
    @test fieldtype(E, :eo) == Union{EO,Nothing}
    @test fieldtype(E, :proj) == Union{Projection,Nothing}
    @test extensiontype(()) === Any
end

@testset "a declared extension with no keys on the item is nothing" begin
    item = STAC.read(joinpath(SPEC_DIR, "simple-item.json"))
    @test item.extensions.eo === nothing
    @test item.extensions.proj === nothing
end

@testset "the deprecated proj:epsg is read next to proj:code" begin
    coded = STAC.read(joinpath(SPEC_DIR, "extended-item.json"))
    @test coded.extensions.proj.code == "EPSG:32659"
    @test coded.extensions.proj.epsg === nothing

    numbered = STAC.read(joinpath(HAND_DIR, "hand-item.json"))
    @test numbered.extensions.proj.epsg == 4326
    @test numbered.extensions.proj.code === nothing
end

@testset "a user-declared subset changes what the item type carries" begin
    item = STAC.read(joinpath(SPEC_DIR, "extended-item.json"); extensions = (EO,))
    @test fieldnames(typeof(item.extensions)) == (:eo,)
    @test item.extensions.eo.cloud_cover == 1.2
    # An undeclared prefix falls to the property tail rather than being dropped.
    @test item.properties.other["proj:code"] == "EPSG:32659"
end

@testset "extension fields survive a write and a reparse" begin
    item = STAC.read(joinpath(SPEC_DIR, "extended-item.json"))
    back = STAC.parse(STAC.json(item))
    @test back.extensions.eo == item.extensions.eo
    @test back.extensions.proj == item.extensions.proj
end
