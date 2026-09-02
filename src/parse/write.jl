# The writer is the inverse of the sink routing: `lower` builds one ordered `JSON.Object` per
# STAC type, putting `type` and `stac_version` back, re-prefixing the extension fields into
# `properties`, and appending the metadata tail in document order.

# Emitted from the struct or the tail's first three keys, so the tail must not repeat them.
const RESTORED_KEYS = ("type", "stac_version", "stac_extensions")

taildict(m::Metadata) = m.data
taildict(::NoMetadata) = ()

@inline function putif!(o::JSON.Object{String,Any}, key::String, value)
    value === nothing || (o[key] = value)
    return o
end

function appendtail!(o::JSON.Object{String,Any}, tail)
    for (k, v) in taildict(tail)
        k in RESTORED_KEYS && continue
        o[k] = v
    end
    return o
end

# `version = STAC_VERSION` restores the key on the object kinds the spec requires it on;
# `version = nothing` writes one back only when the producer sent one, which is how an
# ItemCollection (a plain GeoJSON FeatureCollection) behaves.
function preamble!(o::JSON.Object{String,Any}, typename::String, tail, version = STAC_VERSION)
    o["type"] = typename
    putif!(o, "stac_version", something(get(tail, "stac_version", nothing), version, Some(nothing)))
    putif!(o, "stac_extensions", get(tail, "stac_extensions", nothing))
    return o
end

lowervalue(x) = x
lowervalue(dt::DateTime) = format_rfc3339(dt)
lowervalue(v::Vector{DateTime}) = map(format_rfc3339, v)

StructUtils.lower(::STACStyle, dt::DateTime) = format_rfc3339(dt)

function StructUtils.lower(::STACStyle, g::GeoJSON.AbstractGeometry)
    o = JSON.Object{String,Any}()
    o["type"] = String(nameof(typeof(g)))
    putif!(o, "bbox", getfield(g, :bbox))
    o["coordinates"] = getfield(g, :coordinates)
    return o
end
StructUtils.lower(::STACStyle, m::Metadata) = m.data
StructUtils.lower(::STACStyle, ::NoMetadata) = JSON.Object{String,Any}()

function StructUtils.lower(::STACStyle, l::Link)
    o = JSON.Object{String,Any}()
    o["href"] = l.href
    o["rel"] = l.rel
    putif!(o, "type", l.type)
    putif!(o, "title", l.title)
    putif!(o, "method", l.method)
    putif!(o, "headers", l.headers)
    putif!(o, "body", l.body)
    putif!(o, "merge", l.merge)
    return appendtail!(o, l.metadata)
end

function StructUtils.lower(::STACStyle, a::Asset)
    o = JSON.Object{String,Any}()
    o["href"] = a.href
    putif!(o, "type", a.type)
    putif!(o, "title", a.title)
    putif!(o, "description", a.description)
    putif!(o, "roles", a.roles)
    putif!(o, "bands", a.bands)
    return appendtail!(o, a.metadata)
end

function StructUtils.lower(::STACStyle, b::Band)
    o = JSON.Object{String,Any}()
    putif!(o, "name", b.name)
    putif!(o, "description", b.description)
    putif!(o, "data_type", b.data_type)
    putif!(o, "unit", b.unit)
    return appendtail!(o, b.metadata)
end

function StructUtils.lower(::STACStyle, p::Provider)
    o = JSON.Object{String,Any}()
    o["name"] = p.name
    putif!(o, "description", p.description)
    putif!(o, "roles", p.roles)
    putif!(o, "url", p.url)
    return appendtail!(o, p.metadata)
end

StructUtils.lower(::STACStyle, e::SpatialExtent) =
    appendtail!(JSON.Object{String,Any}("bbox" => e.bbox), e.metadata)

StructUtils.lower(::STACStyle, e::TemporalExtent) =
    appendtail!(JSON.Object{String,Any}("interval" =>
        [[t === nothing ? nothing : format_rfc3339(t) for t in iv] for iv in e.interval]),
        e.metadata)

StructUtils.lower(::STACStyle, e::CollectionExtent) =
    appendtail!(JSON.Object{String,Any}("spatial" => e.spatial, "temporal" => e.temporal),
                e.metadata)

# One field per extension struct, written back under `prefix:name`.
@generated function putextensions!(o::JSON.Object{String,Any}, exts::E) where {E}
    ex = Expr(:block)
    for j in 1:fieldcount(E)
        p = String(fieldname(E, j))
        ET = Base.nonnothingtype(fieldtype(E, j))
        inner = Expr(:block)
        for f in 1:fieldcount(ET)
            key = p * ":" * String(fieldname(ET, f))
            push!(inner.args, :(putif!(o, $key, lowervalue(getfield(e, $f)))))
        end
        push!(ex.args, quote
            let e = getfield(exts, $j)
                if e !== nothing
                    $inner
                end
            end
        end)
    end
    push!(ex.args, :(return o))
    return ex
end

putextensions!(o::JSON.Object{String,Any}, ::Nothing) = o

function lowerproperties(p::Properties, exts)
    o = JSON.Object{String,Any}()
    # `datetime: null` is meaningful: the spec allows it when start_datetime and
    # end_datetime carry the range instead.
    o["datetime"] = p.datetime === nothing ? nothing : format_rfc3339(p.datetime)
    putif!(o, "start_datetime", lowervalue(p.start_datetime))
    putif!(o, "end_datetime", lowervalue(p.end_datetime))
    putif!(o, "created", lowervalue(p.created))
    putif!(o, "updated", lowervalue(p.updated))
    putif!(o, "title", p.title)
    putif!(o, "description", p.description)
    putif!(o, "platform", p.platform)
    putif!(o, "instruments", p.instruments)
    putif!(o, "constellation", p.constellation)
    putif!(o, "mission", p.mission)
    putif!(o, "gsd", p.gsd)
    putif!(o, "license", p.license)
    putif!(o, "providers", p.providers)
    putif!(o, "keywords", p.keywords)
    putif!(o, "bands", p.bands)
    putextensions!(o, exts)
    return appendtail!(o, p.other)
end

function StructUtils.lower(::STACStyle, item::Item)
    o = JSON.Object{String,Any}()
    preamble!(o, "Feature", item.metadata)
    o["id"] = item.id
    # `geometry: null` is meaningful: the spec uses it for items with no footprint.
    o["geometry"] = item.geometry
    putif!(o, "bbox", item.bbox === nothing ? nothing : collect(item.bbox))
    o["properties"] = lowerproperties(item.properties, item.extensions)
    o["links"] = item.links
    o["assets"] = item.assets
    putif!(o, "collection", item.collection)
    return appendtail!(o, item.metadata)
end

function StructUtils.lower(::STACStyle, cat::Catalog)
    o = JSON.Object{String,Any}()
    preamble!(o, "Catalog", cat.metadata)
    o["id"] = cat.id
    putif!(o, "title", cat.title)
    o["description"] = cat.description
    o["links"] = cat.links
    return appendtail!(o, cat.metadata)
end

function StructUtils.lower(::STACStyle, col::Collection)
    o = JSON.Object{String,Any}()
    preamble!(o, "Collection", col.metadata)
    o["id"] = col.id
    putif!(o, "title", col.title)
    o["description"] = col.description
    o["license"] = col.license
    o["extent"] = col.extent
    putif!(o, "keywords", col.keywords)
    putif!(o, "providers", col.providers)
    putif!(o, "summaries", col.summaries)
    putif!(o, "assets", col.assets)
    o["links"] = col.links
    return appendtail!(o, col.metadata)
end

function StructUtils.lower(::STACStyle, fc::ItemCollection)
    o = JSON.Object{String,Any}()
    preamble!(o, "FeatureCollection", fc.metadata, nothing)
    o["features"] = fc.features
    o["links"] = fc.links
    putif!(o, "numberMatched", fc.numberMatched)
    putif!(o, "numberReturned", fc.numberReturned)
    return appendtail!(o, fc.metadata)
end

"""
    STAC.json(obj; kw...) -> String
    STAC.json(io, obj; kw...)

`obj` as a STAC JSON document. `type` and `stac_version` are put back, declared extensions
are written under their prefixes inside `properties`, and every key the parse kept in a
metadata tail returns in the order the producer wrote it.

Keywords are JSON.jl's, so `pretty = 2` gives an indented document.
"""
json(obj; kw...) = JSON.json(obj; style = STACStyle(), kw...)
json(io::IO, obj; kw...) = JSON.json(io, obj; style = STACStyle(), kw...)
