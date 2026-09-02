using STAC, Test, Extents, DE9IM, GeoJSON
using STAC: SpatialIndex, query, spatialindex
import GeoInterface as GI
import GeometryOps as GO

include("fixtures.jl")

const CATALOG = joinpath(HAND_DIR, "antimeridian-catalog", "catalog.json")

catalogitems() = collect(items(STAC.read(CATALOG); recursive = true))

hits(idx, input) = [idx.items[i].id for i in query(idx, input)]

# The 4° box centred on the origin, which `greenwich` sits inside and `outside-corner`
# only reaches into.
const REGION =
    GI.Polygon([GI.LinearRing([(-2.0, -2.0), (2.0, -2.0), (2.0, 2.0), (-2.0, 2.0), (-2.0, -2.0)])])

const REGION_JSON = GeoJSON.write(REGION)

@testset "the spherical index answers across the antimeridian, the planar one does not" begin
    its = catalogitems()
    straddle = Extent(X = (170, -170), Y = (60, 70))

    @test hits(spatialindex(its), straddle) == ["straddle"]

    # The same box read as a plane is empty, west being east of east, which is the case a
    # user picks `Planar()` to rule out.
    @test hits(spatialindex(GO.Planar(), its), straddle) == String[]
    @test hits(spatialindex(its; manifold = GO.Planar()), Extent(X = (-1, 1), Y = (-1, 1))) ==
          ["greenwich"]
end

@testset "a cap at the pole finds the item that covers it" begin
    its = catalogitems()
    idx = spatialindex(its)
    northcap(r) = GO.UnitSpherical.SphericalCap(GO.UnitSpherical.UnitSphericalPoint(0.0, 0.0, 1.0), r)

    @test hits(idx, northcap(0.05)) == ["north-pole"]
    @test hits(idx, GO.UnitSpherical.SphericalCap(
        GO.UnitSpherical.UnitSphericalPoint(0.0, 0.0, -1.0), 0.05)) == ["south-pole"]
    @test hits(idx, GO.UnitSpherical.UnitSphericalPoint(0.0, 0.0, 1.0)) == ["north-pole"]
end

@testset "a predicate runs an exact pass over the tree's candidates" begin
    its = catalogitems()
    idx = spatialindex(its)

    # The coarse pass keeps both boxes that meet the region; `Within` drops the geometry that
    # leaves it.
    @test hits(idx, REGION) == ["greenwich", "outside-corner"]
    @test hits(idx, Within(REGION)) == ["greenwich"]
    @test hits(idx, Intersects(REGION)) == ["greenwich", "outside-corner"]
    @test hits(idx, Covers(REGION)) == String[]
    @test hits(idx, CoveredBy(REGION)) == ["greenwich"]

    # Disjointness holds where the extents do not meet, so it is the one predicate whose
    # candidates are every item rather than the tree's answer.
    @test hits(idx, Disjoint(REGION)) == ["straddle", "north-pole", "south-pole", "bay-area"]

    # An item that locates itself nowhere is in no answer at all.
    @test !("unlocated" in hits(idx, Disjoint(REGION)))

    @test_throws STAC.EmptyPredicate("Within") query(idx, Within())
end

@testset "a Float32 query geometry is lifted to Float64 before the spherical pass" begin
    its = catalogitems()
    idx = spatialindex(its)

    # GeoJSON.jl reads positions as Float32 unless told otherwise, and every spherical pass
    # runs on ExactPredicates, which takes Float64 alone.
    region32 = GeoJSON.read(REGION_JSON)
    region64 = GeoJSON.read(REGION_JSON; numbertype = Float64)
    @test region32 isa GeoJSON.Polygon{2,Float32}

    @test hits(idx, region32) == hits(idx, region64)
    @test hits(idx, Within(region32)) == hits(idx, Within(region64)) == ["greenwich"]
    @test hits(idx, Disjoint(region32)) == hits(idx, Disjoint(region64))
end

@testset "the planar and spherical exact passes agree away from the edges" begin
    its = catalogitems()
    @test hits(spatialindex(GO.Planar(), its), Within(REGION)) ==
          hits(spatialindex(GO.Spherical(), its), Within(REGION))
end

@testset "hits are positions into the indexed vector, ascending and unique" begin
    its = catalogitems()
    idx = spatialindex(its)
    whole = query(idx, Extent(X = (-180, 180), Y = (-90, 90)))

    @test whole isa Vector{Int}
    @test issorted(whole)
    @test allunique(whole)
    # Six of the seven items locate themselves; `unlocated` stays out of the tree.
    @test length(whole) == 6
    @test query(idx, nothing) == collect(1:7)
end

@testset "an index over items that locate themselves nowhere still answers" begin
    its = catalogitems()
    unlocated = filter(i -> i.id == "unlocated", its)
    idx = spatialindex(unlocated)

    @test idx.tree === nothing
    @test length(idx) == 1
    @test query(idx, Extent(X = (-180, 180), Y = (-90, 90))) == Int[]
    @test query(idx, nothing) == [1]
    @test query(idx, Within(REGION)) == Int[]
end

@testset "an index is a spatial tree" begin
    its = catalogitems()
    idx = spatialindex(its)

    @test GO.SpatialTreeInterface.isspatialtree(typeof(idx))
    @test GO.SpatialTreeInterface.nchild(idx) == GO.SpatialTreeInterface.nchild(idx.tree)
    @test Extents.extent(idx) == Extents.extent(idx.tree)

    # The coarse pass through the tree interface reaches the same leaves as `query`.
    found = GO.SpatialTreeInterface.depth_first_search(
        Base.Fix1(Extents.intersects, STAC.lift(idx.manifold, REGION)), idx)
    @test sort(found) == query(idx, REGION)
end
