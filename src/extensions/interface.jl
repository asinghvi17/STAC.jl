"""
    STAC.Extension

Supertype of the structs that give a STAC extension typed fields. An extension is one struct
whose field names are the keys after the prefix, plus [`STAC.prefix`](@ref) and
[`STAC.schema`](@ref):

```julia
struct EO <: STAC.Extension
    cloud_cover::Union{Float64,Nothing}
    snow_cover::Union{Float64,Nothing}
end
STAC.prefix(::Type{EO}) = "eo"
STAC.schema(::Type{EO}) = "https://stac-extensions.github.io/eo/v2.0.0/schema.json"
```

Passing the struct to `extensions =` makes `item.extensions.eo.cloud_cover` a concrete field
read; see [`STAC.extensiontype`](@ref).
"""
abstract type Extension end

# Field-by-field comparison, as for the object types: extension structs hold vectors, which
# Base's `===` fallback for immutable structs reports as unequal across two parses. The
# diagonal rule restricts `T` to concrete types, so `EO() == Sat()` falls through to `===`.
Base.:(==)(a::T, b::T) where {T<:Extension} = fieldsequal(a, b)
Base.isequal(a::T, b::T) where {T<:Extension} = fieldsisequal(a, b)
Base.hash(x::Extension, h::UInt) = fieldshash(x, h)

"""
    STAC.prefix(::Type{<:Extension}) -> String

The `prefix:` an extension's keys carry inside `properties`, without the colon.
"""
function prefix end

"""
    STAC.schema(::Type{<:Extension}) -> String

The schema URI an object lists in `stac_extensions` to declare the extension.
"""
function schema end

"""
    STAC.extensiontype(extensions::Tuple) -> Type

The `E` parameter of [`Item`](@ref) for a tuple of extension structs: a `NamedTuple` type
keyed by each struct's [`STAC.prefix`](@ref), with `Union{T,Nothing}` values so an item that
carries none of an extension's keys reports `nothing`.

```jldoctest
julia> STAC.extensiontype((STAC.EO, STAC.Projection))
@NamedTuple{eo::Union{Nothing, STAC.EO}, proj::Union{Nothing, STAC.Projection}}
```

An empty tuple gives `Any`, the dynamic form in which every prefixed key stays in
`properties.other`.
"""
extensiontype(::Tuple{}) = Any
extensiontype(exts::Tuple{Vararg{Type}}) =
    NamedTuple{map(T -> Symbol(prefix(T)), exts), Tuple{map(T -> Union{T,Nothing}, exts)...}}

# ---------------------------------------------------------------------------------------
# Reaching an extension that was not parsed eagerly

"""
    STAC.exttail(obj) -> AnyMetadata

Where `obj` keeps the extension keys no field of it names, which is where an extension with
no eager slot is read from.

| Object | Tail |
|---|---|
| [`Item`](@ref) | `properties.other`, since an item's extension keys live inside `properties` |
| [`Asset`](@ref), [`Band`](@ref), [`Catalog`](@ref), [`Collection`](@ref) | `metadata`, the object's own unnamed keys |
"""
exttail(item::Item) = item.properties.other
exttail(obj::Union{Asset,Band,Catalog,Collection}) = obj.metadata

"""
    STAC.fromtail(T, tail) -> Union{T,Nothing}

The extension `T` built by looking each of its fields up as `"prefix:field"` in `tail`, or
`nothing` when the tail holds none of them. This is the one function behind every access path
that is not an eager field read.

A field whose key is present is lifted to the field's type through the parse style, so a
`DateTime` field reads an RFC 3339 string and a `Float64` field reads a JSON integer. Every
field of an extension struct is therefore `Union{…,Nothing}`: an absent key has to be
representable.
"""
function fromtail(::Type{T}, tail) where {T<:Extension}
    p = prefix(T)
    vals = ntuple(Val(fieldcount(T))) do i
        v = get(tail, p * ":" * String(fieldname(T, i)), nothing)
        return v === nothing ? nothing : lifttail(fieldtype(T, i), v)
    end
    all(isnothing, vals) && return nothing
    return T(vals...)
end

# `lift` peels no `Union`, so the field's own `Nothing` is stripped before the call: a
# `Union{DateTime,Nothing}` field must reach the style's RFC 3339 method, not `convert`.
lifttail(::Type{FT}, v) where {FT} =
    first(StructUtils.lift(STACStyle(), Base.nonnothingtype(FT), v))

# Whether the item's declared extension tuple carries `T` in a field of its own.
function iseager(::Type{E}, ::Type{T}) where {E,T<:Extension}
    E <: NamedTuple || return false
    name = Symbol(prefix(T))
    name in fieldnames(E) || return false
    return Base.nonnothingtype(fieldtype(E, name)) === T
end

"""
    get(obj, T::Type{<:Extension}) -> Union{T,Nothing}
    T(obj) -> T

The extension `T` of an [`Item`](@ref), [`Asset`](@ref), [`Band`](@ref), [`Catalog`](@ref),
or [`Collection`](@ref). `get` reports `nothing` when the object carries none of `T`'s keys;
the constructor form throws instead.

| Call | Source |
|---|---|
| `item.extensions.eo` | the eager field, when `extensions =` named `STAC.EO` |
| `get(item, STAC.EO)` | that field when it exists, else a lookup in `properties.other` |
| `STAC.EO(item)` | the same, throwing when the item carries no `eo:` key |
| `STAC.Projection(asset)` | a lookup in the asset's own metadata |

An item parsed with `metadata = false` kept no tail, so a lookup on one finds nothing: the
keys were dropped at parse time rather than being absent from the document.

```julia
item = STAC.read("test/fixtures/stac-spec/extended-item.json"; extensions = (STAC.EO,))
item.extensions.eo.cloud_cover    # 1.2, the eager field
get(item, STAC.View)              # STAC.View(3.8, …), read from the tail
STAC.View(item).off_nadir         # 3.8, or a `STAC.MissingExtension` if there is none
get(item, STAC.Sat) === nothing   # true: the item carries no `sat:` key
```
"""
Base.get(item::Item{E}, ::Type{T}) where {E,T<:Extension} =
    iseager(E, T) ? getfield(item.extensions, Symbol(prefix(T))) : fromtail(T, exttail(item))

Base.get(obj::Union{Asset,Band,Catalog,Collection}, ::Type{T}) where {T<:Extension} =
    fromtail(T, exttail(obj))

@noinline _noextension(::Type{T}, obj) where {T} =
    throw(MissingExtension(string(nameof(T)), prefix(T), string(nameof(typeof(obj)))))

function (::Type{T})(obj::Union{Item,Asset,Band,Catalog,Collection}) where {T<:Extension}
    ext = get(obj, T)
    ext === nothing && _noextension(T, obj)
    return ext
end

"""
    STAC.declares(obj, T::Type{<:Extension}) -> Bool
    STAC.declares(obj, uri::AbstractString) -> Bool

Whether an [`Item`](@ref), [`Catalog`](@ref), or [`Collection`](@ref) lists the extension in
its `stac_extensions`. The version segment of the schema URI is ignored, as pystac does, so
an item declaring `eo/v1.1.0` declares [`EO`](@ref) even though this package types the
2.0.0 fields.

Declaring an extension and carrying its keys are different questions: `STAC.declares` reads
the list, `get(obj, T)` reads the keys. Producers get both wrong in both directions.

```julia
item = STAC.read("test/fixtures/stac-spec/extended-item.json")
STAC.declares(item, STAC.EO)                 # true, even though the item lists eo v2.0.0
STAC.declares(item, STAC.schema(STAC.EO))    # the same question, asked by URI
STAC.declares(item, STAC.Sat)                # false: `stac_extensions` never names it
```
"""
declares(obj, ::Type{T}) where {T<:Extension} = declares(obj, schema(T))

function declares(obj::Union{Item,Catalog,Collection}, uri::AbstractString)
    declared = obj.stac_extensions
    declared === nothing && return false
    head, rest = schemaparts(uri)
    return any(u -> schemamatches(u, head, rest), declared)
end

const SCHEMA_VERSION = r"^(.*/)v[0-9][^/]*(/.*)$"

"""
    STAC.schemaparts(uri) -> (head, rest)

A schema URI split around its version segment, or `(uri, "")` when it has none. The two
halves are what [`STAC.declares`](@ref) compares, so that any version of the same schema
matches.
"""
function schemaparts(uri::AbstractString)
    m = match(SCHEMA_VERSION, uri)
    m === nothing && return (String(uri), "")
    return (String(m[1]), String(m[2]))
end

function schemamatches(u::AbstractString, head::AbstractString, rest::AbstractString)
    uhead, urest = schemaparts(u)
    return uhead == head && urest == rest
end
