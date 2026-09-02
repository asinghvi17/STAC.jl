```@meta
CurrentModule = STAC
DocTestSetup = quote
    import STAC
end
```

# Fetching and credentials

A STAC object holds its own origin and nothing else — no connection, no session, no
transport. Everything that fetches is an [`AbstractIO`](@ref STAC.AbstractIO), which a caller
passes as `io =` or which [`STAC.default_io`](@ref) supplies.

Two methods are the whole interface:

| Method | Answers |
|---|---|
| `STAC.read(io, href)` | the bytes at `href` |
| [`STAC.request(io, method, href; headers, body)`](@ref STAC.request) | the body of one request, which is what a search POST and its `next` links need |

The default `request` answers `GET` with `read` and rejects everything else, which is the
whole implementation for a transport that can only fetch.

## The default stack

[`STAC.defaultstack`](@ref) builds a cache over a scheme router:

```text
CachingIO
└── StreamRouterIO
    ├── "https" → HTTPIO(auth)
    ├── "http"  → HTTPIO(auth)
    ├── ""      → PathIO()      # a local path
    └── "file"  → PathIO()
```

Routing per href rather than per catalog is what lets a catalog on `https://` own items on
`s3://`, or a `next` link point at another host.

| Wrapper | Does |
|---|---|
| [`CachingIO`](@ref STAC.CachingIO) | answers a repeated `read` from an LRU; `request` passes through, a search POST not being addressed by its href alone |
| [`StreamRouterIO`](@ref STAC.StreamRouterIO) | picks a child by the href's scheme, with `""` meaning a local path |
| [`HTTPIO`](@ref STAC.HTTPIO) | HTTP.jl, with retries, timeouts, and a `STAC.jl/<version>` `User-Agent` |
| [`PathIO`](@ref STAC.PathIO) | `Base.read` on the path, accepting a `file://` href too |
| [`S3IO`](@ref) | `s3://` through AWSS3.jl, once `import AWSS3` has given it a method |

The cache is why a recursive walk is cheap: `root` and `parent` are reached from every object
the walk visits, and each document is fetched once however often it is linked.

```jldoctest io
julia> examples = joinpath(pkgdir(STAC), "test", "fixtures", "static", "self-contained");

julia> io = STAC.CachingIO(STAC.PathIO(); maxsize = 32)
CachingIO(0/32 cached)
└─ PathIO()

julia> cat = STAC.read(joinpath(examples, "catalog.json"); io);

julia> collect(STAC.items(cat; recursive = true, io));

julia> length(io.cache)     # the catalog, two collections, four items
7

julia> empty!(io); length(io.cache)
0
```

A stack prints as the tree it is, so the transport that will answer a given scheme, and the
credentials sitting on it, are one line each:

```jldoctest io
julia> STAC.defaultstack(STAC.BearerToken("s3cret"))
CachingIO(0/128 cached)
└─ StreamRouterIO(4 routes)
   ├─ "https" → HTTPIO(BearerToken)
   ├─ "http"  → HTTPIO(BearerToken)
   ├─ ""      → PathIO()
   └─ "file"  → PathIO()
```

An auth appears by type. The token itself is never printed, so a stack can go into a bug
report as it stands.

Swap the stack for a block with [`STAC.with`](@ref), which rebinds
[`STAC.DEFAULT_IO`](@ref) for the dynamic extent of the call:

```julia
STAC.with(STAC.defaultstack(STAC.BearerToken(ENV["TOKEN"]))) do
    STAC.read("https://example.com/catalog.json")
end
```

## Credentials

An [`STAC.AbstractAuth`](@ref) answers three questions, all of them per href, so one stack can
hold a token for a catalog's own host and stay anonymous for the buckets its assets live in.

| Question | Method |
|---|---|
| which headers go on a request for this href? | [`STAC.headers`](@ref) |
| what href should a reader see? | [`STAC.rewrite`](@ref) |
| what does GDAL need to fetch it? | [`STAC.gdal_config`](@ref) |

What ships:

| Auth | Headers | Href |
|---|---|---|
| [`NoAuth`](@ref) (the default) | none | unchanged |
| [`BearerToken`](@ref) | `Authorization: Bearer <token>` | unchanged |
| [`STAC.Headers`](@ref) | as given | unchanged |
| [`EarthdataLogin`](@ref) | `Authorization: Bearer <token>`, for NASA hosts only | unchanged |
| [`PlanetaryComputerSAS`](@ref) | none | a SAS token appended per storage container, cached until it expires |

```jldoctest io
julia> STAC.headers(STAC.BearerToken("s3cret"), "https://example.com")
1-element Vector{Pair{String, String}}:
 "Authorization" => "Bearer s3cret"

julia> STAC.headers(STAC.NoAuth(), "https://example.com")
Pair{String, String}[]

julia> STAC.headers(STAC.EarthdataLogin("tok"), "https://example.com/b.tif")   # not a NASA host
Pair{String, String}[]

julia> STAC.headers(STAC.EarthdataLogin("tok"), "https://data.lpdaac.earthdatacloud.nasa.gov/x/B04.tif")
1-element Vector{Pair{String, String}}:
 "Authorization" => "Bearer tok"
```

A [`Client`](@ref) takes one through `auth =` and every later call carries it:

```julia
client = STAC.Client("https://planetarycomputer.microsoft.com/api/stac/v1";
                     auth = STAC.PlanetaryComputerSAS())
client = STAC.Client("https://cmr.earthdata.nasa.gov/stac/LPCLOUD";
                     auth = STAC.EarthdataLogin(ENV["EARTHDATA_TOKEN"]))
```

### Writing your own

An auth that only adds headers needs one method. [`STAC.rewrite`](@ref) defaults to the
identity, and [`STAC.gdal_config`](@ref) turns whatever `headers` returns into a single
`GDAL_HTTP_HEADERS` option, so the credential reaches GDAL without a second method either.

```jldoctest io
julia> struct QueryToken <: STAC.AbstractAuth
           token::String
       end

julia> STAC.headers(::QueryToken, ::AbstractString) = STAC.NO_HEADERS;

julia> STAC.rewrite(a::QueryToken, href::AbstractString) = href * "?token=" * a.token;

julia> STAC.rewrite(QueryToken("abc"), "https://example.com/catalog.json")
"https://example.com/catalog.json?token=abc"
```

### How credentials reach the pixels

[`STAC.authfor`](@ref) asks a stack which auth it would fetch a given href with. A wrapper
asks its inner IO and a router asks the child its scheme picks, so the answer is the auth that
actually applies to the href at hand:

```jldoctest io
julia> stack = STAC.defaultstack(STAC.BearerToken("s3cret"));

julia> STAC.authfor(stack, "https://example.com/b.tif")
STAC.BearerToken("s3cret")

julia> STAC.authfor(stack, "/data/b.tif")
STAC.NoAuth()
```

That is the whole mechanism behind `Raster(client, asset)`:
[`STAC.route`](@ref) asks the stack for the auth, the auth signs the href and names the GDAL
options, and the [Rasters bridge](rasters.md) sets those options against the bucket or host
prefix rather than against the process.

```jldoctest io
julia> STAC.gdal_config(STAC.BearerToken("s3cret"), "https://example.com/b.tif")
1-element Vector{Pair{String, String}}:
 "GDAL_HTTP_HEADERS" => "Authorization: Bearer s3cret"

julia> STAC.gdal_config(STAC.NoAuth(), "https://example.com/b.tif")
Pair{String, String}[]
```

## Hrefs

A [`Link`](@ref) keeps its href exactly as the producer wrote it, so resolution is a separate
step and a document can be written back verbatim. [`STAC.resolve`](@ref) is RFC 3986
reference resolution, with local paths handled as paths:

```jldoctest io
julia> STAC.resolve("./item.json", "https://example.com/a/b")
"https://example.com/a/item.json"

julia> STAC.resolve("./item.json", "https://example.com/a/b/")   # the trailing slash counts
"https://example.com/a/b/item.json"

julia> STAC.resolve("/collections/x.json", "https://example.com/a/b")
"https://example.com/collections/x.json"

julia> STAC.resolve("./item.json", "/data/a/catalog.json")
"/data/a/item.json"
```

[`STAC.urischeme`](@ref) is what the router matches on, and it answers `""` for two things
RFC 3986 would read otherwise: a Windows drive letter, and a path with a raw space in it.

## Buckets

`s3://` needs AWSS3.jl, which resolves credentials the way the AWS CLI does — the
environment, the shared credentials file, then the instance metadata service. [`S3IO`](@ref)
is a name this package owns and that package implements, so calling it before loading AWSS3
raises a `MethodError` that says which package to load.

```julia
import STAC
using AWSS3

s3 = STAC.S3IO(; config = AWSS3.AWS.AWSConfig(; creds = nothing, region = "us-west-2"))
io = STAC.StreamRouterIO("s3" => s3, "https" => STAC.HTTPIO(), "" => STAC.PathIO())
STAC.read("s3://sentinel-cogs/.../S2B_32TQL_20240601_0_L2A.json"; io)
```

Name the region a public bucket lives in: AWS.jl resolves `nothing` to the default one, and a
bucket somewhere else answers a request sent there with a `PermanentRedirect`.

Google Cloud Storage and Azure have no `AbstractPath` type in the Julia ecosystem, so catalog
JSON on those stores is read over `https://` and their assets go through GDAL's `/vsigs/` and
`/vsiaz/` — see [Opening assets as rasters](rasters.md).
