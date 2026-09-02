"""
    STAC

A typed STAC 1.1.0 client. `STAC.read` turns a document into a [`Catalog`](@ref),
[`Collection`](@ref), [`Item`](@ref), or [`ItemCollection`](@ref) whose spec fields are
concrete and whose remaining keys round-trip through [`STAC.json`](@ref).
"""
module STAC

using Dates
using DocStringExtensions: FIELDS
using JSON
using StructUtils
using OrderedCollections: OrderedDict
using LRUCache: LRU

import DataAPI
import DE9IM
import Extents
import GeoFormatTypes
import GeoInterface as GI
import GeoJSON
import GeometryOps as GO
import HTTP
import ScopedValues
import Tables
import URIs

include("errors.jl")
include("metadata.jl")
include("objects.jl")
include("extensions/interface.jl")
include("extensions/eo.jl")
include("extensions/proj.jl")
include("extensions/raster.jl")
include("extensions/sat.jl")
include("extensions/view.jl")
include("extensions/sci.jl")
include("parse/options.jl")
include("parse/style.jl")
include("parse/sinks.jl")
include("parse/write.jl")
include("io/interface.jl")
include("io/auth.jl")
include("io/resolve.jl")
include("io/path.jl")
include("io/http.jl")
include("io/caching.jl")
include("io/router.jl")
include("io/default.jl")
include("traverse.jl")
include("document.jl")
include("geo.jl")
include("spatialindex.jl")
include("client.jl")
include("search/interface.jl")
include("search/backends.jl")
include("tables.jl")
include("dataapi.jl")
include("show.jl")

export Asset, Band, Catalog, Collection, CollectionExtent, Item, ItemCollection, Link,
       Metadata, NoMetadata, Properties, Provider, SpatialExtent, TemporalExtent
export EO, Projection, Sat, Scientific, View
export AbstractIO, BearerToken, CachingIO, HTTPIO, NoAuth, PathIO, StreamRouterIO
export Client, children, collections, items, matched, pages, search
export SpatialIndex, spatialindex

end # module STAC
