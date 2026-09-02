"""
    Sat

The Satellite extension, version 1.1.0: which satellite took the scene and where it was on
its orbit.

`orbit_state` is one of `"ascending"`, `"descending"`, or `"geostationary"`.
`sat:orbit_state_vectors`, an array of position objects, has no typed slot and stays on the
tail, from where [`STAC.json`](@ref) writes it back unchanged.
"""
struct Sat <: Extension
    platform_international_designator::Union{String,Nothing}
    orbit_state::Union{String,Nothing}
    absolute_orbit::Union{Int,Nothing}
    relative_orbit::Union{Int,Nothing}
    orbit_cycle::Union{Int,Nothing}
    anx_datetime::Union{DateTime,Nothing}
end

prefix(::Type{Sat}) = "sat"
schema(::Type{Sat}) = "https://stac-extensions.github.io/sat/v1.1.0/schema.json"
