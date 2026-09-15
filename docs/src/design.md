# How the package fits together

STAC.jl turns documents into values, then uses those same values for catalog traversal, API search, spatial selection, and asset opening. The design keeps three choices separate: what to parse, how to fetch it, and what to do with the result.

| Layer | Owns | Source entry point |
|---|---|---|
| Document model | Typed fields, extension values, metadata tails | [`objects.jl`](https://github.com/asinghvi17/STAC.jl/blob/main/src/objects.jl) |
| Parsing and writing | JSON ↔ document values | [`document.jl`](https://github.com/asinghvi17/STAC.jl/blob/main/src/document.jl), [`parse/`](https://github.com/asinghvi17/STAC.jl/tree/main/src/parse) |
| IO | Bytes, requests, credentials, href resolution | [`io/`](https://github.com/asinghvi17/STAC.jl/tree/main/src/io) |
| Traversal and search | Linked documents → pages → items | [`traverse.jl`](https://github.com/asinghvi17/STAC.jl/blob/main/src/traverse.jl), [`search/`](https://github.com/asinghvi17/STAC.jl/tree/main/src/search) |
| Spatial selection | Item positions that match a query | [`spatialindex.jl`](https://github.com/asinghvi17/STAC.jl/blob/main/src/spatialindex.jl) |
| Ecosystem adapters | Features, tables, rasters, bulk formats, plots | [`geo.jl`](https://github.com/asinghvi17/STAC.jl/blob/main/src/geo.jl), [`tables.jl`](https://github.com/asinghvi17/STAC.jl/blob/main/src/tables.jl), [`ext/`](https://github.com/asinghvi17/STAC.jl/tree/main/ext) |

## Typed fields give structure; tails preserve unfamiliar data

Core fields have declared Julia types. Unrecognized JSON keys go into an ordered metadata dictionary called a *tail*. This lets the package offer predictable access without needing a new release for every producer-specific key.

An item has two tails: `properties.other` for property keys and `metadata` for top-level keys. Its `extensions` field holds the caller's eagerly selected extension structs. Known extension fields leave the property tail; other keys remain available for lookup and writing.

The writer reconstructs a JSON document from these parts. It restores discriminators, puts extension prefixes back, and omits the runtime origin. It writes the parsed values, not the source bytes: field order and timestamp spelling can change, typed timestamps retain only millisecond precision, and most typed null fields are omitted.

The [typed parsing page](parsing.md) explains how this split also supports static compilation.

## Documents carry an origin; callers carry the transport

A document's `href` says where it came from. Traversal resolves a relative link against that origin, fetches the child, and gives the child its own origin. The original link text stays intact.

The IO stack travels separately. The same document can therefore be read through a filesystem, HTTP, a cache, or a test fixture without changing its type or embedding credentials in it.

Origin belongs to the document, not every nested value. In particular, an asset does not inherit its item's origin: asset-opening code cannot resolve a relative asset href from the asset alone.

See [Fetching and credentials](io.md) for the public interface and relative-href limits.

## IO wrappers compose policies

Each wrapper implements a small protocol and delegates the remaining work. The default stack is a cache around a scheme router, with HTTP and path transports underneath. The router's tuple of children lets generated dispatch keep each transport type visible to the compiler.

| Operation | Responsibility | Important boundary |
|---|---|---|
| `STAC.read(io, href)` | Fetch bytes | `CachingIO` caches this operation |
| `STAC.request(io, method, href; headers, body)` | Execute an API request | The cache forwards requests uncached, including GET |
| `STAC.authfor(io, href)` | Find the applicable credentials | Wrappers must forward this too |

Credential discovery also serves external asset readers. Routing prepares a filename and driver configuration; the Rasters bridge passes those to GDAL. GDAL then reads the pixels itself. Sharing credentials does not mean sharing the STAC byte cache.

## Pages unify search; backends choose when to work

The search protocol centers on pages. A backend supplies pages of items; shared iteration flattens their features. An empty page can still have a successor, so flattening continues until page iteration ends.

| Backend | First demand | Later demand |
|---|---|---|
| API | Fetch the first response page | Follow each response's `next` link |
| Static catalog | Walk the catalog and materialize the filtered result | Slice the cached result into pages |

This gives both backends the same user-facing iteration interface without promising the same latency or memory use.

API pagination treats a `next` link as a request description. Its href, method, headers, body, and merge flag determine the next request. A merged body overlays the **original search body**. Keeping that logic at the page boundary prevents endpoint-specific cursor conventions from leaking into item iteration.

See [Searching](search.md) for query options and conformance checks.

## Spatial selection separates candidates from exact answers

The index returns positions in the original item vector. Its tree stores manifold-specific bounding volumes: ordinary extents on the plane, XYZ boxes on the unit sphere. Spherical boxes make queries across the antimeridian possible without treating longitude as one continuous planar interval.

| Query | Work performed | Result means |
|---|---|---|
| Plain extent or geometry | Tree overlap test | Bounding-volume candidates |
| DE-9IM predicate wrapper | Candidate selection, then geometry relation test | Matches for that predicate |
| `Disjoint` predicate | Test every item with a geometry | Disjoint matches can lie outside overlap candidates |

Leaves prefer the item's bbox and fall back to a rectangle over geometry vertices. Exact tests use GeoInterface accessors and the index's manifold. These are separate responsibilities: a fast tree narrows the work; the predicate defines the answer.

See [Spatial selection](spatial.md) for runnable queries and null-geometry behavior.

## Adapters keep one model usable across packages

GeoInterface and Tables methods expose items as features and rows. Heavy integrations live in Julia package extensions under `ext/`, so core STAC use does not load raster, database, or plotting stacks.

There are two different meanings of *extension* here:

| Kind | Purpose | Location |
|---|---|---|
| STAC extension struct, such as `STAC.EO` | Describe prefixed metadata fields | `src/extensions/` |
| Julia package extension, such as `STACRastersExt` | Add methods when dependencies load | `ext/` |

A new metadata schema belongs in the first category. A bridge to another package belongs in the second. For example, the Rasters bridge loads when both Rasters and ArchGDAL are present; it adapts existing assets rather than introducing another item model.

## Tests check the boundaries the design relies on

| Evidence | What it protects |
|---|---|
| Vendored fixtures and round-trip tests | Parsing and reconstruction of real document shapes |
| `FixtureIO` request replay | Production traversal and paging issue the expected method, href, and JSON body; unexpected requests fail locally |
| One safe testset per concern | Tests do not depend on another testset's imports or definitions |
| Aqua with bridge dependencies loaded | Methods added by optional integrations remain compatible |
| Linked trim programs | Selected read, traversal, search, and index paths remain statically resolvable |

Start a change at the layer that owns its policy, then test through its public boundary. Use [Static compilation](compilation.md) to distinguish paths that link today from paths whose unresolved calls are only budgeted.
