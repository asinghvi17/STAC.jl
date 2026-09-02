# How the objects print. Two forms each: the one-line `show` a vector element gets, and the
# `text/plain` block a REPL session gets, which is the one meant to answer "what is this?"
# without a field-by-field dump.

const LABEL_WIDTH = 12
const SHOWN_KEYS = 3          # keys, asset names, and extension fields listed before the ellipsis

showline(io::IO, label::AbstractString) = print(io, "\n  ", rpad(label, LABEL_WIDTH))

function showline(io::IO, label::AbstractString, value)
    showline(io, label)
    print(io, value)
end

"""
    STAC.prefixes(::Type{<:Item}) -> Tuple{Vararg{Symbol}}

The extension prefixes an item type parses eagerly, which is what its type line shows in
place of the three type parameters. An item with `extensions = ()` has none.
"""
prefixes(::Type{Item{E,G,M}}) where {E,G,M} = E <: NamedTuple ? fieldnames(E) : ()
prefixes(item::Item) = prefixes(typeof(item))

function showtypename(io::IO, name::AbstractString, prefixes)
    print(io, name)
    isempty(prefixes) || print(io, "{", join(prefixes, ", "), "}")
    return nothing
end

# "a, b, c, … (7)": the head of a list, with the full count when it was cut short.
function summarylist(values, n = SHOWN_KEYS)
    total = length(values)
    head = join(Iterators.take(values, n), ", ")
    return total > n ? string(head, ", … (", total, ")") : head
end

datetimestring(dt::DateTime) = format_rfc3339(dt)
datetimestring(::Nothing) = "none"

# The instant, or the span an item with `datetime: null` carries instead.
function itemdatetime(p::Properties)
    p.datetime === nothing || return format_rfc3339(p.datetime)
    (p.start_datetime === nothing && p.end_datetime === nothing) && return nothing
    return string(datetimestring(p.start_datetime), " … ", datetimestring(p.end_datetime))
end

# A long vector is cut down: an extension summary is a glance at the item, not its transform.
showvalue(v::AbstractVector) =
    length(v) > SHOWN_KEYS ?
    string("[", join(Iterators.take(v, SHOWN_KEYS), ", "), ", … (", length(v), ")]") : repr(v)
showvalue(v) = repr(v)

boundsstring(b) = string("(", join((round(x; digits = 4) for x in b), ", "), ")")

# `GeoJSON.Polygon{2, Float64}` without the module qualifier, which is how the docs spell it.
typename(::Type{T}) where {T} = replace(string(T), r"^[A-Za-z0-9_.]+\." => "")

function geometrysummary(item::Item)
    geom = item.geometry
    parts = geom === nothing ? "no geometry" :
            string(typename(typeof(geom)), " (", GI.npoint(geom), " vertices)")
    item.bbox === nothing && return parts
    return string(parts, ", bbox ", boundsstring(item.bbox))
end

# "eo (cloud_cover = 1.2)  proj (code = "EPSG:32659")": each extension the item carries, with
# the fields it actually set.
function extensionsummary(exts::NamedTuple)
    parts = String[]
    for name in keys(exts)
        e = getfield(exts, name)
        e === nothing && continue
        set = ["$(f) = $(showvalue(getfield(e, f)))" for f in fieldnames(typeof(e))
               if getfield(e, f) !== nothing]
        push!(parts, string(name, " (", summarylist(set), ")"))
    end
    return isempty(parts) ? nothing : join(parts, "  ")
end

extensionsummary(::Any) = nothing

function metadatasummary(tail)
    n = length(tail)
    n == 0 && return nothing
    return string(n, n == 1 ? " key: " : " keys: ", summarylist(repr(k) for k in keys(tail)))
end

# "root, child ×2, item ×3": what a traversal has to work with, without listing every href.
function linksummary(links::Vector{Link})
    isempty(links) && return "none"
    counts = OrderedDict{String,Int}()
    for l in links
        counts[l.rel] = get(counts, l.rel, 0) + 1
    end
    return join((n == 1 ? rel : string(rel, " ×", n) for (rel, n) in counts), ", ")
end

# ---------------------------------------------------------------------------------------
# Item

function Base.show(io::IO, item::Item)
    showtypename(io, "Item", prefixes(item))
    print(io, " ", repr(item.id))
    dt = item.properties.datetime
    dt === nothing || print(io, " ", Dates.format(dt, dateformat"yyyy-mm-dd"))
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", item::Item)
    show(io, item)
    dt = itemdatetime(item.properties)
    dt === nothing || showline(io, "datetime", dt)
    item.collection === nothing || showline(io, "collection", item.collection)
    showline(io, "geometry", geometrysummary(item))
    isempty(item.assets) || showline(io, "assets", summarylist(keys(item.assets), 4))
    exts = extensionsummary(item.extensions)
    exts === nothing || showline(io, "extensions", exts)
    meta = metadatasummary(item.metadata)
    meta === nothing || showline(io, "metadata", meta)
    return nothing
end

# ---------------------------------------------------------------------------------------
# Catalog and Collection

function Base.show(io::IO, cat::Union{Catalog,Collection})
    print(io, nameof(typeof(cat)), " ", repr(cat.id))
    cat.title === nothing || print(io, " — ", cat.title)
    return nothing
end

function showtail(io::IO, obj)
    showline(io, "links", linksummary(obj.links))
    meta = metadatasummary(obj.metadata)
    meta === nothing || showline(io, "metadata", meta)
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", cat::Catalog)
    show(io, cat)
    showtail(io, cat)
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", col::Collection)
    show(io, col)
    showline(io, "extent", extentsummary(col.extent))
    showline(io, "license", col.license)
    showtail(io, col)
    return nothing
end

function extentsummary(extent::CollectionExtent)
    parts = String[]
    b = isempty(extent.spatial.bbox) ? nothing : first(extent.spatial.bbox)
    b === nothing || push!(parts, string("bbox ", boundsstring(b)))
    iv = isempty(extent.temporal.interval) ? nothing : first(extent.temporal.interval)
    iv === nothing || push!(parts, string(datetimestring(iv[1]), " … ",
                                          datetimestring(length(iv) > 1 ? iv[2] : nothing)))
    return isempty(parts) ? "none" : join(parts, "  ")
end

# ---------------------------------------------------------------------------------------
# ItemCollection

function Base.show(io::IO, fc::ItemCollection)
    showtypename(io, "ItemCollection", prefixes(eltype(fc.features)))
    print(io, " with ", length(fc.features), " items")
    fc.numberMatched === nothing || print(io, " of ", fc.numberMatched, " matched")
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", fc::ItemCollection)
    show(io, fc)
    isempty(fc.features) || showline(io, "items", summarylist((i.id for i in fc.features), 4))
    showtail(io, fc)
    return nothing
end

# ---------------------------------------------------------------------------------------
# SpatialIndex

function Base.show(io::IO, idx::SpatialIndex)
    print(io, "SpatialIndex(", nameof(typeof(idx.manifold)), "()) over ",
          length(idx.items), " items")
    idx.tree === nothing && print(io, ", none of them located")
    return nothing
end

# ---------------------------------------------------------------------------------------
# Client and searches. Neither form fetches anything: printing a search must not run it.

function Base.show(io::IO, client::Client)
    print(io, "Client ", repr(client.url))
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", client::Client)
    show(io, client)
    showline(io, "root", string(repr(client.root.id),
                                client.root.title === nothing ? "" : " — " * client.root.title))
    showline(io, "conforms", string(length(client.conformsTo), " classes"))
    showline(io, "host", string("limit ≤ ", client.host.max_limit, ", default ",
                                client.host.default_limit,
                                client.host.reports_matched ? ", reports numberMatched" :
                                ", no numberMatched"))
    return nothing
end

function Base.show(io::IO, s::APIItemSearch)
    print(io, "APIItemSearch ", s.method, " ", s.href)
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", s::APIItemSearch)
    show(io, s)
    s.body === nothing || showline(io, "body", JSON.json(s.body; style = STACStyle()))
    showline(io, "items")
    showtypename(io, "Item", prefixes(eltype(typeof(s))))
    return nothing
end

function Base.show(io::IO, s::StaticItemSearch)
    print(io, "StaticItemSearch over ")
    show(io, s.root)
    return nothing
end

function Base.show(io::IO, ::MIME"text/plain", s::StaticItemSearch)
    show(io, s)
    s.collections === nothing || showline(io, "collections", join(s.collections, ", "))
    s.ids === nothing || showline(io, "ids", summarylist(s.ids))
    s.interval == (nothing, nothing) ||
        showline(io, "datetime", string(datetimestring(s.interval[1]), " … ",
                                        datetimestring(s.interval[2])))
    s.spatial === nothing || showline(io, "intersects", s.spatial)
    showline(io, "limit", s.limit)
    # The walk runs on the first page asked for, so a search that has not been iterated
    # reports what it will do rather than what it found.
    showline(io, "matched", s.cache === nothing ? "not run yet" : length(s.cache))
    return nothing
end
