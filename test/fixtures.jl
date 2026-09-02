# Fixture paths, shared by every testset. Each `@safetestset` runs in its own module, so this
# file is included rather than imported.

const FIXTURES = joinpath(@__DIR__, "fixtures")
const SPEC_DIR = joinpath(FIXTURES, "stac-spec")
const HAND_DIR = joinpath(FIXTURES, "hand")
const REAL_DIR = joinpath(FIXTURES, "real-world")
const STATIC_DIR = joinpath(FIXTURES, "static")
const TOKEN_DIR = joinpath(FIXTURES, "tokens")
const ENDPOINT_DIR = joinpath(FIXTURES, "endpoints")

# The six recorded APIs. See fixtures/endpoints/SOURCE.txt and fixtures/record.jl.
const ENDPOINTS = ("planetary-computer", "earth-search", "landsatlook", "cmr-lpcloud",
                   "cdse", "itslive")

endpointdir(name) = joinpath(ENDPOINT_DIR, name)

# The one catalog of `fixtures/static/`, published three ways, and what a depth-first walk of
# it yields. See `fixtures/static/SOURCE.txt`.
const LINK_STYLES = ("self-contained", "relative-published", "absolute-published")
const STATIC_BASE = "https://example.com/static/"
const STATIC_ITEM_IDS = ["collectionless-item", "simple-item", "core-item", "extended-item"]
const STATIC_CHILD_IDS = ["simple-collection", "empty-collection"]

"""
    jsonfiles(dir) -> Vector{String}

Every STAC document under `dir`, sorted. The `requests.json` manifest that tells
[`FixtureIO`](@ref) which recording answers which request is left out, being a description of
a fixture rather than one.
"""
function jsonfiles(dir)
    paths = String[]
    for (root, _, files) in walkdir(dir), f in files
        (endswith(f, ".json") && f != "requests.json") && push!(paths, joinpath(root, f))
    end
    return sort!(paths)
end

"""
    nullkeypaths(x) -> Set{String}

The key paths of a parsed document whose value is `null`. The writer omits a null typed
field, so these are the only keys a written document may be missing; which of them it keeps
(`geometry`, `properties.datetime`, and every key of a metadata tail) is asserted directly.
"""
function nullkeypaths(x, prefix = "")
    ks = Set{String}()
    if x isa AbstractDict
        for (k, v) in x
            path = prefix * "/" * k
            v === nothing && push!(ks, path)
            union!(ks, nullkeypaths(v, path))
        end
    elseif x isa AbstractVector
        for v in x
            union!(ks, nullkeypaths(v, prefix * "[]"))
        end
    end
    return ks
end

"""
    keypaths(x) -> Set{String}

Every key of a parsed JSON document, at every depth, as a `/`-joined path with `[]` for the
array steps. Two documents with the same `keypaths` carry the same information regardless of
key order.
"""
function keypaths(x, prefix = "")
    ks = Set{String}()
    if x isa AbstractDict
        for (k, v) in x
            push!(ks, prefix * "/" * k)
            union!(ks, keypaths(v, prefix * "/" * k))
        end
    elseif x isa AbstractVector
        for v in x
            union!(ks, keypaths(v, prefix * "[]"))
        end
    end
    return ks
end
