using STAC, Test, Extents
using STAC: Item, ItemCollection, WGS84, leaf_extent, lift, spherebox
import GeoInterface as GI
import GeometryOps as GO

include("fixtures.jl")

const CATALOG = joinpath(HAND_DIR, "antimeridian-catalog", "catalog.json")

catalogitems() = collect(items(STAC.read(CATALOG); recursive = true))

byid(its, id) = only(filter(i -> i.id == id, its))

@testset "an item is a GeoInterface feature" begin
    its = catalogitems()
    item = byid(its, "greenwich")

    @test GI.testfeature(item)
    @test GI.isfeature(typeof(item))
    @test GI.trait(item) isa GI.FeatureTrait
    @test GI.geometry(item) === item.geometry
    @test GI.properties(item) === item.properties
    @test GI.crs(item) == WGS84
    @test GI.crs(item) == GI.crs(item.geometry)

    # An item with neither geometry nor bbox is still a feature, with nothing in it.
    @test GI.testfeature(byid(its, "unlocated"))
    @test GI.geometry(byid(its, "unlocated")) === nothing
    @test Extents.extent(byid(its, "unlocated")) === nothing
end

@testset "a vector of items and an ItemCollection are feature collections" begin
    its = catalogitems()
    @test GI.testfeaturecollection(its)
    @test GI.trait(its) isa GI.FeatureCollectionTrait
    @test GI.nfeature(GI.trait(its), its) == length(its)
    @test GI.crs(its) == WGS84
    @test GI.geometrycolumns(its) == (:geometry,)

    fc = ItemCollection(its)
    @test GI.testfeaturecollection(fc)
    @test GI.nfeature(GI.trait(fc), fc) == length(its)
    @test GI.getfeature(GI.trait(fc), fc, 1) === its[1]
    @test GI.crs(fc) == WGS84
end

@testset "an item's extent is its bbox" begin
    its = catalogitems()
    @test Extents.extent(byid(its, "greenwich")) == Extent(X = (-1.0, 1.0), Y = (-1.0, 1.0))

    # A bbox that crosses the antimeridian is reported as the producer wrote it, west first.
    @test Extents.extent(byid(its, "straddle")) == Extent(X = (170.0, -170.0), Y = (60.0, 70.0))

    # Six numbers are (west, south, low, east, north, high), so the elevation pair is `Z`.
    six = STAC.read(joinpath(HAND_DIR, "hand-item.json"))
    @test keys(Extents.extent(six)) == (:X, :Y, :Z)
    @test Extents.extent(six).Z == (six.bbox[3], six.bbox[6])

    @test GI.extent(byid(its, "greenwich")) == Extents.extent(byid(its, "greenwich"))
    @test Extents.extent(its) == reduce(Extents.union, filter(!isnothing, Extents.extent.(its)))

    # A page locating nothing has no extent, and neither does an empty one.
    @test Extents.extent([byid(its, "unlocated")]) === nothing
    @test Extents.extent(ItemCollection(empty(its))) === nothing
end

@testset "a longitude/latitude box lifts to the 3D box that covers it" begin
    # Every corner of the rectangle lands inside the box it lifts to.
    corners(w, s, e, n) = [(lon, lat) for lon in (w, e), lat in (s, n)]
    inbox(box, (lon, lat)) = let p = GO.UnitSpherical.UnitSphereFromGeographic()((lon, lat))
        box.X[1] <= p[1] <= box.X[2] && box.Y[1] <= p[2] <= box.Y[2] &&
            box.Z[1] <= p[3] <= box.Z[2]
    end

    for (w, s, e, n) in ((-1.0, -1.0, 1.0, 1.0), (170.0, 60.0, -170.0, 70.0),
                         (-180.0, 85.0, 180.0, 90.0), (-123.0, 37.0, -122.0, 38.0))
        box = spherebox(w, s, e, n)
        @test keys(box) == (:X, :Y, :Z)
        @test all(p -> inbox(box, p), corners(w, s, e, n))
    end

    # The pole itself is in the box of a rectangle that reaches it, and only there.
    @test inbox(spherebox(-180, 85, 180, 90), (0.0, 90.0))
    @test !inbox(spherebox(-1, -1, 1, 1), (0.0, 90.0))

    # A rectangle crossing the antimeridian covers the short way round: 180° is inside it and
    # the opposite meridian is not.
    straddle = spherebox(170, 60, -170, 70)
    @test inbox(straddle, (180.0, 65.0))
    @test !inbox(straddle, (0.0, 65.0))
end

@testset "every query input lifts onto the manifold the index is built in" begin
    poly = GI.Polygon([GI.LinearRing([(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, -1.0)])])
    box = Extent(X = (-1.0, 1.0), Y = (-1.0, 1.0))

    @test lift(GO.Planar(), box) == box
    @test lift(GO.Planar(), (-1, -1, 1, 1)) == box
    @test lift(GO.Planar(), [-1, -1, 0, 1, 1, 10]) == box       # elevation is not indexed
    @test lift(GO.Planar(), poly) == box
    @test lift(GO.Planar(), nothing) === nothing

    @test lift(GO.Spherical(), box) == spherebox(-1, -1, 1, 1)
    @test lift(GO.Spherical(), (-1, -1, 1, 1)) == spherebox(-1, -1, 1, 1)
    @test lift(GO.Spherical(), poly) == Extents.extent(GO.Spherical(), poly)

    # An X/Y/Z extent is already on the unit sphere, and stays as it is.
    cartesian = Extent(X = (0.0, 1.0), Y = (0.0, 1.0), Z = (0.0, 1.0))
    @test lift(GO.Spherical(), cartesian) == cartesian

    point = GO.UnitSpherical.UnitSphericalPoint(0.0, 0.0, 1.0)
    @test lift(GO.Spherical(), point) == Extent(X = (0.0, 0.0), Y = (0.0, 0.0), Z = (1.0, 1.0))

    cap = GO.UnitSpherical.SphericalCap(point, 0.1)
    @test lift(GO.Spherical(), cap) === cap

    @test_throws STAC.NotQueryable("String") lift(GO.Spherical(), "POLYGON((0 0))")
    @test_throws STAC.BadBBox(3) lift(GO.Spherical(), (1, 2, 3))
end

@testset "an item's leaf box comes from its bbox, then from its geometry" begin
    its = catalogitems()
    item = byid(its, "greenwich")

    @test leaf_extent(GO.Planar(), item) == Extent(X = (-1.0, 1.0), Y = (-1.0, 1.0))
    @test leaf_extent(GO.Spherical(), item) == spherebox(-1, -1, 1, 1)
    @test leaf_extent(GO.Spherical(), byid(its, "unlocated")) === nothing

    # Without a bbox the geometry's own vertices give the rectangle, and the same lift runs.
    nobbox = Item(item.id, item.stac_extensions, item.geometry, nothing, item.properties,
                  item.links, item.assets, item.collection, item.extensions, item.metadata,
                  item.href)
    @test Extents.extent(nobbox) == Extent(X = (-1.0, 1.0), Y = (-1.0, 1.0))
    @test leaf_extent(GO.Planar(), nobbox) == Extent(X = (-1.0, 1.0), Y = (-1.0, 1.0))
    @test leaf_extent(GO.Spherical(), nobbox) == spherebox(-1, -1, 1, 1)

    # The trim-safe vertex walk the leaves are built with names the rectangle `GI.extent`
    # names, so the two paths a geometry can take through this file agree.
    @test all(i -> STAC.pointextent(i.geometry) == GI.extent(i.geometry),
              filter(i -> i.geometry !== nothing, its))

    # One box type per manifold, so a tree's leaves never mix key sets.
    @test all(i -> leaf_extent(GO.Planar(), i) isa Union{Nothing,STAC.XYExtent}, its)
    @test all(i -> leaf_extent(GO.Spherical(), i) isa Union{Nothing,STAC.XYZExtent}, its)
end
