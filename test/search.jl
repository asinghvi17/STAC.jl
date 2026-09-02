using STAC, Test, JSON, Dates, Extents, GeoJSON
using STAC: APIItemSearch, Item, ItemCollection, Link, Metadata, ParseOptions, build_body,
            classify, collection, itemtype, nextbody, nextlink, normalize_datetime,
            numbermatched

include("fixtures.jl")
include("FixtureIO.jl")

# The window fixtures/record.jl asked every endpoint for, as the argument a user would write.
const WINDOW = (DateTime(2024, 6, 1), DateTime(2024, 6, 5))
const WINDOW_STRING = "2024-06-01T00:00:00Z/2024-06-05T00:00:00Z"

manifest(name) = JSON.parse(Base.read(joinpath(endpointdir(name), "requests.json"), String))

recorded(name, response) =
    only(filter(r -> r["response"] == response, manifest(name)["requests"]))

pagedoc(name, response) =
    JSON.parse(Base.read(joinpath(endpointdir(name), response), String))

pageids(name, response) = [f["id"] for f in pagedoc(name, response)["features"]]

"""
    recordedsearch(name; kw...) -> (client, search, io)

The search `fixtures/record.jl` recorded for one endpoint, rebuilt from the keywords a user
would pass. The body it produces is asserted against the recorded one, so a formatting change
shows up here rather than as an unmatched replay later.
"""
function recordedsearch(name; kw...)
    dir = endpointdir(name)
    io = recordedio(dir)
    client = Client(endpointurl(dir); io)
    body = recorded(name, "search-1.json")["body"]
    s = search(client; collections = get(body, "collections", nothing), datetime = WINDOW,
               limit = body["limit"], kw...)
    return client, s, io
end

@testset "the request a search builds is the one that was recorded" begin
    for name in ENDPOINTS
        _, s, _ = recordedsearch(name)
        req = recorded(name, "search-1.json")
        @test s.method == req["method"]
        @test s.href == req["href"]
        @test s.body == req["body"]
        @test s.body["datetime"] == WINDOW_STRING
    end
end

@testset "every endpoint pages from its first page to its next link" begin
    for name in ENDPOINTS
        _, s, io = recordedsearch(name)
        reads!(io)
        page1, page2 = collect(Iterators.take(pages(s), 2))
        @test reads!(io) == 2
        @test [i.id for i in page1.features] == pageids(name, "search-1.json")
        @test [i.id for i in page2.features] == pageids(name, "search-2.json")
        @test page1.features isa Vector{itemtype(ParseOptions())}
    end
end

@testset "the three next-link shapes are each followed as sent" begin
    # pgstac: a POST whose body is the whole request again with a `token` added, and no
    # `merge` key at all.
    for name in ("planetary-computer", "cdse", "itslive")
        _, s, _ = recordedsearch(name)
        link = nextlink(first(pages(s)))
        @test link.method == "POST"
        @test link.merge === nothing
        @test haskey(nextbody(link, s.body), "token")
        @test nextbody(link, s.body) == recorded(name, "search-2.json")["body"]
    end

    # stac-server: a POST that says `merge: false`, so its body is used as it stands.
    for name in ("earth-search", "landsatlook")
        _, s, _ = recordedsearch(name)
        link = nextlink(first(pages(s)))
        @test link.method == "POST"
        @test link.merge === false
        @test haskey(nextbody(link, s.body), "next")
        @test nextbody(link, s.body) == recorded(name, "search-2.json")["body"]
    end

    # CMR: a plain GET carrying a cursor, with no method and no body on the link.
    _, s, _ = recordedsearch("cmr-lpcloud")
    link = nextlink(first(pages(s)))
    @test link.method === nothing
    @test link.body === nothing
    @test occursin("cursor=", link.href)
    @test recorded("cmr-lpcloud", "search-2.json")["method"] == "GET"
end

@testset "merge: true puts the link's keys on top of the original body" begin
    original = STAC.jsonobject(Dict("collections" => ["a"], "limit" => 2))
    link = Link("https://example.com/search", "next", nothing, nothing, "POST", nothing,
                Dict("token" => "t2"), true, Metadata())
    @test nextbody(link, original) == Dict("collections" => ["a"], "limit" => 2, "token" => "t2")

    # The default, `merge: false`, replaces it wholesale.
    plain = Link("https://example.com/search", "next", nothing, nothing, "POST", nothing,
                 Dict("token" => "t2"), nothing, Metadata())
    @test nextbody(plain, original) == Dict("token" => "t2")
end

@testset "items are yielded one page at a time" begin
    _, s, io = recordedsearch("earth-search")
    reads!(io)
    @test eltype(s) == itemtype(ParseOptions())
    @test Base.IteratorSize(typeof(s)) == Base.SizeUnknown()

    # Two items per page, so five items is three pages; the recordings stop at two.
    two = collect(Iterators.take(s, 2))
    @test reads!(io) == 1
    @test [i.id for i in two] == pageids("earth-search", "search-1.json")

    _, s2, io2 = recordedsearch("earth-search")
    reads!(io2)
    four = collect(Iterators.take(s2, 4))
    @test reads!(io2) == 2
    @test [i.id for i in four] ==
          vcat(pageids("earth-search", "search-1.json"), pageids("earth-search", "search-2.json"))

    _, s3, io3 = recordedsearch("planetary-computer")
    reads!(io3)
    @test first(s3).id == first(pageids("planetary-computer", "search-1.json"))
    @test reads!(io3) == 1
end

@testset "matched is the total where the endpoint sends one" begin
    for (name, expected) in ("earth-search" => 50336, "landsatlook" => 5594,
                             "itslive" => 4328682)
        _, s, _ = recordedsearch(name)
        @test matched(s) == expected
    end

    # CMR reports through the deprecated `context` object rather than `numberMatched`.
    _, cmr, _ = recordedsearch("cmr-lpcloud")
    @test matched(cmr) == 501345
    @test numbermatched(first(pages(cmr))) == 501345

    # Planetary Computer and CDSE send neither, which the host table already knows, so
    # `matched` answers without a request.
    for name in ("planetary-computer", "cdse")
        _, s, io = recordedsearch(name)
        reads!(io)
        @test matched(s) === nothing
        @test reads!(io) == 0
    end
end

@testset "limit is clamped to the host's cap" begin
    for (name, asked, sent) in (("planetary-computer", 5000, 1000), ("earth-search", 500, 499),
                                ("cdse", 500, 200), ("itslive", 50_000, 10_000),
                                ("cmr-lpcloud", 9999, 5000))
        client, _, _ = recordedsearch(name)
        @test search(client; limit = asked).body["limit"] == sent
        @test search(client; limit = 0).body["limit"] == 1
    end

    pc, _, _ = recordedsearch("planetary-computer")
    @test search(pc).body["limit"] == 250              # the host's own default
    itslive, _, _ = recordedsearch("itslive")
    @test search(itslive).body["limit"] == 100         # the spec's default
end

@testset "a request an endpoint cannot answer fails at the call site" begin
    for name in ("earth-search", "cmr-lpcloud")
        client, _, _ = recordedsearch(name)
        err = try
            search(client; filter = Dict("op" => "=", "args" => []))
        catch e
            e
        end
        @test err isa STAC.NoConformance
        @test err.class == "item-search#filter"
        @test err.argument == "`filter =`"
        @test occursin("item-search#filter", sprint(showerror, err))
    end

    cdse, _, _ = recordedsearch("cdse")
    body = search(cdse; filter = Dict("op" => "=", "args" => [])).body
    @test body["filter-lang"] == "cql2-json"
    @test search(cdse; filter = Dict(), filter_lang = "cql2-text").body["filter-lang"] == "cql2-text"
end

@testset "datetime arguments become RFC 3339 strings" begin
    @test normalize_datetime(nothing) === nothing
    @test normalize_datetime("2024-06-01/..") == "2024-06-01/.."
    @test normalize_datetime(DateTime(2024, 6, 1, 12)) == "2024-06-01T12:00:00Z"
    # A bare date is a full day, because four of five endpoints reject a date-only string.
    @test normalize_datetime(Date(2024, 1, 1)) ==
          "2024-01-01T00:00:00Z/2024-01-01T23:59:59.999Z"
    @test normalize_datetime((DateTime(2024, 6, 1), nothing)) == "2024-06-01T00:00:00Z/.."
    @test normalize_datetime((nothing, DateTime(2024, 6, 5))) == "../2024-06-05T00:00:00Z"
    @test normalize_datetime((Date(2024, 1, 1), Date(2024, 1, 2))) ==
          "2024-01-01T00:00:00Z/2024-01-02T23:59:59.999Z"
    @test normalize_datetime([DateTime(2024, 6, 1), DateTime(2024, 6, 5)]) == WINDOW_STRING
    @test_throws STAC.BadInterval(1) normalize_datetime([DateTime(2024, 6, 1)])
end

@testset "a spatial argument becomes bbox or intersects by its type" begin
    @test classify(nothing) == (:none, nothing)
    @test classify(Extent(X = (-123, -122), Y = (37, 38))) ==
          (:bbox, [-123.0, 37.0, -122.0, 38.0])
    @test classify(Extent(X = (-123, -122), Y = (37, 38), Z = (0, 10))) ==
          (:bbox, [-123.0, 37.0, 0.0, -122.0, 38.0, 10.0])
    @test classify((-123, 37, -122, 38)) == (:bbox, [-123.0, 37.0, -122.0, 38.0])

    # GeoJSON.jl reads positions as Float32 unless told otherwise, and -122.4194 widened from
    # Float32 is -122.41940307617188, a request for a different place.
    poly = GeoJSON.read("""{"type":"Polygon","coordinates":
        [[[-122.4194,37.7749],[-122.0,37.0],[-122.0,38.0],[-122.4194,37.7749]]]}""")
    @test poly isa GeoJSON.Polygon{2,Float32}
    kind, geom = classify(poly)
    @test kind === :intersects
    @test geom isa GeoJSON.Polygon{2,Float64}
    @test JSON.parse(STAC.json(geom))["coordinates"][1][1] == [-122.4194, 37.7749]
    @test_throws STAC.NotAGeometry("String") classify("POLYGON((0 0))")

    # A Z coordinate travels with the position.
    pt3 = GeoJSON.read("""{"type":"Point","coordinates":[-123.0,37.0,10.0]}"""; ndim = 3)
    @test JSON.parse(STAC.json(classify(pt3)[2]))["coordinates"] == [-123.0, 37.0, 10.0]

    # A GeometryCollection travels whole, its members with it.
    gc = GeoJSON.read("""{"type":"GeometryCollection","geometries":
        [{"type":"Point","coordinates":[-123.0,37.0]}]}""")
    written = JSON.parse(STAC.json(classify(gc)[2]))
    @test written["type"] == "GeometryCollection"
    @test written["geometries"][1]["coordinates"] == [-123.0, 37.0]

    client, _, _ = recordedsearch("planetary-computer")
    @test haskey(search(client; intersects = Extent(X = (-1, 1), Y = (-1, 1))).body, "bbox")
    @test haskey(search(client; intersects = poly).body, "intersects")
end

@testset "a search body carries only the keys the caller named" begin
    body = build_body(; limit = 10)
    @test collect(keys(body)) == ["limit"]

    body = build_body(; collections = "a", ids = ["x", "y"], datetime = WINDOW,
                      sortby = "-datetime", limit = 10)
    @test body["collections"] == ["a"]
    @test body["ids"] == ["x", "y"]
    @test body["sortby"] == [Dict("field" => "datetime", "direction" => "desc")]
    @test build_body(; sortby = ["+id", "-datetime"], limit = 1)["sortby"] ==
          [Dict("field" => "id", "direction" => "asc"),
           Dict("field" => "datetime", "direction" => "desc")]
end

@testset "a GET search puts the body in the query string" begin
    client, _, io = recordedsearch("earth-search")
    s = search(client; collections = ["sentinel-2-l2a"], datetime = WINDOW, limit = 2,
               method = "GET")
    @test s.method == "GET"
    @test s.body === nothing
    @test occursin("collections=sentinel-2-l2a", s.href)
    @test occursin("limit=2", s.href)
    @test occursin("datetime=2024-06-01T00%3A00%3A00Z%2F2024-06-05T00%3A00%3A00Z", s.href)
    @test STAC.querystring(build_body(; intersects = (-1, 1, 2, 3), limit = 1)) ==
          "bbox=-1.0%2C1.0%2C2.0%2C3.0&limit=1"

    # Everything outside RFC 3986's unreserved set is escaped, a multi-byte character one
    # byte at a time, which is what `URIs.escapeuri` does for the same string.
    @test STAC.percentencode("a~b c/é") == "a%7Eb%20c%2F%C3%A9"
    @test STAC.queryvalue(Any["a", 2, 3.5, true]) == "a,2,3.5,true"
    @test STAC.queryvalue(Any[Dict("field" => "id")]) == "[{\"field\":\"id\"}]"
end

@testset "a search takes its parse options as a value" begin
    client, _, _ = recordedsearch("earth-search")
    opts = ParseOptions(; extensions = (), metadata = false)
    s = search(client, opts; collections = ["sentinel-2-l2a"], datetime = WINDOW, limit = 2)
    @test eltype(s) == itemtype(opts)
    @test s.body == recorded("earth-search", "search-1.json")["body"]

    # The keyword form names the same options, and both reach the features endpoint too.
    @test eltype(search(client; extensions = (), metadata = false)) == itemtype(opts)
    @test eltype(items(client, "sentinel-2-l2a", opts; limit = 2)) == itemtype(opts)
end

@testset "a collection's items come through the features endpoint" begin
    for name in ENDPOINTS
        client, _, io = recordedsearch(name)
        id = first(pagedoc(name, "collections.json")["collections"])["id"]
        s = items(client, id; limit = 2)
        @test s isa APIItemSearch
        @test s.method == "GET"
        @test s.href == recorded(name, "items.json")["href"]
        reads!(io)
        # One page holds two items, so asking for two costs exactly one request.
        @test [i.id for i in Iterators.take(s, 2)] == pageids(name, "items.json")
        @test reads!(io) == 1
    end

    # A collection whose window holds nothing gives an empty search, not an error.
    client, _, _ = recordedsearch("planetary-computer")
    empty = items(client, "daymet-annual-pr"; limit = 2)
    @test isempty(collect(empty))

    # The `Collection` object routes through its own `items` link.
    col = collection(client, "daymet-annual-pr")
    @test STAC.linkhref(col, "items") !== nothing
end
