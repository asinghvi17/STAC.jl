# Items as a Tables.jl row table. The column layout is stac-geoparquet's, so the parquet
# writer of a later phase hands these rows on unchanged.

"""
    STAC.BBox4
    STAC.BBox6

A row's `bbox`, as the struct column stac-geoparquet defines: the four planar bounds, or the
six a 3D box carries, in the order STAC writes them.
"""
const BBox4 = @NamedTuple{xmin::Float64, ymin::Float64, xmax::Float64, ymax::Float64}
const BBox6 = @NamedTuple{xmin::Float64, ymin::Float64, zmin::Float64,
                          xmax::Float64, ymax::Float64, zmax::Float64}

bboxrow(::Nothing) = nothing
bboxrow(b::NTuple{4,Float64}) = BBox4(b)
bboxrow(b::NTuple{6,Float64}) = BBox6(b)

"""
    STAC.ItemColumn

One column of an item table: its name, the type the schema declares for it, and the function
that reads it out of an item.

The reader is a closure rather than the callable struct the parse routers use: which columns
exist is a property of the rows, not of the type, so this list is built at runtime and read
through a dynamic call either way. Nothing here is on a `--trim=safe` path.
"""
struct ItemColumn
    name::Symbol
    type::Type
    read::Function
end

"""
    STAC.ItemColumns

The columns of one item table, built once and shared by every row, with a name lookup for
`Tables.getcolumn(row, ::Symbol)`.
"""
struct ItemColumns
    columns::Vector{ItemColumn}
    names::Vector{Symbol}
    types::Vector{Type}
    lookup::Dict{Symbol,Int}
end

function ItemColumns(columns::Vector{ItemColumn})
    names = [c.name for c in columns]
    return ItemColumns(columns, names, Type[c.type for c in columns],
                       Dict(nm => i for (i, nm) in pairs(names)))
end

# The typed fields of an item and its properties, in the order stac-geoparquet lists them.
const ROW_FIELDS = (:id, :stac_extensions, :geometry, :collection)

_field(item::Item, name::Symbol) = getfield(item, name)
_property(item::Item, name::Symbol) = getfield(item.properties, name)

function _extension(item::Item, ext::Symbol, name::Symbol)
    e = getfield(item.extensions, ext)
    return e === nothing ? nothing : getfield(e, name)
end

# `missing`, not `nothing`: a key no other row carried is absent from this one, which is a
# different statement from a key the producer wrote as `null`.
_tailvalue(tail, key::String) = get(tail, key, missing)

"""
    STAC.itemcolumns(items) -> STAC.ItemColumns

The column layout of a table of items: the typed fields first, then one column per field of
each declared extension, then the keys the rows' tails carry.

| Columns | Type |
|---|---|
| `id`, `stac_extensions`, `geometry`, `collection` | the item's own field types |
| `bbox` | [`STAC.BBox4`](@ref) or [`STAC.BBox6`](@ref) |
| every [`Properties`](@ref) field but `other` | the field's type, so `datetime` is a `Union{DateTime,Nothing}` column |
| `"eo:cloud_cover"`, `"proj:code"`, … | the extension field's type, one column per field of each extension in `E` |
| the keys seen in `properties.other` | `Any` |
| `links`, `assets` | `Vector{Link}`, `OrderedDict{String,Asset}` |
| the keys seen in the items' own tails | `Any` |

The last two groups need one pass over the items, since only the rows say which keys the
producer used. A row missing a tail key reports `missing`. A tail key that spells a column
this layout already has — a property named `links` — is left out rather than shadowing it.
"""
function itemcolumns(items::AbstractVector{Item{E,G,M}}) where {E,G,M}
    I = Item{E,G,M}
    cols = ItemColumn[]
    # The two nested columns are added last but claim their names first, so a tail key cannot
    # take one of them.
    taken = Set{Symbol}((:links, :assets))
    for name in ROW_FIELDS
        addcolumn!(cols, taken, ItemColumn(name, fieldtype(I, name), item -> _field(item, name)))
    end
    addcolumn!(cols, taken,
               ItemColumn(:bbox, Union{Nothing,BBox4,BBox6}, item -> bboxrow(item.bbox)))
    for name in fieldnames(Properties)
        name === :other && continue
        addcolumn!(cols, taken, ItemColumn(name, fieldtype(Properties{M}, name),
                                           item -> _property(item, name)))
    end
    if E <: NamedTuple
        for ext in fieldnames(E)
            ET = Base.nonnothingtype(fieldtype(E, ext))
            for name in fieldnames(ET)
                addcolumn!(cols, taken,
                           ItemColumn(Symbol(String(ext), ':', name), fieldtype(ET, name),
                                      item -> _extension(item, ext, name)))
            end
        end
    end
    for key in tailkeys(items, item -> item.properties.other)
        addcolumn!(cols, taken, ItemColumn(Symbol(key), Any,
                                           item -> _tailvalue(item.properties.other, key)))
    end
    push!(cols, ItemColumn(:links, fieldtype(I, :links), item -> item.links))
    push!(cols, ItemColumn(:assets, fieldtype(I, :assets), item -> item.assets))
    for key in tailkeys(items, item -> item.metadata)
        addcolumn!(cols, taken, ItemColumn(Symbol(key), Any,
                                           item -> _tailvalue(item.metadata, key)))
    end
    return ItemColumns(cols)
end

function addcolumn!(cols::Vector{ItemColumn}, taken::Set{Symbol}, col::ItemColumn)
    col.name in taken && return cols
    push!(taken, col.name)
    push!(cols, col)
    return cols
end

"""
    STAC.tailkeys(items, tailof) -> Vector{String}

Every key the items' tails carry, in the order they are first seen.
"""
function tailkeys(items, tailof)
    keys = String[]
    seen = Set{String}()
    for item in items, k in Base.keys(tailof(item))
        key = String(k)
        key in seen || (push!(seen, key); push!(keys, key))
    end
    return keys
end

"""
    STAC.ItemRow

One item presented as a Tables.jl row: the item itself plus the columns its table settled on.
"""
struct ItemRow{I<:Item} <: Tables.AbstractRow
    item::I
    columns::ItemColumns
end

"""
    STAC.ItemRows

A vector of [`Item`](@ref)s as a Tables.jl row table. Build one with `Tables.rows(items)`.
"""
struct ItemRows{I<:Item,V<:AbstractVector{I}} <: AbstractVector{ItemRow{I}}
    items::V
    columns::ItemColumns
end

ItemRows(items::AbstractVector{<:Item}) = ItemRows(items, itemcolumns(items))

Base.size(rows::ItemRows) = (length(rows.items),)
Base.IndexStyle(::Type{<:ItemRows}) = IndexLinear()
Base.getindex(rows::ItemRows, i::Int) = ItemRow(rows.items[i], rows.columns)

@noinline _nocolumn(name) = throw(MissingColumn(name))

Tables.getcolumn(row::ItemRow, i::Int) = getfield(row, :columns).columns[i].read(getfield(row, :item))

function Tables.getcolumn(row::ItemRow, name::Symbol)
    i = get(getfield(row, :columns).lookup, name, 0)
    i == 0 && _nocolumn(name)
    return Tables.getcolumn(row, i)
end

Tables.columnnames(row::ItemRow) = getfield(row, :columns).names

"""
    Tables.schema(items::AbstractVector{<:Item})
    Tables.schema(page::ItemCollection)

The column layout of [`STAC.itemcolumns`](@ref), as a `Tables.Schema`.
"""
Tables.schema(rows::ItemRows) = Tables.Schema(rows.columns.names, rows.columns.types)

"""
    STAC.STACTable

The two things a vector of items can arrive as: the vector, and the [`ItemCollection`](@ref)
page holding one.
"""
const STACTable = Union{ItemCollection,AbstractVector{<:Item}}

features(fc::ItemCollection) = fc.features
features(items::AbstractVector{<:Item}) = items

Tables.istable(::Type{<:STACTable}) = true
Tables.istable(::Type{<:ItemRows}) = true
Tables.rowaccess(::Type{<:STACTable}) = true
Tables.rowaccess(::Type{<:ItemRows}) = true

Tables.rows(t::STACTable) = ItemRows(features(t))
Tables.rows(rows::ItemRows) = rows
Tables.schema(t::STACTable) = Tables.schema(Tables.rows(t))
