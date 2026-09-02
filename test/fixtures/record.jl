# Refresh test/fixtures/endpoints/ from the live APIs. Run by hand, never in CI:
#
#     julia --project=. test/fixtures/record.jl [endpoint …]
#
# Each endpoint gets its landing page, its conformance document, the first page of its
# collections, and two pages of one search, plus a `requests.json` manifest naming the exact
# (method, href, body) that produced each file. `test/FixtureIO.jl` replays that manifest, so
# a client that formats a request differently than what is recorded here fails loudly rather
# than silently reaching the network.
#
# The paging here deliberately does not call `STAC.pages`: it re-reads the `next` link
# straight from the spec, so the recording is an independent check on the client rather than
# a copy of it.

using STAC, JSON, Dates
using STAC: HTTPIO, NoAuth

const ENDPOINTS_DIR = joinpath(@__DIR__, "endpoints")

# The window every search asks for, chosen to be far enough in the past that the endpoints
# answer the same items on a re-record.
const WINDOW = "2024-06-01T00:00:00Z/2024-06-05T00:00:00Z"
const PAGE = 2

# Seconds between requests. CDSE answers two searches in quick succession with a 429.
const PAUSE = 5

struct Endpoint
    name::String
    url::String
    collection::Union{String,Nothing}
end

const ENDPOINTS = [
    Endpoint("planetary-computer", "https://planetarycomputer.microsoft.com/api/stac/v1", "sentinel-2-l2a"),
    Endpoint("earth-search", "https://earth-search.aws.element84.com/v1", "sentinel-2-l2a"),
    Endpoint("landsatlook", "https://landsatlook.usgs.gov/stac-server", "landsat-c2l2-sr"),
    Endpoint("cmr-lpcloud", "https://cmr.earthdata.nasa.gov/stac/LPCLOUD", nothing),
    Endpoint("cdse", "https://stac.dataspace.copernicus.eu/v1", "sentinel-2-l2a"),
    Endpoint("itslive", "https://stac.itslive.cloud", "itslive-granules"),
]

searchbody(e::Endpoint) =
    e.collection === nothing ?
    Dict{String,Any}("datetime" => WINDOW, "limit" => PAGE) :
    Dict{String,Any}("collections" => [e.collection], "datetime" => WINDOW, "limit" => PAGE)

linkhref(doc, rel; method = nothing) =
    for l in get(doc, "links", ())
        get(l, "rel", "") == rel || continue
        (method === nothing || !haskey(l, "method") || l["method"] == method) || continue
        return l["href"]
    end

# The `next` link, read as STAC API 1.0.0 defines it: `method` defaults to GET, a body is
# present only for POST, and `merge` (default false) says whether that body is a delta on the
# original request or the whole of the next one.
function nextrequest(page, body)
    links = get(page, "links", ())
    i = findfirst(l -> get(l, "rel", "") == "next", links)
    i === nothing && return nothing
    link = links[i]
    linkbody = get(link, "body", nothing)
    next = linkbody === nothing ? nothing :
           get(link, "merge", false) === true && body !== nothing ?
           merge(body, linkbody) : linkbody
    return (uppercase(get(link, "method", "GET")), link["href"], next)
end

function fetch!(manifest, io, dir, name, method, href, body)
    payload = body === nothing ? nothing : JSON.json(body)
    headers = body === nothing ? STAC.NO_HEADERS :
              ["Content-Type" => "application/json"]
    @info "recording" name method href
    sleep(PAUSE)
    bytes = STAC.request(io, method, href; headers, body = payload)
    write(joinpath(dir, name), bytes)
    push!(manifest, Dict{String,Any}("method" => method, "href" => href,
                                     "body" => body, "response" => name))
    return JSON.parse(bytes)
end

function record(e::Endpoint)
    dir = joinpath(ENDPOINTS_DIR, e.name)
    mkpath(dir)
    io = HTTPIO(NoAuth())
    manifest = Dict{String,Any}[]

    root = fetch!(manifest, io, dir, "root.json", "GET", e.url, nothing)
    fetch!(manifest, io, dir, "conformance.json", "GET", linkhref(root, "conformance"), nothing)

    # A landing page lists every collection it has, which is megabytes on the CMR and
    # Planetary Computer deployments; only the first two are kept.
    colhref = linkhref(root, "data")
    cols = JSON.parse(STAC.read(io, colhref))
    cols["collections"] = first(cols["collections"], 2)
    write(joinpath(dir, "collections.json"), JSON.json(cols))
    push!(manifest, Dict{String,Any}("method" => "GET", "href" => colhref, "body" => nothing,
                                     "response" => "collections.json"))

    # The two GET paths: one collection by id, and its items through OGC API - Features.
    colid = cols["collections"][1]["id"]
    base = rstrip(colhref, '/') * "/" * colid
    fetch!(manifest, io, dir, "collection.json", "GET", base, nothing)
    fetch!(manifest, io, dir, "items.json", "GET", base * "/items?limit=" * string(PAGE), nothing)

    href = linkhref(root, "search"; method = "POST")
    body = searchbody(e)
    page = fetch!(manifest, io, dir, "search-1.json", "POST", href, body)

    nxt = nextrequest(page, body)
    if nxt === nothing
        @warn "no next link" endpoint = e.name
    else
        fetch!(manifest, io, dir, "search-2.json", nxt...)
    end

    write(joinpath(dir, "requests.json"),
          JSON.json(Dict{String,Any}("url" => e.url, "recorded" => string(today()),
                                     "requests" => manifest); pretty = 2))
    return nothing
end

for e in ENDPOINTS
    (isempty(ARGS) || e.name in ARGS) || continue
    try
        record(e)
    catch err
        @error "recording failed" endpoint = e.name exception = err
    end
end
