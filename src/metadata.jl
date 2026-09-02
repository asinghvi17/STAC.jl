"""
    STAC.AnyMetadata

The tail of a STAC object — the keys no struct field names — as an `AbstractDict{String,Any}`.
Two types inhabit it, and they are the two values the `M` parameter of [`Item`](@ref),
[`Catalog`](@ref), [`Collection`](@ref), and [`Properties`](@ref) takes:

| Type | Parsed with | Holds |
|---|---|---|
| [`Metadata`](@ref) | `metadata = true` | every unnamed key, in document order |
| [`NoMetadata`](@ref) | `metadata = false` | nothing, and proves it in the type |

Both answer the `AbstractDict` interface, so a tail indexes, iterates as `key => value`, and
passes to anything that takes a dictionary.
"""
abstract type AnyMetadata <: AbstractDict{String,Any} end

"""
    Metadata(data::JSON.Object{String,Any})
    Metadata()

The keys of a STAC object that no struct field names, kept in document order so that
[`STAC.json`](@ref) writes them back where the producer put them. Extension keys with no
struct, producer-specific keys, and `stac_version` all land here.

```jldoctest
julia> using JSON

julia> m = STAC.Metadata(JSON.Object{String,Any}("s2:mgrs_tile" => "59UNT"))
Metadata("s2:mgrs_tile")

julia> m["s2:mgrs_tile"], get(m, "eo:cloud_cover", nothing)
("59UNT", nothing)
```
"""
struct Metadata <: AnyMetadata
    data::JSON.Object{String,Any}
end

Metadata() = Metadata(JSON.Object{String,Any}())

"""
    NoMetadata()

The tail of an object parsed with `metadata = false`: unnamed keys were skipped during the
parse, so the type itself proves that nothing unknown was kept. It is an empty
`AbstractDict`, and a singleton, so carrying one costs no memory.
"""
struct NoMetadata <: AnyMetadata end

Base.get(m::Metadata, key, default) = get(m.data, key, default)
Base.getindex(m::Metadata, key) = getindex(m.data, key)
Base.haskey(m::Metadata, key) = haskey(m.data, key)
Base.keys(m::Metadata) = keys(m.data)
Base.values(m::Metadata) = values(m.data)
Base.length(m::Metadata) = length(m.data)
Base.isempty(m::Metadata) = isempty(m.data)
Base.iterate(m::Metadata) = iterate(m.data)
Base.iterate(m::Metadata, state) = iterate(m.data, state)

Base.get(::NoMetadata, key, default) = default
Base.getindex(::NoMetadata, key) = throw(KeyError(key))
Base.haskey(::NoMetadata, key) = false
Base.keys(::NoMetadata) = ()
Base.values(::NoMetadata) = ()
Base.length(::NoMetadata) = 0
Base.isempty(::NoMetadata) = true
Base.iterate(::NoMetadata) = nothing
Base.iterate(::NoMetadata, state) = nothing

# A tail is read for its key names far more often than for its values, so both forms print
# the names; `AbstractDict`'s would dump every value of a search page's producer keys.
function Base.show(io::IO, m::Metadata)
    print(io, "Metadata(")
    join(io, (repr(k) for k in keys(m)), ", ")
    print(io, ")")
end

Base.show(io::IO, ::NoMetadata) = print(io, "NoMetadata()")
Base.show(io::IO, ::MIME"text/plain", m::AnyMetadata) = show(io, m)
