```@meta
CurrentModule = STAC
DocTestSetup = quote
    using STAC, Extents, GeometryOps
end
```

# Spatial selection

[`spatialindex`](@ref) builds a [GeometryOps](https://juliageo.org/GeometryOps.jl/stable)
R-tree over a vector of items, and [`STAC.query`](@ref) returns the positions in that vector
of everything a spatial argument matches. The tree is built on the unit sphere by default.

The catalog used below is the one the tests use for edge cases: seven items, of which one
straddles the antimeridian, two cover a pole, and one is unlocated.

```jldoctest spatial
julia> edges = joinpath(pkgdir(STAC), "test", "fixtures", "hand", "antimeridian-catalog");

julia> its = collect(items(STAC.read(joinpath(edges, "catalog.json")); recursive = true));

julia> [i.id for i in its]
7-element Vector{String}:
 "straddle"
 "north-pole"
 "south-pole"
 "greenwich"
 "bay-area"
 "outside-corner"
 "unlocated"

julia> idx = spatialindex(its);

julia> length(idx)      # every item, indexed or not
7

julia> hits = STAC.query(idx, Extent(X = (-123, -122), Y = (37, 38)));

julia> [its[i].id for i in hits]
1-element Vector{String}:
 "bay-area"
```

`query` is reached as `STAC.query`: GeometryOps and SortTileRecursiveTree both export a
`query` of their own, and a session holding any two of the three would find the bare name
ambiguous.

## Why the sphere

A longitude/latitude box that crosses the antimeridian has a `west` greater than its `east`,
which as a planar rectangle is empty. Satellite catalogs are full of them.

```jldoctest spatial
julia> box = Extent(X = (170, -170), Y = (60, 70));      # 20° of longitude across 180°

julia> [its[i].id for i in STAC.query(idx, box)]
1-element Vector{String}:
 "straddle"

julia> planar = spatialindex(its; manifold = GeometryOps.Planar());

julia> STAC.query(planar, box)                            # the same box, read as a rectangle
Int64[]
```

`Spherical()` indexes each item by its box on the unit sphere: [`STAC.spherebox`](@ref) turns
the longitude/latitude rectangle into a 3D Cartesian box by interval arithmetic on `cos` and
`sin`, rounded outward a few ulps, splitting at the antimeridian when `west > east` and
taking the whole `X`/`Y` disc at a pole, where every longitude meets.

`Planar()` is the opt-in, and it is the right choice for a region well away from both: it
prunes on two intervals instead of three and does no trigonometry.

## What a query takes

Every input reaches the tree through [`STAC.lift`](@ref), so a geometry, an extent, and a
spherical cap all prune against the same leaves.

| Input | On `Spherical()` | On `Planar()` |
|---|---|---|
| `Extents.Extent` with `X`/`Y` | its unit-sphere box | the same box |
| a bbox of 4 or 6 numbers | as above; elevation is dropped | `X`/`Y` |
| any GeoInterface geometry | `Extents.extent(Spherical(), geom)`, which follows the great circle between two vertices | the rectangle its vertices span |
| `Extents.Extent` with `X`/`Y`/`Z` | unchanged: already on the unit sphere | `X`/`Y` |
| `SphericalCap`, `UnitSphericalPoint` | unchanged | unsupported |
| `nothing` | every item, the unlocated ones included | the same |

A cap is the way to ask for "everything within so many radians of this point", which no
longitude/latitude rectangle expresses near a pole:

```jldoctest spatial
julia> using GeometryOps.UnitSpherical

julia> cap = SphericalCap(UnitSphericalPoint(0.0, 0.0, 1.0), 0.2);   # 0.2 rad of the north pole

julia> [its[i].id for i in STAC.query(idx, cap)]
1-element Vector{String}:
 "north-pole"
```

An item that locates itself nowhere — no `bbox` and no geometry — stays out of the tree and
never appears among the hits. `query(idx, nothing)` is the one call that returns it, since
"no spatial filter" keeps everything.

## Exact predicates

A tree pass answers "which boxes could match". [DE9IM.jl](https://github.com/JuliaGeo/DE9IM.jl)
predicates answer "which geometries do", and `query` runs both: the tree first, then the
predicate over the survivors, evaluated by GeometryOps on the index's manifold.

```jldoctest spatial
julia> using DE9IM

julia> region = STAC.read(joinpath(edges, "mid", "greenwich.json")).geometry;

julia> [its[i].id for i in STAC.query(idx, Within(region))]
1-element Vector{String}:
 "greenwich"
```

All ten predicates work — `Intersects`, `Disjoint`, `Contains`, `Within`, `Covers`,
`CoveredBy`, `Touches`, `Crosses`, `Overlaps`, `Equals` — through GeometryOps' `RelateNG`,
which is the one entry point with a spherical implementation for the whole set. `Disjoint`
takes every item as its candidate set, being the one predicate that holds *because* two
extents do not meet.

The same predicates go to [`search`](@ref), on both backends: the server (or the walk) gets
the wrapped geometry's `intersects` as a coarse filter, and each page is then filtered
through the exact predicate before the caller sees it.

```jldoctest spatial
julia> s = search(STAC.read(joinpath(edges, "catalog.json")); intersects = Within(region));

julia> [i.id for i in s]
1-element Vector{String}:
 "greenwich"
```

## Using the index elsewhere

A [`SpatialIndex`](@ref) forwards GeometryOps' `SpatialTreeInterface`, so it is usable
wherever a GeometryOps tree is — a `dual_depth_first_search` between two catalogs' indexes
runs the coarse pass without unwrapping either one.

```jldoctest spatial
julia> Extents.extent(idx)      # the tree's own box, on the unit sphere
Extent(X = (-0.5000000000000019, 1.0), Y = (-0.6772813238185248, 0.08715574274765997), Z = (-1.0, 1.0))

julia> GeometryOps.SpatialTreeInterface.isspatialtree(typeof(idx))
true
```

`idx.items` is the vector the index was built over, so `idx.items[hits]` is the selection and
`hits` are positions in the original order — ascending and without repeats.
