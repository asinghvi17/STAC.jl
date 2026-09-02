```@raw html
---
layout: home

hero:
  name: "STAC.jl"
  tagline: A typed, spatially indexed SpatioTemporal Asset Catalog client for Julia
  image:
    src: /logo.png
    alt: STAC.jl
  actions:
    - theme: brand
      text: Reading a catalog
      link: /objects
    - theme: alt
      text: Searching
      link: /search
    - theme: alt
      text: API reference
      link: /api

features:
  - title: Typed all the way down
    details: Every field the spec names is a concrete field; the keys it does not name round-trip through a metadata tail.
    link: /objects
  - title: One search, two backends
    details: The same keywords search a STAC API and a catalog on disk, and paging follows each endpoint's next link.
    link: /search
  - title: Spherical by default
    details: A GeometryOps R-tree on the unit sphere, so the antimeridian and the poles are ordinary places.
    link: /spatial
---
```

```@meta
CurrentModule = STAC
DocTestSetup = quote
    import STAC
end
```

STAC.jl turns a catalog URL, a local directory, an `s3://` path, or a
[STAC API](https://github.com/radiantearth/stac-api-spec) endpoint into [`Catalog`](@ref),
[`Collection`](@ref), and [`Item`](@ref) values that

- behave as [GeoInterface](https://juliageo.org/GeoInterface.jl/stable) features and
  [Tables.jl](https://tables.juliadata.org/stable) rows,
- answer one set of [`search`](@ref) keywords whether they came from an API or from a
  directory,
- index and query on the sphere, and
- open as [Rasters](https://rafaqz.github.io/Rasters.jl/stable) with the credentials the
  catalog was opened with.

## Installation

```julia
using Pkg
Pkg.add("STAC")
```

## A first catalog

The package ships the [stac-spec](https://github.com/radiantearth/stac-spec) example
documents, so this runs with nothing fetched:

```jldoctest index
julia> examples = joinpath(pkgdir(STAC), "test", "fixtures", "static", "self-contained");

julia> cat = STAC.read(joinpath(examples, "catalog.json"))
Catalog "examples" — Example Catalog
  links       root, child ×2, item
  metadata    1 key: "stac_version"

julia> [c.id for c in STAC.children(cat)]
2-element Vector{String}:
 "simple-collection"
 "empty-collection"

julia> item = last(collect(STAC.items(cat; recursive = true)))
Item{eo, proj, raster, sat, view, sci} "extended-item" 2020-12-14
  datetime    2020-12-14T18:02:31.437Z
  collection  simple-collection
  geometry    Polygon{2, Float64} (5 vertices), bbox (172.9117, 1.3439, 172.9547, 1.369)
  assets      analytic, thumbnail, visual, udm, … (6)
  extensions  eo (cloud_cover = 1.2, snow_cover = 0.0)  proj (code = "EPSG:32659", shape = [5558, 9559], transform = [0.5, 0.0, 712710.0, … (9)])  view (off_nadir = 3.8, sun_azimuth = 135.7, sun_elevation = 54.9)  sci (doi = "10.5061/dryad.s2v81.2/27.2")
  metadata    1 key: "stac_version"

julia> item.extensions.eo.cloud_cover
1.2
```

The type line names the extensions parsed into fields, `cloud_cover` is a `Float64` field
read rather than a dictionary lookup, and the one key no field names —
`stac_version` — is still there to be written back.

## Where to go

| Question | Page |
|---|---|
| I have a catalog. How do I read and walk it? | [Reading a catalog](objects.md) |
| How do I find the items I want? | [Searching](search.md) |
| The endpoint wants a token. Where does it go? | [Fetching and credentials](io.md) |
| How do these items reach DataFrames, Makie, GeometryOps? | [Items as features and tables](features.md) |
| How do I select by area without the antimeridian biting? | [Spatial selection](spatial.md) |
| How do I get pixels? | [Opening assets as rasters](rasters.md) |
| Where does `eo:cloud_cover` live, and how do I add my own? | [Extensions](extensions.md) |
| How do I read a million items, or publish a catalog? | [Bulk formats](formats.md) |
| Can this go in a static binary? | [Static compilation](compilation.md) |
