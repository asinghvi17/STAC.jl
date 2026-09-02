```@meta
CurrentModule = STAC
DocTestSetup = quote
    using STAC
end
```

# Items as features and tables

An [`Item`](@ref) is a GeoInterface feature, and a `Vector{Item}` or an
[`ItemCollection`](@ref) is both a feature collection and a Tables.jl table. There is no
conversion step and no wrapper type: that is the whole integration story with GeometryOps,
Makie, GeoDataFrames, Rasters, and DataFrames.

```jldoctest features
julia> using GeoInterface, Extents

julia> examples = joinpath(pkgdir(STAC), "test", "fixtures", "static", "self-contained");

julia> its = collect(items(STAC.read(joinpath(examples, "catalog.json")); recursive = true));

julia> GeoInterface.isfeature(eltype(its)), GeoInterface.trait(its[2])
(true, FeatureTrait())

julia> GeoInterface.testfeature(its[2]) && GeoInterface.testfeaturecollection(its)
true

julia> typeof(GeoInterface.geometry(its[2]))
GeoJSON.Polygon{2, Float64}

julia> GeoInterface.crs(its[2])
EPSG:4326
```

`Float64`, not the `Float32` GeoJSON.jl reads by default: at 180° a `Float32` longitude is
precise to about 1.7 m, which is a real error for a tile footprint and enough to make
ExactPredicates refuse the geometry outright.

The coordinate reference system is always WGS 84 longitude/latitude. GeoJSON fixes it and
STAC inherits it, which is why a `bbox` from any producer can be compared with any other
without a projection step.

## Extent

`Extents.extent` reads the item's `bbox`, in the key order STAC writes it, and falls back to
the geometry for an item that published none.

```jldoctest features
julia> Extents.extent(its[2])
Extent(X = (172.91173669923782, 172.95469614953714), Y = (1.3438851951615003, 1.3690476620161975))

julia> Extents.extent(its)      # the union over a whole page
Extent(X = (-122.59750209, 172.95469614953714), Y = (1.3438851951615003, 37.613537207))
```

An extent is spatial only — `X`, `Y`, and `Z` for a 6-number bbox — and never temporal. That
is what lets it be handed to a GeometryOps tree, a Rasters selector, and every other `extent`
consumer unchanged; time is a [`search`](@ref) keyword instead.

## Tables

`Tables.rows` over a vector of items builds one column list from a single pass over the rows,
because only the rows say which tail keys the producer used. The layout is
stac-geoparquet's, so the [parquet writer](formats.md) hands the same rows on unchanged.

| Columns | Type |
|---|---|
| `id`, `stac_extensions`, `geometry`, `collection` | the item's own field types |
| `bbox` | a `NamedTuple` of 4 or 6 bounds |
| every [`Properties`](@ref) field but `other` | the field's own type, so `datetime` is a `Union{DateTime,Nothing}` column |
| `"eo:cloud_cover"`, `"proj:code"`, … | one per field of each extension parsed eagerly |
| the keys seen in `properties.other` | `Any` |
| `links`, `assets` | `Vector{Link}`, `OrderedDict{String,Asset}` |
| the keys seen in the items' own tails | `Any` |

```jldoctest features
julia> using Tables, DataFrames

julia> sch = Tables.schema(its);

julia> length(sch.names)
61

julia> [sch.types[findfirst(==(n), sch.names)] for n in (:id, :datetime, Symbol("eo:cloud_cover"))]
3-element Vector{Type}:
 String
 Union{Nothing, Dates.DateTime}
 Union{Nothing, Float64}

julia> df = DataFrame(its);

julia> df[!, ["id", "datetime", "gsd", "eo:cloud_cover"]]
4×4 DataFrame
 Row │ id                   datetime                 gsd     eo:cloud_cover
     │ String               Union…                   Union…  Union…
─────┼──────────────────────────────────────────────────────────────────────
   1 │ collectionless-item                           0.512
   2 │ simple-item          2020-12-11T22:38:32.125
   3 │ core-item                                     0.512
   4 │ extended-item        2020-12-14T18:02:31.437  0.66    1.2
```

A row missing a tail key reports `missing`, which is a different statement from a key the
producer wrote as `null`; that one is `nothing`.

## Where a column came from

Every `"prefix:field"` column carries one DataAPI key, `"stac_extension"`, holding the schema
URI of the extension that named it. DataFrames copies it into `colmetadata`, so a table says
where `"eo:cloud_cover"` is specified without the caller keeping a prefix table of their own.

```jldoctest features
julia> colmetadata(df, Symbol("eo:cloud_cover"), "stac_extension")
"https://stac-extensions.github.io/eo/v2.0.0/schema.json"

julia> collect(colmetadatakeys(df, Symbol("rd:sat_id")))    # a producer key names no schema
Union{}[]
```

The objects themselves answer DataAPI too, so a tail key is reachable by the same three
functions a table is:

```jldoctest features
julia> using DataAPI

julia> collect(DataAPI.metadatakeys(its[4]))
1-element Vector{String}:
 "stac_version"

julia> DataAPI.metadata(its[4], "stac_version")
"1.1.0"
```

Spell it `DataAPI.metadata` rather than `metadata`: DataFrames, DimensionalData, and Rasters
all export a `metadata` of their own, and a session holding two of them finds the bare name
ambiguous.

## Plotting

Makie draws an item as its geometry and a page of items as the vector of them. The methods
arrive with `using Makie` (or GeoMakie, or CairoMakie):

```julia
using STAC, GeoMakie

fig, ax, plt = poly(its; color = [i.properties.gsd for i in its], axis = (; aspect = DataAspect()))
lines!(ax, its)
```

An item that locates itself nowhere is drawn as a hole rather than raising, so a vector of
items and a vector of per-item colors stay the same length.
