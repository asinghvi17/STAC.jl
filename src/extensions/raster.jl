"""
    Raster

The Raster extension, version 2.0.0: how the pixels of one band map onto the values they
stand for.

These are band and asset keys rather than item keys, so `Raster(asset)` and `Raster(band)`
are the access paths that find them; an item carrying none reports `nothing`. Two shapes stay
on the tail: `raster:histogram`, a nested object, and `raster:bands`, the 1.1.0 array whose
entries moved into the core `bands` field in STAC 1.1.

`Raster` is not exported, because Rasters.jl exports a `Raster` of its own and
`Raster(asset)` opening a COG is the call that matters in a session where both are loaded.
"""
struct Raster <: Extension
    bits_per_sample::Union{Int,Nothing}
    sampling::Union{String,Nothing}
    scale::Union{Float64,Nothing}
    offset::Union{Float64,Nothing}
    spatial_resolution::Union{Float64,Nothing}
end

prefix(::Type{Raster}) = "raster"
schema(::Type{Raster}) = "https://stac-extensions.github.io/raster/v2.0.0/schema.json"
