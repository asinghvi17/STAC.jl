"""
    STAC

A typed STAC 1.1.0 client. `STAC.read` turns a document into a [`Catalog`](@ref),
[`Collection`](@ref), [`Item`](@ref), or [`ItemCollection`](@ref) whose spec fields are
concrete and whose remaining keys round-trip through [`STAC.json`](@ref).
"""
module STAC

using Dates
using JSON
using StructUtils
using OrderedCollections: OrderedDict

import GeoJSON

include("metadata.jl")
include("objects.jl")
include("extensions/interface.jl")
include("extensions/eo.jl")
include("extensions/proj.jl")
include("parse/options.jl")
include("parse/style.jl")
include("parse/sinks.jl")
include("parse/write.jl")
include("read.jl")

export Asset, Band, Catalog, Collection, CollectionExtent, Item, ItemCollection, Link,
       Metadata, NoMetadata, Properties, Provider, SpatialExtent, TemporalExtent
export EO, Projection

end # module STAC
