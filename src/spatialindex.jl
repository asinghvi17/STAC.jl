# The spatial index: a GeometryOps R-tree over the items' manifold boxes, plus the two-pass
# query that runs the tree first and an exact predicate second.

"""
    SpatialIndex(tree, items, manifold)

An R-tree over a vector of [`Item`](@ref)s together with the items themselves, so a query
can run its exact pass and report positions in the original vector. Build one with
[`spatialindex`](@ref) and search it with [`STAC.query`](@ref).

`tree` is a GeometryOps `RTree` whose leaves are the items' boxes on `manifold`, or `nothing`
when no item locates itself anywhere.
"""
struct SpatialIndex{Tr,V<:AbstractVector,Mf<:GO.Manifold}
    tree::Tr
    items::V
    manifold::Mf
end

"""
    spatialindex(manifold, items) -> SpatialIndex
    spatialindex(items; manifold = Spherical()) -> SpatialIndex

An index over `items` for spatial queries.

`Spherical()`, the default, indexes each item by its 3D box on the unit sphere, so a
footprint that crosses the antimeridian or covers a pole prunes correctly.
`Planar()` indexes the longitude/latitude box as it stands, which is faster and right for a
region well away from both.

Items that locate themselves nowhere — no `bbox` and no geometry — stay out of the tree and
never appear among the hits.

```julia
idx = spatialindex(items)
STAC.query(idx, Extent(X = (-123, -122), Y = (37, 38)))
```
"""
function spatialindex(m::GO.Manifold, items::AbstractVector)
    exts = leafextenttype(m)[]
    idxs = Int[]
    for (i, item) in pairs(items)
        ext = leaf_extent(m, item)
        ext === nothing && continue
        push!(exts, ext)
        push!(idxs, i)
    end
    isempty(idxs) && return SpatialIndex(nothing, items, m)
    return SpatialIndex(GO.RTree(GO.STR(), items; extents = exts, indices = idxs), items, m)
end

spatialindex(items::AbstractVector; manifold::GO.Manifold = GO.Spherical()) =
    spatialindex(manifold, items)

# The items, not the leaves: an item the tree left out is still one a `nothing` query returns.
Base.length(idx::SpatialIndex) = length(idx.items)

"""
    STAC.query(idx::SpatialIndex, input) -> Vector{Int}

The positions in `idx.items` of every item the query matches, ascending and without repeats.

`input` is lifted onto the index's manifold by [`STAC.lift`](@ref) and run against the tree.
A DE-9IM predicate from DE9IM.jl — `Within(poly)`, `Covers(ext)`, `Disjoint(poly)` — adds an
exact second pass over the survivors, evaluated by GeometryOps on the same manifold.

`nothing` matches every item, including the ones the tree leaves out.

```julia
using DE9IM
STAC.query(idx, Within(region))
```
"""
query(idx::SpatialIndex, ::Nothing) = Int[i for i in eachindex(idx.items)]

function query(idx::SpatialIndex, input)::Vector{Int}
    idx.tree === nothing && return Int[]
    return _treequery(idx.tree, lift(idx.manifold, input))
end

_treequery(tree, ext::Extents.Extent) = GO.FlexibleRTrees.query(tree, ext)::Vector{Int}

# A cap prunes against the leaf boxes directly, which is tighter than the Cartesian box that
# would contain it.
_treequery(tree, cap::GO.UnitSpherical.SphericalCap) =
    sort!(GO.SpatialTreeInterface.depth_first_search(Base.Fix1(Extents.intersects, cap),
                                                    tree))::Vector{Int}

@noinline _nopredicategeometry(pred) =
    throw(ArgumentError(string(nameof(typeof(pred))) *
                        "() carries no geometry to compare against; wrap one, as in " *
                        string(nameof(typeof(pred))) * "(polygon)"))

function query(idx::SpatialIndex, pred::DE9IM.DE9IMPredicate)::Vector{Int}
    geom = parent(pred)
    geom === nothing && _nopredicategeometry(pred)
    hits = _candidates(idx, pred, geom)
    alg = GO.RelateNG(idx.manifold)
    filter!(hits) do i
        a = GI.geometry(idx.items[i])
        return a !== nothing && _holds(alg, pred, a, geom)
    end
    return hits
end

# Every predicate but `Disjoint` implies the two extents meet, so the tree pass is a valid
# prefilter; disjointness is the one that holds *because* they do not, and needs every item.
_candidates(idx::SpatialIndex, ::DE9IM.Disjoint, geom) = query(idx, nothing)
_candidates(idx::SpatialIndex, ::DE9IM.DE9IMPredicate, geom) = query(idx, geom)

# DE9IM.jl names a predicate, GeometryOps evaluates it. `RelateNG` is the entry point that
# carries a manifold and answers all ten; the two-argument forms of `crosses` and `overlaps`
# are planar only.
for (P, f) in ((:Intersects, :intersects), (:Disjoint, :disjoint), (:Contains, :contains),
               (:Within, :within), (:Covers, :covers), (:CoveredBy, :coveredby),
               (:Touches, :touches), (:Crosses, :crosses), (:Overlaps, :overlaps),
               (:Equals, :equals))
    @eval _holds(alg, ::DE9IM.$P, a, b) = GO.$f(alg, a, b)
end

# ---------------------------------------------------------------------------------------
# SpatialTreeInterface

# Forwarding these makes an index usable wherever a GeometryOps tree is: a
# `dual_depth_first_search` between two catalogs' indexes runs the coarse pass without
# unwrapping either one.
const IndexedTree = SpatialIndex{<:GO.RTree}

GO.SpatialTreeInterface.isspatialtree(::Type{<:IndexedTree}) = true
GO.SpatialTreeInterface.isleaf(idx::IndexedTree) = GO.SpatialTreeInterface.isleaf(idx.tree)
GO.SpatialTreeInterface.nchild(idx::IndexedTree) = GO.SpatialTreeInterface.nchild(idx.tree)
GO.SpatialTreeInterface.getchild(idx::IndexedTree) = GO.SpatialTreeInterface.getchild(idx.tree)
GO.SpatialTreeInterface.getchild(idx::IndexedTree, i) =
    GO.SpatialTreeInterface.getchild(idx.tree, i)
GO.SpatialTreeInterface.child_indices_extents(idx::IndexedTree) =
    GO.SpatialTreeInterface.child_indices_extents(idx.tree)

Extents.extent(idx::IndexedTree) = Extents.extent(idx.tree)
