using STAC, Test
using STAC: Link, Metadata, absolutehref, isabsolutehref, localpath, resolve, urischeme

include("fixtures.jl")

link(href) = Link(href, "child", nothing, nothing, nothing, nothing, nothing, nothing, Metadata())

@testset "urischeme separates a scheme from a path" begin
    @test urischeme("https://example.com/a") == "https"
    @test urischeme("s3://bucket/key") == "s3"
    @test urischeme("file:///a/b") == "file"
    @test urischeme("/a/b/catalog.json") == ""
    @test urischeme("./item.json") == ""
    @test urischeme("catalog.json") == ""
    # A single letter before the colon is a Windows drive, not a one-character scheme.
    @test urischeme("C:/data/catalog.json") == ""
    # A raw space makes the href no URI reference at all, which is to say a local path.
    @test urischeme("/my catalogs/catalog.json") == ""
    @test resolve("item.json", "/my catalogs/catalog.json") == "/my catalogs/item.json"
end

@testset "an absolute href is one that can be fetched on its own" begin
    @test isabsolutehref("https://example.com/a")
    @test isabsolutehref("/a/b")
    @test !isabsolutehref("./item.json")
    @test !isabsolutehref("item.json")
end

@testset "an href with a scheme resolves to itself" begin
    for href in ("https://example.com/item.json", "s3://bucket/item.json")
        @test resolve(href, "https://elsewhere.example/a/b") == href
        @test resolve(href, "/somewhere/else") == href
        @test resolve(href, nothing) == href
    end
end

@testset "a root-relative href follows the kind of base it has" begin
    @test resolve("/a/item.json", "/somewhere/else") == "/a/item.json"
    @test resolve("/a/item.json", nothing) == "/a/item.json"
    @test resolve("/a/item.json", "https://example.com/b/c") == "https://example.com/a/item.json"
end

# RFC 3986 §5.4, against the specification's own base URI.
@testset "RFC 3986 reference resolution" begin
    base = "http://a/b/c/d;p?q"
    @test resolve("g", base) == "http://a/b/c/g"
    @test resolve("./g", base) == "http://a/b/c/g"
    @test resolve("g/", base) == "http://a/b/c/g/"
    @test resolve("/g", base) == "http://a/g"
    @test resolve("..", base) == "http://a/b/"
    @test resolve("../g", base) == "http://a/b/g"
    @test resolve("../../g", base) == "http://a/g"
    @test resolve("./g?y", base) == "http://a/b/c/g?y"
end

@testset "a trailing slash on the base is significant" begin
    @test resolve("./item.json", "http://a/b") == "http://a/item.json"
    @test resolve("./item.json", "http://a/b/") == "http://a/b/item.json"
    @test resolve("./item.json", "/a/b") == "/a/item.json"
    @test resolve("./item.json", "/a/b/") == "/a/b/item.json"
end

@testset "a local base joins and normalises" begin
    @test resolve("item.json", "/a/b/catalog.json") == "/a/b/item.json"
    @test resolve("../c/item.json", "/a/b/catalog.json") == "/a/c/item.json"
    @test resolve("./x/../y/item.json", "/a/catalog.json") == "/a/y/item.json"
end

@testset "resolve takes a Link and reads its href" begin
    @test resolve(link("./item.json"), "/a/catalog.json") == "/a/item.json"
    @test resolve(link("https://example.com/item.json"), "/a/catalog.json") ==
          "https://example.com/item.json"
end

@testset "a relative href with no base says so" begin
    @test_throws STAC.NoOrigin("./item.json") resolve("./item.json", nothing)
end

@testset "a file URL reduces to its path" begin
    @test localpath("file:///a/b/catalog.json") == "/a/b/catalog.json"
    @test localpath("file:///a/b%20c/catalog.json") == "/a/b c/catalog.json"
    @test localpath("/a/b/catalog.json") == "/a/b/catalog.json"
end

@testset "absolutehref records a local path as absolute and leaves URLs alone" begin
    @test absolutehref("test/fixtures") == abspath("test/fixtures")
    @test absolutehref("https://example.com/a") == "https://example.com/a"
    @test absolutehref("s3://bucket/key") == "s3://bucket/key"
end
