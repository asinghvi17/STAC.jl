# Publishing a catalog as a directory tree: where each document lands, and how the links
# between them are spelled once they have moved.

"""
    STAC.CATALOG_TYPE

The media type of a catalog or collection document, which is what the hierarchy links
[`STAC.write`](@ref) writes carry.
"""
const CATALOG_TYPE = "application/json"

"""
    STAC.ITEM_TYPE

The media type of an item document. An `item` link gets this rather than
[`STAC.CATALOG_TYPE`](@ref): an item is a GeoJSON Feature, and the best-practices document
asks producers to say so.
"""
const ITEM_TYPE = "application/geo+json"

# Rewritten from the tree the walk builds. Every other `rel` is the producer's own and is
# carried over with its href made absolute.
const HIERARCHY_RELS = ("self", "root", "parent", "child", "item", "collection")

@noinline _badoption(option, value, allowed) =
    throw(BadOption(String(option), String(value), allowed))

@noinline _noroothref(links) = throw(MissingRootHref(String(links)))

const LINK_STYLES = (:self_contained, :relative_published, :absolute_published)

const LAYOUTS = (:best, :keep)

"""
    STAC.hrefdir(href) -> String

Everything up to and including the last `/` of `href`: the directory a relative link beside
it resolves against. An href with no `/` gives `""`.
"""
function hrefdir(href::AbstractString)
    i = findlast('/', href)
    return i === nothing ? "" : String(SubString(href, 1, i))
end

"""
    STAC.relativepath(to, fromdir) -> String

The `/`-separated path from directory `fromdir` to the document `to`, both relative to the
same root, with `../` for each level climbed. The result is spelled as a relative link:
`"./item.json"` for a sibling, `"../catalog.json"` for the level above.

```jldoctest
julia> STAC.relativepath("catalog.json", "simple-collection")
"../catalog.json"

julia> STAC.relativepath("simple-collection/simple-item.json", "simple-collection")
"./simple-item.json"
```
"""
function relativepath(to::AbstractString, fromdir::AbstractString)
    isempty(fromdir) && return "./" * to
    a = split(fromdir, '/')
    b = split(to, '/')
    i = 1
    while i <= length(a) && i < length(b) && a[i] == b[i]
        i += 1
    end
    up = length(a) - i + 1
    rel = join(Iterators.flatten((Iterators.repeated("..", up), @view b[i:end])), "/")
    return startswith(rel, "..") ? rel : "./" * rel
end

"""
    STAC.parentdir(path) -> String

The directory of a `/`-separated relative path, `""` for a document at the top of the tree.
"""
function parentdir(path::AbstractString)
    i = findlast('/', path)
    return i === nothing ? "" : String(SubString(path, 1, prevind(path, i)))
end

"""
    STAC.documentname(obj) -> String

The file name the best-practices layout gives a document: `catalog.json`,
`collection.json`, or `<item-id>.json`.
"""
documentname(::Catalog) = "catalog.json"
documentname(::Collection) = "collection.json"
documentname(obj::Item) = obj.id * ".json"
documentname(obj::ItemCollection) = "itemcollection.json"

joinrel(dir::AbstractString, name::AbstractString) = isempty(dir) ? name : dir * "/" * name

"""
    STAC.bestpath(obj, parentdir, isroot) -> String

Where the STAC best-practices layout puts `obj` under a parent directory: a catalog or
collection in a directory named after its id, an item in a directory of its own beside its
own name.

| `obj` | Path |
|---|---|
| the root of the tree | `catalog.json`, `collection.json`, or `<id>.json` |
| a child catalog or collection | `<parentdir>/<id>/catalog.json`, `…/collection.json` |
| an item | `<parentdir>/<id>/<id>.json` |
"""
bestpath(obj::STACObject, dir::AbstractString, isroot::Bool) =
    isroot ? documentname(obj) : joinrel(joinrel(dir, obj.id), documentname(obj))

struct Publisher{L,I<:AbstractIO,O<:ParseOptions}
    dir::String
    layout::L
    links::Symbol
    root_href::Union{String,Nothing}
    origin::Union{String,Nothing}
    io::I
    opts::O
    seen::Set{String}
end

# `:keep` reproduces the tree the objects were read from, which needs both an origin for the
# object and one for the root to measure it against; anything else falls to `:best`.
function placement(p::Publisher, obj::STACObject, dir::AbstractString, isroot::Bool = false)
    p.layout === :best && return bestpath(obj, dir, isroot)
    # A leading separator would put the document at the filesystem root rather than under
    # `dest`, which is never what a layout function means.
    p.layout === :keep ||
        return String(lstrip(p.layout(obj, isroot ? nothing : dir), '/'))
    href = obj.href
    (href === nothing || p.origin === nothing) && return bestpath(obj, dir, isroot)
    startswith(href, p.origin) || return bestpath(obj, dir, isroot)
    return String(SubString(href, sizeof(p.origin) + 1))
end

abshref(p::Publisher, path::AbstractString) = (p.root_href::String) * path

# The spelling one document's link to another takes, which is the whole of the difference
# between the three published forms.
target(p::Publisher, from::AbstractString, to::AbstractString) =
    p.links === :absolute_published ? abshref(p, to) : relativepath(to, parentdir(from))

hierarchylink(href::AbstractString, rel::AbstractString, type::AbstractString) =
    Link(href, rel, type, nothing, nothing, nothing, nothing, nothing, Metadata())

# A producer's own link — `license`, `describedby`, `via` — keeps everything but its href,
# which is made absolute so it still resolves from wherever the tree is published.
function carried(link::Link, base::Union{String,Nothing})
    (base === nothing || isabsolutehref(link.href)) && return link
    return rebuild(link, Val(:href), resolve(link.href, base))
end

function absoluteasset(asset::Asset, base::Union{String,Nothing})
    (base === nothing || isabsolutehref(asset.href)) && return asset
    return rebuild(asset, Val(:href), resolve(asset.href, base))
end

absoluteassets(assets::AbstractDict{String,Asset}, base) =
    OrderedDict{String,Asset}(k => absoluteasset(a, base) for (k, a) in assets)

absoluteassets(::Nothing, _) = nothing

# A Catalog and an ItemCollection carry no assets, so there is nothing to make absolute.
withabsoluteassets(obj::Union{Item,Collection}, base) =
    rebuild(obj, Val(:assets), absoluteassets(obj.assets, base))

withabsoluteassets(obj::STACObject, _) = obj

"""
    STAC.republish(p, obj, path, parent, collection, root, childpaths, itempaths) -> obj

`obj` with the links it will be published with: `self` as the link style asks for, `root`,
`parent`, `collection`, and one `child` or `item` per document below it, all pointing at
where this walk puts them, and every other link carried over with its href made absolute.

`collection` is the path of the [`Collection`](@ref) an item belongs to, and `nothing` for an
item whose parent is a plain catalog.
"""
function republish(p::Publisher, obj::STACObject, path::AbstractString,
                   parent::Union{String,Nothing}, collection::Union{String,Nothing},
                   root::AbstractString, childpaths::Vector{String},
                   itempaths::Vector{String})
    links = Link[]
    if p.links === :absolute_published || (p.links === :relative_published && path == root)
        push!(links, hierarchylink(abshref(p, path), "self",
                                   obj isa Item ? ITEM_TYPE : CATALOG_TYPE))
    end
    push!(links, hierarchylink(target(p, path, root), "root", CATALOG_TYPE))
    parent === nothing ||
        push!(links, hierarchylink(target(p, path, parent), "parent", CATALOG_TYPE))
    collection === nothing ||
        push!(links, hierarchylink(target(p, path, collection), "collection", CATALOG_TYPE))
    for c in childpaths
        push!(links, hierarchylink(target(p, path, c), "child", CATALOG_TYPE))
    end
    for i in itempaths
        push!(links, hierarchylink(target(p, path, i), "item", ITEM_TYPE))
    end
    for l in obj.links
        l.rel in HIERARCHY_RELS || push!(links, carried(l, obj.href))
    end
    out = withabsoluteassets(obj, obj.href)
    return sethref(rebuild(out, Val(:links), links), nothing)
end

"""
    STAC.writedocument(path, obj) -> String

`obj` written to `path` as one indented STAC JSON document, and the path it went to. Missing
directories are created.
"""
function writedocument(path::AbstractString, obj::STACObject)
    mkpath(dirname(abspath(path)))
    io = open(path, "w")
    try
        json(io, obj; pretty = 2)
    finally
        close(io)
    end
    return String(path)
end

# Depth first, and a child's path is known before the parent is written, because the parent's
# `child` links name it. An href already visited is a cycle in the producer's links.
function publish!(p::Publisher, obj::STACObject, path::AbstractString,
                  parent::Union{String,Nothing}, root::AbstractString)
    collection = obj isa Collection ? path : nothing
    obj.href === nothing || push!(p.seen, obj.href)
    dir = parentdir(path)
    kids = filter(k -> !(k.href in p.seen), collect(children(obj, p.opts; io = p.io)))
    kidpaths = String[placement(p, k, dir) for k in kids]
    its = collect(items(obj, p.opts; io = p.io))
    itempaths = String[placement(p, i, dir) for i in its]
    writedocument(joinpath(p.dir, path),
                  republish(p, obj, path, parent, nothing, root, kidpaths, itempaths))
    for (k, kp) in zip(kids, kidpaths)
        publish!(p, k, kp, path, root)
    end
    for (i, ip) in zip(its, itempaths)
        writedocument(joinpath(p.dir, ip),
                      republish(p, i, ip, path, i.collection === nothing ? nothing : collection,
                                root, String[], String[]))
    end
    return p
end

"""
    STAC.write(dest, obj; layout, links, root_href, io, extensions, geometry, metadata)
    STAC.write(dest, obj, opts::ParseOptions; layout, links, root_href, io)

`obj` written as STAC JSON, either as one document or as the whole tree below it.

| `dest` | Writes |
|---|---|
| a path ending in `.json` | `obj` alone, exactly as [`STAC.json`](@ref) renders it |
| any other path | `obj` and every catalog, collection, and item it links to, as a directory tree |

The tree form takes two decisions, both named after the [STAC best practices
document](https://github.com/radiantearth/stac-spec/blob/master/best-practices.md): where
each document lands, and how the links between them are spelled.

| `layout` | Puts |
|---|---|
| `:best` (default) | `catalog.json`, then `<collection-id>/collection.json`, then `<item-id>/<item-id>.json` |
| `:keep` | each object where it was read from, relative to the root's origin |
| `(obj, parent_dir) -> path` | wherever the function says, as a `/`-separated path under `dest`. `parent_dir` is `nothing` for the root and the parent's directory below it |

| `links` | Writes |
|---|---|
| `:self_contained` (default) | no `self` links; every hierarchy link relative. The tree moves anywhere |
| `:relative_published` | one absolute `self` on the root; every hierarchy link relative |
| `:absolute_published` | an absolute `self` and absolute hierarchy links on every document |

The two published forms need `root_href`, the URL the tree will be reachable at; a missing
trailing `/` is added. Asset hrefs and the producer's own links (`license`, `describedby`,
`via`) are made absolute against the origin each object was read from, so they resolve from
the new location.

```julia
cat = STAC.read("test/fixtures/static/self-contained/catalog.json")
STAC.write("out", cat)                                       # "out/catalog.json"
STAC.write("out", cat; links = :absolute_published, root_href = "https://example.com/out/")
STAC.write("out/one-item.json", first(items(cat)))
```
"""
write(dest::AbstractString, obj::STACObject; layout = :best, links::Symbol = :self_contained,
      root_href::Union{AbstractString,Nothing} = nothing, io::AbstractIO = default_io(),
      kw...) =
    write(dest, obj, ParseOptions(; kw...); layout, links, root_href, io)

function write(dest::AbstractString, obj::STACObject, opts::ParseOptions; layout = :best,
               links::Symbol = :self_contained, root_href::Union{AbstractString,Nothing} = nothing,
               io::AbstractIO = default_io())
    endswith(dest, ".json") && return writedocument(dest, obj)
    links in LINK_STYLES ||
        _badoption(:links, links, ":self_contained, :relative_published, or :absolute_published")
    layout isa Symbol && !(layout in LAYOUTS) &&
        _badoption(:layout, layout, ":best, :keep, or a function of (object, parent directory)")
    base = root_href === nothing ? nothing : String(root_href)
    if links !== :self_contained
        base === nothing && _noroothref(links)
        endswith(base, '/') || (base *= "/")
    end
    origin = obj.href === nothing ? nothing : hrefdir(obj.href)
    p = Publisher(String(dest), layout, links, base, origin, io, opts, Set{String}())
    root = placement(p, obj, "", true)
    publish!(p, obj, root, nothing, root)
    return joinpath(p.dir, root)
end
