# The API path under `--trim=safe`: open a STAC API, POST an item search, follow the `next`
# link to a second page, index what came back, and print the ids. `read_item.jl` covers the
# parse and `search_index.jl` the static walk; this program is the one that measures what a
# request costs, and `runtests.jl` holds it to that measurement.
#
# It does not link today. A STAC API request body is a JSON document — the search body, a
# `next` link's body, a link's header map — and a JSON document's values are `Any`, so every
# call that touches one is a dynamic dispatch. The count and the three call sites are in
# `runtests.jl`.
#
# The declared extension, geometry, and metadata types are literals, and `io` is passed
# explicitly rather than read from the scoped default: under trimming the set of parse and
# fetch methods must be closed at compile time.

using STAC
using STAC: Client, Item, Metadata, ParseOptions, EO, Projection, extensiontype, query,
            spatialindex
using Dates
using Extents
using GeoJSON

const E = extensiontype((EO, Projection))
const G = Union{Nothing,GeoJSON.Polygon{2,Float64},GeoJSON.MultiPolygon{2,Float64}}
const ITEM = Item{E,G,Metadata}
const OPTS = ParseOptions{E,G,Metadata}()

# The endpoint `test/fixtures/endpoints/planetary-computer/` was recorded from, and the
# search that was recorded against it.
const URL = "https://planetarycomputer.microsoft.com/api/stac/v1"
const COLLECTION = "sentinel-2-l2a"
const FROM = DateTime(2024, 6, 1)
const TO = DateTime(2024, 6, 5)
const PAGE = 2
const WANTED = 4

# A window over the westernmost of the four recorded footprints, so the index reports one hit
# out of the four items the search returns.
const BOX = Extents.Extent(X = (171.0, 171.5), Y = (53.2, 53.5))

# ---------------------------------------------------------------------------------------

struct NoRecording <: Exception
    method::String
    href::String
end

Base.showerror(io::IO, e::NoRecording) = print(io, "no recording for ", e.method, " ", e.href)

"""
    ReplayIO(methods, hrefs, paths, used)

The trim-safe half of `test/FixtureIO.jl`: an [`STAC.AbstractIO`](@ref) that answers each
`(method, href)` with the recorded file named for it, in the order the recordings were made,
and raises on anything else.

`FixtureIO` matches a POST body as well, by comparing two `Any`-valued JSON objects — one
dynamic dispatch per value, and so an unresolved call under `--trim=safe`. Matching on the
method, the href, and the order is the same evidence for a program whose whole request
sequence is fixed, and it leaves the measurement to `STAC` rather than to the transport.
"""
struct ReplayIO <: STAC.AbstractIO
    methods::Vector{String}
    hrefs::Vector{String}
    paths::Vector{String}
    used::Vector{Bool}
end

@noinline _norecording(method::String, href::String) = throw(NoRecording(method, href))

function replay(io::ReplayIO, method::String, href::String)
    for i in eachindex(io.hrefs)
        (io.used[i] || io.methods[i] != method || io.hrefs[i] != href) && continue
        io.used[i] = true
        return Base.read(io.paths[i])
    end
    return _norecording(method, href)
end

STAC.read(io::ReplayIO, href::AbstractString) = replay(io, "GET", String(href))

STAC.request(io::ReplayIO, method::AbstractString, href::AbstractString;
             headers = STAC.NO_HEADERS, body = nothing) =
    replay(io, String(method), String(href))

# ---------------------------------------------------------------------------------------

function (@main)(args::Vector{String})::Cint
    if length(args) != 1
        println(Core.stderr, "usage: api_search ENDPOINT_DIR")
        return 1
    end

    dir = args[1]
    io = ReplayIO(["GET", "POST", "POST"],
                  [URL, URL * "/search", URL * "/search"],
                  [joinpath(dir, "root.json"), joinpath(dir, "search-1.json"),
                   joinpath(dir, "search-2.json")],
                  [false, false, false])

    client = Client(URL; io)
    println(Core.stdout, client.root.id)

    s = search(client, OPTS; collections = COLLECTION, datetime = (FROM, TO), limit = PAGE)

    # Two items per page, so stopping at four costs two requests and never asks for the third
    # page the second one's `next` link offers.
    found = ITEM[]
    for item in s
        push!(found, item)
        println(Core.stdout, item.id)
        length(found) == WANTED && break
    end

    println(Core.stdout, length(query(spatialindex(found), BOX)))
    return 0
end
