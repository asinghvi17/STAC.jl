# The six endpoints through the real HTTP stack. Opt in, because these reach the network and
# each one is somebody's production service:
#
#     STAC_LIVE_TESTS=1 julia --project=. test/live/runtests.jl
#
# `test/client.jl` and `test/search.jl` cover the same ground against the recordings under
# fixtures/endpoints/. What this file adds is the answer to one question those cannot ask:
# whether the endpoints still behave the way they were recorded.

using STAC, Test, Dates, HTTP

const LIVE = get(ENV, "STAC_LIVE_TESTS", "0") == "1"

const ENDPOINTS = [
    (name = "planetary-computer", url = "https://planetarycomputer.microsoft.com/api/stac/v1",
     collection = "sentinel-2-l2a", matched = false),
    (name = "earth-search", url = "https://earth-search.aws.element84.com/v1",
     collection = "sentinel-2-l2a", matched = true),
    (name = "landsatlook", url = "https://landsatlook.usgs.gov/stac-server",
     collection = "landsat-c2l2-sr", matched = true),
    (name = "cmr-lpcloud", url = "https://cmr.earthdata.nasa.gov/stac/LPCLOUD",
     collection = nothing, matched = true),
    (name = "cdse", url = "https://stac.dataspace.copernicus.eu/v1",
     collection = "sentinel-2-l2a", matched = false),
    (name = "itslive", url = "https://stac.itslive.cloud",
     collection = "itslive-granules", matched = true),
]

const WINDOW = (DateTime(2024, 6, 1), DateTime(2024, 6, 5))

"""
    retrying(f; attempts = 3, pause = 20)

`f()`, retried after a pause on HTTP 429. CDSE answers two searches that arrive back to back
with one, and a paging pass is two searches by construction.
"""
function retrying(f; attempts = 3, pause = 20)
    for i in 1:attempts
        try
            return f()
        catch err
            (err isa HTTP.StatusError && err.status == 429 && i < attempts) || rethrow()
            @info "429; retrying" attempt = i
            sleep(pause)
        end
    end
end

if !LIVE
    @info "skipping the live endpoint tests; set STAC_LIVE_TESTS=1 to run them"
else
    @testset "live: $(e.name)" for e in ENDPOINTS
        client = Client(e.url)
        @test STAC.conforms(client, "item-search")
        @test !isempty(collections(client))

        s = search(client; collections = e.collection, datetime = WINDOW, limit = 2)

        # Two pages in one pass, which is the assertion that matters: the `next` link this
        # endpoint sends today is still one this client can follow.
        two = retrying(() -> collect(Iterators.take(pages(s), 2)))
        @test length(two) == 2
        @test all(p -> length(p.features) <= 2, two)
        @test all(i -> i isa Item, two[1].features)
        @test isempty(intersect([i.id for i in two[1].features],
                                [i.id for i in two[2].features]))

        @test (retrying(() -> matched(s)) isa Int) == e.matched
        sleep(5)
    end
end

# The Planetary Computer's SAS token service, which no recording can keep honest: a token is
# minted per request and expires within the hour. What this asks is whether an anonymous
# request still works and whether what comes back still signs a blob href.
#
# Rasters and ArchGDAL are weak dependencies, so opening the pixels is not part of this
# environment. `route` is the whole of what STAC contributes to that call, and it is core.
if LIVE
    @testset "live: Planetary Computer SAS" begin
        auth = PlanetaryComputerSAS()
        client = Client("https://planetarycomputer.microsoft.com/api/stac/v1"; auth)
        item = retrying() do
            first(search(client; collections = ["sentinel-2-l2a"], datetime = WINDOW,
                         limit = 1))
        end
        asset = STAC.asset(item, "B04")
        @test STAC.blobparts(asset.href) !== nothing

        r = STAC.route(STAC.driver(asset), asset, client.io)
        @test startswith(r.filename, "/vsicurl/https://")
        @test occursin("sig=", r.filename)
        @test r.source === :gdal

        # The signed URL is one GDAL can range-read, which is the assertion that matters.
        signed = chopprefix(r.filename, "/vsicurl/")
        resp = HTTP.request("GET", signed, ["Range" => "bytes=0-99"]; status_exception = false)
        @test resp.status == 206
    end
end
