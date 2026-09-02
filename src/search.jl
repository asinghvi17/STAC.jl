# Item search. One protocol, `pages`, with the API backend here; Phase 4 adds the static
# backend on the same contract.

"""
    STAC.AbstractItemSearch

A prepared item search. A backend implements [`pages`](@ref), which yields
[`ItemCollection`](@ref) values lazily, and everything a caller does with the search —
iterating items, `Iterators.take`, `collect` — derives from it.

| Method | Contract |
|---|---|
| `pages(s)` | an iterator of `ItemCollection`, one per request; required |
| `matched(s)` | the total the endpoint reports, or `nothing`; optional |

`IteratorSize` is `SizeUnknown()`, so `first` and `take` fetch only the pages they reach.
"""
abstract type AbstractItemSearch end

"""
    pages(s::AbstractItemSearch)

The pages of a search, as a lazy iterator of [`ItemCollection`](@ref). One element is one
request: the first is the search itself, each further one follows the previous page's `next`
link.
"""
function pages end

"""
    matched(s::AbstractItemSearch) -> Union{Int,Nothing}

The number of items the search matches in total, or `nothing` when the endpoint does not
report one. Reading it costs one request, since the count lives on the first page.
"""
matched(::AbstractItemSearch) = nothing

Base.IteratorSize(::Type{<:AbstractItemSearch}) = Base.SizeUnknown()

"""
    STAC.ItemSearchState

Where a search is inside its pages: the page iterator and its state, the page in hand, and
how many of that page's items have been yielded.
"""
struct ItemSearchState{P,S,C}
    pageiter::P
    pagestate::S
    page::C
    i::Int
end

# One item at a time out of the page in hand, pulling the next page when it runs out. A page
# with no features is skipped rather than ending the search, because a filtered page can be
# empty and still be followed by a `next` link.
function _nextitem(it, pagestate, page, i)
    while true
        if page !== nothing && i < length(page.features)
            return page.features[i + 1], ItemSearchState(it, pagestate, page, i + 1)
        end
        nxt = pagestate === nothing ? iterate(it) : iterate(it, pagestate)
        nxt === nothing && return nothing
        page, pagestate = nxt
        i = 0
    end
end

Base.iterate(s::AbstractItemSearch) = _nextitem(pages(s), nothing, nothing, 0)

Base.iterate(::AbstractItemSearch, state::ItemSearchState) =
    _nextitem(state.pageiter, state.pagestate, state.page, state.i)

"""
    STAC.nextlink(page::ItemCollection) -> Union{Link,Nothing}

The `next` link of a page, which is a whole request template: `method`, `headers`, `body`,
and `merge` all describe how to ask for the page after this one.
"""
function nextlink(page::ItemCollection)
    for l in page.links
        l.rel == "next" && return l
    end
    return nothing
end

"""
    STAC.numbermatched(page::ItemCollection) -> Union{Int,Nothing}

The total a page reports, from `numberMatched` or from the deprecated `context.matched` that
the CMR endpoints still send.
"""
function numbermatched(page::ItemCollection)
    page.numberMatched === nothing || return page.numberMatched
    ctx = get(page.metadata, "context", nothing)
    ctx isa AbstractDict || return nothing
    n = get(ctx, "matched", nothing)
    return n isa Real ? Int(n) : nothing
end

# ---------------------------------------------------------------------------------------
# Request construction

"""
    STAC.normalize_datetime(x) -> Union{String,Nothing}

A `datetime` argument as the RFC 3339 string a STAC API takes.

| Argument | Sent |
|---|---|
| `nothing` | nothing; the search is unbounded in time |
| `DateTime` | the instant, in UTC, ending in `Z` |
| `Date` | the full-day interval, because four of five endpoints probed reject a date-only string |
| `(start, stop)` of `DateTime`, `Date`, or `nothing` | `start/stop`, an open side written `..` |
| `String` | passed through unchanged |
"""
normalize_datetime(::Nothing) = nothing
normalize_datetime(s::AbstractString) = String(s)
normalize_datetime(dt::DateTime) = format_rfc3339(dt)
normalize_datetime(d::Date) = _daystart(d) * "/" * _dayend(d)
normalize_datetime(interval::Tuple{Any,Any}) =
    _intervalstart(interval[1]) * "/" * _intervalstop(interval[2])
normalize_datetime(interval::AbstractVector) =
    (length(interval) == 2 ? normalize_datetime((interval[1], interval[2])) :
     throw(ArgumentError("a `datetime` interval is two values, got " * string(length(interval)))))

_daystart(d::Date) = format_rfc3339(DateTime(d))
_dayend(d::Date) = format_rfc3339(DateTime(d) + Day(1) - Millisecond(1))

_intervalstart(::Nothing) = ".."
_intervalstart(s::AbstractString) = String(s)
_intervalstart(dt::DateTime) = format_rfc3339(dt)
_intervalstart(d::Date) = _daystart(d)

_intervalstop(::Nothing) = ".."
_intervalstop(s::AbstractString) = String(s)
_intervalstop(dt::DateTime) = format_rfc3339(dt)
_intervalstop(d::Date) = _dayend(d)

@noinline _notgeometry(x) =
    throw(ArgumentError("`intersects` takes a GeoInterface geometry, an `Extent`, or a " *
                        "bbox of 4 or 6 numbers, not a " * string(typeof(x))))

geomtypename(::GI.PointTrait) = "Point"
geomtypename(::GI.LineStringTrait) = "LineString"
geomtypename(::GI.PolygonTrait) = "Polygon"
geomtypename(::GI.MultiPointTrait) = "MultiPoint"
geomtypename(::GI.MultiLineStringTrait) = "MultiLineString"
geomtypename(::GI.MultiPolygonTrait) = "MultiPolygon"

# Positions are rebuilt as `Float64` rather than taken from `GI.coordinates`, whose element
# type is the geometry's own: GeoJSON.jl defaults to `Float32`, and a request body that
# rounds a longitude to seven digits searches a different place than the caller asked for.
function coordinates(geom)
    trait = GI.geomtrait(geom)
    trait isa GI.PointTrait || return [coordinates(g) for g in GI.getgeom(geom)]
    return GI.is3d(geom) ? Float64[GI.x(geom), GI.y(geom), GI.z(geom)] :
           Float64[GI.x(geom), GI.y(geom)]
end

"""
    STAC.geojsonobject(geom) -> JSON.Object{String,Any}

Any GeoInterface geometry as the GeoJSON object a request body carries. This is what lets
`intersects =` take a geometry from any package in the stack.
"""
function geojsonobject(geom)
    trait = GI.geomtrait(geom)
    trait === nothing && _notgeometry(geom)
    o = JSON.Object{String,Any}()
    if trait isa GI.GeometryCollectionTrait
        o["type"] = "GeometryCollection"
        o["geometries"] = Any[geojsonobject(g) for g in GI.getgeom(geom)]
    else
        o["type"] = geomtypename(trait)
        o["coordinates"] = coordinates(geom)
    end
    return o
end

"""
    STAC.classify(intersects) -> (kind, value)

What a spatial argument becomes in a request body: `(:none, nothing)`, `(:bbox, numbers)`, or
`(:intersects, geojson)`. Supplying both a `bbox` and an `intersects` is a 400 at every
endpoint, so one argument carries both and its type decides.

| Argument | `kind` |
|---|---|
| `nothing` | `:none` |
| `Extents.Extent` with `X`/`Y`, optionally `Z` | `:bbox` |
| a tuple or vector of 4 or 6 numbers | `:bbox` |
| any GeoInterface geometry | `:intersects` |
"""
classify(::Nothing) = (:none, nothing)

function classify(e::Extents.Extent{K}) where {K}
    x = e.X
    y = e.Y
    :Z in K || return (:bbox, Float64[x[1], y[1], x[2], y[2]])
    z = e.Z
    return (:bbox, Float64[x[1], y[1], z[1], x[2], y[2], z[2]])
end

function classify(v::Union{Tuple,AbstractVector})
    (length(v) == 4 || length(v) == 6) && all(x -> x isa Real, v) &&
        return (:bbox, Float64[v...])
    return _notgeometry(v)
end

classify(geom) = (:intersects, geojsonobject(geom))

_stringlist(s::AbstractString) = String[String(s)]
_stringlist(v) = String[String(x) for x in v]

_sortentry(s::AbstractString) =
    startswith(s, '-') ? JSON.Object{String,Any}("field" => String(s[2:end]), "direction" => "desc") :
    JSON.Object{String,Any}("field" => String(lstrip(s, '+')), "direction" => "asc")
_sortentry(x) = x

_sortby(s::AbstractString) = Any[_sortentry(s)]
_sortby(v) = Any[_sortentry(x) for x in v]

"""
    STAC.build_body(; collections, ids, intersects, datetime, query, filter, filter_lang,
                    sortby, fields, limit) -> JSON.Object{String,Any}

The POST body of one item search, with only the keys the caller named plus `limit`. This is
the request the paging loop merges each `next` link into.
"""
function build_body(; collections = nothing, ids = nothing, intersects = nothing,
                    datetime = nothing, query = nothing, filter = nothing,
                    filter_lang = nothing, sortby = nothing, fields = nothing, limit::Int)
    body = JSON.Object{String,Any}()
    collections === nothing || (body["collections"] = _stringlist(collections))
    ids === nothing || (body["ids"] = _stringlist(ids))
    kind, value = classify(intersects)
    kind === :none || (body[String(kind)] = value)
    dt = normalize_datetime(datetime)
    dt === nothing || (body["datetime"] = dt)
    query === nothing || (body["query"] = query)
    if filter !== nothing
        body["filter"] = filter
        body["filter-lang"] = filter_lang === nothing ? "cql2-json" : String(filter_lang)
    end
    sortby === nothing || (body["sortby"] = _sortby(sortby))
    fields === nothing || (body["fields"] = fields)
    body["limit"] = limit
    return body
end

_queryvalue(v::AbstractString) = String(v)
_queryvalue(v::Bool) = string(v)
_queryvalue(v::Real) = string(v)
_queryvalue(v::AbstractVector) =
    all(x -> x isa Union{AbstractString,Real}, v) ? join(map(_queryvalue, v), ',') :
    JSON.json(v; style = STACStyle())
_queryvalue(v) = JSON.json(v; style = STACStyle())

"""
    STAC.querystring(body) -> String

A search body as the query string its `GET` form takes: lists comma-joined, anything nested
(`intersects`, `filter`, `query`) as JSON, everything percent-encoded.
"""
function querystring(body)
    parts = String[]
    for (k, v) in body
        push!(parts, URIs.escapeuri(k) * "=" * URIs.escapeuri(_queryvalue(v)))
    end
    return join(parts, '&')
end

withquery(href::AbstractString, query::AbstractString) =
    isempty(query) ? String(href) : String(href) * (occursin('?', href) ? "&" : "?") * query

# ---------------------------------------------------------------------------------------
# The API backend

"""
    STAC.APIItemSearch

A search against a STAC API, as one prepared request plus the parse options its pages are
read with. Build one with [`search`](@ref) or [`items`](@ref); iterate it for items, or
[`pages`](@ref) it for whole [`ItemCollection`](@ref)s.
"""
struct APIItemSearch{I<:AbstractIO,O<:ParseOptions} <: AbstractItemSearch
    io::I
    method::String
    href::String
    body::Union{JSON.Object{String,Any},Nothing}
    headers::RequestHeaders
    host::HostDefaults
    opts::O
end

Base.eltype(::Type{APIItemSearch{I,O}}) where {I,O} = itemtype(O)

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
Base.eltype(::Type{PageIterator{APIItemSearch{I,O}}}) where {I,O} = itemcollectiontype(O)

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
    hs = state.body === nothing ? state.headers : vcat(state.headers, [JSON_CONTENT_TYPE])
    payload = state.body === nothing ? nothing : JSON.json(state.body; style = STACStyle())
    bytes = request(s.io, state.method, state.href; headers = hs, body = payload)
    page = JSON.parse(bytes, itemcollectiontype(s.opts); style = STACStyle())
    return sethref(page, state.href)
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
linkheaders(m::Metadata) = RequestHeaders([k => _queryvalue(v) for (k, v) in m])

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
# `search`

@noinline _noconformance(client::Client, class::AbstractString, why::AbstractString) =
    throw(ArgumentError(client.url * " does not advertise the conformance class `" * class *
                        "`, which " * why * " needs. Its landing page lists " *
                        string(length(client.conformsTo)) * " classes."))

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

A prepared item search. Nothing is fetched until the result is iterated, so building a search
costs no request.

| Keyword | Takes |
|---|---|
| `collections`, `ids` | a string or a list of strings |
| `intersects` | a GeoInterface geometry, an `Extents.Extent`, or a bbox of 4 or 6 numbers |
| `datetime` | see [`STAC.normalize_datetime`](@ref) |
| `query`, `filter`, `filter_lang`, `fields` | the extension bodies, passed through |
| `sortby` | `"-datetime"`, `"+id"`, a list of those, or the spec's `{field, direction}` objects |
| `limit` | the page size, clamped to the host's cap; the host default when omitted |
| `method` | `"POST"` (the default) or `"GET"` |
| `extensions`, `geometry`, `metadata` | [`ParseOptions`](@ref)'s, fixing the item type |

The request is checked against the endpoint's `conformsTo` before it is built, so a `filter`
an endpoint cannot answer raises here rather than 400ing later.

```julia
s = search(client; collections = ["sentinel-2-l2a"],
           intersects = Extent(X = (-123, -122), Y = (37, 38)),
           datetime = (DateTime(2024, 6, 1), DateTime(2024, 6, 5)), limit = 100)
matched(s)                       # the total, when the endpoint reports one
first(Iterators.take(s, 5))      # one request, five items
```
"""
function search(client::Client; collections = nothing, ids = nothing, intersects = nothing,
                datetime = nothing, query = nothing, filter = nothing, filter_lang = nothing,
                sortby = nothing, fields = nothing, limit = nothing,
                method::AbstractString = "POST", extensions = DEFAULT_EXTENSIONS,
                geometry = DEFAULT_GEOMETRY, metadata = true)
    check_conformance(client; filter, query, sortby, fields)
    body = build_body(; collections, ids, intersects, datetime, query, filter, filter_lang,
                      sortby, fields, limit = searchlimit(client.host, limit))
    opts = ParseOptions(; extensions, geometry, metadata)
    verb = uppercase(method)
    href = requiredlink(client, "search"; method = verb)
    verb == "GET" && return APIItemSearch(client.io, "GET", withquery(href, querystring(body)),
                                          nothing, NO_HEADERS, client.host, opts)
    return APIItemSearch(client.io, verb, href, body, NO_HEADERS, client.host, opts)
end

"""
    STAC.featuresearch(client, href; …) -> APIItemSearch

A `GET` search against an OGC API - Features items endpoint, which is what
[`items(client, collection)`](@ref) returns. The keywords are [`search`](@ref)'s, minus the
ones the path already fixes.
"""
function featuresearch(client::Client, href::AbstractString; ids = nothing, intersects = nothing,
                       datetime = nothing, query = nothing, filter = nothing,
                       filter_lang = nothing, sortby = nothing, fields = nothing,
                       limit = nothing, extensions = DEFAULT_EXTENSIONS,
                       geometry = DEFAULT_GEOMETRY, metadata = true)
    body = build_body(; ids, intersects, datetime, query, filter, filter_lang, sortby, fields,
                      limit = searchlimit(client.host, limit))
    opts = ParseOptions(; extensions, geometry, metadata)
    return APIItemSearch(client.io, "GET", withquery(href, querystring(body)), nothing,
                         NO_HEADERS, client.host, opts)
end
