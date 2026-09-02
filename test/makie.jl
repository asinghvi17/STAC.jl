using STAC, Test
using STAC: Item, ItemCollection
import GeoInterface as GI
import Makie

include("fixtures.jl")

const CATALOG = joinpath(HAND_DIR, "antimeridian-catalog", "catalog.json")

catalogitems() = collect(items(STAC.read(CATALOG); recursive = true))

byid(its, id) = only(filter(i -> i.id == id, its))

# A plotting backend draws what `convert_arguments` hands it, so converting is the whole of
# what STAC.jl owns here; no backend is loaded.

@testset "an item converts to the geometry Makie draws" begin
    item = byid(catalogitems(), "greenwich")

    @test Makie.plottype(item) === Makie.Poly
    @test GI.geomtrait(only(Makie.convert_arguments(Makie.Poly, item))) isa GI.PolygonTrait

    for p in (Makie.Lines, Makie.PointBased())
        ring = only(Makie.convert_arguments(p, item))
        @test all(pt -> GI.geomtrait(pt) isa GI.PointTrait, ring)
        # The ring is the item's own, not its bounding box.
        @test length(ring) == GI.npoint(GI.geometry(item))
    end
end

@testset "a vector of items and an ItemCollection convert as one geometry each" begin
    its = catalogitems()

    for arg in (its, ItemCollection(its))
        polys = only(Makie.convert_arguments(Makie.Poly, arg))
        @test length(polys) == length(its)
        @test Makie.plottype(arg) === Makie.Poly

        # The item with no geometry holds its place as a NaN polygon, so that a vector of
        # per-item colors still lines up with the geometries.
        holes = findall(p -> any(isnan, first(GI.getpoint(p))), polys)
        @test holes == findall(i -> GI.geometry(i) === nothing, its)
    end
end

@testset "items mixing Polygon and MultiPolygon convert to one type" begin
    multis = STAC.read(joinpath(endpointdir("cdse"), "items.json")).features
    mixed = vcat(multis, catalogitems()[1:2])
    @test length(unique(typeof.(GI.geometry.(mixed)))) == 2

    polys = only(Makie.convert_arguments(Makie.Poly, mixed))
    @test length(polys) == length(mixed)
    @test isconcretetype(eltype(polys))
    @test all(p -> GI.geomtrait(p) isa GI.MultiPolygonTrait, polys)
end
