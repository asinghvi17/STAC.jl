module STACDuckDBExt

# stac-geoparquet, through DuckDB. A row of that format is a STAC item taken apart: the
# properties hoisted to top-level columns, `assets` one nested struct, `links` a list of them,
# and the geometry WKB. SQL puts the row back together as one JSON document, which the
# package's own parser reads, and this module supplies the one piece SQL cannot: the WKB
# codec, DuckDB core carrying the GEOMETRY type but none of the `ST_` functions.

import DuckDB
import GeoInterface as GI
import GeoJSON
import JSON
import STAC
import StructUtils
import Tables

using DuckDB: DBInterface

# ---------------------------------------------------------------------------------------
# WKB

# ISO WKB: a byte-order flag, a type code, then the positions. 1000 on the code adds a Z
# ordinate and 2000 an M one, both of which are read and dropped, GeoJSON.jl's geometries
# here being two-dimensional.
mutable struct WKBReader
    const bytes::Vector{UInt8}
    pos::Int
    little::Bool
end

WKBReader(bytes) = WKBReader(convert(Vector{UInt8}, bytes), 1, true)

function take!(r::WKBReader, ::Type{T}) where {T}
    n = sizeof(T)
    v = GC.@preserve r unsafe_load(Ptr{T}(pointer(r.bytes, r.pos)))
    r.pos += n
    return r.little == (ENDIAN_BOM == 0x04030201) ? v : bswap(v)
end

# The header of a geometry, and of each part of a multi-geometry: every one carries its own.
function header!(r::WKBReader)
    r.little = r.bytes[r.pos] == 0x01
    r.pos += 1
    code = take!(r, UInt32)
    kind = Int(code % UInt32(1000))
    ndim = code >= UInt32(3000) ? 4 : code >= UInt32(2000) ? 3 : code >= UInt32(1000) ? 3 : 2
    return kind, ndim
end

function position!(r::WKBReader, ndim::Int)
    x = take!(r, Float64)
    y = take!(r, Float64)
    for _ in 3:ndim
        take!(r, Float64)
    end
    return (x, y)
end

positions!(r::WKBReader, ndim::Int) =
    [position!(r, ndim) for _ in 1:Int(take!(r, UInt32))]

rings!(r::WKBReader, ndim::Int) =
    [positions!(r, ndim) for _ in 1:Int(take!(r, UInt32))]

parts!(r::WKBReader, n::Int) = [geometry!(r) for _ in 1:n]

@noinline _unknownwkb(kind, allowed) =
    throw(STAC.UnknownGeometryType(string("WKB type ", kind), allowed))

function geometry!(r::WKBReader)
    kind, ndim = header!(r)
    kind == 1 && return GeoJSON.Point{2,Float64}(nothing, position!(r, ndim))
    kind == 2 && return GeoJSON.LineString{2,Float64}(nothing, positions!(r, ndim))
    kind == 3 && return GeoJSON.Polygon{2,Float64}(nothing, rings!(r, ndim))
    n = Int(take!(r, UInt32))
    kind == 4 && return GeoJSON.MultiPoint{2,Float64}(nothing,
        [GI.coordinates(g) for g in parts!(r, n)])
    kind == 5 && return GeoJSON.MultiLineString{2,Float64}(nothing,
        [GI.coordinates(g) for g in parts!(r, n)])
    kind == 6 && return GeoJSON.MultiPolygon{2,Float64}(nothing,
        [GI.coordinates(g) for g in parts!(r, n)])
    _unknownwkb(kind, "Point, LineString, Polygon, MultiPoint, MultiLineString, MultiPolygon")
end

"""
    STACDuckDBExt.wkbgeometry(G, bytes) -> G

The geometry `bytes` spells in well-known binary, as one of the GeoJSON.jl types the union
`G` names. A Z or M ordinate is read and dropped: `G`'s members are two-dimensional.
"""
function wkbgeometry(::Type{G}, bytes) where {G}
    g = geometry!(WKBReader(bytes))
    g isa G || throw(STAC.UnknownGeometryType(String(nameof(typeof(g))), string(G)))
    return g::G
end

putwkb(io::IO, x::UInt32) = Base.write(io, htol(x))
putwkb(io::IO, x::Float64) = Base.write(io, htol(x))

function putheader(io::IO, kind::Integer)
    Base.write(io, 0x01)
    putwkb(io, UInt32(kind))
    return io
end

function putposition(io::IO, p)
    putwkb(io, Float64(GI.x(p)))
    putwkb(io, Float64(GI.y(p)))
    return io
end

function putpositions(io::IO, g)
    putwkb(io, UInt32(GI.npoint(g)))
    for p in GI.getpoint(g)
        putposition(io, p)
    end
    return io
end

putwkbgeom(io::IO, ::GI.PointTrait, g) = putposition(putheader(io, 1), g)
putwkbgeom(io::IO, ::GI.LineStringTrait, g) = putpositions(putheader(io, 2), g)

function putwkbgeom(io::IO, ::GI.PolygonTrait, g)
    putheader(io, 3)
    putwkb(io, UInt32(GI.nring(g)))
    for r in GI.getring(g)
        putpositions(io, r)
    end
    return io
end

function putparts(io::IO, kind::Integer, g)
    putheader(io, kind)
    putwkb(io, UInt32(GI.ngeom(g)))
    for part in GI.getgeom(g)
        putwkbgeom(io, GI.geomtrait(part), part)
    end
    return io
end

putwkbgeom(io::IO, ::GI.MultiPointTrait, g) = putparts(io, 4, g)
putwkbgeom(io::IO, ::GI.MultiLineStringTrait, g) = putparts(io, 5, g)
putwkbgeom(io::IO, ::GI.MultiPolygonTrait, g) = putparts(io, 6, g)

"""
    STACDuckDBExt.wkbbytes(geom) -> Vector{UInt8}

`geom` in little-endian well-known binary, reached through GeoInterface so any geometry a
STAC item can hold is writable.
"""
function wkbbytes(geom)
    io = IOBuffer()
    putwkbgeom(io, GI.geomtrait(geom), geom)
    return Base.take!(io)
end

# ---------------------------------------------------------------------------------------
# The columns of a stac-geoparquet file

# The item's own keys. Every other column is a property the format hoisted to the top level.
const ITEM_COLUMNS = ("type", "stac_version", "stac_extensions", "id", "geometry", "bbox",
                      "links", "assets", "collection")

quoteid(name::AbstractString) = string('"', replace(name, '"' => "\"\""), '"')

quotestr(s::AbstractString) = string('\'', replace(s, '\'' => "''"), '\'')

# A timestamp column has to reach the parser as RFC 3339, and `strftime` renders it in the
# session's time zone, which `connection` pins to UTC — a laptop in New York would otherwise
# shift every instant in the file by five hours.
columnexpr(name::AbstractString, type::AbstractString) =
    startswith(type, "TIMESTAMP") ?
    string("strftime(", quoteid(name), ", '%Y-%m-%dT%H:%M:%S.%fZ')") : quoteid(name)

# The four or six numbers a STAC bbox is, from the struct the format keys its spatial filters
# on. A file whose items all state no footprint types the column with no `xmin` to read.
function bboxexpr(type::AbstractString)
    occursin("xmin", type) || return "NULL"
    corners = occursin("zmin", type) ?
              "[bbox.xmin, bbox.ymin, bbox.zmin, bbox.xmax, bbox.ymax, bbox.zmax]" :
              "[bbox.xmin, bbox.ymin, bbox.xmax, bbox.ymax]"
    return string("CASE WHEN bbox IS NULL THEN NULL ELSE ", corners, " END")
end

pair(key::AbstractString, expr::AbstractString) = string(quotestr(key), ", ", expr)

"""
    STACDuckDBExt.itemquery(source, names, types) -> String

The SQL that turns the rows of a stac-geoparquet source into one STAC item document each:
the item's own keys as they stand, every other column re-nested under `properties`, and the
geometry alongside as WKB.

The document a row produces states a null for every key any row of the file uses, that being
what a columnar format stores; [`STACDuckDBExt.itemdocument`](@ref) is what drops them.
"""
function itemquery(source::AbstractString, names::Vector{String}, types::Vector{String})
    props = [pair(n, columnexpr(n, types[i])) for (i, n) in enumerate(names)
             if !(n in ITEM_COLUMNS)]
    parts = [pair("type", "'Feature'")]
    for key in ("stac_version", "stac_extensions", "id", "links", "assets", "collection")
        i = findfirst(==(key), names)
        i === nothing || push!(parts, pair(key, quoteid(key)))
    end
    i = findfirst(==("bbox"), names)
    i === nothing || push!(parts, pair("bbox", bboxexpr(types[i])))
    push!(parts, pair("properties", string("json_object(", join(props, ", "), ")")))
    geometry = "geometry" in names ? "geometry" : "NULL"
    return string("SELECT json_object(", join(parts, ", "), ")::VARCHAR AS doc, ",
                  geometry, " AS wkb FROM ", source)
end

readsource(path::AbstractString) = string("read_parquet(", quotestr(path), ")")

"""
    STACDuckDBExt.itemdocument(doc) -> String

`doc` with its null values dropped, at every depth.

A stac-geoparquet file has one column per key any row uses, so a row states a null for every
asset, band, and property its siblings have and it does not. Reading those back as written
would give an item a `bands` entry keyed `eo:common_name` holding nothing, which is a key the
producer never wrote and which [`STAC.json`](@ref) would then publish.
"""
itemdocument(doc::AbstractString) = JSON.json(JSON.parse(doc); omit_null = true)

"""
    STACDuckDBExt.connection() -> DuckDB.DB

A DuckDB connection of this module's own, pinned to UTC. Every instant in a STAC document is
UTC, and both halves of the format depend on the setting: `strftime` renders a timestamp
column in the session time zone, and `read_json` reads an RFC 3339 string into one.
"""
function connection()
    con = DBInterface.connect(DuckDB.DB, ":memory:")
    DBInterface.execute(con, "SET TimeZone='UTC'")
    return con
end

describe(con, source::AbstractString) =
    Tables.columntable(DBInterface.execute(con, string("DESCRIBE SELECT * FROM ", source)))

function STAC.read_geoparquet(::STAC.DuckDBDriver, path::AbstractString; kw...)
    opts = STAC.ParseOptions(; kw...)
    T = STAC.itemtype(opts)
    G = fieldtype(T, :geometry)
    con = connection()
    try
        source = readsource(path)
        described = describe(con, source)
        sql = itemquery(source, collect(String, described.column_name),
                        collect(String, described.column_type))
        rows = Tables.columntable(DBInterface.execute(con, sql))
        out = Vector{T}(undef, length(rows.doc))
        for i in eachindex(rows.doc)
            item = STAC.parse(itemdocument(rows.doc[i]), T)
            wkb = rows.wkb[i]
            out[i] = wkb === missing ? item :
                     STAC.rebuild(item, Val(:geometry), wkbgeometry(G, wkb))
        end
        return out
    finally
        DBInterface.close!(con)
    end
end

# ---------------------------------------------------------------------------------------
# Writing

"""
    STACDuckDBExt.GEO_METADATA

The GeoParquet `geo` key written on every file: one WKB geometry column named `geometry`, in
the OGC:CRS84 longitude/latitude the format defaults to when no `crs` is stated, which is the
only CRS a STAC item's footprint is in.
"""
const GEO_METADATA = """
{"version":"1.1.0","primary_column":"geometry","columns":{"geometry":{"encoding":"WKB","geometry_types":[]}}}"""

"""
    STACDuckDBExt.STAC_GEOPARQUET_METADATA

The `stac-geoparquet` key, naming the specification version the file follows. It is what
tells a reader the nested `assets` and `links` columns are there to be found.
"""
const STAC_GEOPARQUET_METADATA = """{"version":"1.0.0"}"""

function bboxstruct(bbox::NTuple{4,Float64})
    o = JSON.Object{String,Any}()
    o["xmin"], o["ymin"], o["xmax"], o["ymax"] = bbox
    return o
end

function bboxstruct(bbox::NTuple{6,Float64})
    o = JSON.Object{String,Any}()
    o["xmin"], o["ymin"], o["zmin"], o["xmax"], o["ymax"], o["zmax"] = bbox
    return o
end

# One staged line per item: the item as it writes, with the geometry moved out to a hex
# string and the bbox turned into the struct the format keys its spatial filters on. DuckDB
# infers the unified schema over the whole file from these, which is the job that would
# otherwise need a column-type union computed by hand.
function stage(io::IO, item::STAC.Item)
    o = StructUtils.lower(STAC.STACStyle(), item)
    delete!(o, "geometry")
    o["stac_extensions"] = something(item.stac_extensions, String[])
    item.bbox === nothing ? delete!(o, "bbox") : (o["bbox"] = bboxstruct(item.bbox))
    o["__wkb"] = item.geometry === nothing ? nothing : bytes2hex(wkbbytes(item.geometry))
    JSON.json(io, o; style = STAC.STACStyle())
    print(io, '\n')
    return io
end

function copysql(staged::AbstractString, path::AbstractString)
    return string("COPY (SELECT * EXCLUDE (properties, __wkb) ",
                  "REPLACE (stac_extensions::VARCHAR[] AS stac_extensions), ",
                  "properties.*, unhex(__wkb) AS geometry ",
                  "FROM read_json(", quotestr(staged),
                  ", format = 'newline_delimited', sample_size = -1)) TO ", quotestr(path),
                  " (FORMAT PARQUET, KV_METADATA {", quotestr("geo"), ": ",
                  quotestr(GEO_METADATA), ", ", quotestr("stac-geoparquet"), ": ",
                  quotestr(STAC_GEOPARQUET_METADATA), "})")
end

function STAC.write_geoparquet(::STAC.DuckDBDriver, path::AbstractString, items)
    staged = string(tempname(), ".ndjson")
    con = connection()
    try
        open(io -> foreach(item -> stage(io, item), items), staged, "w")
        mkpath(dirname(abspath(path)))
        DBInterface.execute(con, copysql(staged, path))
    finally
        DBInterface.close!(con)
        rm(staged; force = true)
    end
    return String(path)
end

end # module STACDuckDBExt
