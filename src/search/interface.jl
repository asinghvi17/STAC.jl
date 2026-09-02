# The search protocol and the request its keywords describe: what a backend answers, and the
# argument vocabulary every backend shares.

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

```julia
first(s)                          # one item, one request
collect(Iterators.take(s, 5))     # five items, however many pages that takes
collect(pages(s))                 # every page, to the end of the result set
```
"""
abstract type AbstractItemSearch end

"""
    pages(s::AbstractItemSearch)

The pages of a search, as a lazy iterator of [`ItemCollection`](@ref). One element is one
request: the first is the search itself, each further one follows the previous page's `next`
link.

```julia
page = first(pages(s))            # one request
page.features                     # the items it carried
page.numberReturned               # how many that is
```
"""
function pages end

"""
    matched(s::AbstractItemSearch) -> Union{Int,Nothing}

The number of items the search matches in total, or `nothing` when the endpoint does not
report one. Reading it costs one request, since the count lives on the first page.

```julia
s = search(client; collections = ["sentinel-2-l2a"], datetime = Date(2024, 6, 1))
matched(s)          # an `Int` where the endpoint counts, `nothing` where it does not
```
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
# The `datetime` argument, two ways: as the string an endpoint takes, and as the pair of
# instants a client-side filter compares against.

@noinline _badinterval(n) = throw(BadInterval(n))

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

```julia
normalize_datetime(DateTime(2024, 6, 1))            # "2024-06-01T00:00:00Z"
normalize_datetime(Date(2024, 6, 1))                # "2024-06-01T00:00:00Z/2024-06-01T23:59:59.999Z"
normalize_datetime((DateTime(2024, 6, 1), nothing)) # "2024-06-01T00:00:00Z/.."
```
"""
normalize_datetime(::Nothing) = nothing
normalize_datetime(s::AbstractString) = String(s)
normalize_datetime(dt::DateTime) = format_rfc3339(dt)
normalize_datetime(d::Date) = _daystart(d) * "/" * _dayend(d)
normalize_datetime(interval::Tuple{Any,Any}) =
    _intervalstart(interval[1]) * "/" * _intervalstop(interval[2])
normalize_datetime(interval::AbstractVector) =
    (length(interval) == 2 ? normalize_datetime((interval[1], interval[2])) :
     _badinterval(length(interval)))

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

The window a static search keeps items inside: `NTuple{2,Union{DateTime,Nothing}}`, with
`nothing` for an open side.
"""
const TimeInterval = Tuple{Union{DateTime,Nothing},Union{DateTime,Nothing}}

"""
    STAC.datetime_interval(x) -> NTuple{2,Union{DateTime,Nothing}}

A `datetime` argument as the pair of instants a client-side filter compares against, with
`nothing` for an open side. This is the counterpart of
[`STAC.normalize_datetime`](@ref), which sends the same argument to a server; both read a
bare date as the whole day.

```julia
datetime_interval(Date(2024, 6, 1))     # (DateTime(2024, 6, 1), DateTime(2024, 6, 1, 23, 59, 59, 999))
datetime_interval("2024-06-01/..")      # (DateTime(2024, 6, 1), nothing)
```
"""
datetime_interval(::Nothing) = (nothing, nothing)
datetime_interval(dt::DateTime) = (dt, dt)
datetime_interval(d::Date) = (DateTime(d), DateTime(d) + Day(1) - Millisecond(1))
datetime_interval(t::Tuple{Any,Any}) = (_boundstart(t[1]), _boundstop(t[2]))

datetime_interval(v::AbstractVector) =
    (length(v) == 2 ? datetime_interval((v[1], v[2])) : _badinterval(length(v)))

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

# ---------------------------------------------------------------------------------------
# The `intersects` argument: a bbox, a geometry, or a predicate wrapping either.

@noinline _notgeometry(x) = throw(NotAGeometry(string(typeof(x))))

"""
    STAC.geojsongeometry(geom) -> GeoJSON.AbstractGeometry

Any GeoInterface geometry as the `Float64` GeoJSON geometry a request body carries. This is
what lets `intersects =` take a geometry from any package in the stack.

`numbertype = Float64` is the load-bearing part: GeoJSON.jl reads positions as `Float32` by
default, and a longitude rounded to seven digits searches a different place than the caller
asked for. `ndim` comes from the geometry, since the reader's own 2D-then-3D retry warns.
"""
function geojsongeometry(geom)
    GI.geomtrait(geom) === nothing && _notgeometry(geom)
    return GeoJSON.read(GeoJSON.write(geom); ndim = GI.is3d(geom) ? 3 : 2,
                        numbertype = Float64)
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

```julia
classify(Extent(X = (-123, -122), Y = (37, 38)))    # (:bbox, [-123.0, 37.0, -122.0, 38.0])
classify((-123, 37, -122, 38))                      # the same bbox, as four numbers
classify(GeoJSON.read(read("aoi.geojson", String)))  # (:intersects, a Float64 GeoJSON polygon)
```
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

classify(geom) = (:intersects, geojsongeometry(geom))

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

# ---------------------------------------------------------------------------------------
# The request body, and the query string its `GET` form takes.

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

```julia
querystring(build_body(; collections = "sentinel-2-l2a", limit = 2))
# "collections=sentinel-2-l2a&limit=2"
```
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
