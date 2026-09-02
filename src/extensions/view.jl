"""
    View

The View Geometry extension, version 1.0.0: where the sensor and the sun were when the scene
was taken, every angle in degrees.

`off_nadir`, `incidence_angle`, and `azimuth` describe the sensor, `sun_azimuth` and
`sun_elevation` the illumination.
"""
struct View <: Extension
    off_nadir::Union{Float64,Nothing}
    incidence_angle::Union{Float64,Nothing}
    azimuth::Union{Float64,Nothing}
    sun_azimuth::Union{Float64,Nothing}
    sun_elevation::Union{Float64,Nothing}
end

prefix(::Type{View}) = "view"
schema(::Type{View}) = "https://stac-extensions.github.io/view/v1.0.0/schema.json"
