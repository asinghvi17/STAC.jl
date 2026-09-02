# Conventions for STAC.jl

STAC.jl follows the GeometryOps.jl house style. This file is the checklist; read it before
adding a file, a method, or a test.

## Layout

**One job per file.** `src/parse/sinks.jl` holds the parse routers and nothing else;
`src/parse/write.jl` holds the writer. A new concern gets a new file and one `include` in
`src/STAC.jl`, and `test/<name>.jl` mirrors it as a `@safetestset` listed in
`test/runtests.jl`.

| Directory | Holds |
|---|---|
| `src/` | the package, one file per concern |
| `src/extensions/` | `interface.jl` plus one file per shipped STAC extension |
| `src/parse/` | the JSON style, its sinks, the writer, and `ParseOptions` |
| `ext/` | weak-dependency bridges, one module per trigger package |
| `test/fixtures/` | vendored documents; nothing here is fetched at test time |
| `test/compile/` | `juliac --trim=safe` programs and the testset that builds them |

## Argument conventions

- **Manifold first.** `spatialindex(Spherical(), items)` is the positional form; the
  `manifold =` keyword belongs only on the convenience method.
- **`GI.*` accessors.** Reach a geometry through GeoInterface, never through a concrete
  type's fields.
- **`io` last, as a keyword with a default.** `children(cat; io = default_io())`.

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

## Fixtures

Fixtures are vendored, never fetched during a test run.

| Directory | Source |
|---|---|
| `test/fixtures/stac-spec/` | the `examples/` directory of radiantearth/stac-spec, pinned in `SOURCE.txt` |
| `test/fixtures/hand/` | hand-written documents covering shapes the spec examples miss |
| `test/fixtures/real-world/` | one recorded response per public endpoint, recorded once with `curl` |

Re-record a real-world fixture with the same URL and a `STAC.jl` User-Agent, and keep the
response body byte-for-byte as the server sent it.

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
