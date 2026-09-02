# Conventions for STAC.jl

STAC.jl follows the GeometryOps.jl house style. This file is the checklist; read it before
adding a file, a method, or a test.

## Layout

**One job per file.** `src/parse/sinks.jl` holds the parse routers and nothing else;
`src/parse/write.jl` holds the writer. A new concern gets a new file and one `include` in
`src/STAC.jl`, and `test/<name>.jl` mirrors it as a `@safetestset` listed in
`test/runtests.jl`.

A file at the top of `src/` never repeats the name of a directory beside it: the document
layer is `src/document.jl`, not `src/read.jl`, which would read as `src/io/`'s twin.

| Directory | Holds |
|---|---|
| `src/` | the package, one file per concern |
| `src/errors.jl` | every exception the package throws, under one `STACError` supertype |
| `src/document.jl` | `STAC.parse` and `STAC.read`: the `type` key choosing a struct, and `sethref` |
| `src/extensions/` | `interface.jl` plus one file per shipped STAC extension |
| `src/parse/` | the JSON style, its sinks, the writer, and `ParseOptions` |
| `src/search/` | `interface.jl`: the search protocol and the request its keywords build; `backends.jl`: the API and static searches |
| `src/io/` | the `AbstractIO` stack, auth, and href resolution: one wrapper per file |
| `ext/` | weak-dependency bridges, one module per trigger package |
| `test/fixtures/` | vendored documents; nothing here is fetched at test time |
| `test/compile/` | `juliac --trim=safe` programs and the testset that builds them |

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

## Fixtures

Fixtures are vendored, never fetched during a test run.

| Directory | Source |
|---|---|
| `test/fixtures/stac-spec/` | the `examples/` directory of radiantearth/stac-spec, pinned in `SOURCE.txt` |
| `test/fixtures/hand/` | hand-written documents covering shapes the spec examples miss |
| `test/fixtures/real-world/` | one recorded response per public endpoint, recorded once with `curl` |
| `test/fixtures/static/` | one catalog published three ways, derived from the spec examples |

Re-record a real-world fixture with the same URL and a `STAC.jl` User-Agent, and keep the
response body byte-for-byte as the server sent it.

Tests reach a fixture through `test/FixtureIO.jl`, which mounts a directory at an href
prefix and raises on any href it was not given. Fetching goes through the production
`AbstractIO` seam, never around it; the one exception is `test/io.jl`, which serves the same
fixtures over a loopback `HTTP.serve` so the HTTP path is exercised over real sockets.

## Tests

`Aqua.test_all` first, then one `@safetestset` per source concern.
`Pkg.test(test_args = ["parse", "write"])` runs a subset. The `--trim=safe` programs run when
they are named (`test_args = ["compile"]`) or `STAC_COMPILE_TESTS=1` is set, and as their own
CI job.

## Writing

Prose and comments follow `~/.claude/skills/writing/SKILL.md`: a comment carries the *why*
the code cannot show, a docstring leads with what the thing is, and cases and outcomes are
tables rather than run-on sentences.

## Commits

Imperative, capitalized, no prefix: `Add the spherical index`, not `feat: added index`.
