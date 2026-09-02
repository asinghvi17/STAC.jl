"""
    Metadata(data::JSON.Object{String,Any})
    Metadata()

The keys of a STAC object that no struct field names, kept in document order so that
[`STAC.json`](@ref) writes them back where the producer put them. Extension keys with no
struct, producer-specific keys, and `stac_version` all land here.

Answers `get`, `keys`, `haskey`, `length`, and iteration as `key => value` pairs.
"""
struct Metadata
    data::JSON.Object{String,Any}
end

Metadata() = Metadata(JSON.Object{String,Any}())

"""
    NoMetadata()

The tail of an object parsed with `metadata = false`: unnamed keys were skipped during the
parse, so the type itself proves that nothing unknown was kept. Answers the same accessors
as [`Metadata`](@ref), always empty.
"""
struct NoMetadata end

const AnyMetadata = Union{Metadata,NoMetadata}

Base.get(m::Metadata, key, default) = get(m.data, key, default)
Base.getindex(m::Metadata, key) = getindex(m.data, key)
Base.haskey(m::Metadata, key) = haskey(m.data, key)
Base.keys(m::Metadata) = keys(m.data)
Base.values(m::Metadata) = values(m.data)
Base.length(m::Metadata) = length(m.data)
Base.isempty(m::Metadata) = isempty(m.data)
Base.iterate(m::Metadata) = iterate(m.data)
Base.iterate(m::Metadata, state) = iterate(m.data, state)
Base.pairs(m::Metadata) = m.data
Base.:(==)(a::Metadata, b::Metadata) = a.data == b.data

Base.get(::NoMetadata, key, default) = default
Base.haskey(::NoMetadata, key) = false
Base.keys(::NoMetadata) = ()
Base.values(::NoMetadata) = ()
Base.length(::NoMetadata) = 0
Base.isempty(::NoMetadata) = true
Base.iterate(::NoMetadata) = nothing
Base.iterate(::NoMetadata, state) = nothing
Base.pairs(::NoMetadata) = ()

function Base.show(io::IO, m::Metadata)
    print(io, "Metadata(")
    join(io, (repr(k) for k in keys(m)), ", ")
    print(io, ")")
end
