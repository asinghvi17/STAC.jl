# Items as GeoInterface features, and the manifold boxes the spatial index is built and
# queried with.

"""
    STAC.WGS84

The coordinate reference system of every STAC geometry. GeoJSON fixes longitude/latitude on
WGS 84, and STAC inherits it.
"""
const WGS84 = GeoFormatTypes.EPSG(4326)

# ---------------------------------------------------------------------------------------
# GeoInterface

GI.isfeature(::Type{<:Item}) = true
GI.trait(::Item) = GI.FeatureTrait()
GI.geometry(item::Item) = item.geometry
GI.properties(item::Item) = item.properties
GI.crs(::GI.FeatureTrait, ::Item) = WGS84

GI.isfeaturecollection(::Type{<:ItemCollection}) = true
GI.isfeaturecollection(::Type{<:AbstractVector{<:Item}}) = true

GI.trait(::ItemCollection) = GI.FeatureCollectionTrait()
GI.trait(::AbstractVector{<:Item}) = GI.FeatureCollectionTrait()

GI.nfeature(::GI.FeatureCollectionTrait, fc::ItemCollection) = length(fc.features)
GI.getfeature(::GI.FeatureCollectionTrait, fc::ItemCollection, i::Integer) = fc.features[i]
GI.getfeature(::GI.FeatureCollectionTrait, fc::ItemCollection) = fc.features

GI.nfeature(::GI.FeatureCollectionTrait, items::AbstractVector{<:Item}) = length(items)
GI.getfeature(::GI.FeatureCollectionTrait, items::AbstractVector{<:Item}, i::Integer) = items[i]
GI.getfeature(::GI.FeatureCollectionTrait, items::AbstractVector{<:Item}) = items

GI.crs(::GI.FeatureCollectionTrait, ::ItemCollection) = WGS84
GI.crs(::GI.FeatureCollectionTrait, ::AbstractVector{<:Item}) = WGS84

# ---------------------------------------------------------------------------------------
# Extents

"""
    Extents.extent(item::Item) -> Union{Extents.Extent,Nothing}

The item's `bbox` as an `Extents.Extent`, in the key order STAC writes it.

| `bbox` | Keys |
|---|---|
| 4 numbers | `X = (west, east)`, `Y = (south, north)` |
| 6 numbers | the same, plus `Z = (low, high)` |
| absent | `GeoInterface.extent` of the geometry, or `nothing` when there is no geometry either |
"""
function Extents.extent(item::Item)
    b = item.bbox
    b === nothing || return bboxextent(b)
    return GI.calc_extent(GI.FeatureTrait(), item)
end

"""
    STAC.bboxextent(bbox) -> Extents.Extent

A STAC `bbox` tuple as an extent, keeping the elevation interval a 6-number box carries.
"""
bboxextent(b::NTuple{4,Float64}) = Extents.Extent(X = (b[1], b[3]), Y = (b[2], b[4]))
bboxextent(b::NTuple{6,Float64}) =
    Extents.Extent(X = (b[1], b[4]), Y = (b[2], b[5]), Z = (b[3], b[6]))

Extents.extent(fc::ItemCollection) = Extents.extent(fc.features)

# `Extents.union` absorbs a `nothing` on either side, so a page whose items all locate
# themselves nowhere folds to `nothing`.
Extents.extent(items::AbstractVector{<:Item}) =
    mapreduce(Extents.extent, Extents.union, items; init = nothing)

# ---------------------------------------------------------------------------------------
# Manifold boxes

const XYExtent = Extents.Extent{(:X, :Y),NTuple{2,Tuple{Float64,Float64}}}
const XYZExtent = Extents.Extent{(:X, :Y, :Z),NTuple{3,Tuple{Float64,Float64}}}

_pair(t) = (Float64(t[1]), Float64(t[2]))

xybox(x, y) = Extents.Extent{(:X, :Y)}((_pair(x), _pair(y)))::XYExtent
xybox(e::Extents.Extent) = xybox(e.X, e.Y)

xyzbox(x, y, z) = Extents.Extent{(:X, :Y, :Z)}((_pair(x), _pair(y), _pair(z)))::XYZExtent

# Whether some angle congruent to `t` lies in the interval, which is what decides whether a
# coordinate reaches its extremum inside the interval or only at an endpoint.
_spans(lo, hi, t) = hi - lo >= 360 || mod(t - lo, 360) <= hi - lo

_cosrange(lo, hi) = (_spans(lo, hi, 180) ? -1.0 : min(cosd(lo), cosd(hi)),
                     _spans(lo, hi, 0) ? 1.0 : max(cosd(lo), cosd(hi)))

_sinrange(lo, hi) = (_spans(lo, hi, 270) ? -1.0 : min(sind(lo), sind(hi)),
                     _spans(lo, hi, 90) ? 1.0 : max(sind(lo), sind(hi)))

function _mulrange(a, b)
    p = (a[1] * b[1], a[1] * b[2], a[2] * b[1], a[2] * b[2])
    return (min(p...), max(p...))
end

# Outward rounding by a few ulps, so the box covers the region it stands for even after the
# trigonometry above has rounded each bound the wrong way.
_guard(r) = (max(-1.0, prevfloat(r[1] - 8eps())), min(1.0, nextfloat(r[2] + 8eps())))

"""
    STAC.spherebox(west, south, east, north) -> Extents.Extent{(:X,:Y,:Z)}

The 3D Cartesian box on the unit sphere covering a longitude/latitude rectangle, which is
what a spherical index prunes with.

`west > east` means the rectangle crosses the antimeridian, as STAC writes it, and the box
covers the short way round. A rectangle reaching a pole gets the whole `X`/`Y` disc there,
because every longitude meets at the pole.

Interval arithmetic on the rectangle's own edges gives the bounds. Its northern and southern
edges are parallels of latitude, which lie equatorward of the great circles
`Extents.extent(GO.Spherical(), geom)` bounds a polygon by.
"""
function spherebox(west, south, east, north)
    south, north = minmax(clamp(Float64(south), -90.0, 90.0),
                          clamp(Float64(north), -90.0, 90.0))
    lo = Float64(west)
    hi = Float64(east) < lo ? Float64(east) + 360.0 : Float64(east)
    coslat = (min(cosd(south), cosd(north)),
              south <= 0 <= north ? 1.0 : max(cosd(south), cosd(north)))
    return xyzbox(_guard(_mulrange(coslat, _cosrange(lo, hi))),
                  _guard(_mulrange(coslat, _sinrange(lo, hi))),
                  _guard((sind(south), sind(north))))
end

spherebox(e::Extents.Extent) = spherebox(e.X[1], e.Y[1], e.X[2], e.Y[2])

"""
    STAC.lift(manifold, input) -> Union{Extents.Extent,Nothing}

A query argument as the box the index built on `manifold` prunes with. Every input reaches
the tree pass through this one function, so a geometry, an extent, and a spherical cap all
prune against the same leaves.

| Input | `Planar()` | `Spherical()` |
|---|---|---|
| `Extents.Extent` with `X`/`Y` | the same box | the 3D box of [`STAC.spherebox`](@ref) |
| a bbox of 4 or 6 numbers | `X`/`Y`; elevation is dropped | as above |
| a GeoInterface geometry | `Extents.extent(Planar(), geom)`, the vertex rectangle | `Extents.extent(Spherical(), geom)`, which follows the great circle between two vertices |
| `Extents.Extent` with `X`/`Y`/`Z` | `X`/`Y` | unchanged: already on the unit sphere |
| `SphericalCap`, `UnitSphericalPoint` | unsupported | unchanged |
| `nothing` | `nothing` | `nothing` |
"""
lift(::GO.Manifold, ::Nothing) = nothing

lift(::GO.Planar, e::Extents.Extent) = xybox(e)
lift(::GO.Spherical, e::Extents.Extent{(:X, :Y)}) = spherebox(e)
lift(::GO.Spherical, e::Extents.Extent{(:X, :Y, :Z)}) = xyzbox(e.X, e.Y, e.Z)

lift(m::GO.Manifold, v::Union{Tuple,AbstractVector}) = lift(m, _xybbox(v))

lift(::GO.Spherical, cap::GO.UnitSpherical.SphericalCap) = cap
lift(::GO.Spherical, p::GO.UnitSpherical.UnitSphericalPoint) =
    xyzbox((p[1], p[1]), (p[2], p[2]), (p[3], p[3]))

lift(m::GO.Manifold, geom) = _liftgeom(m, GI.geomtrait(geom), geom)

_liftgeom(m::GO.Planar, ::GI.AbstractGeometryTrait, geom) = xybox(Extents.extent(m, geom))
_liftgeom(m::GO.Spherical, ::GI.AbstractGeometryTrait, geom) =
    Extents.extent(m, float64geometry(geom))::XYZExtent
_liftgeom(::GO.Manifold, ::Nothing, x) = _notliftable(x)

"""
    STAC.float64geometry(x) -> x

`x` with `Float64` positions, which is what every spherical pass takes: the great-circle
extent and the DE-9IM predicates run on ExactPredicates, and ExactPredicates raises on
`Float32`. A geometry GeoJSON.jl read arrives as `Float32` unless the reader was told
otherwise, so this is the normalisation [`STAC.geojsongeometry`](@ref) already does for a
request body.

An `Extents.Extent` or a `SphericalCap` describes a place without being a geometry and
passes through; every pass that takes one works in `Float64` already.
"""
float64geometry(geom::GeoJSON.AbstractGeometry{D,Float64}) where {D} = geom
float64geometry(e::Extents.Extent) = e
float64geometry(x) = _float64geometry(GI.geomtrait(x), x)

_float64geometry(::GI.AbstractGeometryTrait, geom) = geojsongeometry(geom)
_float64geometry(::Nothing, x) = x

@noinline _notliftable(x) = throw(NotQueryable(string(typeof(x))))

@noinline _notbbox(v) = throw(BadBBox(length(v)))

# A query bbox keeps `X`/`Y` alone: `Spherical()` reads an `X`/`Y`/`Z` extent as a box already
# on the unit sphere, which the elevation interval of a 6-number lon/lat bbox is not.
function _xybbox(v)
    n = length(v)
    n == 4 && return xybox((v[1], v[3]), (v[2], v[4]))
    n == 6 && return xybox((v[1], v[4]), (v[2], v[5]))
    return _notbbox(v)
end

# ---------------------------------------------------------------------------------------
# Leaves

leafextenttype(::GO.Planar) = XYExtent
leafextenttype(::GO.Spherical) = XYZExtent

_leafbox(::GO.Planar, e::Extents.Extent) = xybox(e)
_leafbox(::GO.Spherical, e::Extents.Extent) = spherebox(e)

const _NOBOX = (Inf, -Inf, Inf, -Inf)     # (xmin, xmax, ymin, ymax)

"""
    STAC.pointextent(geom) -> Extents.Extent{(:X,:Y)}

The longitude/latitude rectangle a geometry's vertices span, reached through GeoInterface's
indexed accessors so that one method resolves per nesting level under `--trim=safe`.

[`STAC.leaf_extent`](@ref) is the one caller, and a static binary builds its index leaves
with it. Every other rectangle in this file comes from `Extents.extent(manifold, geom)`,
whose fold over a `Flatten` generator the trim verifier cannot resolve.
"""
function pointextent(geom)
    b = _grow(_NOBOX, GI.geomtrait(geom), geom)
    return xybox((b[1], b[2]), (b[3], b[4]))
end

function _growpoint(b, p)
    x = Float64(GI.x(p))
    y = Float64(GI.y(p))
    return (min(b[1], x), max(b[2], x), min(b[3], y), max(b[4], y))
end

function _growline(b, line)
    for i in 1:GI.npoint(line)
        b = _growpoint(b, GI.getpoint(line, i))
    end
    return b
end

function _growpolygon(b, poly)
    for i in 1:GI.nring(poly)
        b = _growline(b, GI.getring(poly, i))
    end
    return b
end

_grow(b, ::GI.PointTrait, geom) = _growpoint(b, geom)
_grow(b, ::Union{GI.LineStringTrait,GI.LinearRingTrait,GI.MultiPointTrait}, geom) =
    _growline(b, geom)
_grow(b, ::GI.PolygonTrait, geom) = _growpolygon(b, geom)

function _grow(b, ::GI.MultiPolygonTrait, geom)
    for i in 1:GI.ngeom(geom)
        b = _growpolygon(b, GI.getgeom(geom, i))
    end
    return b
end

function _grow(b, ::GI.MultiLineStringTrait, geom)
    for i in 1:GI.ngeom(geom)
        b = _growline(b, GI.getgeom(geom, i))
    end
    return b
end

# Anything else — a geometry collection, a type a later spec adds — walks GeoInterface's own
# flattening iterator.
function _grow(b, ::GI.AbstractGeometryTrait, geom)
    for p in GI.getpoint(geom)
        b = _growpoint(b, p)
    end
    return b
end

_grow(b, ::Nothing, geom) = _notliftable(geom)

"""
    STAC.leaf_extent(manifold, item) -> Union{Extents.Extent,Nothing}

One item's box on `manifold`, or `nothing` when the item locates itself nowhere.

The `bbox` comes first, being the footprint the producer published and the one STAC requires
of every item whose geometry is non-null. An item that carries only a geometry gets the
rectangle its vertices span through [`STAC.pointextent`](@ref), so the leaf is the same kind
of box either way.
"""
function leaf_extent(m::GO.Manifold, item::Item)
    b = item.bbox
    b === nothing || return _leafbox(m, bboxextent(b))
    item.geometry === nothing && return nothing
    return _leafbox(m, pointextent(item.geometry))
end
