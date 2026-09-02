module STACRastersExt

# Rasters does the reading. What STAC adds is the three things Rasters cannot know: which
# file an asset means once its href is signed, which backend reads that file, and which GDAL
# options the fetch needs. `route` answers all three, and each method here is that answer
# handed to a Rasters constructor unchanged.
#
# ArchGDAL is a trigger of this extension beside Rasters, because both jobs need GDAL in the
# process: Rasters opens a GeoTIFF through ArchGDAL, and the credentials go to GDAL's virtual
# filesystem rather than to Rasters.

import ArchGDAL
import Dates
import NetworkOptions
import Rasters
import STAC
using Rasters: Ti
using STAC: Asset, Client, Item, Projection

# ---------------------------------------------------------------------------------------
# Credentials, per path prefix

"""
    STACRastersExt.APPLIED

The `(prefix, option, value)` triples already handed to GDAL. Setting one is a global side
effect, so each is set once; a rotated credential has a different value and is therefore a
different triple, which is what makes the memo safe.
"""
const APPLIED = Set{Tuple{String,String,String}}()

const APPLIED_LOCK = ReentrantLock()

"""
    STACRastersExt.certificates() -> Vector{Pair{String,String}}

The certificate store GDAL's curl should trust, as one `CURL_CA_BUNDLE` option holding
Julia's own CA roots. GDAL_jll ships a curl with no bundle compiled in, so a `/vsicurl/` fetch
on macOS otherwise ends in "unable to get local issuer certificate".

A `CURL_CA_BUNDLE` already in the environment is the caller's answer and is left alone.
"""
certificates() =
    haskey(ENV, "CURL_CA_BUNDLE") ? Pair{String,String}[] :
    Pair{String,String}["CURL_CA_BUNDLE" => NetworkOptions.ca_roots_path()]

"""
    STACRastersExt.apply_config!(route) -> route

`route`'s GDAL options, set against the bucket, container, or host prefix of its filename
rather than against the process. A token for one Planetary Computer container stays out of
every request to every other host.

A network route also gets the certificate store `certificates` names, and gets it first, so
that an option the route carries under the same name wins.

GDAL consults path-specific options for the `/vsis3/`, `/vsigs/`, and `/vsiaz/` credential
names and, from 3.7 on, for the `GDAL_HTTP_*` and curl names as well.
"""
function apply_config!(route)
    network = STAC.isvsinetwork(route.filename)
    (network || !isempty(route.config)) || return route
    prefix = STAC.vsi_prefix(route.filename)
    Base.lock(APPLIED_LOCK) do
        network && setoptions!(prefix, certificates())
        setoptions!(prefix, route.config)
    end
    return route
end

function setoptions!(prefix::String, options)
    for (name, value) in options
        triple = (prefix, name, value)
        triple in APPLIED && continue
        ArchGDAL.GDAL.vsisetpathspecificoption(prefix, name, value)
        push!(APPLIED, triple)
    end
    return nothing
end

"""
    STACRastersExt.opened(asset, io) -> (; filename, source, config)

`asset`'s route with its credentials already given to GDAL. A GeoJSON asset raises a
[`STAC.NotARasterAsset`](@ref), since [`STAC.read`](@ref) is what parses one.
"""
function opened(asset::Asset, io::STAC.AbstractIO)
    driver = STAC.driver(asset)
    driver isa STAC.GeoJSONDriver && STAC._notarasterasset(driver, asset)
    return apply_config!(STAC.route(driver, asset, io))
end

# ---------------------------------------------------------------------------------------
# One asset

"""
    Raster(asset::Asset; io = STAC.default_io(), kw...)
    Raster(client::Client, asset::Asset; kw...)

The pixels an [`Asset`](@ref) points at, opened through the driver its media type names and
the credentials `io` carries for its href. Every other keyword goes to
[`Rasters.Raster`](https://rafaqz.github.io/Rasters.jl/stable/api/#Rasters.Raster) as it
stands, `lazy = true` among them.

The `Client` form is the one to reach for on a credentialed endpoint: it opens the asset with
the same auth the search that found it ran under.

```julia
using STAC, Rasters, ArchGDAL

client = Client("https://planetarycomputer.microsoft.com/api/stac/v1";
                auth = PlanetaryComputerSAS())
item = first(search(client; collections = ["sentinel-2-l2a"], limit = 1))
red = Raster(client, STAC.asset(item, "B04"); lazy = true)
size(red)                       # (10980, 10980)
red[1000:1010, 1000:1010]       # one window, one range request
```

This is a method on Rasters.jl's `Raster`. [`STAC.Raster`](@ref) is a different thing — the
Raster extension's `raster:scale` and `raster:offset` — and stays unexported so that `Raster`
means Rasters.jl's in a session holding both.
"""
function Rasters.Raster(asset::Asset; io::STAC.AbstractIO = STAC.default_io(), kw...)
    r = opened(asset, io)
    return Rasters.Raster(r.filename; source = r.source, kw...)
end

Rasters.Raster(client::Client, asset::Asset; kw...) = Rasters.Raster(asset; io = client.io, kw...)

# ---------------------------------------------------------------------------------------
# Several assets of one item

"""
    STACRastersExt.projshape(item, asset) -> Union{Vector{Int},Nothing}

The `proj:shape` that applies to one asset: its own when it states one, and the item's
otherwise, which is where a producer puts the shape every asset shares.
"""
function projshape(item::Item, asset::Asset)
    own = get(asset, Projection)
    (own !== nothing && own.shape !== nothing) && return own.shape
    shared = get(item, Projection)
    return shared === nothing ? nothing : shared.shape
end

@noinline _mixedresolution(names, shapes) =
    throw(STAC.MixedResolution(names, shapes))

"""
    STACRastersExt.checkgrid(item, names, assets)

Raise a [`STAC.MixedResolution`](@ref) when the assets state `proj:shape`s that differ. An
asset that states none is left out of the comparison: an unstated shape is unknown, not
different.
"""
function checkgrid(item::Item, names::Vector{String}, assets::Vector{Asset})
    shapes = [projshape(item, a) for a in assets]
    known = findall(!isnothing, shapes)
    length(known) < 2 && return nothing
    allequal(shapes[i] for i in known) && return nothing
    return _mixedresolution(names[known],
                            [join(shapes[i], "×") for i in known])
end

"""
    RasterStack(item::Item, keys; io = STAC.default_io(), kw...)

The named assets of one [`Item`](@ref) as the layers of one stack, keyed as the item keys
them. `keys` is a vector or a tuple of strings or symbols.

Assets whose `proj:shape` differ raise a [`STAC.MixedResolution`](@ref) naming the keys and
their shapes: a 10 m band and a 20 m band share no grid, and which resampling brings them
onto one is a choice the data makes, not the stack.

```julia
using STAC, Rasters, ArchGDAL

client = Client("https://planetarycomputer.microsoft.com/api/stac/v1";
                auth = PlanetaryComputerSAS())
item = first(search(client; collections = ["sentinel-2-l2a"], limit = 1))
st = RasterStack(item, ["B04", "B03", "B02"]; io = client.io, lazy = true)
keys(st)                        # (:B04, :B03, :B02)
size(st)                        # (10980, 10980)
```
"""
# Two methods rather than one over `Any`, because `RasterStack(table, dims::Tuple)` is what a
# tuple of keys would otherwise be equally good a match for.
Rasters.RasterStack(item::Item, keys::AbstractVector; kw...) = stackof(item, keys; kw...)
Rasters.RasterStack(item::Item, keys::Tuple; kw...) = stackof(item, keys; kw...)

function stackof(item::Item, keys; io::STAC.AbstractIO = STAC.default_io(), kw...)
    names = String[String(k) for k in keys]
    assets = Asset[STAC.asset(item, k) for k in names]
    checkgrid(item, names, assets)
    routes = [opened(a, io) for a in assets]
    layers = NamedTuple{Tuple(Symbol.(names))}(Tuple(r.filename for r in routes))
    sources = [r.source for r in routes]
    common = allequal(sources) ? (; source = first(sources)) : (;)
    return Rasters.RasterStack(layers; common..., kw...)
end

# ---------------------------------------------------------------------------------------
# One asset across many items

@noinline _nodatetime(id) = throw(STAC.MissingDatetime(String(id)))

"""
    STACRastersExt.itemtime(item) -> DateTime

Where an item sits on a time axis: its `datetime`, or the start of its interval when it
covers a span instead.
"""
function itemtime(item::Item)
    t = item.properties.datetime
    t !== nothing && return t
    s = item.properties.start_datetime
    s === nothing && _nodatetime(item.id)
    return s
end

"""
    RasterSeries(items, key; io = STAC.default_io(), kw...)

One asset of every item, stacked along `Ti`, which carries each item's `datetime`. This is
what a search over a time window becomes once the pixels matter.

`Ti` holds the items in the order they arrive, which is the endpoint's, not sorted. Most
endpoints answer newest first, giving a descending axis that `Ti(a .. b)` selects on as well
as an ascending one; a search with no ordering at all gives an unordered axis, where `At` and
`Near` still work and a range does not. `sort!(items; by = i -> i.properties.datetime)` before
the call, or `sortby` on the search, is what makes the axis ordered.

An item that states neither `datetime` nor `start_datetime` raises a
[`STAC.MissingDatetime`](@ref) naming it.

```julia
using STAC, Rasters, ArchGDAL

client = Client("https://earth-search.aws.element84.com/v1")
found = collect(search(client; collections = ["sentinel-2-l2a"],
                       datetime = (DateTime(2024, 6, 1), DateTime(2024, 6, 5)), limit = 4))
series = RasterSeries(found, "red"; lazy = true)
dims(series, Ti)
```
"""
function Rasters.RasterSeries(items::AbstractVector{<:Item},
                              key::Union{AbstractString,Symbol};
                              io::STAC.AbstractIO = STAC.default_io(), kw...)
    times = Dates.DateTime[itemtime(i) for i in items]
    layers = [Rasters.Raster(STAC.asset(i, key); io, kw...) for i in items]
    return Rasters.RasterSeries(layers, Ti(times))
end

end # module STACRastersExt
