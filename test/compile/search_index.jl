# A `--trim=safe` program: walk a fixture catalog, search it with an extent, build a spherical
# index over the same items, and print what each finds.
#
# The declared extension, geometry, and metadata types are literals, and `io` is passed
# explicitly rather than read from the scoped default: under trimming the set of parse and
# fetch methods must be closed at compile time.

using STAC
using STAC: Catalog, Item, Metadata, ParseOptions, PathIO, EO, Projection, extensiontype,
            query, spatialindex
using Extents
using GeoJSON

const E = extensiontype((EO, Projection))
const G = Union{Nothing,GeoJSON.Polygon{2,Float64},GeoJSON.MultiPolygon{2,Float64}}
const OPTS = ParseOptions{E,G,Metadata}()

# The window across the antimeridian, which the spherical leaves cover and a planar box
# would not.
const BOX = Extents.Extent(X = (170.0, -170.0), Y = (60.0, 70.0))

function (@main)(args::Vector{String})::Cint
    if length(args) != 1
        println(Core.stderr, "usage: search_index CATALOG")
        return 1
    end

    io = PathIO()
    catalog = STAC.read(Catalog{Metadata}, args[1], io, OPTS)
    println(Core.stdout, catalog.id)

    for item in search(catalog, OPTS; io, intersects = BOX)
        println(Core.stdout, item.id)
    end

    walked = Item{E,G,Metadata}[]
    for item in items(catalog, OPTS; io, recursive = true)
        push!(walked, item)
    end
    println(Core.stdout, length(query(spatialindex(walked), BOX)))

    return 0
end
