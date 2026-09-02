"""
    Projection

The Projection extension, version 2.0.0: the native grid an item's assets are on.

`code` (`"EPSG:32610"`) is the 2.0.0 spelling and `epsg` the 1.x one; producers still emit
either, so both are read. `shape` and `transform` are what a reader needs to place the grid
without opening a file.
"""
struct Projection <: Extension
    code::Union{String,Nothing}
    epsg::Union{Int,Nothing}
    wkt2::Union{String,Nothing}
    bbox::Union{Vector{Float64},Nothing}
    shape::Union{Vector{Int},Nothing}
    transform::Union{Vector{Float64},Nothing}
end

prefix(::Type{Projection}) = "proj"
schema(::Type{Projection}) = "https://stac-extensions.github.io/projection/v2.0.0/schema.json"
