```@meta
CurrentModule = STAC
DocTestSetup = quote
    import STAC
end
```

# Bulk formats

STAC ships in four shapes, and all four read and write here.

| Shape | Read | Write |
|---|---|---|
| one JSON document | [`STAC.read`](@ref) | [`STAC.json`](@ref), [`STAC.write`](@ref) |
| a directory tree of them | [`STAC.read`](@ref) plus [`items`](@ref) | [`STAC.write`](@ref) |
| newline-delimited JSON | [`STAC.read_ndjson`](@ref) | [`STAC.write_ndjson`](@ref) |
| [stac-geoparquet](https://github.com/stac-utils/stac-geoparquet) | [`STAC.read_geoparquet`](@ref) | [`STAC.write_geoparquet`](@ref) |

The examples below write into a temporary directory:

```jldoctest formats
julia> examples = joinpath(pkgdir(STAC), "test", "fixtures", "static", "self-contained");

julia> cat = STAC.read(joinpath(examples, "catalog.json"));

julia> dir = mktempdir();
```

## Publishing a catalog as a directory

[`STAC.write`](@ref) is one function, and the destination decides what it does: a path ending
in `.json` writes one document, anything else writes the whole tree below the object.

```jldoctest formats
julia> out = STAC.write(joinpath(dir, "tree"), cat);

julia> [relpath(p, joinpath(dir, "tree"))
        for (root, _, files) in walkdir(joinpath(dir, "tree")) for p in joinpath.(root, files)]
7-element Vector{String}:
 "catalog.json"
 "collectionless-item/collectionless-item.json"
 "empty-collection/collection.json"
 "simple-collection/collection.json"
 "simple-collection/core-item/core-item.json"
 "simple-collection/extended-item/extended-item.json"
 "simple-collection/simple-item/simple-item.json"

julia> [i.id for i in STAC.items(STAC.read(out); recursive = true)]
4-element Vector{String}:
 "collectionless-item"
 "simple-item"
 "core-item"
 "extended-item"
```

Two decisions, both named after the [STAC best practices
document](https://github.com/radiantearth/stac-spec/blob/master/best-practices.md): where
each document lands, and how the links between them are spelled.

| `layout` | Puts |
|---|---|
| `:best` (default) | `catalog.json`, then `<collection-id>/collection.json`, then `<item-id>/<item-id>.json` |
| `:keep` | each object where it was read from, relative to the root's origin |
| `(obj, parent_dir) -> path` | wherever the function says; `parent_dir` is `nothing` for the root |

| `links` | Writes |
|---|---|
| `:self_contained` (default) | no `self` links, every hierarchy link relative. The tree moves anywhere |
| `:relative_published` | one absolute `self` on the root, every hierarchy link relative |
| `:absolute_published` | absolute `self` and hierarchy links on every document |

```jldoctest formats
julia> [l.rel for l in STAC.read(out).links]         # :self_contained: no `self`
4-element Vector{String}:
 "root"
 "child"
 "child"
 "item"

julia> pub = STAC.write(joinpath(dir, "pub"), cat;
                        links = :absolute_published, root_href = "https://example.com/pub/");

julia> [l.rel => l.href for l in STAC.read(pub).links][1:3]
3-element Vector{Pair{String, String}}:
  "self" => "https://example.com/pub/catalog.json"
  "root" => "https://example.com/pub/catalog.json"
 "child" => "https://example.com/pub/simple-collection/collection.json"
```

The two published forms need `root_href`, the URL the tree will be reachable at. Asset hrefs
and the producer's own links — `license`, `describedby`, `via` — are made absolute against
the origin each object was read from, so they still resolve from the new location.

A tree written this way opens in pystac: `pystac.Catalog.from_file`, `get_items(recursive =
True)`, `make_all_asset_hrefs_absolute`, and `validate_all` against the STAC 1.1.0 schemas all
pass on the output of both self-contained and relative-published writes.

## Newline-delimited JSON

One item per line, which is how a corpus too large to hold as one FeatureCollection is
usually handed around. The reader is lazy: `first` reads one line, and a corrupt line the
iteration never reaches costs nothing.

```jldoctest formats
julia> STAC.write_ndjson(joinpath(dir, "items.ndjson"), STAC.items(cat; recursive = true))
4

julia> lines = STAC.read_ndjson(joinpath(dir, "items.ndjson"));

julia> first(lines).id      # one line read
"collectionless-item"

julia> [i.id for i in lines]
4-element Vector{String}:
 "collectionless-item"
 "simple-item"
 "core-item"
 "extended-item"
```

`write_ndjson` takes anything iterable: a vector, a [`search`](@ref), or another file's
`read_ndjson`, which streams one item at a time. A path source opens a fresh handle per
iteration and closes it when the lines run out, so the same iterator reads twice; an `IO`
source is yours, and the iterator picks up where the stream stands.

## stac-geoparquet

A stac-geoparquet row is a STAC item taken apart: the properties hoisted to top-level
columns, `assets` one nested struct, `links` a list of them, and the geometry as WKB. SQL
puts it back together, so the reader needs DuckDB rather than a flat parquet reader.

```jldoctest formats
julia> using DuckDB

julia> path = STAC.write_geoparquet(joinpath(dir, "items.parquet"),
                                    collect(STAC.items(cat; recursive = true)));

julia> back = STAC.read_geoparquet(path);

julia> [i.id for i in back]
4-element Vector{String}:
 "collectionless-item"
 "simple-item"
 "core-item"
 "extended-item"

julia> back[4].extensions.eo.cloud_cover        # the typed slots are filled
1.2
```

The file carries the two key-value metadata entries the format is read by: `geo`, naming the
WKB geometry column, and `stac-geoparquet`, naming the specification version. A file written
by the Python stac-geoparquet library reads into items field for field equal to the same
documents read from their JSON — ids, datetimes, extension values, geometry, bbox, per-item
asset keys, links, and property tails.

The column layout is the one [`Tables.schema`](features.md) reports, so the same rows go to a
`DataFrame` and to a parquet file without a second definition.

## Assets that hold tables

Two asset media types read in without Rasters. A GeoJSON asset is read in core, through the
same IO stack the catalog was read with:

```julia
fc = STAC.read(STAC.asset(item, "footprints"))      # a GeoJSON.jl FeatureCollection
```

A *flat* GeoParquet asset — one table of features with a WKB geometry column, a published
footprint set or a field boundary file — reads once `import GeoParquet` has given
[`STAC.route`](@ref) that row:

```julia
import STAC
using GeoParquet

asset = STAC.Asset(abspath("footprints.parquet"), "application/vnd.apache.parquet",
                   nothing, nothing, ["data"], nothing, STAC.NoMetadata())
df = STAC.read(asset)       # a GeoParquet.jl GeoDataFrame
```

An [`Asset`](@ref) carries no origin of its own, so its href has to be absolute; that is what
`abspath` is doing above.
