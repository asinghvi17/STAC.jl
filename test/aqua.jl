using STAC, Test, Aqua, GeoJSON, JSON, StructUtils

# The parser owns `StructUtils.make` for the types it materializes. Two of those types come
# from elsewhere — GeoJSON.jl geometry, which STAC discriminates on the nested `"type"` key,
# and the 4-or-6-number bbox tuple — and the style JSON.jl hands to `make` is its own
# `JSONReadStyle` wrapper rather than `STACStyle`, so the methods must dispatch on the
# abstract `StructStyle`. Aqua counts that as piracy; it is the documented extension point.
Aqua.test_all(
    STAC;
    piracies = (; treat_as_own = [GeoJSON.AbstractGeometry, Tuple]),
)
