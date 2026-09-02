# A `--trim=safe` program: parse one item, one catalog, and one collection from vendored
# fixtures and print their ids. `Collection` is here from the first phase because it nests
# `extent`, `providers`, and `summaries`, which is the recursive typed parse the trim
# verifier has the most to say about.
#
# The declared extension, geometry, and metadata types are literals: under trimming the set
# of parse methods must be closed at compile time.

using STAC
using STAC: Item, Catalog, Collection, Metadata, EO, Projection, STACStyle, extensiontype
using JSON
using GeoJSON

const E = extensiontype((EO, Projection))
const G = Union{Nothing,GeoJSON.Polygon{2,Float64},GeoJSON.MultiPolygon{2,Float64}}
const ITEM = Item{E,G,Metadata}
const CATALOG = Catalog{Metadata}
const COLLECTION = Collection{Metadata}

function (@main)(args::Vector{String})::Cint
    if length(args) != 3
        println(Core.stderr, "usage: read_item ITEM CATALOG COLLECTION")
        return 1
    end

    item = JSON.parse(read(args[1]), ITEM; style = STACStyle())
    println(Core.stdout, item.id)

    catalog = JSON.parse(read(args[2]), CATALOG; style = STACStyle())
    println(Core.stdout, catalog.id)

    collection = JSON.parse(read(args[3]), COLLECTION; style = STACStyle())
    println(Core.stdout, collection.id)

    return 0
end
