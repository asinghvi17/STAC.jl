module STACMakieExt

# Makie draws an item as its geometry, and a page of items as the vector of their
# geometries. `GeoInterface.@enable_makie` writes these methods for geometry types only — a
# feature is not one — so they are spelled out here over the geometries, and each one ends
# in the same conversion the macro calls: GeoInterface's Makie extension, which is what
# folds a vector mixing `Polygon` and `MultiPolygon` into the one type Makie can draw.

import GeoInterface as GI
import Makie
using STAC: Item, ItemCollection

const Items = Union{ItemCollection,AbstractVector{<:Item}}

# An item that locates itself nowhere becomes a hole rather than an error, so that a vector
# of items and a vector of per-item colors stay the same length. GeoInterface's converter
# draws a hole as a NaN geometry.
_hole(::Nothing) = missing
_hole(geom) = geom

geometries(fc::ItemCollection) = geometries(fc.features)
geometries(items::AbstractVector{<:Item}) = map(item -> _hole(GI.geometry(item)), items)

_plottype(::Union{GI.PointTrait,GI.MultiPointTrait}) = Makie.Scatter
_plottype(::Union{GI.LineStringTrait,GI.MultiLineStringTrait}) = Makie.Lines
_plottype(::Union{GI.PolygonTrait,GI.MultiPolygonTrait,GI.LinearRingTrait,
                  GI.GeometryCollectionTrait}) = Makie.Poly
_plottype(::Nothing) = throw(ArgumentError("an item with no geometry has nothing to plot"))

Makie.plottype(item::Item) = _plottype(GI.geomtrait(GI.geometry(item)))
Makie.plottype(items::Items) = _plottype(GI.geomtrait(first(skipmissing(geometries(items)))))

for P in (:(Type{<:Makie.Poly}), :(Type{<:Makie.Lines}), :(Makie.PointBased))
    @eval begin
        Makie.convert_arguments(p::$P, item::Item; kw...) =
            GI._makie_convert_arguments(p, GI.geometry(item))
        Makie.convert_arguments(p::$P, items::Items; kw...) =
            GI._makie_convert_array_arguments(p, geometries(items))
    end
end

end
