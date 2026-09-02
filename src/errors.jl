# Every exception the package raises. Each type carries the values its message names, so a
# caller can branch on `e.rel` or `e.class` rather than on message text.
#
# Two rules keep these off the code a `--trim=safe` program carries: a throw site stays a
# `@noinline` helper that only builds the struct, and a `showerror` prints its fields one
# argument at a time rather than interpolating them into a string.

"""
    STAC.STACError

Supertype of every exception this package raises, so one `catch` clause covers the package.

| Group | Raised when |
|---|---|
| [`STAC.DocumentError`](@ref) | a document is not the STAC the call expected |
| [`STAC.LookupError`](@ref) | a link, key, column, or extension the call needs is absent |
| [`STAC.ArgumentShapeError`](@ref) | an argument has the wrong type or the wrong number of values |
| [`STAC.EndpointError`](@ref) | an endpoint does not offer what the call needs |

```julia
try
    STAC.resolve("./item.json", nothing)
catch e
    e isa STAC.STACError || rethrow()   # true: it is a `STAC.NoOrigin`
    @warn "cannot resolve" exception = e
end
```
"""
abstract type STACError <: Exception end

"""
    STAC.DocumentError

The document differs from the one the call expected: a `type` key naming something else, a
required field the producer left out, or a value the spec's grammar rejects.
"""
abstract type DocumentError <: STACError end

"""
    STAC.LookupError

A link with a given `rel`, a `collections` array, a table column, or an extension's keys —
something the call needed to reach is absent from the object it looked in.
"""
abstract type LookupError <: STACError end

"""
    STAC.ArgumentShapeError

An argument has the wrong type or the wrong number of values — a `datetime` interval of one
instant, a bbox of five numbers, a spatial argument that is no geometry.
"""
abstract type ArgumentShapeError <: STACError end

"""
    STAC.EndpointError

The endpoint does not offer what the call needs: a conformance class it never advertised, a
scheme the IO stack has no route for, a method a transport cannot make.
"""
abstract type EndpointError <: STACError end

# ---------------------------------------------------------------------------------------
# Documents

"""
    STAC.NotSTACDocument(type)

The document's `type` key names something other than the four STAC document kinds, or the
document carries no `type` key at all (`type === nothing`).
"""
struct NotSTACDocument <: DocumentError
    type::Union{String,Nothing}
end

function Base.showerror(io::IO, e::NotSTACDocument)
    print(io, "not a STAC document: ")
    if e.type === nothing
        print(io, "no `type` key")
    else
        print(io, "`type` is \"", e.type, "\", expected \"Feature\", \"FeatureCollection\", ",
              "\"Catalog\", or \"Collection\"")
    end
    return nothing
end

"""
    STAC.WrongDocumentType(expected, got)

A link led to a document of the wrong kind: an `item` link to a catalog, a `child` link to an
item. Both fields are type names.
"""
struct WrongDocumentType <: DocumentError
    expected::String
    got::String
end

Base.showerror(io::IO, e::WrongDocumentType) =
    print(io, "expected a ", e.expected, ", got a ", e.got)

"""
    STAC.WrongJSONType(expected, target)

A JSON value of the wrong kind where a struct or a vector was being built: `expected` is
`:object` or `:array`, and `target` names the type the parse was filling.
"""
struct WrongJSONType <: DocumentError
    expected::Symbol
    target::String
end

Base.showerror(io::IO, e::WrongJSONType) =
    print(io, "expected a JSON ", e.expected, " for ", e.target)

"""
    STAC.MissingField(type, field)

A field the spec requires is absent from the document and the struct has no `nothing` to put
there.
"""
struct MissingField <: DocumentError
    type::String
    field::Symbol
end

Base.showerror(io::IO, e::MissingField) =
    print(io, "missing required field ", e.field, " for ", e.type)

"""
    STAC.UnknownGeometryType(type, allowed)

A geometry the declared `geometry =` union has no member for, or one carrying no `type` key
at all (`type === nothing`). `allowed` is the union the parse was told to build.
"""
struct UnknownGeometryType <: DocumentError
    type::Union{String,Nothing}
    allowed::String
end

function Base.showerror(io::IO, e::UnknownGeometryType)
    if e.type === nothing
        print(io, "geometry object has no \"type\" key; expected one of ", e.allowed)
    else
        print(io, "geometry type ", e.type, " is not in ", e.allowed)
    end
    return nothing
end

"""
    STAC.BadDateTime(value)

A date-time string RFC 3339 rejects, from a document's `datetime` or from a `datetime =`
argument.
"""
struct BadDateTime <: DocumentError
    value::String
end

Base.showerror(io::IO, e::BadDateTime) =
    print(io, "invalid RFC 3339 date-time: ", e.value)

"""
    STAC.MissingCollections(href)

The document a `data` link points at carries no `collections` array, so
[`collections`](@ref) has nothing to read.
"""
struct MissingCollections <: DocumentError
    href::String
end

Base.showerror(io::IO, e::MissingCollections) =
    print(io, "the document at ", e.href, " has no `collections` array")

# ---------------------------------------------------------------------------------------
# Lookups

"""
    STAC.MissingLink(url, rel)

The landing page of `url` publishes no link with this `rel`, so the call has nothing to
fetch.
"""
struct MissingLink <: LookupError
    url::String
    rel::String
end

Base.showerror(io::IO, e::MissingLink) =
    print(io, "the landing page of ", e.url, " has no `", e.rel,
          "` link, so this call has nothing to fetch")

"""
    STAC.NoOrigin(href)

A relative href with no base to resolve against, which is what an object built in memory
rather than read from somewhere gives its links.
"""
struct NoOrigin <: LookupError
    href::String
end

Base.showerror(io::IO, e::NoOrigin) =
    print(io, "cannot resolve the relative href \"", e.href,
          "\": the object it came from has no origin. Read it from a path or a URL, or set ",
          "one with `STAC.sethref`.")

"""
    STAC.MissingExtension(extension, prefix, object)

The object carries none of the extension's `prefix:` keys, so `T(obj)` has no struct to
build. `get(obj, T)` reports the same absence as `nothing`.
"""
struct MissingExtension <: LookupError
    extension::String
    prefix::String
    object::String
end

Base.showerror(io::IO, e::MissingExtension) =
    print(io, "this ", e.object, " carries no `", e.prefix, ":` keys, so it has no ",
          e.extension, ". `get(obj, ", e.extension, ")` reports that as `nothing`.")

"""
    STAC.MissingColumn(name)

A column name no item in the table carries. The column list of an item table comes from the
items themselves, so a producer key one page uses may be absent from the next.
"""
struct MissingColumn <: LookupError
    name::Symbol
end

Base.showerror(io::IO, e::MissingColumn) =
    print(io, "no column named :", e.name, " in this item table")

# ---------------------------------------------------------------------------------------
# Argument shapes

"""
    STAC.NotAGeometry(got)

An `intersects =` argument that describes no place. `got` is the type that arrived.
"""
struct NotAGeometry <: ArgumentShapeError
    got::String
end

Base.showerror(io::IO, e::NotAGeometry) =
    print(io, "`intersects` takes a GeoInterface geometry, an `Extent`, or a bbox of 4 or 6 ",
          "numbers, not a ", e.got)

"""
    STAC.NotQueryable(got)

A [`STAC.query`](@ref) argument the index cannot turn into a box. `got` is the type that
arrived.
"""
struct NotQueryable <: ArgumentShapeError
    got::String
end

Base.showerror(io::IO, e::NotQueryable) =
    print(io, "cannot query a spatial index with a ", e.got,
          ": pass a GeoInterface geometry, an `Extents.Extent`, a bbox of 4 or 6 numbers, ",
          "or a `SphericalCap`")

"""
    STAC.BadBBox(n)

A bbox of `n` numbers, where a STAC bbox is four (west, south, east, north) or six with the
elevation interval in the middle.
"""
struct BadBBox <: ArgumentShapeError
    n::Int
end

Base.showerror(io::IO, e::BadBBox) =
    print(io, "a bbox is 4 or 6 numbers in longitude/latitude order, got ", e.n)

"""
    STAC.BadInterval(n)

A `datetime =` interval of `n` values, where an interval is a start and a stop.
"""
struct BadInterval <: ArgumentShapeError
    n::Int
end

Base.showerror(io::IO, e::BadInterval) =
    print(io, "a `datetime` interval is two values, got ", e.n)

"""
    STAC.EmptyPredicate(predicate)

A DE-9IM predicate wrapping no geometry, which is the `Within()` singleton rather than the
`Within(polygon)` a search compares against.
"""
struct EmptyPredicate <: ArgumentShapeError
    predicate::String
end

Base.showerror(io::IO, e::EmptyPredicate) =
    print(io, e.predicate, "() carries no geometry to compare against; wrap one, as in ",
          e.predicate, "(polygon)")

# ---------------------------------------------------------------------------------------
# Endpoints

"""
    STAC.NoConformance(url, class, argument, nclasses)

The endpoint's landing page lists `nclasses` conformance classes and `class` is not among
them, so `argument` cannot be answered. Raised at the call site, ahead of the request.
"""
struct NoConformance <: EndpointError
    url::String
    class::String
    argument::String
    nclasses::Int
end

Base.showerror(io::IO, e::NoConformance) =
    print(io, e.url, " does not advertise the conformance class `", e.class, "`, which ",
          e.argument, " needs. Its landing page lists ", e.nclasses, " classes.")

"""
    STAC.NoRoute(scheme, href)

A [`StreamRouterIO`](@ref STAC.StreamRouterIO) with no child for this href's scheme.
"""
struct NoRoute <: EndpointError
    scheme::String
    href::String
end

Base.showerror(io::IO, e::NoRoute) =
    print(io, "no route for scheme \"", e.scheme, "\" (", e.href,
          "). Build a `StreamRouterIO` with one, or load the bridge that adds it.")

"""
    STAC.MethodUnsupported(io, method)

A transport asked for a method it cannot make. `io` names the [`AbstractIO`](@ref
STAC.AbstractIO) type; a read-only one such as [`PathIO`](@ref STAC.PathIO) answers `GET`
alone.
"""
struct MethodUnsupported <: EndpointError
    io::String
    method::String
end

Base.showerror(io::IO, e::MethodUnsupported) =
    print(io, e.io, " answers GET only, not ", e.method)
