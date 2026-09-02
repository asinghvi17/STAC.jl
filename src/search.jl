# Item search. One protocol, `pages`, with two backends on it: a STAC API, and a static
# catalog walked and filtered in memory.

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

"""
    STAC.TimeInterval

The window a static search keeps items inside: a start and a stop, either of them `nothing`
for an open side.
"""
const TimeInterval = Tuple{Union{DateTime,Nothing},Union{DateTime,Nothing}}

"""
    STAC.datetime_interval(x) -> STAC.TimeInterval

A `datetime` argument as the pair of instants a client-side filter compares against. This is
the counterpart of [`STAC.normalize_datetime`](@ref), which sends the same argument to a
server; both read a bare date as the whole day.
"""
datetime_interval(::Nothing) = (nothing, nothing)
datetime_interval(dt::DateTime) = (dt, dt)
datetime_interval(d::Date) = (DateTime(d), DateTime(d) + Day(1) - Millisecond(1))
datetime_interval(t::Tuple{Any,Any}) = (_boundstart(t[1]), _boundstop(t[2]))

datetime_interval(v::AbstractVector) =
    (length(v) == 2 ? datetime_interval((v[1], v[2])) :
     throw(ArgumentError("a `datetime` interval is two values, got " * string(length(v)))))

function datetime_interval(s::AbstractString)
    i = findfirst('/', s)
    i === nothing && return (_boundstart(s), _boundstop(s))
    return (_boundstart(SubString(s, 1, i - 1)), _boundstop(SubString(s, i + 1)))
end

_isopen(s::AbstractString) = isempty(s) || s == ".."
_isdateonly(s::AbstractString) = length(s) == 10

_boundstart(::Nothing) = nothing
_boundstart(dt::DateTime) = dt
_boundstart(d::Date) = DateTime(d)
_boundstart(s::AbstractString) = _isopen(s) ? nothing : parse_rfc3339(s)

_boundstop(::Nothing) = nothing
_boundstop(dt::DateTime) = dt
_boundstop(d::Date) = DateTime(d) + Day(1) - Millisecond(1)
_boundstop(s::AbstractString) =
    _isopen(s) ? nothing :
    _isdateonly(s) ? parse_rfc3339(s) + Day(1) - Millisecond(1) : parse_rfc3339(s)

"""
    STAC.intimerange(item, interval::STAC.TimeInterval) -> Bool

Whether an item falls in a search's window. An item with a `datetime` is one instant; an item
with `start_datetime` and `end_datetime` is a span, and matches when the two spans overlap.
An item that carries neither is outside every closed window.
"""
function intimerange(item::Item, interval::TimeInterval)
    from, to = interval
    (from === nothing && to === nothing) && return true
    dt = item.properties.datetime
    if dt !== nothing
        return (from === nothing || dt >= from) && (to === nothing || dt <= to)
    end
    start, stop = item.properties.start_datetime, item.properties.end_datetime
    (start === nothing && stop === nothing) && return false
    (to === nothing || start === nothing || start <= to) || return false
    return from === nothing || stop === nothing || stop >= from
end

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

# A predicate travels to the server as its own geometry: `intersects` is the widest request
# that can hold every item the predicate keeps, and the exact pass runs on what comes back.
classify(p::DE9IM.DE9IMPredicate) = classify(parent(p))

"""
    STAC.predicate(intersects) -> Union{DE9IM.DE9IMPredicate,Nothing}

The DE-9IM predicate an `intersects` argument carries, or `nothing` when it is a plain
geometry, extent, or bbox. A search that has one runs it over every page it receives.
"""
predicate(::Any) = nothing
predicate(p::DE9IM.DE9IMPredicate) =
    parent(p) === nothing ? _nopredicategeometry(p) : p

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
    hs = state.body === nothing ? state.headers : vcat(state.headers, [JSON_CONTENT_TYPE])
    payload = state.body === nothing ? nothing : JSON.json(state.body; style = STACStyle())
    bytes = request(s.io, state.method, state.href; headers = hs, body = payload)
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
    pred = predicate(intersects)
    verb = uppercase(method)
    href = requiredlink(client, "search"; method = verb)
    verb == "GET" && return APIItemSearch(client.io, "GET", withquery(href, querystring(body)),
                                          nothing, NO_HEADERS, client.host, opts, pred)
    return APIItemSearch(client.io, verb, href, body, NO_HEADERS, client.host, opts, pred)
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
                         NO_HEADERS, client.host, opts, predicate(intersects))
end

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
s = search(cat; collections = ["simple-collection"],
           intersects = Extent(X = (170, -170), Y = (60, 70)))
matched(s)                       # exact: the filtered set is in memory
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
