# The stack every call that takes no `io` uses, and the scoped value that holds it.

"""
    STAC.defaultstack() -> AbstractIO

A fresh copy of the stack [`STAC.default_io`](@ref) returns: an LRU cache over a scheme
router that sends `https` and `http` to an anonymous [`HTTPIO`](@ref STAC.HTTPIO) and
everything else to [`PathIO`](@ref STAC.PathIO).
"""
defaultstack() = CachingIO(StreamRouterIO(("https" => HTTPIO(), "http" => HTTPIO(),
                                           "" => PathIO(), "file" => PathIO())))

"""
    STAC.DEFAULT_IO

The `ScopedValue` holding the [`AbstractIO`](@ref STAC.AbstractIO) that
[`STAC.default_io`](@ref) returns. Rebind it for a block with [`STAC.with`](@ref).
"""
const DEFAULT_IO = ScopedValues.ScopedValue{AbstractIO}(defaultstack())

"""
    STAC.default_io() -> AbstractIO

The IO stack a call uses when the caller names none. Reading it is the one dynamic dispatch
in the fetch path; `read(io, href)` declares `Vector{UInt8}` on every method, so everything
below that call is inferred.
"""
default_io() = DEFAULT_IO[]

"""
    STAC.with(f, io::AbstractIO)

Run `f()` with `io` as [`STAC.default_io`](@ref).

```julia
STAC.with(CachingIO(StreamRouterIO(("https" => HTTPIO(BearerToken(tok)),)))) do
    STAC.read("https://example.com/catalog.json")
end
```
"""
with(f, io::AbstractIO) = ScopedValues.with(f, DEFAULT_IO => io)
