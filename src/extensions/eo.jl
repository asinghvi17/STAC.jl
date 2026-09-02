"""
    EO

The Electro-Optical extension, version 2.0.0. Band descriptions moved into core `bands` in
STAC 1.1, leaving the two cloud and snow fractions.
"""
struct EO <: Extension
    cloud_cover::Union{Float64,Nothing}
    snow_cover::Union{Float64,Nothing}
end

prefix(::Type{EO}) = "eo"
schema(::Type{EO}) = "https://stac-extensions.github.io/eo/v2.0.0/schema.json"
