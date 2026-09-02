# Conventions for STAC.jl

STAC.jl follows the GeometryOps.jl house style. This file is the checklist; read it before
adding a file, a method, or a test.

## Layout

**One job per file.** `src/parse/sinks.jl` holds the parse routers and nothing else;
`src/parse/write.jl` holds the writer. A new concern gets a new file and one `include` in
`src/STAC.jl`, and `test/<name>.jl` mirrors it as a `@safetestset` listed in
`test/runtests.jl`.

A file at the top of `src/` never repeats the name of a directory beside it: the document
layer is `src/document.jl`, not `src/read.jl`, which would read as `src/io/`'s twin, and the
directory writer is `src/publish.jl`, not `src/write.jl`, which would read as
`src/parse/write.jl`'s. The name says the job: this one publishes a catalog as a tree.

| Directory | Holds |
|---|---|
| `src/` | the package, one file per concern |
| `src/errors.jl` | every exception the package throws, under one `STACError` supertype |
| `src/document.jl` | `STAC.parse` and `STAC.read`: the `type` key choosing a struct, and `sethref` |
| `src/extensions/` | `interface.jl` plus one file per shipped STAC extension |
| `src/parse/` | the JSON style, its sinks, the writer, and `ParseOptions` |
| `src/ndjson.jl` | `read_ndjson` and `write_ndjson`: one item per line |
| `src/publish.jl` | `STAC.write`: one document, or a whole catalog as a directory tree |
| `src/search/` | `interface.jl`: the search protocol and the request its keywords build; `backends.jl`: the API and static searches |
| `src/io/` | the `AbstractIO` stack, auth, and href resolution: one wrapper per file |
| `ext/` | weak-dependency bridges, one module per trigger package |
| `test/fixtures/` | vendored documents; nothing here is fetched at test time |
| `test/compile/` | `juliac --trim=safe` programs and the testset that builds them |
| `.github/workflows/` | `CI.yml`: the test matrix, the trim programs, Aqua with the extensions loaded, and the docs build; `TagBot.yml` and `CompatHelper.yml`, the registry pair |

## Argument conventions

- **Manifold first.** `spatialindex(Spherical(), items)` is the positional form; the
  `manifold =` keyword belongs only on the convenience method.
- **`GI.*` accessors.** Reach a geometry through GeoInterface, never through a concrete
  type's fields.
- **`io` last, as a keyword with a default.** `children(cat; io = default_io())`.

## Errors

Every raise goes through `src/errors.jl`. A new failure mode gets three things:

1. **A struct under one of the four groups** — `DocumentError`, `LookupError`,
   `ArgumentShapeError`, `EndpointError` — all of them under `STACError`, so a caller can
   catch the package as a class. Reuse a struct when the shape of the complaint matches;
   `WrongJSONType` covers both "expected an object" and "expected an array".
2. **Fields carrying the values the message names**, as `String`, `Int`, or `Symbol`. A
   `Type` field would make `showerror` a dynamic dispatch; the throw site spells `string(T)`
   where `T` is a static parameter and the trim verifier can resolve it.
3. **A `Base.showerror` that `print`s its fields one argument at a time.** Interpolation and
   `sprint` in an error path are what `--trim=safe` reports as unresolved calls.

The throw site stays a `@noinline` helper (`_nolink`, `_badbbox`) that only builds the
struct, which keeps the raise out of the caller's inlined code.

## Parsing

The parser is a `StructUtils` style with `make` methods for the types this package
materializes. Three rules keep the pass single, inferable, and trim-safe:

1. **Sinks are callable structs, never closures.** `applyeach` only forwards its function
   argument, so a closure compiles unspecialized: a dynamic dispatch at runtime and an
   unresolved call under `--trim=safe`.
2. **Tail values go through `lift(style, Any, v)`, not `make`.** `lift` is JSON's
   trim-verifiable generic path and allocates about 40% less.
3. **Every nesting level is a distinct method.** One generic `make` (or one helper) that
   calls itself is the recursive typed parse the trim verifier reports as an unresolved
   invoke, so `make` is generated per type with `@eval` and the field ladders emit their
   `make` calls inline.

Every sink needs a method for integer keys as well as string keys: the verifier follows the
array branch of `applyeach` even when the source is an object.

Adding a struct with a metadata tail means four edits: the struct, `nsynthetic`, the `@eval`
loop that gives it a `make`, and a `lower` method in `parse/write.jl`.

## Trimming

Static compilation is a supported target, and `test/compile/` is where it is measured: each
program there builds with `juliac --experimental --trim=safe`, and a verifier error fails the
build rather than warning. Build one on its own with

```sh
julia --project=test/compile \
  "$(julia -e 'print(joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac.jl"))')" \
  --output-exe /tmp/prog --experimental --trim=safe test/compile/<program>.jl
```

The log lists every error twice, so what to count is distinct statements.

**The rule under all of it: a call resolves when the compiler knows the concrete type of every
argument, and both arms of a branch are compiled whatever the runtime values.** Everything
below follows from that, and each row was measured against a program.

| Shape | Cost | Instead |
|---|---|---|
| a call on a value typed `Any` | 1 per call site, whether the callee has one method or five | narrow with `isa` *at the call site*: `v isa Vector{Any}` resolves the loop over it, `v isa AbstractVector` leaves it dynamic |
| a keyword argument whose value is a union, `body::Union{Nothing,String}` | 1 | one call per shape: keywords travel as one `NamedTuple`, and a union in it is not a concrete type |
| a type computed at run time, `ParseOptions(; extensions, geometry, metadata)` | 4 | the explicit `opts::ParseOptions` form every entry point carries beside its keyword one |
| a closure handed to `applyeach` | 1 per level | a callable struct ([Parsing](#parsing)) |
| a recursive typed parse, one `make` calling itself | 1 per level | one method per nesting level ([Parsing](#parsing)) |
| a `Type` field on an exception, or interpolation in a message | 1 per throw site | `String`/`Int`/`Symbol` fields and a `showerror` that prints one argument at a time ([Errors](#errors)) |

A trim program names its parse types as top-level constants, passes `io` explicitly rather
than reading the scoped default, and lives beside a testset entry in
`test/compile/runtests.jl`.

Upstream calls that cost verifier errors, all of them measured here, with what replaced them:

| Call | Errors | Replacement |
|---|---|---|
| `IntervalArithmetic` ≥ 0.22.30 `__init__`, which `ccall`s a library named by a JLL property | the binary aborts before `main` | `test/compile/Project.toml` pins `=0.22.23` |
| `GI.calc_extent`, an `extrema` fold over `Base.FlatteningRF` | 28 | `STAC.pointextent`, one method per geometry level |
| GeometryOps' `_spherical_region_extent`, which captures a reassigned variable | ~20 | leaves come from the item's `bbox`, through `STAC.spherebox` |
| `join` over a generator, which is all of `URIs.escapeuri` | 10, in `Base.AnnotatedString` | `STAC.percentencode`, a byte loop |
| `lpad`, and `Base.repeat` under it | 2 | the digits spelled out (`STAC.format_rfc3339`) |
| `eachline`, whose `ondone` field is typed `Function` | 2 | `read_ndjson` opens and closes the stream itself |
| `open(f, path, "w")`, splatting through `_apply_iterate` | 1 | open explicitly, `close` in a `finally` |
| JSON.jl writing an `Any`-valued document | 4 for a search body, 12 for `STAC.json` | nothing yet: `StructUtils.lower` is called per value, and a JSON document's values are `Any` |

An `__init__` is not itself a problem: STAC's registers an error hint, and both linking
programs carry it.

The last row is why `test/compile/api_search.jl` does not link. A STAC API carries JSON
documents in the request as well as the response — the search body, a `next` link's body and
header map — so the API path costs six unresolved statements where the parse path costs none.
That program runs as a script in the testset and its verifier errors are held to a budget, so
the cost is a number CI reports rather than a surprise; `runtests.jl` names each one and what
would close it.

## Extensions

An extension is a struct plus `prefix` and `schema`. Field names are the JSON keys after the
prefix, so `eo:cloud_cover` is `EO.cloud_cover`. A deprecated key with a typed replacement,
such as `proj:epsg` beside `proj:code`, is an ordinary field so both are read.

Three rules follow from the access paths in `src/extensions/interface.jl`:

1. **Every field is `Union{…,Nothing}`.** `fromtail` builds the struct from whichever keys a
   tail carries, so an absent key has to be representable.
2. **A key whose value is a nested object or an array of them stays on the tail.** It
   round-trips through `STAC.json` from there, and typing it would need a `make` method and a
   `lower` method of its own.
3. **The name goes in the export list only if no package a bridge loads owns it.**
   `STAC.Raster` is not exported: Rasters.jl exports its own `Raster`, and `Raster(asset)`
   opening a COG is the call that matters in a session holding both.

Shipping one is five edits, and nothing else in the package learns its name — `fromtail`
walks `fieldnames`, and the writer puts each non-`nothing` field back under the prefix:

| # | Edit |
|---|---|
| 1 | `src/extensions/<prefix>.jl`: the struct, `prefix(::Type{T})`, `schema(::Type{T})` at the version the fields come from |
| 2 | one `include` in `src/STAC.jl`, beside the other six |
| 3 | `DEFAULT_EXTENSIONS` in `src/parse/options.jl`, when producers set its keys often enough to earn a field on every item; a struct left out is still reached by `get(item, T)` and `extensions = (…, T)` |
| 4 | the export list, under rule 3 above |
| 5 | `test/extensions.jl`: the three access paths against a fixture that carries the keys |

A user's own extension is steps 1 and 5 in their own package, which is the interface working
as designed.

## Fixtures

Fixtures are vendored, never fetched during a test run.

| Directory | Source |
|---|---|
| `test/fixtures/stac-spec/` | the `examples/` directory of radiantearth/stac-spec, pinned in `SOURCE.txt` |
| `test/fixtures/hand/` | hand-written documents covering shapes the spec examples miss |
| `test/fixtures/real-world/` | one recorded response per public endpoint, recorded once with `curl` |
| `test/fixtures/endpoints/` | one directory per API, recorded by `test/fixtures/record.jl` with the `requests.json` manifest that replays it |
| `test/fixtures/static/` | one catalog published three ways, derived from the spec examples |
| `test/fixtures/tokens/` | credential responses in the shape a service sends, with fixed expiries |
| `test/fixtures/geoparquet/` | parquet files written by the Python libraries that define stac-geoparquet and GeoParquet |

`stac-spec/` and `hand/` hold STAC documents alone: `test/write.jl` reads every `.json` under
both and round-trips it, so anything else belongs in a directory of its own.

Re-record a real-world fixture with the same URL and a `STAC.jl` User-Agent, and keep the
response body byte-for-byte as the server sent it.

Tests reach a fixture through `test/FixtureIO.jl`, which mounts a directory at an href
prefix and raises on any href it was not given. Fetching goes through the production
`AbstractIO` seam, never around it; the one exception is `test/io.jl`, which serves the same
fixtures over a loopback `HTTP.serve` so the HTTP path is exercised over real sockets.

### Recording an endpoint

```sh
julia --project=. test/fixtures/record.jl [endpoint …]
```

Run by hand, never in CI. Each endpoint named on the command line — all six with none — gets
its landing page, conformance document, first page of collections, one collection, one page
of that collection's items, and two pages of one search, through the production `HTTPIO`.
Four rules keep a recording usable as evidence rather than as a copy of the client:

1. **The recorder reads each `next` link from the spec, not from `STAC.pages`.** A client that
   pages differently than the spec says fails here.
2. **`requests.json` names the exact `(method, href, body)` that produced each file**, and
   `FixtureIO` matches all three. A client that formats a request differently fails to replay
   rather than being answered anyway.
3. **The window is fixed** — 2024-06-01 to 2024-06-05, two items a page — far enough in the
   past that a re-record answers with the same items.
4. **Five seconds between requests.** CDSE answers two searches in quick succession with a
   429.

Adding an endpoint is one `Endpoint(name, url, collection)` row. A credential recording
(`endpoints/planetary-computer-sas/`) needs hand-written bodies beside it in
`fixtures/tokens/`, since which side of a recorded expiry the clock is on changes by the hour.

## Tests

`Aqua.test_all` first, then one `@safetestset` per source concern.
`Pkg.test(test_args = ["parse", "write"])` runs a subset. The `--trim=safe` programs run when
they are named (`test_args = ["compile"]`) or `STAC_COMPILE_TESTS=1` is set, and as their own
CI job.

Three environment variables switch on the runs that are too slow or too networked for the
default:

| Variable | Effect |
|---|---|
| `STAC_COMPILE_TESTS=1` | build the `test/compile/` programs, as `test_args = ["compile"]` does |
| `STAC_EXTENSION_AQUA=1` | load all six trigger packages before Aqua, so the five extensions are checked; the `aqua-extensions` CI job |
| `STAC_LIVE_TESTS=1` | `test/live/runtests.jl` against the six public endpoints, by hand |

## Writing

Prose and comments follow `~/.claude/skills/writing/SKILL.md`: a comment carries the *why*
the code cannot show, a docstring leads with what the thing is, and cases and outcomes are
tables rather than run-on sentences.

### Examples

**Every example is written for `import STAC`, and spells this package's names `STAC.foo`.**
The export list is uneven — `collections` is exported and `collection` is not — so one
qualified spelling is what makes an example run whichever name it reaches for. It applies to
runnable code: a fenced block, a docstring's signature line, and inline code that is a call.
A bare name in prose or in `@ref` link text is the thing's name and stays as it is.

Two things stay unqualified, both because the name belongs to another package:

| Unqualified | Because |
|---|---|
| `Raster`, `RasterStack`, `RasterSeries`, `GeoInterface.geometry`, `Extents.extent`, `DataFrame`, `parent`, `get` | methods this package adds to another package's (or Base's) function |
| `using Rasters, ArchGDAL`, `using DuckDB`, `using GeoParquet`, `using AWSS3`, `using Makie` | a trigger package loaded for its own sake; `import STAC` goes on the line above |

`docs/make.jl` sets the doctest environment to `import STAC` alone, so a doctest's output
prints types the way a reader's session does — `STAC.Asset`, not `Asset`.

Run every example before committing it. Phase 8 found nine wrong docstrings that way, and the
qualification pass found six more sites: five doctest outputs that only matched because the
build had `using STAC` in `Main`, and one `s3://` block that raised.

## Commits

Imperative, capitalized, no prefix: `Add the spherical index`, not `feat: added index`.
