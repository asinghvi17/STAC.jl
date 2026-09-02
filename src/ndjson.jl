# Newline-delimited JSON: one STAC item per line, the interchange format for a corpus too
# large to hold as one FeatureCollection.

"""
    STAC.ItemLines{T}

The lazy iterator behind [`STAC.read_ndjson`](@ref). One line is read and parsed per
`iterate`, so a million-line file costs one line's work to look at its first item.

A file source opens a fresh handle per iteration, closed when the lines run out, so the same
`ItemLines` reads twice. A stream source picks up where the stream stands, that being what a
stream offers.
"""
struct ItemLines{T,S,O<:ParseOptions}
    source::S
    opts::O
end

ItemLines{T}(source::S, opts::O) where {T,S,O} = ItemLines{T,S,O}(source, opts)

Base.eltype(::Type{<:ItemLines{T}}) where {T} = T
Base.IteratorSize(::Type{<:ItemLines}) = Base.SizeUnknown()

# Owning the handle here is what keeps the reader `--trim=safe`: `eachline`'s `ondone` field
# is typed `Function`, so the close it makes at the end costs two verifier errors.
openlines(path::AbstractString) = (open(path), true)
openlines(io::IO) = (io, false)

# Blank lines are skipped rather than parsed: a corpus written by `cat`ting files together
# carries them, and every ndjson reader in the STAC ecosystem tolerates them.
function nextline(io::IO, owned::Bool)
    while !eof(io)
        line = readline(io)
        isempty(strip(line)) || return line
    end
    owned && close(io)
    return nothing
end

function advance(it::ItemLines{T}, io::IO, owned::Bool) where {T}
    line = nextline(io, owned)
    line === nothing && return nothing
    return readdoc(T, line, it.opts), (io, owned)
end

Base.iterate(it::ItemLines) = advance(it, openlines(it.source)...)

Base.iterate(it::ItemLines, state) = advance(it, state[1], state[2])

"""
    STAC.read_ndjson(path; extensions, geometry, metadata) -> STAC.ItemLines
    STAC.read_ndjson(io::IO; extensions, geometry, metadata)

The [`Item`](@ref)s of a newline-delimited JSON file, as a lazy iterator of one item per
line. The keywords are [`ParseOptions`](@ref)'s.

Nothing is read until an element is reached, so `first` costs one line and
`Iterators.take(items, 10)` costs ten.

| Source | Handle |
|---|---|
| a path | opened per iteration and closed when the lines run out, so the same iterator reads twice. An iteration abandoned part way leaves the handle to the garbage collector |
| an `IO` | yours: the iterator picks up where the stream stands and leaves it open |

```julia
items = STAC.read_ndjson("corpus.ndjson")
first(items).id                                 # one line read
sum(1 for _ in items)                           # the whole file, one line at a time
idx = spatialindex(collect(Iterators.take(items, 1000)))
```
"""
read_ndjson(path::AbstractString; kw...) = read_ndjson(path, ParseOptions(; kw...))

read_ndjson(path::AbstractString, opts::ParseOptions) =
    ItemLines{itemtype(opts)}(String(path), opts)

read_ndjson(io::IO; kw...) = read_ndjson(io, ParseOptions(; kw...))

read_ndjson(io::IO, opts::ParseOptions) = ItemLines{itemtype(opts)}(io, opts)

"""
    STAC.write_ndjson(path, items) -> Int
    STAC.write_ndjson(io::IO, items)

`items` as newline-delimited JSON, one [`STAC.json`](@ref) document per line, and the number
of lines written. `items` is anything iterable: a vector, a [`search`](@ref), or another
file's [`STAC.read_ndjson`](@ref), which streams one item at a time.

```julia
cat = STAC.read("test/fixtures/static/self-contained/catalog.json")
STAC.write_ndjson("items.ndjson", items(cat; recursive = true))    # 4
[i.id for i in STAC.read_ndjson("items.ndjson")]
```
"""
function write_ndjson(path::AbstractString, items)
    mkpath(dirname(abspath(path)))
    io = open(path, "w")
    try
        return write_ndjson(io, items)
    finally
        close(io)
    end
end

function write_ndjson(io::IO, items)
    n = 0
    for item in items
        json(io, item)
        print(io, '\n')
        n += 1
    end
    return n
end
