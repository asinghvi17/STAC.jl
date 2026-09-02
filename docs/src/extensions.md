```@meta
CurrentModule = STAC
DocTestSetup = quote
    using STAC
end
```

# Extensions

A [STAC extension](https://stac-extensions.github.io) adds prefixed keys to `properties`:
`eo:cloud_cover`, `proj:code`, `sat:orbit_state`. Here an extension is a plain struct whose
field names are the keys after the prefix, plus two one-line methods.

Six ship, and they are what a read parses eagerly when the caller names none:

| Struct | Prefix | Covers |
|---|---|---|
| [`EO`](@ref) | `eo` | cloud and snow fractions |
| [`Projection`](@ref) | `proj` | the native grid: `code`, `epsg`, `wkt2`, `shape`, `transform` |
| [`STAC.Raster`](@ref) | `raster` | how pixel values map to the quantity they stand for |
| [`Sat`](@ref) | `sat` | which satellite, and where on its orbit |
| [`View`](@ref) | `view` | sensor and sun angles |
| [`Scientific`](@ref) | `sci` | how to cite the data |

[`STAC.Raster`](@ref) is not exported: Rasters.jl exports a `Raster` of its own, and
`Raster(asset)` opening a COG is the call that matters in a session holding both.

## Three ways to the same struct

```jldoctest extensions
julia> examples = joinpath(pkgdir(STAC), "test", "fixtures", "static", "self-contained");

julia> item = STAC.read(joinpath(examples, "simple-collection", "extended-item.json"));

julia> item.extensions.eo.cloud_cover           # the eager field: one `Float64` load
1.2

julia> get(item, EO).cloud_cover                # the same, without knowing the type parameter
1.2

julia> EO(item).cloud_cover                     # the same again, throwing when absent
1.2

julia> get(item, Sat) === nothing               # this item carries no `sat:` key
true
```

| Way | Reads from | Use when |
|---|---|---|
| `item.extensions.eo` | the eager field | the extension was named in `extensions =`; type stable, and the path a `--trim=safe` program sees |
| `get(item, EO)` | that field when it exists, else `properties.other` | the code does not know whether this item carries it |
| `EO(item)` | the same as `get`, raising a [`STAC.MissingExtension`](@ref) instead of reporting `nothing` | the extension is required for what follows |

An extension outside the parsed set is not lost. Its keys stay on the tail, and `get` finds
them there:

```jldoctest extensions
julia> narrow = STAC.read(joinpath(examples, "simple-collection", "extended-item.json");
                          extensions = (EO,));

julia> narrow.extensions.eo.cloud_cover         # the one eager field
1.2

julia> get(narrow, View).off_nadir              # read out of `properties.other`
3.8
```

The one thing that does erase them is `metadata = false`, which drops the tail during the
parse: the keys were skipped, not absent from the document.

## Declaring is not carrying

`stac_extensions` says which extensions a producer *claims*; the keys say which ones are
actually there. Producers get both wrong in both directions, so the two questions have two
functions.

```jldoctest extensions
julia> STAC.declares(item, EO)                  # the schema URI is in `stac_extensions`
true

julia> STAC.declares(item, Sat)
false

julia> STAC.declares(item, STAC.schema(EO))     # the same question, asked by URI
true
```

The version segment of a schema URI is ignored, as pystac does, so an item declaring
`eo/v1.1.0` declares [`EO`](@ref) even though this package types the 2.0.0 fields.

## Assets and bands carry them too

`proj:` keys on an asset override the item's, which is how a producer says that one band sits
on a different grid from the rest.

```jldoctest extensions
julia> proj = STAC.read(joinpath(pkgdir(STAC), "test", "fixtures", "stac-spec",
                                 "extensions-collection", "proj-example", "proj-example.json"));

julia> Projection(proj).shape                   # the item's grid
2-element Vector{Int64}:
 8391
 8311

julia> Projection(proj.assets["B8"]).shape      # the panchromatic band's own
2-element Vector{Int64}:
 16781
 16621

julia> get(proj.assets["B1"], Projection) === nothing    # this one states none
true
```

This is what [`RasterStack`](rasters.md) reads to refuse a stack of mixed resolutions.

## Writing your own

An extension is a struct, a prefix, and a schema. Every field is `Union{…,Nothing}`, because
the struct is built from whichever keys a tail carries and an absent key has to be
representable.

The catalog the examples on this page read declares the
[Remote Data](https://github.com/stac-extensions/remote-data) extension, which this package
ships no struct for. Five lines give it one:

```jldoctest extensions
julia> struct RemoteData <: STAC.Extension
           type::Union{String,Nothing}
           sat_id::Union{String,Nothing}
           product_level::Union{String,Nothing}
           anomalous_pixels::Union{Float64,Nothing}
           earth_sun_distance::Union{Float64,Nothing}
       end

julia> STAC.prefix(::Type{RemoteData}) = "rd";

julia> STAC.schema(::Type{RemoteData}) =
           "https://stac-extensions.github.io/remote-data/v1.0.0/schema.json";
```

That is enough for the two lazy paths, on items you have already read:

```jldoctest extensions
julia> RemoteData(item).sat_id
"cool_sat2"

julia> STAC.declares(item, RemoteData)
true
```

Naming it in `extensions =` makes it an eager field, on equal footing with the six that ship:

```jldoctest extensions
julia> typed = STAC.read(joinpath(examples, "simple-collection", "extended-item.json");
                         extensions = (EO, Projection, RemoteData));

julia> typed.extensions.rd.sat_id, typed.extensions.rd.anomalous_pixels
("cool_sat2", 0.14)

julia> collect(keys(typed.properties.other))    # what is left on the tail
5-element Vector{String}:
 "statistics"
 "view:sun_elevation"
 "view:off_nadir"
 "view:sun_azimuth"
 "sci:doi"
```

A field whose value is a nested object or an array of them stays on the tail rather than
getting a typed slot: `raster:histogram`, `raster:bands`, `sat:orbit_state_vectors`, and
`sci:publications` are the four in the shipped set. They round-trip through
[`STAC.json`](@ref) from there.

## Exploring a catalog you have not seen

`extensions = ()` parses nothing eagerly and gives an `Item{Any}`, where every prefixed key
is on the tail and every access path but the eager field still works.

```jldoctest extensions
julia> raw = STAC.read(joinpath(examples, "simple-collection", "extended-item.json");
                       extensions = ());

julia> typeof(raw).parameters[1]
Any

julia> length(collect(keys(raw.properties.other)))
15

julia> get(raw, EO).cloud_cover
1.2
```

This is the form for a corpus that mixes extension sets, and the one to reach for when
deciding which structs are worth declaring. It costs a dictionary lookup and a `lift` per
access, where an eager field costs neither.
