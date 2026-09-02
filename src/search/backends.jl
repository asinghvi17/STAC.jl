# The two backends on the search protocol: a STAC API, paged by following `next` links, and a
# static catalog, walked once and filtered in memory.

# ---------------------------------------------------------------------------------------
# The API backend

"""
    STAC.APIItemSearch

A search against a STAC API, as one prepared request plus the parse options its pages are
read with. Build one with [`search`](@ref) or [`items`](@ref); iterate it for items, or
[`pages`](@ref) it for whole [`ItemCollection`](@ref)s.

`predicate` holds the DE-9IM predicate an `intersects =` argument carried, and every page is
filtered through it on the sphere before the caller sees it.
"""
struct APIItemSearch{I<:AbstractIO,O<:ParseOptions,P} <: AbstractItemSearch
    io::I
    method::String
    href::String
    body::Union{JSON.Object{String,Any},Nothing}
    headers::RequestHeaders
    host::HostDefaults
    opts::O
    predicate::P
end

Base.eltype(::Type{<:APIItemSearch{I,O}}) where {I,O} = itemtype(O)

const JSON_CONTENT_TYPE = "Content-Type" => "application/json"

"""
    STAC.PageIterator

The paging loop of an [`STAC.APIItemSearch`](@ref): one element per request, each one the
`next` link of the previous page.
"""
struct PageIterator{S<:APIItemSearch}
    search::S
end

Base.IteratorSize(::Type{<:PageIterator}) = Base.SizeUnknown()
Base.eltype(::Type{<:PageIterator{<:APIItemSearch{I,O}}}) where {I,O} = itemcollectiontype(O)

pages(s::APIItemSearch) = PageIterator(s)

"""
    STAC.PageState

The request the next `iterate` of a [`STAC.PageIterator`](@ref) will make, rewritten in place
from each page's `next` link.
"""
mutable struct PageState
    method::String
    href::String
    body::Union{JSON.Object{String,Any},Nothing}
    headers::RequestHeaders
    done::Bool
end

PageState(s::APIItemSearch) = PageState(s.method, s.href, s.body, s.headers, false)

function fetchpage(s::APIItemSearch, state::PageState)
    body = state.body
    # One call per shape rather than one carrying `body::Union{Nothing,String}`: keyword
    # arguments are passed as one named tuple, and a union in it makes the call a dynamic
    # dispatch that `--trim=safe` reports as unresolved.
    bytes = body === nothing ?
            request(s.io, state.method, state.href; headers = state.headers) :
            request(s.io, state.method, state.href;
                    headers = vcat(state.headers, [JSON_CONTENT_TYPE]),
                    body = JSON.json(body; style = STACStyle()))
    page = JSON.parse(bytes, itemcollectiontype(s.opts); style = STACStyle())
    return sethref(filterpage(s.predicate, page), state.href)
end

"""
    STAC.filterpage(predicate, page::ItemCollection) -> ItemCollection

`page` with only the items the predicate holds for, evaluated on the sphere. `numberMatched`
stays as the endpoint reported it, since that is a property of the request rather than of
what survived; `numberReturned` counts what is left.
"""
filterpage(::Nothing, page::ItemCollection) = page

function filterpage(pred::DE9IM.DE9IMPredicate, page::ItemCollection)
    alg = GO.RelateNG(GO.Spherical())
    b = parent(pred)
    kept = filter(page.features) do item
        a = GI.geometry(item)
        return a !== nothing && _holds(alg, pred, a, b)
    end
    return ItemCollection(kept; links = page.links, numberMatched = page.numberMatched,
                          metadata = page.metadata, href = page.href)
end

"""
    STAC.nextbody(link, original) -> Union{JSON.Object{String,Any},Nothing}

The body of the request a `next` link describes. `merge: true` means the link carries only
the keys that changed, so they go on top of the search's original body; the default,
`merge: false`, means the link's body is the whole request.
"""
function nextbody(link::Link, original)
    link.body === nothing && return nothing
    body = jsonobject(link.body)
    (link.merge === true && original !== nothing) || return body
    merged = JSON.Object{String,Any}()
    for (k, v) in original
        merged[k] = v
    end
    for (k, v) in body
        merged[k] = v
    end
    return merged
end

jsonobject(o::JSON.Object{String,Any}) = o
jsonobject(d::AbstractDict) = JSON.Object{String,Any}(String(k) => v for (k, v) in d)

linkheaders(::Nothing) = NO_HEADERS

function linkheaders(m::Metadata)
    hs = RequestHeaders()
    for (k, v) in m
        push!(hs, k => queryvalue(v))
    end
    return hs
end

function advance!(state::PageState, s::APIItemSearch, page::ItemCollection)
    link = nextlink(page)
    if link === nothing
        state.done = true
        return state
    end
    state.method = link.method === nothing ? "GET" : uppercase(link.method)
    state.href = resolve(link, page.href)
    state.body = nextbody(link, s.body)
    state.headers = linkheaders(link.headers)
    return state
end

function Base.iterate(p::PageIterator, state::PageState = PageState(p.search))
    state.done && return nothing
    page = fetchpage(p.search, state)
    advance!(state, p.search, page)
    return page, state
end

function matched(s::APIItemSearch)
    s.host.reports_matched || return nothing
    return numbermatched(fetchpage(s, PageState(s)))
end

# ---------------------------------------------------------------------------------------
# `search(client; …)`, and the features endpoint `items(client, collection)` reaches

@noinline _noconformance(client::Client, class::AbstractString, argument::AbstractString) =
    throw(NoConformance(client.url, String(class), String(argument), length(client.conformsTo)))

"""
    STAC.check_conformance(client; filter, query, sortby, fields)

Raise unless the endpoint advertises every conformance class the request needs. The error
names the missing class, so a request that cannot work fails at the call site rather than as
a 400 pages later.

| Argument given | Class required |
|---|---|
| any search | `item-search` |
| `filter` | `item-search#filter` |
| `query` | `item-search#query` |
| `sortby` | `item-search#sort` |
| `fields` | `item-search#fields` |
"""
function check_conformance(client::Client; filter = nothing, query = nothing,
                           sortby = nothing, fields = nothing)
    conforms(client, "item-search") || _noconformance(client, "item-search", "`search`")
    filter === nothing || conforms(client, "item-search#filter") ||
        _noconformance(client, "item-search#filter", "`filter =`")
    query === nothing || conforms(client, "item-search#query") ||
        _noconformance(client, "item-search#query", "`query =`")
    sortby === nothing || conforms(client, "item-search#sort") ||
        _noconformance(client, "item-search#sort", "`sortby =`")
    fields === nothing || conforms(client, "item-search#fields") ||
        _noconformance(client, "item-search#fields", "`fields =`")
    return nothing
end

searchlimit(host::HostDefaults, ::Nothing) = host.default_limit
searchlimit(host::HostDefaults, limit::Integer) = clamp(Int(limit), 1, host.max_limit)

"""
    search(client; collections, ids, intersects, datetime, query, filter, filter_lang,
           sortby, fields, limit, method, extensions, geometry, metadata) -> APIItemSearch
    search(client, opts::ParseOptions; …)

A prepared item search. Nothing is fetched until the result is iterated, so building a search
costs no request.

| Keyword | Takes |
|---|---|
| `collections`, `ids` | a string or a list of strings |
| `intersects` | a GeoInterface geometry, an `Extents.Extent`, a bbox of 4 or 6 numbers, or a DE-9IM predicate wrapping any of those |
| `datetime` | see [`STAC.normalize_datetime`](@ref) |
| `query`, `filter`, `filter_lang`, `fields` | the extension bodies, passed through |
| `sortby` | `"-datetime"`, `"+id"`, a list of those, or the spec's `{field, direction}` objects |
| `limit` | the page size, clamped to the host's cap; the host default when omitted |
| `method` | `"POST"` (the default) or `"GET"` |
| `extensions`, `geometry`, `metadata` | [`ParseOptions`](@ref)'s, fixing the item type |

The request is checked against the endpoint's `conformsTo` before it is built, so a `filter`
an endpoint cannot answer raises here rather than 400ing later.

```julia
client = Client("https://earth-search.aws.element84.com/v1")

# a collection, an area, and a window
s = search(client; collections = ["sentinel-2-l2a"],
           intersects = Extent(X = (-123, -122), Y = (37, 38)),
           datetime = (DateTime(2024, 6, 1), DateTime(2024, 6, 5)), limit = 100)
matched(s)                        # the total, on an endpoint that reports one

# a geometry goes as `intersects`, in Float64 whatever precision it arrived in
aoi = GeoJSON.read(read("aoi.geojson", String))
search(client; intersects = aoi, datetime = Date(2024, 6, 1))

# pages arrive as they are reached
collect(Iterators.take(s, 5))     # five items, from one request of 100
```

`search(client, opts::ParseOptions; …)` is the explicit form, matching
[`children(obj, opts; io)`](@ref children). It is what a `--trim=safe` program calls: the
options are a type there, and building one from three keywords inside the call leaves the
item type to a runtime computation over `DataType` values.
"""
function search(client::Client, opts::ParseOptions; collections = nothing, ids = nothing,
                intersects = nothing, datetime = nothing, query = nothing, filter = nothing,
                filter_lang = nothing, sortby = nothing, fields = nothing, limit = nothing,
                method::AbstractString = "POST")
    check_conformance(client; filter, query, sortby, fields)
    body = build_body(; collections, ids, intersects, datetime, query, filter, filter_lang,
                      sortby, fields, limit = searchlimit(client.host, limit))
    pred = predicate(intersects)
    verb = uppercase(method)
    href = requiredlink(client, "search"; method = verb)
    verb == "GET" && return APIItemSearch(client.io, "GET", withquery(href, querystring(body)),
                                          nothing, NO_HEADERS, client.host, opts, pred)
    return APIItemSearch(client.io, verb, href, body, NO_HEADERS, client.host, opts, pred)
end

search(client::Client; extensions = DEFAULT_EXTENSIONS, geometry = DEFAULT_GEOMETRY,
       metadata = true, kw...) =
    search(client, ParseOptions(; extensions, geometry, metadata); kw...)

"""
    STAC.featuresearch(client, href; …) -> APIItemSearch
    STAC.featuresearch(client, href, opts::ParseOptions; …)

A `GET` search against an OGC API - Features items endpoint, which is what
[`items(client, collection)`](@ref) returns. The keywords are [`search`](@ref)'s, minus the
ones the path already fixes.
"""
function featuresearch(client::Client, href::AbstractString, opts::ParseOptions;
                       ids = nothing, intersects = nothing, datetime = nothing,
                       query = nothing, filter = nothing, filter_lang = nothing,
                       sortby = nothing, fields = nothing, limit = nothing)
    body = build_body(; ids, intersects, datetime, query, filter, filter_lang, sortby, fields,
                      limit = searchlimit(client.host, limit))
    return APIItemSearch(client.io, "GET", withquery(href, querystring(body)), nothing,
                         NO_HEADERS, client.host, opts, predicate(intersects))
end

featuresearch(client::Client, href::AbstractString; extensions = DEFAULT_EXTENSIONS,
              geometry = DEFAULT_GEOMETRY, metadata = true, kw...) =
    featuresearch(client, href, ParseOptions(; extensions, geometry, metadata); kw...)

# ---------------------------------------------------------------------------------------
# The static backend

"""
    STAC.StaticItemSearch

A search over a catalog on disk or on a plain web server, as the walk it will make plus the
filters it will apply. It answers the same [`pages`](@ref) protocol as
[`STAC.APIItemSearch`](@ref), so iteration, `Iterators.take`, and [`matched`](@ref) behave
the same on both. Build one with [`search`](@ref).

The walk, the filters, and the index run once, on the first page asked for, and the result
is kept: `matched(s)` after `collect(s)` costs nothing.
"""
mutable struct StaticItemSearch{E,G,M,C,I<:AbstractIO,S,Mf<:GO.Manifold} <: AbstractItemSearch
    root::C
    io::I
    opts::ParseOptions{E,G,M}
    collections::Union{Vector{String},Nothing}
    ids::Union{Vector{String},Nothing}
    interval::TimeInterval
    spatial::S
    manifold::Mf
    limit::Int
    cache::Union{Nothing,Vector{Item{E,G,M}}}
end

Base.eltype(::Type{<:StaticItemSearch{E,G,M}}) where {E,G,M} = Item{E,G,M}

function _selects(s::StaticItemSearch, item::Item)
    if s.collections !== nothing
        (item.collection !== nothing && item.collection in s.collections) || return false
    end
    s.ids === nothing || item.id in s.ids || return false
    return intimerange(item, s.interval)
end

"""
    STAC.staticitems(s::StaticItemSearch) -> Vector{Item}

Every item the search matches, in catalog order. The first call walks the catalog — one
request per document reached — filters by collection, id, and time, then runs the spatial
argument against an index of what is left; later calls read the kept vector.
"""
function staticitems(s::StaticItemSearch{E,G,M}) where {E,G,M}
    s.cache === nothing || return s.cache
    kept = Item{E,G,M}[]
    for item in items(s.root, s.opts; io = s.io, recursive = true)
        _selects(s, item) && push!(kept, item)
    end
    hits = query(spatialindex(s.manifold, kept), s.spatial)
    s.cache = kept[hits]
    return s.cache
end

matched(s::StaticItemSearch) = length(staticitems(s))

"""
    STAC.StaticPages

The pages of a [`STAC.StaticItemSearch`](@ref): the matching items cut into chunks of
`limit`, each one an [`ItemCollection`](@ref) reporting the exact total.
"""
struct StaticPages{S<:StaticItemSearch}
    search::S
end

Base.IteratorSize(::Type{<:StaticPages}) = Base.SizeUnknown()
Base.eltype(::Type{<:StaticPages{<:StaticItemSearch{E,G,M}}}) where {E,G,M} =
    ItemCollection{E,G,M}

pages(s::StaticItemSearch) = StaticPages(s)

# A search that matches nothing still yields one empty page, as one request against an API
# would, so `first(pages(s))` is always a page.
function Base.iterate(p::StaticPages, i::Int = 1)
    its = staticitems(p.search)
    (i > 1 && i > length(its)) && return nothing
    stop = min(i + p.search.limit - 1, length(its))
    chunk = its[i:stop]
    page = ItemCollection(chunk; numberMatched = length(its), href = p.search.root.href)
    return page, max(i, stop) + 1
end

"""
    search(catalog; collections, ids, intersects, datetime, limit, manifold, io,
           extensions, geometry, metadata) -> STAC.StaticItemSearch
    search(catalog, opts::ParseOptions; …)

A search over a static [`Catalog`](@ref) or [`Collection`](@ref), with the spatial and
temporal keywords [`search(client; …)`](@ref search) takes. Nothing is fetched until the
result is iterated.

| Keyword | Takes |
|---|---|
| `collections`, `ids` | a string or a list of strings |
| `intersects` | a GeoInterface geometry, an `Extents.Extent`, a bbox of 4 or 6 numbers, a `SphericalCap`, or a DE-9IM predicate wrapping any of those |
| `datetime` | see [`STAC.datetime_interval`](@ref) |
| `limit` | the page size; the spec's default of 100 when omitted |
| `manifold` | `Spherical()` (the default) or `Planar()`, the space the index is built in |
| `io` | the [`AbstractIO`](@ref STAC.AbstractIO) the walk fetches through |
| `extensions`, `geometry`, `metadata` | [`ParseOptions`](@ref)'s, fixing the item type |

```julia
cat = STAC.read("catalog.json")

# the walk runs on the first item asked for, and a box across the antimeridian is one box
s = search(cat; collections = "edges", intersects = Extent(X = (170, -170), Y = (60, 70)))
matched(s)                        # exact: the filtered set is in memory
first(s).id

# a DE-9IM predicate keeps only the items it holds for, evaluated on the sphere
aoi = GeoJSON.read(read("aoi.geojson", String); numbertype = Float64)
collect(search(cat; intersects = Within(aoi), datetime = Date(2024, 6, 4)))
```
"""
function search(obj::Union{Catalog,Collection}, opts::ParseOptions; collections = nothing,
                ids = nothing, intersects = nothing, datetime = nothing, limit = nothing,
                manifold::GO.Manifold = GO.Spherical(), io::AbstractIO = default_io())
    return StaticItemSearch(obj, io, opts,
                            collections === nothing ? nothing : _stringlist(collections),
                            ids === nothing ? nothing : _stringlist(ids),
                            datetime_interval(datetime), intersects, manifold,
                            limit === nothing ? GENERIC_HOST.default_limit : max(1, Int(limit)),
                            nothing)
end

search(obj::Union{Catalog,Collection}; extensions = DEFAULT_EXTENSIONS,
       geometry = DEFAULT_GEOMETRY, metadata = true, kw...) =
    search(obj, ParseOptions(; extensions, geometry, metadata); kw...)
