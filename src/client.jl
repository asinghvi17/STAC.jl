# The API client: one landing-page read, the conformance list it advertises, and the per-host
# quirks table that turns the choices the spec leaves open into data.

"""
    HostDefaults(max_limit, default_limit, reports_matched, dotdot_ok)

What one endpoint does with the four things STAC API 1.0.0 leaves to the server. A
[`Client`](@ref) matches one from [`STAC.HOST_DEFAULTS`](@ref) at construction, and a caller
who knows better passes their own as `host =`.

| Field | Meaning |
|---|---|
| `max_limit` | the largest `limit` the endpoint accepts; [`search`](@ref) clamps to it |
| `default_limit` | the page size to ask for when the caller names none |
| `reports_matched` | whether a page carries a total, so [`matched`](@ref) is worth a request |
| `dotdot_ok` | whether a `..` segment in a path survives the endpoint's gateway |
"""
struct HostDefaults
    max_limit::Int
    default_limit::Int
    reports_matched::Bool
    dotdot_ok::Bool
end

"""
    STAC.GENERIC_HOST

The spec's own limits, used for an endpoint no [`STAC.HOST_DEFAULTS`](@ref) pattern matches.
"""
const GENERIC_HOST = HostDefaults(10_000, 100, true, true)

"""
    STAC.HOST_DEFAULTS

The recorded quirks of the endpoints this package was probed against, most specific pattern
first. Add to it from an `__init__` to teach the package about another deployment.
"""
const HOST_DEFAULTS = Pair{Regex,HostDefaults}[
    # 1001 is a 400, only `numberReturned` comes back, and the CDN answers `..` with a 403.
    r"planetarycomputer\.microsoft\.com" => HostDefaults(1000, 250, false, false),
    # 500 and above is a 502 from the gateway, whatever the landing page advertises.
    r"earth-search\.aws\.element84\.com" => HostDefaults(499, 100, true, true),
    # stac-server again, behind a CloudFront distribution that rejects `..`.
    r"landsatlook\.usgs\.gov" => HostDefaults(10_000, 100, true, false),
    r"cmr\.earthdata\.nasa\.gov" => HostDefaults(5000, 100, true, true),
    # The cap is per collection; 200 is the tightest one observed (sentinel-2-l2a), and the
    # F5 WAF answers a `..` path with an HTML page at HTTP 200.
    r"stac\.dataspace\.copernicus\.eu" => HostDefaults(200, 100, false, false),
]

"""
    STAC.host_defaults(url) -> HostDefaults

The [`HostDefaults`](@ref) recorded for `url`'s host, or [`STAC.GENERIC_HOST`](@ref).
"""
function host_defaults(url::AbstractString)
    for (pattern, defaults) in HOST_DEFAULTS
        occursin(pattern, url) && return defaults
    end
    return GENERIC_HOST
end

"""
    Client(url; auth = NoAuth(), io = STAC.defaultstack(auth), host = nothing)

A STAC API, opened by reading its landing page once. The client holds that catalog, the
`conformsTo` list it advertises, the [`AbstractIO`](@ref STAC.AbstractIO) every later call
fetches through, and the [`HostDefaults`](@ref) matched from `url`.

The landing page is always parsed keeping its metadata tail, because `conformsTo` is not a
[`Catalog`](@ref) field; the parse options of [`search`](@ref) and [`collections`](@ref) are
per call.

```julia
client = Client("https://planetarycomputer.microsoft.com/api/stac/v1")
client.root.id                                  # "microsoft-pc"
STAC.conforms(client, "item-search")            # true
client.host.max_limit                           # 1000, from the recorded host table
first(search(client; collections = ["sentinel-2-l2a"], limit = 10)).id
```

A credentialed endpoint takes an [`STAC.AbstractAuth`](@ref) through `auth =`, and every
later call fetches with it.
"""
struct Client{I<:AbstractIO}
    url::String
    root::Catalog{Metadata}
    conformsTo::Vector{String}
    io::I
    host::HostDefaults
end

function Client(url::AbstractString; auth::AbstractAuth = NoAuth(),
                io::AbstractIO = defaultstack(auth), host::Union{HostDefaults,Nothing} = nothing)
    origin = absolutehref(url)
    root = sethref(JSON.parse(read(io, origin), Catalog{Metadata}; style = STACStyle()), origin)
    return Client(String(origin), root, conformanceclasses(root), io,
                  something(host, host_defaults(origin)))
end

"""
    STAC.conformanceclasses(root::Catalog) -> Vector{String}

The `conformsTo` array of a landing page, which the parse leaves in the catalog's metadata
tail. An endpoint that publishes none gives an empty vector.
"""
function conformanceclasses(root::Catalog)
    v = get(root.metadata, "conformsTo", nothing)
    v isa AbstractVector || return String[]
    return String[x for x in v if x isa AbstractString]
end

"""
    STAC.conforms(client, class) -> Bool

Whether the endpoint advertises a conformance class. A full URI must match an entry exactly;
a short name such as `"item-search"` or `"item-search#filter"` matches any version, since
endpoints publish the same class under `v1.0.0`, `v1.0.0-rc.2`, and the OGC URIs
side by side.

```julia
STAC.conforms(client, "item-search")                            # any version
STAC.conforms(client, "https://api.stacspec.org/v1.0.0/core")   # exactly this one
```
"""
function conforms(client::Client, class::AbstractString)
    occursin("://", class) && return class in client.conformsTo
    suffix = "/" * class
    return any(c -> endswith(c, suffix), client.conformsTo)
end

@noinline _nolink(client::Client, rel) = throw(MissingLink(client.url, String(rel)))

"""
    STAC.linkhref(obj, rel; method = nothing) -> Union{String,Nothing}

The href of `obj`'s first link with this `rel`, resolved against `obj`'s origin. When
`method` is given, a link that names a different one is skipped, which is how the two
`search` links of a landing page are told apart.
"""
function linkhref(obj, rel::AbstractString; method::Union{AbstractString,Nothing} = nothing)
    for l in obj.links
        l.rel == rel || continue
        (method === nothing || l.method === nothing || l.method == method) || continue
        return resolve(l, obj.href)
    end
    return nothing
end

function requiredlink(client::Client, rel::AbstractString; method = nothing)
    href = linkhref(client.root, rel; method)
    href === nothing && _nolink(client, rel)
    return href
end

"""
    STAC.selfhref(obj) -> Union{String,Nothing}

The absolute `self` href `obj` publishes, or `nothing`. This is the origin an object fetched
as part of a larger document (one entry of `/collections`) gets stamped with.
"""
function selfhref(obj)
    for l in obj.links
        (l.rel == "self" && isabsolutehref(l.href)) && return l.href
    end
    return nothing
end

@noinline _nocollections(href) = throw(MissingCollections(String(href)))

"""
    collections(client; extensions, geometry, metadata) -> Vector{Collection}

Every collection the endpoint's `data` link lists, each stamped with its own `self` href.

The keywords are [`ParseOptions`](@ref)'s. Endpoints page `/collections`; this reads the
first page only, which is every collection on all six endpoints probed.

```julia
client = Client("https://earth-search.aws.element84.com/v1")
cols = collections(client)
[c.id for c in cols]                # "sentinel-2-l2a", "landsat-c2-l2", …
first(cols).href                    # its own `self` href, so its links resolve
```
"""
function collections(client::Client, opts::ParseOptions)
    href = requiredlink(client, "data")
    doc = JSON.lazy(read(client.io, href))
    entries = get(doc, :collections, nothing)
    entries === nothing && _nocollections(href)
    cols = JSON.parse(entries, Vector{collectiontype(opts)}; style = STACStyle())
    return map(c -> sethref(c, selfhref(c)), cols)
end

collections(client::Client; kw...) = collections(client, ParseOptions(; kw...))

"""
    collection(client, id; extensions, geometry, metadata) -> Collection

One collection by id, from `<data href>/<id>`.

```julia
client = Client("https://earth-search.aws.element84.com/v1")
col = collection(client, "sentinel-2-l2a")
col.extent.spatial.bbox[1]          # the collection's footprint, as a bbox
first(items(client, col)).id        # its first item, through /collections/<id>/items
```
"""
function collection(client::Client, id::AbstractString, opts::ParseOptions)
    href = rstrip(requiredlink(client, "data"), '/') * "/" * id
    return read(collectiontype(opts), href, client.io, opts)
end

collection(client::Client, id::AbstractString; kw...) =
    collection(client, id, ParseOptions(; kw...))

"""
    items(client, collection_id; limit, datetime, bbox, extensions, geometry, metadata)
    items(client, collection::Collection; …)

The items of one collection through the OGC API - Features endpoint
(`/collections/<id>/items`), as an [`AbstractItemSearch`](@ref STAC.AbstractItemSearch): a
lazy iterator of [`Item`](@ref)s that follows `next` links.

This is the `GET` twin of [`search`](@ref) and takes the same spatial and temporal keywords;
`collections` and `ids` are not among them, since the path already names the collection.
"""
function items(client::Client, collection_id::AbstractString; kw...)
    href = rstrip(requiredlink(client, "data"), '/') * "/" * collection_id * "/items"
    return featuresearch(client, href; kw...)
end

function items(client::Client, col::Collection; kw...)
    href = linkhref(col, "items")
    href === nothing && _nolink(client, "items")
    return featuresearch(client, href; kw...)
end
