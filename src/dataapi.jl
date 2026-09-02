# DataAPI's metadata interface over the metadata tails, so a STAC object and a DataFrame
# built from one answer the same three functions.

"""
    STAC.TailedObject

The objects whose unnamed keys are reachable through `DataAPI.metadata`: everything that
carries a tail of its own.
"""
const TailedObject = Union{Item,Catalog,Collection,Asset,Band,ItemCollection}

# The keys a reader of the document sees at the top level. An item's *extension* keys sit one
# level down, inside `properties`; `STAC.exttail` is what reaches those.
objecttail(obj::TailedObject) = obj.metadata

const NO_METADATA_KEY = gensym(:nometadatakey)

DataAPI.metadatasupport(::Type{<:TailedObject}) = (read = true, write = false)

"""
    DataAPI.metadatakeys(obj) -> keys

The keys of `obj`'s metadata tail: the top-level keys no field of it names, in document
order. An object parsed with `metadata = false` has none, since the parse kept none.
"""
DataAPI.metadatakeys(obj::TailedObject) = keys(objecttail(obj))

"""
    DataAPI.metadata(obj, key[, default]; style = false) -> value

One key of `obj`'s metadata tail. The style is always `:note`, which is the style DataFrames
propagates through its operations.

```julia
DataAPI.metadata(collection, "item_assets")
DataAPI.metadata(item, "s2:mgrs_tile", missing)
```
"""
function DataAPI.metadata(obj::TailedObject, key::AbstractString; style::Bool = false)
    value = get(objecttail(obj), key, NO_METADATA_KEY)
    value === NO_METADATA_KEY && throw(KeyError(key))
    return style ? (value, :note) : value
end

DataAPI.metadata(obj::TailedObject, key::AbstractString, default; style::Bool = false) =
    (value = get(objecttail(obj), key, default); style ? (value, :note) : value)

"""
    DataAPI.colmetadatakeys(items[, column])
    DataAPI.colmetadata(items, column, key[, default]; style = false)

Where a column of an item table comes from. A column named `"prefix:field"` carries one key,
`"stac_extension"`, holding the schema URI of the extension that defines it, so
`DataFrame(items)` says where `"eo:cloud_cover"` is specified without the caller keeping a
prefix table of their own.
"""
DataAPI.colmetadatasupport(::Type{<:Union{STACTable,ItemRows}}) = (read = true, write = false)

const COLUMN_SOURCE = "stac_extension"

function DataAPI.colmetadatakeys(t::Union{STACTable,ItemRows})
    names = Tables.rows(t).columns.names
    return (nm => (COLUMN_SOURCE,) for nm in names if hassource(t, nm))
end

DataAPI.colmetadatakeys(t::Union{STACTable,ItemRows}, col::Symbol) =
    hassource(t, col) ? (COLUMN_SOURCE,) : ()

# A tail column can carry a prefix no extension struct claims — `"s2:product_type"` — and
# those name no schema, so they carry no column metadata either.
hassource(t, col::Symbol) = columnsource(t, col, COLUMN_SOURCE, nothing) !== nothing

function DataAPI.colmetadata(t::Union{STACTable,ItemRows}, col::Symbol, key::AbstractString;
                             style::Bool = false)
    value = columnsource(t, col, key, NO_METADATA_KEY)
    value === NO_METADATA_KEY && throw(KeyError(key))
    return style ? (value, :note) : value
end

DataAPI.colmetadata(t::Union{STACTable,ItemRows}, col::Symbol, key::AbstractString, default;
                    style::Bool = false) =
    (value = columnsource(t, col, key, default); style ? (value, :note) : value)

function columnsource(t, col::Symbol, key::AbstractString, default)
    key == COLUMN_SOURCE || return default
    name = String(col)
    i = findfirst(==(':'), name)
    i === nothing && return default
    uri = extensionschema(rowitemtype(t), SubString(name, 1, i - 1))
    return uri === nothing ? default : uri
end

rowitemtype(t::STACTable) = eltype(features(t))
rowitemtype(rows::ItemRows) = eltype(rows.items)

# The prefix is a key of `E`, and the struct behind that key is the one that named the column.
# A tail key that happens to carry a prefix names no struct, and reports nothing.
function extensionschema(::Type{Item{E,G,M}}, prefix::AbstractString) where {E,G,M}
    E <: NamedTuple || return nothing
    name = Symbol(prefix)
    name in fieldnames(E) || return nothing
    return schema(Base.nonnothingtype(fieldtype(E, name)))
end
