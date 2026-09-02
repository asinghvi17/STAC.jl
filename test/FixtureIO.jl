# The test transport. Every traversal, client, and search test runs vendored documents
# through the same `AbstractIO` seam production uses, so what is exercised is the real
# `read` / `request` path; an href nobody recorded raises instead of reaching the network.

using STAC

"""
    FixtureIO(prefix => dir, …)

An [`STAC.AbstractIO`](@ref) that answers a fixed set of hrefs from vendored files. Each
mount maps one href prefix onto a directory: the file at `<dir>/<rel>` answers
`<prefix><rel>`, with `/` separators whatever the host filesystem uses.

`io.reads` counts the fetches that happened, which is how the traversal tests assert that
nothing is fetched before it is reached.
"""
mutable struct FixtureIO <: STAC.AbstractIO
    const routes::Dict{String,String}
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
    return FixtureIO(routes, 0)
end

_unrecorded(io::FixtureIO, href) =
    error("FixtureIO has no recording for ", repr(String(href)), ".\nIt holds ",
          length(io.routes), " hrefs, beginning ",
          join(sort!(collect(keys(io.routes)))[1:min(end, 3)], ", "), ".")

function STAC.read(io::FixtureIO, href::AbstractString)
    path = get(io.routes, convert(String, href), nothing)
    path === nothing && _unrecorded(io, href)
    io.reads += 1
    return Base.read(path)
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
