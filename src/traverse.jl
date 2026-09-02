# Static traversal: `children`, `items`, `parent`, and `root` are all `rel`-filtered links
# resolved against the owner's origin and fetched one at a time.

@noinline _wrongdoc(::Type{T}, obj) where {T} =
    throw(WrongDocumentType(string(T), string(nameof(typeof(obj)))))

"""
    STAC.readdoc(T, bytes, opts) -> T

`bytes` parsed as `T`. A concrete `T` is the parse target directly; anything wider (the
`Union{Catalog{M},Collection{M}}` a `child` link can point at) is decided by the document's
own `type` key.
"""
readdoc(::Type{Catalog{M}}, bytes, ::ParseOptions) where {M} =
    JSON.parse(bytes, Catalog{M}; style = STACStyle())

readdoc(::Type{Collection{M}}, bytes, ::ParseOptions) where {M} =
    JSON.parse(bytes, Collection{M}; style = STACStyle())

readdoc(::Type{Item{E,G,M}}, bytes, ::ParseOptions) where {E,G,M} =
    JSON.parse(bytes, Item{E,G,M}; style = STACStyle())

readdoc(::Type{ItemCollection{E,G,M}}, bytes, ::ParseOptions) where {E,G,M} =
    JSON.parse(bytes, ItemCollection{E,G,M}; style = STACStyle())

function readdoc(::Type{T}, bytes, opts::ParseOptions) where {T}
    obj = parse(bytes, opts)
    obj isa T || _wrongdoc(T, obj)
    return obj::T
end

"""
    STAC.read(T, href, io, opts) -> T

The document at `href`, fetched through `io`, parsed as `T`, and stamped with `href` as its
origin. This is the one fetch every traversal call goes through.
"""
read(::Type{T}, href::AbstractString, io::AbstractIO, opts::ParseOptions) where {T} =
    sethref(readdoc(T, read(io, href), opts), href)

"""
    STAC.rellinks(obj, rel) -> Vector{Link}

The links of `obj` whose `rel` is `rel`, in document order.
"""
rellinks(obj, rel::AbstractString) = filter(l -> l.rel == rel, obj.links)

"""
    STAC.LinkIterator{T}(links, base, io, opts)

The lazy iterator behind [`children`](@ref) and [`items`](@ref). Nothing is fetched until an
element is reached, so `length` costs no requests and `first` costs exactly one.

`base` is the origin of the object the links came from, which is what
[`STAC.resolve`](@ref) resolves each relative href against.
"""
struct LinkIterator{T,I<:AbstractIO,O<:ParseOptions}
    links::Vector{Link}
    base::Union{String,Nothing}
    io::I
    opts::O
end

LinkIterator{T}(links::Vector{Link}, base, io::I, opts::O) where {T,I,O} =
    LinkIterator{T,I,O}(links, base, io, opts)

Base.eltype(::Type{<:LinkIterator{T}}) where {T} = T
Base.length(it::LinkIterator) = length(it.links)
Base.isempty(it::LinkIterator) = isempty(it.links)

Base.iterate(it::LinkIterator{T}, i::Int = 1) where {T} =
    i > length(it.links) ? nothing :
    (read(T, resolve(@inbounds(it.links[i]), it.base), it.io, it.opts), i + 1)

"""
    STAC.children(obj; io = STAC.default_io(), extensions, geometry, metadata) -> LinkIterator
    STAC.children(obj, opts::ParseOptions; io = STAC.default_io())

The `child` links of a [`Catalog`](@ref) or [`Collection`](@ref), as a lazy iterator of the
catalogs and collections they point at. Each element's struct is chosen by that document's
own `type` key.

The keywords are [`ParseOptions`](@ref)'s, plus `io`, the [`AbstractIO`](@ref STAC.AbstractIO)
that fetches.

```julia
cat = STAC.read("test/fixtures/static/self-contained/catalog.json")
length(STAC.children(cat))              # 2, from the link count, before any request
[c.id for c in STAC.children(cat)]      # ["simple-collection", "empty-collection"]
```
"""
children(obj::STACObject, opts::ParseOptions; io::AbstractIO = default_io()) =
    LinkIterator{childtype(opts)}(rellinks(obj, "child"), obj.href, io, opts)

children(obj::STACObject; io::AbstractIO = default_io(), kw...) =
    children(obj, ParseOptions(; kw...); io)

"""
    STAC.items(obj; recursive = false, io = STAC.default_io(), extensions, geometry, metadata)
    STAC.items(obj, opts::ParseOptions; recursive = false, io = STAC.default_io())

The [`Item`](@ref)s of a catalog or collection, as a lazy iterator.

| `recursive` | Yields |
|---|---|
| `false` | the `item` links of `obj` itself |
| `true` | the same, then every descendant's, depth first through [`children`](@ref) |

The recursive form fetches one document per object it reaches and no more, so a walk of a
rate-limited catalog costs exactly as many requests as it visits documents.

```julia
cat = STAC.read("test/fixtures/static/self-contained/catalog.json")
[i.id for i in STAC.items(cat)]                         # ["collectionless-item"]
length(collect(STAC.items(cat; recursive = true)))      # 4, the descendants' as well
first(STAC.items(cat; recursive = true)).properties.datetime
```
"""
function items(obj::STACObject, opts::ParseOptions; io::AbstractIO = default_io(),
               recursive::Bool = false)
    recursive && return RecursiveItems(obj, io, opts)
    return LinkIterator{itemtype(opts)}(rellinks(obj, "item"), obj.href, io, opts)
end

items(obj::STACObject; io::AbstractIO = default_io(), recursive::Bool = false, kw...) =
    items(obj, ParseOptions(; kw...); io, recursive)

"""
    STAC.RecursiveItems

The depth-first walk behind `items(obj; recursive = true)`. It carries the child hrefs it
has yet to visit rather than the fetched objects, so a container is fetched only when the
walk reaches it.
"""
struct RecursiveItems{T,C,I<:AbstractIO,O<:ParseOptions}
    root::C
    io::I
    opts::O
end

RecursiveItems(root::C, io::I, opts::O) where {C,I,O} =
    RecursiveItems{itemtype(opts),C,I,O}(root, io, opts)

Base.eltype(::Type{<:RecursiveItems{T}}) where {T} = T
Base.IteratorSize(::Type{<:RecursiveItems}) = Base.SizeUnknown()

mutable struct RecursiveItemsState{L}
    const pending::Vector{String}
    links::L
    i::Int
end

# Reversed, because `pending` is a stack: the first child listed must be the first one off it.
function _pushchildren!(pending::Vector{String}, obj)
    links = rellinks(obj, "child")
    for i in reverse(eachindex(links))
        push!(pending, resolve(@inbounds(links[i]), obj.href))
    end
    return pending
end

function _initstate(it::RecursiveItems{T}) where {T}
    links = LinkIterator{T}(rellinks(it.root, "item"), it.root.href, it.io, it.opts)
    return RecursiveItemsState(_pushchildren!(String[], it.root), links, 1)
end

function Base.iterate(it::RecursiveItems{T}, state = _initstate(it)) where {T}
    while true
        next = iterate(state.links, state.i)
        if next !== nothing
            item, i = next
            state.i = i
            return item, state
        end
        isempty(state.pending) && return nothing
        child = read(childtype(it.opts), pop!(state.pending), it.io, it.opts)
        _pushchildren!(state.pending, child)
        state.links = LinkIterator{T}(rellinks(child, "item"), child.href, it.io, it.opts)
        state.i = 1
    end
end

function _firstlink(obj, rel::AbstractString, io::AbstractIO, opts::ParseOptions)
    T = childtype(opts)
    for l in obj.links
        l.rel == rel && return read(T, resolve(l, obj.href), io, opts)
    end
    return nothing
end

"""
    parent(obj, opts::ParseOptions; io = STAC.default_io())
    parent(obj; io = STAC.default_io(), extensions, geometry, metadata)

The catalog or collection `obj`'s `parent` link points at, or `nothing` when it has none.

```julia
col = STAC.read("test/fixtures/static/self-contained/simple-collection/collection.json")
parent(col).id                      # "examples", the catalog above it
parent(parent(col)) === nothing     # true: the root has no parent
```
"""
Base.parent(obj::STACObject, opts::ParseOptions; io::AbstractIO = default_io()) =
    _firstlink(obj, "parent", io, opts)

Base.parent(obj::STACObject; io::AbstractIO = default_io(), kw...) =
    parent(obj, ParseOptions(; kw...); io)

"""
    STAC.root(obj, opts::ParseOptions; io = STAC.default_io())
    STAC.root(obj; io = STAC.default_io(), extensions, geometry, metadata)

The catalog or collection `obj`'s `root` link points at, or `nothing` when it has none.

```julia
col = STAC.read("test/fixtures/static/self-contained/simple-collection/collection.json")
STAC.root(col).id                   # "examples", however deep `col` sits
```
"""
root(obj::STACObject, opts::ParseOptions; io::AbstractIO = default_io()) =
    _firstlink(obj, "root", io, opts)

root(obj::STACObject; io::AbstractIO = default_io(), kw...) = root(obj, ParseOptions(; kw...); io)
