using STAC, Test, Aqua, JSON, StructUtils
# Imported rather than `using`: Rasters exports a `GeoJSON` of its own, GeoFormatTypes' format
# type, and the weak dependencies below bring it into this namespace.
import GeoJSON

# Aqua's ambiguity and piracy checks see only the modules a session has loaded, and this file
# runs first, before any testset has reached a weak dependency. `STAC_EXTENSION_AQUA=1` loads
# every trigger package first, so the five extensions are in the picture; that is what the
# `aqua-extensions` CI job sets, and it is slow enough (six heavy packages) to be its own job
# rather than the default.
if get(ENV, "STAC_EXTENSION_AQUA", "0") == "1"
    using ArchGDAL, AWSS3, DuckDB, GeoParquet, Makie, Rasters
end

# The parser owns `StructUtils.make` for the types it materializes. Two of those types come
# from elsewhere — GeoJSON.jl geometry, which STAC discriminates on the nested `"type"` key,
# and the 4-or-6-number bbox tuple — and the style JSON.jl hands to `make` is its own
# `JSONReadStyle` wrapper rather than `STACStyle`, so the methods must dispatch on the
# abstract `StructStyle`. Aqua counts that as piracy; it is the documented extension point.
Aqua.test_all(
    STAC;
    piracies = (; treat_as_own = [GeoJSON.AbstractGeometry, Tuple]),
)
