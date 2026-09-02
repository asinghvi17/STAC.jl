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
# Base's `===` fallback for immutable structs reports as unequal across two parses.
function Base.:(==)(a::T, b::T) where {T<:Extension}
    for i in 1:fieldcount(T)
        isequal(getfield(a, i), getfield(b, i)) || return false
    end
    return true
end

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
