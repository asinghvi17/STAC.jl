# The test transport. Every traversal, client, and search test runs vendored documents
# through the same `AbstractIO` seam production uses, so what is exercised is the real
# `read` / `request` path; an href nobody recorded raises instead of reaching the network.

using STAC, JSON

"""
    Recording(method, href, body, path)

One request `fixtures/record.jl` made and the file holding what came back. A replay has to
match the method, the href, and the body, so a client that formats its search differently
than what was recorded fails rather than being answered anyway.
"""
struct Recording
    method::String
    href::String
    body::Any
    path::String
end

"""
    FixtureIO(prefix => dir, …)
    recordedio(dir, …)

An [`STAC.AbstractIO`](@ref) that answers a fixed set of requests from vendored files, two
ways. A *mount* maps one href prefix onto a directory, so the file at `<dir>/<rel>` answers
`<prefix><rel>`; a *recording* replays one exact `(method, href, body)` from a `requests.json`
manifest.

`io.reads` counts the fetches that happened, which is how the traversal and paging tests
assert that nothing is fetched before it is reached, and `io.seen` holds the headers of each
fetch in order, which is how the auth tests assert what a credential put on the wire.
"""
mutable struct FixtureIO <: STAC.AbstractIO
    const routes::Dict{String,String}
    const recordings::Vector{Recording}
    const seen::Vector{STAC.RequestHeaders}
    reads::Int
end

function FixtureIO(mounts::Pair...)
    routes = Dict{String,String}()
    for (prefix, dir) in mounts
        for (root, _, files) in walkdir(dir), f in files
            endswith(f, ".json") || continue
            path = joinpath(root, f)
            routes[prefix * replace(relpath(path, dir), '\\' => '/')] = path
        end
    end
    return FixtureIO(routes, Recording[], STAC.RequestHeaders[], 0)
end

"""
    recordings(dir) -> Vector{Recording}

The `requests.json` manifest of one endpoint directory under `fixtures/endpoints/`.
"""
function recordings(dir::AbstractString)
    manifest = JSON.parse(Base.read(joinpath(dir, "requests.json"), String))
    return [Recording(r["method"], r["href"], get(r, "body", nothing),
                      joinpath(dir, r["response"])) for r in manifest["requests"]]
end

recordedio(dirs::AbstractString...) =
    FixtureIO(Dict{String,String}(), reduce(vcat, map(recordings, dirs)),
              STAC.RequestHeaders[], 0)

"""
    answering(href => path, …)

A [`FixtureIO`](@ref) that answers `GET href` with the bytes of `path`, for the hrefs a
mount cannot express: a token service names its resource with a path, not with a `.json`
file.
"""
answering(pairs::Pair...) =
    FixtureIO(Dict{String,String}(),
              [Recording("GET", String(first(p)), nothing, String(last(p))) for p in pairs],
              STAC.RequestHeaders[], 0)

"""
    endpointurl(dir) -> String

The landing-page URL an endpoint directory was recorded from.
"""
endpointurl(dir::AbstractString) =
    JSON.parse(Base.read(joinpath(dir, "requests.json"), String))["url"]

_jsonbody(::Nothing) = nothing
_jsonbody(s::AbstractString) = JSON.parse(s)
_jsonbody(b::AbstractVector{UInt8}) = JSON.parse(b)

function _unrecorded(io::FixtureIO, method, href, body)
    near = [r.href for r in io.recordings if r.method == method]
    error("FixtureIO has no recording for ", method, " ", repr(String(href)),
          body === nothing ? "" : " with body " * JSON.json(body),
          ".\nIt holds ", length(io.routes), " mounted hrefs and ", length(io.recordings),
          " recordings", isempty(near) ? "" : ", including " * join(unique(near), ", "), ".")
end

function _replay(io::FixtureIO, method, href, body)
    want = _jsonbody(body)
    for r in io.recordings
        (r.method == method && r.href == href && isequal(r.body, want)) || continue
        io.reads += 1
        return Base.read(r.path)
    end
    return _unrecorded(io, method, href, want)
end

function STAC.read(io::FixtureIO, href::AbstractString)
    push!(io.seen, STAC.RequestHeaders())
    path = get(io.routes, convert(String, href), nothing)
    path === nothing && return _replay(io, "GET", href, nothing)
    io.reads += 1
    return Base.read(path)
end

function STAC.request(io::FixtureIO, method::AbstractString, href::AbstractString;
                      headers = STAC.NO_HEADERS, body = nothing)
    (method == "GET" && body === nothing && haskey(io.routes, convert(String, href))) &&
        return STAC.read(io, href)
    push!(io.seen, STAC.RequestHeaders(collect(headers)))
    return _replay(io, method, href, body)
end

"""
    reads!(io::FixtureIO) -> Int

The fetch count since the last call, and reset it.
"""
function reads!(io::FixtureIO)
    n = io.reads
    io.reads = 0
    return n
end
