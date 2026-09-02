```@meta
CurrentModule = STAC
DocTestSetup = quote
    import STAC
end
```

# Static compilation

Julia 1.12's `juliac --trim=safe` builds a small executable from a program whose whole call
graph the compiler can resolve statically. A STAC reader is a good fit for it — a command
that reads a catalog and prints ids has no business paying a Julia startup — and this package
is written so that the core paths qualify. `test/compile/` holds programs that build and run
in CI, so a trim regression shows up as a verifier error there rather than at release time.

## A program

Three things make a program trimmable, and they are all visible in this one.

```julia
import STAC
using Extents, GeoJSON

const E = STAC.extensiontype((STAC.EO, STAC.Projection))
const G = Union{Nothing,GeoJSON.Polygon{2,Float64},GeoJSON.MultiPolygon{2,Float64}}
const OPTS = STAC.ParseOptions{E,G,STAC.Metadata}()
const BOX = Extents.Extent(X = (170.0, -170.0), Y = (60.0, 70.0))

function (@main)(args::Vector{String})::Cint
    io = STAC.PathIO()
    catalog = STAC.read(STAC.Catalog{STAC.Metadata}, args[1], io, OPTS)
    println(Core.stdout, catalog.id)

    for item in STAC.search(catalog, OPTS; io, intersects = BOX)
        println(Core.stdout, item.id)
    end

    walked = STAC.Item{E,G,STAC.Metadata}[]
    for item in STAC.items(catalog, OPTS; io, recursive = true)
        push!(walked, item)
    end
    println(Core.stdout, length(STAC.query(STAC.spatialindex(walked), BOX)))
    return 0
end
```

| Rule | Why |
|---|---|
| the extension tuple, geometry union, and metadata type are compile-time constants | under trimming the set of parse methods must be closed; `ParseOptions{E,G,M}` is what names it |
| `io` is passed explicitly | [`STAC.default_io`](@ref) reads a `ScopedValue`, which is one dynamic dispatch the verifier cannot follow |
| the positional forms are used — `STAC.search(catalog, opts; …)`, `STAC.search(client, opts; …)`, `STAC.items(obj, opts; …)`, `STAC.read(T, href, io, opts)` | they take the options as a value rather than rebuilding one from keywords |

Build it with the `juliac` driver that ships with Julia:

```bash
julia --project=test/compile \
      $(julia -e 'print(joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac.jl"))') \
      --output-exe search_index --experimental --trim=safe test/compile/search_index.jl
```

## What links today

Measured with throwaway `--trim=safe` programs against each entry point:

| Path | Verifier errors | Note |
|---|---|---|
| parse an item, a catalog, or a collection | 0 | `test/compile/read_item.jl` |
| walk a static catalog, search it, build a spherical index | 0 | `test/compile/search_index.jl` |
| [`STAC.read_ndjson`](@ref) over a file | 0 | |
| [`STAC.json`](@ref), and so [`STAC.write_ndjson`](@ref) | 12 | JSON.jl's writer calls `StructUtils.lower` on the `Any` values of a metadata tail. A `NoMetadata` object costs the same 12, so the tail is not the cause |
| [`STAC.write`](@ref) over a catalog tree | 40 | the 12 above, plus the recursive walk: `publish!` calls itself on a `Union{Catalog,Collection}` child |
| a STAC API search | 8 | `test/compile/api_search.jl`, which opens an endpoint, POSTs a search, follows the `next` link, and indexes what came back. The eight sit under three causes, named below |

Three costs were bought back and are in the code. `eachline` costs two errors, its `ondone`
field being typed `Function`, so [`STAC.read_ndjson`](@ref) opens and closes the stream
itself. `open(f, path, "w")` costs one, `Base.open(f, args...)` splatting through
`_apply_iterate`, so both writers open explicitly and `close` in a `finally`. And
`URIs.escapeuri` costs thirteen, `join` over a generator reaching the annotated-string path,
so a query string is built by [`STAC.percentencode`](@ref), a byte loop over RFC 3986's
unreserved set.

The API path is the one that does not link yet, and the reason is the request rather than the
response: a search body, a `next` link's body, and a link's header map are JSON documents,
whose values are `Any`, so a call that reads one is a dynamic dispatch.

| Call | Where | What would close it |
|---|---|---|
| [`STAC.queryvalue`](@ref)`(::Any)` (2) | a link's header map, a `GET` search's query string | a body whose values are a closed set of JSON types |
| `STAC.jsonobject(::Any)` (2) | a `next` link's body | [`Link`](@ref)`.body` typed `JSON.Object{String,Any}` |
| `StructUtils.lower`, `JSON.WriteClosure` (4) | JSON.jl writing the POST body | a writer that narrows a JSON value before lowering it |

`test/compile/runtests.jl` holds the six distinct statements behind those eight calls as a
budget and asserts that each is one of the three causes, so an upstream fix lowers the number
and a new kind of unresolved call fails the test.

## What the package does to stay this way

These are conventions of the source rather than anything a user calls, but they explain why
some of the code looks the way it does.

| Convention | Instead of |
|---|---|
| parse sinks are callable structs | closures, which `applyeach` compiles unspecialized: a dynamic dispatch at runtime and an unresolved call under `--trim=safe` |
| tail values go through `StructUtils.lift(style, Any, v)` | `make`, which is not the trim-verifiable generic path, and allocates about 40% more |
| every nesting level of the parse is a distinct `@eval`-generated method | one generic `make` calling itself, which is the recursive typed parse the verifier reports |
| exceptions are structs with `String`, `Int`, and `Symbol` fields, and `showerror` prints them one argument at a time | interpolation and `sprint` in an error path, both of which the verifier reports |
| [`STAC.pointextent`](@ref) walks polygons, rings, and points with one method per level | `GeoInterface.calc_extent`, whose `extrema` fold over `Base.FlatteningRF` costs 28 verifier errors |
| a value typed `Any` is read through an `isa` ladder in one method — [`STAC.queryvalue`](@ref) | one method per type: a call on an `Any` is unresolved even when exactly one method matches, so the methods cost what the ladder saves |
| [`STAC.leaf_extent`](@ref) reads the item's `bbox` first | GeometryOps' `_spherical_region_extent`, which captures a reassigned variable in a closure and makes every statement around it `Any` |

One upstream pin belongs to the trim environment rather than to the package:
`IntervalArithmetic` from 0.22.30 on `ccall`s a library named by a property of a JLL module in
its `__init__`, which trimming resolves to nothing and which aborts the binary before `main`
runs. `test/compile/Project.toml` pins `=0.22.23`.

## Which extensions a trimmed program sees

The set is closed at compile time, so `extensions = (STAC.EO, STAC.Projection)` in a trim
program is not a default that can be widened later — it is the whole list of extension structs the
binary carries parse code for. Reaching for one outside it through [`get`](@ref) still works,
[`STAC.fromtail`](@ref) being a lookup rather than a parse, but the wider the declared tuple
the more code the binary holds.
