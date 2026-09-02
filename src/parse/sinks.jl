# The parse routers. Each `make` method below builds a slot array, runs one
# `StructUtils.applyeach` over the source, and constructs the struct; the sink returns the
# byte position after each value, which is what keeps the whole parse a single forward pass.
#
# Sinks are callable structs rather than closures: `applyeach` only forwards its function
# argument, so Julia compiles a closure unspecialized, which is a dynamic dispatch at runtime
# and an unresolved call under `--trim=safe`.

@static if VERSION >= v"1.11"
    const Slots = Memory{Any}
else
    const Slots = Vector{Any}
end

newslots(n::Int) = Slots(undef, n)

# `applyeach` dispatches on the runtime JSON type, so the array (integer key) path of every
# sink is reachable; one resolvable method each leaves the trim verifier nothing to chase.
@noinline _notobject(::Type{T}) where {T} =
    throw(ArgumentError("expected a JSON object for " * string(T)))

newtail(::Type{Metadata}) = JSON.Object{String,Any}()
newtail(::Type{NoMetadata}) = NoMetadata()
wraptail(::Type{Metadata}, o::JSON.Object{String,Any}) = Metadata(o)
wraptail(::Type{NoMetadata}, ::NoMetadata) = NoMetadata()

# `lift(style, Any, v)` is JSON's generic materializer and has an explicit type switch;
# `make(style, Any, v)` recurses through `Vector{Any}` / `Object{String,Any}`, which infers as
# `Any`, allocates 40% more, and leaves the trim verifier with unresolved calls.
function tailstore!(tail::JSON.Object{String,Any}, style, k, v)
    val, pos = StructUtils.lift(style, Any, v)
    tail[convert(String, k)] = val
    return pos
end

# Returning `nothing` makes applyobject skip the value without materializing it.
tailstore!(::NoMetadata, style, k, v) = nothing

# The expression a generated field ladder uses to build one value. `lift` is JSON's generic
# path for an `Any` field; `make` is the typed one. Emitting the call rather than routing it
# through a shared helper keeps each nesting level a distinct method, which is what the trim
# verifier needs to resolve `Collection` -> `CollectionExtent` -> `SpatialExtent`.
makevalueexpr(::Type{Any}) = :(StructUtils.lift(style, Any, v))
makevalueexpr(::Type{V}) where {V} = :(StructUtils.make(style, $V, v))

# ---------------------------------------------------------------------------
# Key -> field routing for the structs whose trailing fields no JSON key can fill.

# Trailing fields filled by the sink itself rather than by a key.
nsynthetic(::Type) = 0
nsynthetic(::Type{<:Union{Link,Asset,Band,Provider,SpatialExtent,TemporalExtent,CollectionExtent}}) = 1  # metadata
nsynthetic(::Type{<:Properties}) = 1                                         # other
nsynthetic(::Type{<:Union{Catalog,Collection,ItemCollection}}) = 2           # metadata, href
nsynthetic(::Type{<:Item}) = 3                                               # extensions, metadata, href

nroutable(::Type{T}) where {T} = fieldcount(T) - nsynthetic(T)

# `properties` on an Item is filled by `makeproperties`, which also fills `extensions`; it
# must stay out of the ladder or the trim verifier follows StructUtils' default
# `makestruct(Properties)` into a recursive `make(Any)`.
routable(::Type{T}) where {T} = 1:nroutable(T)
routable(::Type{T}) where {T<:Item} = filter(i -> fieldname(T, i) !== :properties, 1:nroutable(T))

# The `type` key of these objects is what selected the struct, so the struct restates it.
implicittype(::Type) = false
implicittype(::Type{<:Union{Catalog,Collection,Item,ItemCollection}}) = true

# A generated ladder of literal comparisons against JSON's pointer strings: known keys never
# allocate a `String`.
@generated function keyindex(::Type{T}, k) where {T}
    ex = Expr(:block)
    for i in routable(T)
        push!(ex.args, :(k == $(String(fieldname(T, i))) && return $i))
    end
    push!(ex.args, :(return 0))
    return ex
end

# A ladder over field types so each value is built with a compile-time constant type.
@generated function makefield!(vals, style, ::Type{T}, i::Int, v) where {T}
    ex = Expr(:block)
    for j in routable(T)
        push!(ex.args, quote
            if i == $j
                val, pos = $(makevalueexpr(fieldtype(T, j)))
                @inbounds vals[$j] = val
                return pos
            end
        end)
    end
    push!(ex.args, :(return nothing))
    return ex
end

@noinline _missingfield(::Type{T}, i) where {T} =
    throw(ArgumentError(string("missing required field ", fieldname(T, i), " for ", T)))

@inline function getval(vals, ::Type{T}, i, ::Type{FT}) where {T,FT}
    if isassigned(vals, i)
        return @inbounds(vals[i])::FT
    elseif Nothing <: FT
        return nothing
    else
        _missingfield(T, i)
    end
end

@generated function construct(::Type{T}, vals, tails...) where {T}
    args = Any[:(getval(vals, T, $i, $(fieldtype(T, i)))) for i in 1:nroutable(T)]
    return :(T($(args...), tails...))
end

# ---------------------------------------------------------------------------
# Objects whose whole tail is a `Metadata`. Each gets its own `make` so the nested parse
# resolves statically: StructUtils' default `makestruct` reaches its fields through a
# four-argument `make` the trim verifier cannot resolve (Julia issue #62661).

struct TailSink{T,S,Tail}
    vals::Slots
    style::S
    tail::Tail
end

(f::TailSink{T})(k::Integer, v) where {T} = _notobject(T)

function (f::TailSink{T})(k, v) where {T}
    implicittype(T) && k == "type" && return nothing
    i = keyindex(T, k)
    i == 0 && return tailstore!(f.tail, f.style, k, v)
    return makefield!(f.vals, f.style, T, i, v)
end

tailsink(::Type{T}, vals, style, tail) where {T} =
    TailSink{T,typeof(style),typeof(tail)}(vals, style, tail)

# One method per type rather than one method over their union: a `CollectionExtent` nests a
# `SpatialExtent`, and a single generic method calling itself is the recursive typed parse
# whose inner `make` the trim verifier reports as an unresolved invoke.
for T in (:Link, :Asset, :Band, :Provider, :SpatialExtent, :TemporalExtent, :CollectionExtent)
    @eval function StructUtils.make(style::StructUtils.StructStyle, ::Type{$T},
                                    src::JSON.LazyValue)
        vals = newslots(fieldcount($T))
        tail = newtail(Metadata)
        pos = StructUtils.applyeach(style, tailsink($T, vals, style, tail), src)
        return construct($T, vals, wraptail(Metadata, tail)), pos::Int
    end
end

for O in (:Catalog, :Collection)
    @eval function StructUtils.make(style::StructUtils.StructStyle, ::Type{$O{M}},
                                    src::JSON.LazyValue) where {M}
        T = $O{M}
        vals = newslots(fieldcount(T))
        tail = newtail(M)
        pos = StructUtils.applyeach(style, tailsink(T, vals, style, tail), src)
        return construct(T, vals, wraptail(M, tail), nothing), pos::Int
    end
end

function StructUtils.make(style::StructUtils.StructStyle, ::Type{ItemCollection{E,G,M}},
                          src::JSON.LazyValue) where {E,G,M}
    T = ItemCollection{E,G,M}
    vals = newslots(fieldcount(T))
    tail = newtail(M)
    pos = StructUtils.applyeach(style, tailsink(T, vals, style, tail), src)
    return construct(T, vals, wraptail(M, tail), nothing), pos::Int
end

# ---------------------------------------------------------------------------
# Arrays of the types above. StructUtils' `makearray` would also work, but its `ArrayClosure`
# is one method for every element type, so a nested parse reaches it twice and the trim
# verifier reports the inner pass as an unresolved invoke.

@noinline _notarray(::Type{T}) where {T} = throw(ArgumentError("expected a JSON array for " * string(T)))

struct VectorSink{V,T,S}
    vec::V
    style::S
end

(f::VectorSink{V,T})(k, v) where {V,T} = _notarray(V)

function (f::VectorSink{V,T})(k::Integer, v) where {V,T}
    val, pos = StructUtils.make(f.style, T, v)
    push!(f.vec, val)
    return pos
end

for T in (:Link, :Provider, :Band)
    @eval function StructUtils.make(style::StructUtils.StructStyle, ::Type{Vector{$T}},
                                    src::JSON.LazyValue)
        vec = Vector{$T}()
        pos = StructUtils.applyeach(style, VectorSink{Vector{$T},$T,typeof(style)}(vec, style), src)
        return vec, pos::Int
    end
end

function StructUtils.make(style::StructUtils.StructStyle, ::Type{Vector{Item{E,G,M}}},
                          src::JSON.LazyValue) where {E,G,M}
    vec = Vector{Item{E,G,M}}()
    sink = VectorSink{Vector{Item{E,G,M}},Item{E,G,M},typeof(style)}(vec, style)
    pos = StructUtils.applyeach(style, sink, src)
    return vec, pos::Int
end

# ---------------------------------------------------------------------------
# `Metadata` as a value in its own right, which is what a Collection's `summaries` is.

struct MetadataSink{S}
    tail::JSON.Object{String,Any}
    style::S
end

(f::MetadataSink)(k::Integer, v) = _notobject(Metadata)
(f::MetadataSink)(k, v) = tailstore!(f.tail, f.style, k, v)

function StructUtils.make(style::StructUtils.StructStyle, ::Type{Metadata}, src::JSON.LazyValue)
    tail = JSON.Object{String,Any}()
    pos = StructUtils.applyeach(style, MetadataSink(tail, style), src)
    return Metadata(tail), pos::Int
end

# ---------------------------------------------------------------------------
# String-keyed maps. StructUtils' `makedict` would also work, but its `DictClosure` has no
# integer-key method, which the trim verifier reports for the (unreachable) array branch.

struct MapSink{D,V,S}
    dict::D
    style::S
end

(f::MapSink{D,V})(k::Integer, v) where {D,V} = _notobject(D)

function (f::MapSink{D,V})(k, v) where {D,V}
    val, pos = StructUtils.make(f.style, V, v)
    f.dict[convert(String, k)] = val
    return pos
end

function StructUtils.make(style::StructUtils.StructStyle,
                          ::Type{OrderedDict{String,Asset}}, src::JSON.LazyValue)
    d = OrderedDict{String,Asset}()
    pos = StructUtils.applyeach(style, MapSink{typeof(d),Asset,typeof(style)}(d, style), src)
    return d, pos::Int
end

# ---------------------------------------------------------------------------
# `properties` fills the typed slots, the extension slots, and the property tail from one
# object scan. The NamedTuple field name of `E` is the extension prefix: a generator cannot
# call `prefix(::Type)`, because generated functions may not call methods defined after them.

extkeyindex(::Type{Any}, k) = (0, 0)

@generated function extkeyindex(::Type{E}, k) where {E}
    ex = Expr(:block)
    for j in 1:fieldcount(E)
        p = String(fieldname(E, j))
        ET = Base.nonnothingtype(fieldtype(E, j))
        for f in 1:fieldcount(ET)
            push!(ex.args, :(k == $(p * ":" * String(fieldname(ET, f))) && return ($j, $f)))
        end
    end
    push!(ex.args, :(return (0, 0)))
    return ex
end

@generated function makeextfield!(evals, style, ::Type{E}, j::Int, f::Int, v) where {E}
    ex = Expr(:block)
    for jj in 1:fieldcount(E)
        ET = Base.nonnothingtype(fieldtype(E, jj))
        inner = Expr(:block)
        for ff in 1:fieldcount(ET)
            push!(inner.args, quote
                if f == $ff
                    val, pos = $(makevalueexpr(fieldtype(ET, ff)))
                    @inbounds evals[$jj][$ff] = val
                    return pos
                end
            end)
        end
        push!(ex.args, :(if j == $jj; $inner; end))
    end
    push!(ex.args, :(return nothing))
    return ex
end

newextvals(::Type{Any}) = ()

@generated function newextvals(::Type{E}) where {E}
    t = Expr(:tuple)
    for j in 1:fieldcount(E)
        ET = Base.nonnothingtype(fieldtype(E, j))
        push!(t.args, :(newslots($(fieldcount(ET)))))
    end
    return t
end

@generated function constructext(::Type{ET}, vals) where {ET}
    n = fieldcount(ET)
    anyset = foldl((a, i) -> :($a || isassigned(vals, $i)), 1:n; init = false)
    args = Any[:(getval(vals, ET, $i, $(fieldtype(ET, i)))) for i in 1:n]
    return :($anyset ? ET($(args...)) : nothing)
end

constructexts(::Type{Any}, evals) = nothing

@generated function constructexts(::Type{E}, evals) where {E}
    t = Expr(:tuple)
    for j in 1:fieldcount(E)
        ET = Base.nonnothingtype(fieldtype(E, j))
        push!(t.args, :(constructext($ET, evals[$j])))
    end
    return :(E($t))
end

struct PropSink{P,E,S,Tail,EV}
    vals::Slots
    evals::EV
    style::S
    tail::Tail
end

(f::PropSink{P,E})(k::Integer, v) where {P,E} = _notobject(P)

function (f::PropSink{P,E})(k, v) where {P,E}
    i = keyindex(P, k)
    i != 0 && return makefield!(f.vals, f.style, P, i, v)
    j, ff = extkeyindex(E, k)
    j != 0 && return makeextfield!(f.evals, f.style, E, j, ff, v)
    return tailstore!(f.tail, f.style, k, v)
end

function makeproperties(style, ::Type{Properties{M}}, ::Type{E}, src) where {M,E}
    vals = newslots(fieldcount(Properties))
    evals = newextvals(E)
    tail = newtail(M)
    sink = PropSink{Properties{M},E,typeof(style),typeof(tail),typeof(evals)}(vals, evals, style, tail)
    pos = StructUtils.applyeach(style, sink, src)
    return construct(Properties{M}, vals, wraptail(M, tail)), constructexts(E, evals), pos::Int
end

# ---------------------------------------------------------------------------
# Item: `properties` fills two slots, everything unnamed falls to the tail.

const PROPERTIES_SLOT = findfirst(==(:properties), fieldnames(Item))::Int
const EXTENSIONS_SLOT = findfirst(==(:extensions), fieldnames(Item))::Int

struct ItemSink{I,S,Tail}
    vals::Slots
    style::S
    tail::Tail
end

(f::ItemSink{Item{E,G,M}})(k::Integer, v) where {E,G,M} = _notobject(Item{E,G,M})

function (f::ItemSink{Item{E,G,M}})(k, v) where {E,G,M}
    k == "type" && return nothing
    if k == "properties"
        props, exts, pos = makeproperties(f.style, Properties{M}, E, v)
        @inbounds f.vals[PROPERTIES_SLOT] = props
        @inbounds f.vals[EXTENSIONS_SLOT] = exts
        return pos
    end
    i = keyindex(Item{E,G,M}, k)
    i == 0 && return tailstore!(f.tail, f.style, k, v)
    return makefield!(f.vals, f.style, Item{E,G,M}, i, v)
end

function StructUtils.make(style::StructUtils.StructStyle, ::Type{Item{E,G,M}},
                          src::JSON.LazyValue) where {E,G,M}
    I = Item{E,G,M}
    vals = newslots(fieldcount(I))
    tail = newtail(M)
    pos = StructUtils.applyeach(style, ItemSink{I,typeof(style),typeof(tail)}(vals, style, tail), src)
    exts = getval(vals, I, EXTENSIONS_SLOT, E)
    return construct(I, vals, exts, wraptail(M, tail), nothing), pos::Int
end

# ---------------------------------------------------------------------------
# Geometry, discriminated by the nested "type" key. Any union of GeoJSON.jl geometries is a
# subtype of `GeoJSON.AbstractGeometry`, so one method covers every declared combination;
# `null` is peeled by StructUtils before this runs.

struct GeomTypeSink{S}
    style::S
end

(f::GeomTypeSink)(k::Integer, v) = _notobject(GeoJSON.AbstractGeometry)

function (f::GeomTypeSink)(k, v)
    k == "type" || return nothing
    s, _ = StructUtils.make(f.style, String, v)
    return StructUtils.EarlyReturn(s)
end

@noinline _notageometry() = throw(ArgumentError("geometry object has no \"type\" key"))

function geometrytypename(style, src)
    ret = StructUtils.applyeach(style, GeomTypeSink(style), src)
    ret isa StructUtils.EarlyReturn || _notageometry()
    return ret.value::String
end

@generated function makegeometry(style, ::Type{U}, src, t::String) where {U}
    ex = Expr(:block)
    for C in Base.uniontypes(U)
        push!(ex.args, :(t == $(String(nameof(C))) && return StructUtils.make(style, $C, src)))
    end
    push!(ex.args, :(throw(ArgumentError("geometry type " * t * " is not in " * $(string(U))))))
    return ex
end

# Both arities, as `@choosetype` emits: the three-argument form is what StructUtils calls
# after peeling `Nothing`.
function StructUtils.make(style::StructUtils.StructStyle, ::Type{U},
                          src::JSON.LazyValue) where {U<:GeoJSON.AbstractGeometry}
    isconcretetype(U) && return @invoke StructUtils.make(style::StructUtils.StructStyle, U::Type{U}, src::Any)
    return makegeometry(style, U, src, geometrytypename(style, src))
end

StructUtils.make(style::StructUtils.StructStyle, ::Type{U}, src::JSON.LazyValue, tags) where {U<:GeoJSON.AbstractGeometry} =
    StructUtils.make(style, U, src)

# ---------------------------------------------------------------------------
# bbox: 4 or 6 numbers, decided by count.

const BBox = Union{NTuple{4,Float64},NTuple{6,Float64}}

mutable struct BBoxAcc
    n::Int
    x1::Float64
    x2::Float64
    x3::Float64
    x4::Float64
    x5::Float64
    x6::Float64
    BBoxAcc() = new(0, 0, 0, 0, 0, 0, 0)
end

@noinline _badbbox(n) = throw(ArgumentError("bbox must have 4 or 6 numbers, got " * string(n)))

struct BBoxSink{S}
    acc::BBoxAcc
    style::S
end

(f::BBoxSink)(i, v) = _badbbox(0)

function (f::BBoxSink)(i::Int, v)
    x, p = StructUtils.make(f.style, Float64, v)
    i <= 6 || _badbbox(i)
    setfield!(f.acc, i + 1, x)
    f.acc.n = i
    return p
end

function StructUtils.make(style::StructUtils.StructStyle, ::Type{BBox}, src::JSON.LazyValue)
    acc = BBoxAcc()
    pos = StructUtils.applyeach(style, BBoxSink(acc, style), src)
    n = acc.n
    if n == 4
        return (acc.x1, acc.x2, acc.x3, acc.x4), pos::Int
    elseif n == 6
        return (acc.x1, acc.x2, acc.x3, acc.x4, acc.x5, acc.x6), pos::Int
    else
        _badbbox(n)
    end
end

StructUtils.make(style::StructUtils.StructStyle, ::Type{BBox}, src::JSON.LazyValue, tags) =
    StructUtils.make(style, BBox, src)
