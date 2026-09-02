using STAC, Test, JSON, Dates, GeoJSON
using STAC: EO, Projection, Raster, Sat, Scientific, View, Extension, prefix, schema,
            extensiontype, Item, Metadata

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

@testset "the four extensions this phase adds read their own keys" begin
    item = STAC.read(joinpath(SPEC_DIR, "extended-item.json"))
    @test item.extensions.view.off_nadir == 3.8
    @test item.extensions.view.sun_elevation == 54.9
    @test item.extensions.sci.doi == "10.5061/dryad.s2v81.2/27.2"
    # Declared, but the document sets none of their keys.
    @test item.extensions.raster === nothing
    @test item.extensions.sat === nothing

    pc = first(STAC.read(joinpath(REAL_DIR, "pc.search.json")).features)
    @test pc.extensions.sat.orbit_state == "descending"
    @test pc.extensions.sat.relative_orbit isa Int
end

@testset "a value from the tail is lifted to the field's type" begin
    tail = Metadata(JSON.Object{String,Any}("sat:anx_datetime" => "2024-06-04T23:51:29Z",
                                            "sat:absolute_orbit" => 37693))
    sat = STAC.fromtail(STAC.Sat, tail)
    @test sat.anx_datetime == DateTime(2024, 6, 4, 23, 51, 29)
    @test sat.absolute_orbit === 37693
    @test sat.orbit_state === nothing
    @test STAC.fromtail(STAC.Sat, Metadata()) === nothing
end

@testset "an undeclared extension is reachable three ways" begin
    item = STAC.read(joinpath(SPEC_DIR, "extended-item.json"); extensions = (EO,))
    @test item.extensions.eo.cloud_cover == 1.2                       # the eager field
    @test get(item, EO) == item.extensions.eo                         # the field again
    @test get(item, View).off_nadir isa Float64                       # from the tail
    @test View(item).off_nadir == 3.8
    @test get(item, Sat) === nothing
    @test_throws ArgumentError Sat(item)
end

@testset "asset-level and collection-level keys read from their own tails" begin
    pc = first(STAC.read(joinpath(REAL_DIR, "pc.search.json")).features)
    asset = pc.assets["AOT"]
    @test haskey(asset.metadata, "proj:shape")
    @test Projection(asset).shape == asset.metadata["proj:shape"]
    @test Projection(asset).code === nothing
    @test get(pc.assets["preview"], Projection) === nothing

    cdse = STAC.read(joinpath(REAL_DIR, "cdse.collection.json"))
    @test Scientific(cdse).doi == cdse.metadata["sci:doi"]
end

@testset "declares reads the list, not the keys" begin
    hand = STAC.read(joinpath(HAND_DIR, "hand-item.json"))
    # The item declares eo at 1.1.0 and this package types 2.0.0: same schema, other version.
    @test hand.stac_extensions == ["https://stac-extensions.github.io/eo/v1.1.0/schema.json"]
    @test STAC.declares(hand, EO)
    @test STAC.declares(hand, "https://stac-extensions.github.io/eo/v2.0.0/schema.json")
    # It carries proj: and sat: keys without declaring either.
    @test !STAC.declares(hand, Projection)
    @test hand.extensions.proj !== nothing
    @test !STAC.declares(hand, View)

    # The list is a field, so `metadata = false` neither drops it nor breaks `declares`.
    bare = STAC.read(joinpath(HAND_DIR, "hand-item.json"); metadata = false)
    @test STAC.declares(bare, EO)
    @test JSON.parse(STAC.json(bare))["stac_extensions"] == hand.stac_extensions

    # An empty list and an absent one both declare nothing.
    simple = STAC.read(joinpath(SPEC_DIR, "simple-item.json"))
    @test isempty(simple.stac_extensions)
    @test !STAC.declares(simple, EO)
    @test !STAC.declares(STAC.read(joinpath(SPEC_DIR, "catalog.json")), EO)

    # Collections declare extensions the same way items do.
    col = STAC.read(joinpath(SPEC_DIR, "collection.json"))
    @test STAC.declares(col, EO)
    @test STAC.declares(col, View)
    @test !STAC.declares(col, Sat)
end

@testset "extensions = () keeps every prefixed key reachable" begin
    item = STAC.read(joinpath(SPEC_DIR, "extended-item.json"); extensions = ())
    @test item isa Item{Any}
    @test item.extensions === nothing
    for key in ("eo:cloud_cover", "proj:code", "view:off_nadir", "sci:doi", "rd:sat_id")
        @test haskey(item.properties.other, key)
    end
    @test get(item, EO).cloud_cover == 1.2
    @test EO(item).snow_cover == 0.0

    source = JSON.parse(read(joinpath(SPEC_DIR, "extended-item.json")))
    written = JSON.parse(STAC.json(item))
    @test keypaths(written) == keypaths(source)
end

@testset "an unknown catalog reads with the widest geometry" begin
    opts = STAC.ParseOptions(; extensions = (), geometry = GeoJSON.AbstractGeometry)
    @test STAC.itemtype(opts) == Item{Any,STAC.ANY_GEOMETRY,Metadata}
    item = STAC.read(joinpath(SPEC_DIR, "simple-item.json");
                     extensions = (), geometry = GeoJSON.AbstractGeometry)
    @test item.geometry isa GeoJSON.Polygon{2,Float64}
    @test STAC.parse(STAC.json(item), opts).id == item.id
end
