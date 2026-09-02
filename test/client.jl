using STAC, Test, JSON, Dates
using STAC: Catalog, Collection, GENERIC_HOST, HostDefaults, Metadata, collection,
            conforms, host_defaults, linkhref, selfhref

include("fixtures.jl")
include("FixtureIO.jl")

"""
    apiclient(name) -> (client, io)

A [`Client`](@ref) over one endpoint's recordings, with the [`FixtureIO`](@ref) it fetches
through so a test can count requests.
"""
function apiclient(name)
    dir = endpointdir(name)
    io = recordedio(dir)
    return Client(endpointurl(dir); io), io
end

conformancedoc(name) =
    JSON.parse(Base.read(joinpath(endpointdir(name), "conformance.json"), String))["conformsTo"]

collectionids(name) =
    [c["id"] for c in JSON.parse(Base.read(joinpath(endpointdir(name), "collections.json"),
                                           String))["collections"]]

@testset "every recorded endpoint opens as a client" begin
    for name in ENDPOINTS
        client, io = apiclient(name)
        @test client.url == endpointurl(endpointdir(name))
        @test client.root isa Catalog{Metadata}
        @test client.root.href == client.url
        @test reads!(io) == 1                    # the landing page, and nothing else
        @test conforms(client, "core")
        @test conforms(client, "item-search")
        @test linkhref(client.root, "search"; method = "POST") !== nothing
    end
end

@testset "the landing page's conformsTo is the conformance document" begin
    for name in ENDPOINTS
        client, _ = apiclient(name)
        @test client.conformsTo == conformancedoc(name)
        # A full URI matches exactly; a short name matches whatever version is published.
        @test all(c -> conforms(client, c), client.conformsTo)
        @test !conforms(client, "https://api.stacspec.org/v1.0.0/nonesuch")
        @test !conforms(client, "nonesuch")
    end
end

@testset "the four filter-shaped classes are read per endpoint" begin
    # Earth Search and CMR publish no `item-search#filter`; the other four do, two of them
    # only under a release-candidate version, which the short-name match has to see through.
    filtered = Dict(name => conforms(first(apiclient(name)), "item-search#filter")
                    for name in ENDPOINTS)
    @test filtered["earth-search"] == false
    @test filtered["cmr-lpcloud"] == false
    @test all(filtered[n] for n in ("planetary-computer", "landsatlook", "cdse", "itslive"))

    cdse, _ = apiclient("cdse")
    @test conforms(cdse, "https://api.stacspec.org/v1.0.0-rc.2/item-search#filter")
    @test !conforms(cdse, "https://api.stacspec.org/v1.0.0/item-search#filter")
    @test conforms(cdse, "item-search#filter")
end

@testset "host quirks are matched from the url" begin
    pc, _ = apiclient("planetary-computer")
    @test pc.host.max_limit == 1000
    @test pc.host.default_limit == 250
    @test pc.host.reports_matched == false

    es, _ = apiclient("earth-search")
    @test es.host.max_limit == 499
    @test es.host.reports_matched == true

    # ITS_LIVE has no recorded quirks, so it runs on the spec's own limits.
    itslive, _ = apiclient("itslive")
    @test itslive.host === GENERIC_HOST
    @test host_defaults("https://example.com/stac") === GENERIC_HOST

    # A caller who knows better than the table wins.
    dir = endpointdir("cdse")
    mine = HostDefaults(20, 5, true, true)
    @test Client(endpointurl(dir); io = recordedio(dir), host = mine).host === mine
end

@testset "collections parse into a typed vector, each with its own origin" begin
    for name in ENDPOINTS
        client, io = apiclient(name)
        reads!(io)
        cols = collections(client)
        @test cols isa Vector{Collection{Metadata}}
        @test [c.id for c in cols] == collectionids(name)
        @test reads!(io) == 1
        for c in cols
            @test c.href === selfhref(c)
            @test c.href === nothing || startswith(c.href, "http")
        end
    end
end

@testset "one collection by id comes from the data link" begin
    for name in ENDPOINTS
        client, _ = apiclient(name)
        id = first(collectionids(name))
        col = collection(client, id)
        @test col isa Collection{Metadata}
        @test col.id == id
        @test col.href == rstrip(linkhref(client.root, "data"), '/') * "/" * id
    end
end

@testset "the parse options reach a collection read" begin
    client, _ = apiclient("earth-search")
    id = first(collectionids("earth-search"))
    @test collection(client, id; metadata = false) isa Collection{STAC.NoMetadata}
    @test first(collections(client; metadata = false)) isa Collection{STAC.NoMetadata}
end

@testset "a client over a catalog that is not an API says so" begin
    io = FixtureIO(STATIC_BASE * "self-contained/" => joinpath(STATIC_DIR, "self-contained"))
    client = Client(STATIC_BASE * "self-contained/catalog.json"; io)
    @test isempty(client.conformsTo)
    @test !conforms(client, "core")

    err = try
        search(client; collections = ["simple-collection"])
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("item-search", err.msg)

    # No `data` link either, so the collection calls name the link they wanted.
    @test_throws ArgumentError collections(client)
end
