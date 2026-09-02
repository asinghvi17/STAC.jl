using STAC, Test, JSON
using STAC: Catalog, Collection, Item, Metadata, isabsolutehref, relativepath

include("fixtures.jl")
include("FixtureIO.jl")

const OUT_BASE = "https://example.com/out/"

catalog() = STAC.read(joinpath(STATIC_DIR, "self-contained", "catalog.json"))

"""
    publishedio(dir) -> FixtureIO

The tree under `dir`, mounted at the URL it was published under, so an
`:absolute_published` catalog reads back through the [`STAC.AbstractIO`](@ref) seam rather
than off the filesystem its links no longer name.
"""
publishedio(dir) = FixtureIO(OUT_BASE => dir)

alllinks(dir) = [(relpath(joinpath(root, f), dir), l)
                 for (root, _, files) in walkdir(dir) for f in files
                 for l in JSON.parse(read(joinpath(root, f), String))["links"]]

documents(dir) = sort([relpath(joinpath(root, f), dir)
                       for (root, _, files) in walkdir(dir) for f in files])

@testset "relative paths climb and descend" begin
    @test relativepath("catalog.json", "") == "./catalog.json"
    @test relativepath("catalog.json", "simple-collection") == "../catalog.json"
    @test relativepath("a/b/c.json", "a/x") == "../b/c.json"
    @test relativepath("a/b/c.json", "a/b") == "./c.json"
end

@testset "the best-practices layout puts every document where the spec says" begin
    dir = mktempdir()
    @test STAC.write(dir, catalog()) == joinpath(dir, "catalog.json")
    @test documents(dir) == sort(["catalog.json",
                                  joinpath("collectionless-item", "collectionless-item.json"),
                                  joinpath("empty-collection", "collection.json"),
                                  joinpath("simple-collection", "collection.json"),
                                  joinpath("simple-collection", "core-item", "core-item.json"),
                                  joinpath("simple-collection", "extended-item", "extended-item.json"),
                                  joinpath("simple-collection", "simple-item", "simple-item.json")])
end

@testset "every link style walks back to the same items" begin
    for style in (:self_contained, :relative_published, :absolute_published)
        dir = mktempdir()
        root = STAC.write(dir, catalog(); links = style,
                          root_href = style === :self_contained ? nothing : OUT_BASE)
        cat = style === :absolute_published ?
              STAC.read(OUT_BASE * "catalog.json"; io = publishedio(dir)) : STAC.read(root)
        io = style === :absolute_published ? publishedio(dir) : STAC.default_io()
        @test cat.id == "examples"
        @test [c.id for c in children(cat; io)] == ["simple-collection", "empty-collection"]
        @test sort([i.id for i in items(cat; io, recursive = true)]) == sort(STATIC_ITEM_IDS)
    end
end

@testset "each link style spells `self` the way it is named for" begin
    self(dir) = [(path, l["href"]) for (path, l) in alllinks(dir) if l["rel"] == "self"]

    contained = mktempdir()
    STAC.write(contained, catalog())
    @test isempty(self(contained))

    relative = mktempdir()
    STAC.write(relative, catalog(); links = :relative_published, root_href = OUT_BASE)
    @test self(relative) == [("catalog.json", OUT_BASE * "catalog.json")]
    @test all(!isabsolutehref(l["href"]) for (_, l) in alllinks(relative) if l["rel"] != "self")

    absolute = mktempdir()
    STAC.write(absolute, catalog(); links = :absolute_published, root_href = OUT_BASE)
    @test length(self(absolute)) == length(documents(absolute))
    @test all(isabsolutehref(l["href"]) for (_, l) in alllinks(absolute))
end

@testset "a re-read then re-write is byte stable" begin
    for style in (:self_contained, :relative_published)
        first_pass = mktempdir()
        root = STAC.write(first_pass, catalog(); links = style,
                          root_href = style === :self_contained ? nothing : OUT_BASE)
        second_pass = mktempdir()
        STAC.write(second_pass, STAC.read(root); links = style,
                   root_href = style === :self_contained ? nothing : OUT_BASE)
        @test documents(first_pass) == documents(second_pass)
        for name in documents(first_pass)
            @test read(joinpath(first_pass, name)) == read(joinpath(second_pass, name))
        end
    end
end

@testset "`:keep` reproduces the tree the catalog was read from" begin
    dir = mktempdir()
    STAC.write(dir, catalog(); layout = :keep)
    source = joinpath(STATIC_DIR, "self-contained")
    @test documents(dir) == documents(source)
end

@testset "a layout function places every document" begin
    dir = mktempdir()
    flat(obj, parent) = parent === nothing ? "root.json" : obj.id * ".json"
    STAC.write(dir, catalog(); layout = flat)
    @test documents(dir) == sort(["root.json", "collectionless-item.json", "core-item.json",
                                  "empty-collection.json", "extended-item.json",
                                  "simple-collection.json", "simple-item.json"])
    @test [i.id for i in items(STAC.read(joinpath(dir, "root.json")); recursive = true)] ==
          STATIC_ITEM_IDS
end

@testset "an item keeps its collection link and gains no other" begin
    dir = mktempdir()
    STAC.write(dir, catalog())
    inside = JSON.parse(read(joinpath(dir, "simple-collection", "simple-item",
                                      "simple-item.json"), String))
    @test [l["rel"] for l in inside["links"]] == ["root", "parent", "collection"]
    loose = JSON.parse(read(joinpath(dir, "collectionless-item",
                                     "collectionless-item.json"), String))
    @test [l["rel"] for l in loose["links"]] == ["root", "parent"]
end

@testset "asset hrefs are made absolute against where the item came from" begin
    dir = mktempdir()
    STAC.write(dir, catalog())
    for (_, l) in alllinks(dir)
        @test l["type"] in ("application/json", "application/geo+json")
    end
    item = JSON.parse(read(joinpath(dir, "simple-collection", "simple-item",
                                    "simple-item.json"), String))
    @test all(isabsolutehref(a["href"]) for a in values(item["assets"]))
end

@testset "a `.json` destination writes one document" begin
    dir = mktempdir()
    item = STAC.read(joinpath(SPEC_DIR, "simple-item.json"))
    path = STAC.write(joinpath(dir, "nested", "one.json"), item)
    @test path == joinpath(dir, "nested", "one.json")
    @test documents(dir) == [joinpath("nested", "one.json")]
    @test STAC.read(path).id == item.id
end

@testset "a published style without a root href says so" begin
    dir = mktempdir()
    @test_throws STAC.MissingRootHref STAC.write(dir, catalog(); links = :relative_published)
    @test_throws STAC.BadOption STAC.write(dir, catalog(); links = :absolute)
    @test_throws STAC.BadOption STAC.write(dir, catalog(); layout = :flat)
    msg = sprint(showerror, STAC.MissingRootHref("absolute_published"))
    @test occursin("root_href", msg)
end

@testset "a collection publishes as its own root" begin
    dir = mktempdir()
    col = STAC.read(joinpath(STATIC_DIR, "self-contained", "simple-collection",
                             "collection.json"))
    root = STAC.write(dir, col)
    @test root == joinpath(dir, "collection.json")
    @test [i.id for i in items(STAC.read(root))] ==
          ["simple-item", "core-item", "extended-item"]
end
