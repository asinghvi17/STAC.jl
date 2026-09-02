using STAC, Test
using STAC: Catalog, Collection, Item, LinkIterator, Metadata, ParseOptions, itemtype

include("fixtures.jl")
include("FixtureIO.jl")

"""
    staticio() -> FixtureIO

The three published forms of `fixtures/static/`, each mounted at its own
`https://example.com/static/<style>/` prefix.
"""
staticio() = FixtureIO((STATIC_BASE * style * "/" => joinpath(STATIC_DIR, style)
                        for style in LINK_STYLES)...)

rooturl(style) = STATIC_BASE * style * "/catalog.json"

@testset "every link style walks to the same items" begin
    for style in LINK_STYLES
        io = staticio()
        cat = STAC.read(rooturl(style); io)
        @test cat isa Catalog{Metadata}
        @test cat.id == "examples"
        @test cat.href == rooturl(style)
        @test [i.id for i in items(cat; io, recursive = true)] == STATIC_ITEM_IDS
        @test [c.id for c in children(cat; io)] == STATIC_CHILD_IDS
    end
end

@testset "the two relative styles also walk from a local path" begin
    for style in ("self-contained", "relative-published")
        cat = STAC.read(joinpath(STATIC_DIR, style, "catalog.json"))
        @test [i.id for i in items(cat; recursive = true)] == STATIC_ITEM_IDS
    end
end

@testset "children yields the struct each document's own type names" begin
    io = staticio()
    cat = STAC.read(rooturl("self-contained"); io)
    kids = collect(children(cat; io))
    @test eltype(children(cat; io)) == Union{Catalog{Metadata},Collection{Metadata}}
    @test all(k -> k isa Collection{Metadata}, kids)
    @test kids[1].href == STATIC_BASE * "self-contained/simple-collection/collection.json"
end

@testset "nothing is fetched before it is reached" begin
    io = staticio()
    cat = STAC.read(rooturl("self-contained"); io)
    @test reads!(io) == 1                       # the catalog itself

    kids = children(cat; io)
    @test length(kids) == 2
    @test !isempty(kids)
    @test reads!(io) == 0                       # length comes from the link count

    first(kids)
    @test reads!(io) == 1

    collect(kids)
    @test reads!(io) == 2

    # One request per document reached: two collections plus four items.
    length(collect(items(cat; io, recursive = true)))
    @test reads!(io) == 6
end

@testset "an unrecorded href raises rather than reaching the network" begin
    io = staticio()
    @test_throws ErrorException STAC.read(STATIC_BASE * "self-contained/nope.json"; io)

    cat = STAC.read(rooturl("self-contained"); io)
    moved = STAC.sethref(cat, STATIC_BASE * "elsewhere/catalog.json")
    @test_throws ErrorException collect(children(moved; io))
end

@testset "parent and root walk back up" begin
    io = staticio()
    item = STAC.read(STATIC_BASE * "self-contained/simple-collection/simple-item.json"; io)
    @test parent(item; io).id == "simple-collection"
    @test STAC.root(item; io).id == "examples"

    empty = STAC.read(STATIC_BASE * "self-contained/collection-only/collection.json"; io)
    @test isempty(items(empty; io))
    @test isempty(children(empty; io))

    # A document with no such link answers `nothing` rather than raising.
    @test parent(STAC.root(item; io); io) === nothing
end

@testset "the parse options reach every fetched object" begin
    io = staticio()
    cat = STAC.read(rooturl("self-contained"); io, metadata = false, extensions = ())
    @test cat.metadata === STAC.NoMetadata()
    item = first(items(cat; io, metadata = false, extensions = ()))
    @test item isa Item{Any,STAC.DEFAULT_GEOMETRY,STAC.NoMetadata}
    @test item.metadata === STAC.NoMetadata()

    typed = first(items(cat; io))
    @test typed isa itemtype(ParseOptions())
    @test typed.extensions.eo === nothing || typed.extensions.eo isa EO
end

@testset "a link iterator reports its element type and length without fetching" begin
    io = staticio()
    cat = STAC.read(rooturl("self-contained"); io)
    it = items(cat; io)
    @test it isa LinkIterator
    @test eltype(it) == itemtype(ParseOptions())
    @test length(it) == 1
    @test Base.IteratorSize(typeof(items(cat; io, recursive = true))) == Base.SizeUnknown()
    @test eltype(items(cat; io, recursive = true)) == itemtype(ParseOptions())
end

@testset "the traversal path is inferable" begin
    io = staticio()
    opts = ParseOptions()
    cat = STAC.read(rooturl("self-contained"); io)
    @test only(Base.return_types(iterate, Tuple{typeof(items(cat, opts; io))})) ==
          Union{Nothing,Tuple{itemtype(opts),Int}}
    @test only(Base.return_types(iterate, Tuple{typeof(children(cat, opts; io))})) ==
          Union{Nothing,Tuple{STAC.childtype(opts),Int}}
    @test only(Base.return_types(STAC.read, Tuple{typeof(io),String})) == Vector{UInt8}
end

@testset "a child link pointing at the wrong kind of document is named" begin
    io = staticio()
    cat = STAC.read(rooturl("self-contained"); io)
    # The item link, read as though it were a child link.
    bad = STAC.LinkIterator{STAC.childtype(ParseOptions())}(
        STAC.rellinks(cat, "item"), cat.href, io, ParseOptions())
    @test_throws STAC.WrongDocumentType collect(bad)
end
