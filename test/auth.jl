using STAC, Test, Dates
using STAC: BearerToken, EarthdataLogin, Headers, NoAuth, PlanetaryComputerSAS, authfor,
            blobparts, defaultstack, fetchsastoken, gdal_config, headers, rewrite

include("fixtures.jl")
include("FixtureIO.jl")

const BLOB = "https://sentinel2l2a01.blob.core.windows.net/sentinel2-l2/x/B04.tif"
const TOKEN_URL = "https://token.test/token"
const TOKEN_HREF = TOKEN_URL * "/sentinel2l2a01/sentinel2-l2"

# A `PlanetaryComputerSAS` whose token service is one vendored file.
signing(fixture; kw...) =
    (io = answering(TOKEN_HREF => joinpath(TOKEN_DIR, fixture));
     (PlanetaryComputerSAS(; url = TOKEN_URL, io, kw...), io))

@testset "an auth that adds headers gives GDAL the same headers" begin
    @test isempty(gdal_config(NoAuth(), "https://example.com/B4.tif"))
    @test gdal_config(BearerToken("s3cret"), "https://example.com/B4.tif") ==
          ["GDAL_HTTP_HEADERS" => "Authorization: Bearer s3cret"]
    # GDAL separates several headers with CRLF, as HTTP does.
    @test gdal_config(Headers("X-Api-Key" => "k", "X-Tenant" => "acme"), "https://example.com") ==
          ["GDAL_HTTP_HEADERS" => "X-Api-Key: k\r\nX-Tenant: acme"]
end

@testset "an Earthdata token goes to Earthdata hosts and nowhere else" begin
    auth = EarthdataLogin("edl-token")
    inside = "https://data.lpdaac.earthdatacloud.nasa.gov/lp-prod/B04.tif"
    outside = "https://sentinel-cogs.s3.us-west-2.amazonaws.com/B04.tif"

    @test headers(auth, inside) == ["Authorization" => "Bearer edl-token"]
    @test isempty(headers(auth, outside))
    @test gdal_config(auth, inside) ==
          ["GDAL_HTTP_HEADERS" => "Authorization: Bearer edl-token"]
    @test isempty(gdal_config(auth, outside))

    # A redirect target on a signed S3 URL rejects an Authorization header it did not ask
    # for, which is why the suffix test is the whole rule.
    @test isempty(gdal_config(auth, "https://d1nqr2c1n2v4a.cloudfront.net/B04.tif"))
    @test STAC.isearthdata("https://cmr.earthdata.nasa.gov/stac/LPCLOUD")
    @test !STAC.isearthdata("not a uri at all")
end

@testset "a blob href names the account and container its token signs" begin
    @test blobparts(BLOB) == ("sentinel2l2a01", "sentinel2-l2")
    @test blobparts("https://example.com/B4.tif") === nothing
    @test blobparts("s3://usgs-landsat/c2/B4.TIF") === nothing
    @test blobparts("https://.blob.core.windows.net/c/x") === nothing
    @test blobparts("https://acct.blob.core.windows.net/") === nothing
end

@testset "signing appends the token to a blob href and leaves every other href alone" begin
    auth, io = signing("pc-sas-fresh.json")
    signed = rewrite(auth, BLOB)
    @test startswith(signed, BLOB * "?")
    @test occursin("sig=handwrittenfixture", signed)
    @test reads!(io) == 1

    @test rewrite(auth, "s3://usgs-landsat/c2/B4.TIF") == "s3://usgs-landsat/c2/B4.TIF"
    @test rewrite(auth, "https://example.com/B4.tif") == "https://example.com/B4.tif"
    # An href the producer already signed is left as it stands.
    @test rewrite(auth, signed) == signed
    @test reads!(io) == 0

    # An href carrying a query string of its own gets the token as another parameter.
    @test occursin("?versionid=3&st=", rewrite(auth, BLOB * "?versionid=3"))
end

@testset "a token is held until it expires and re-requested after" begin
    auth, io = signing("pc-sas-fresh.json")
    signed = rewrite(auth, BLOB)
    @test rewrite(auth, BLOB) == signed
    @test rewrite(auth, BLOB) == signed
    @test reads!(io) == 1

    stale, staleio = signing("pc-sas-expired.json")
    rewrite(stale, BLOB)
    rewrite(stale, BLOB)
    @test reads!(staleio) == 2

    # The margin refreshes ahead of the stated expiry, so a token good for another minute is
    # replaced rather than handed to a reader who will still be using it.
    early, earlyio = signing("pc-sas-fresh.json"; margin = Day(400_000))
    rewrite(early, BLOB)
    rewrite(early, BLOB)
    @test reads!(earlyio) == 2
end

@testset "the subscription key goes on the token request only when it is given" begin
    auth, io = signing("pc-sas-fresh.json")
    rewrite(auth, BLOB)
    @test !any(hs -> any(p -> first(p) == "Ocp-Apim-Subscription-Key", hs), io.seen)

    keyed, keyedio = signing("pc-sas-fresh.json"; subscription_key = "sub-key")
    rewrite(keyed, BLOB)
    @test any(hs -> ("Ocp-Apim-Subscription-Key" => "sub-key") in hs, keyedio.seen)
end

@testset "the recorded service response parses into a token and an expiry" begin
    dir = endpointdir("planetary-computer-sas")
    io = recordedio(dir)
    auth = PlanetaryComputerSAS(; url = endpointurl(dir), io)
    token, expiry = fetchsastoken(auth, "sentinel2l2a01", "sentinel2-l2")
    @test occursin("sig=", token)
    @test occursin("se=", token)
    @test expiry isa DateTime
    @test expiry > DateTime(2026)
end

@testset "a token service answering without a token says so" begin
    dir = mktempdir()
    write(joinpath(dir, "empty.json"), "{\"msft:expiry\": \"2999-01-01T00:00:00Z\"}")
    io = answering(TOKEN_HREF => joinpath(dir, "empty.json"))
    auth = PlanetaryComputerSAS(; url = TOKEN_URL, io)
    err = try
        rewrite(auth, BLOB)
    catch e
        e
    end
    @test err isa STAC.NoToken
    @test err isa STAC.STACError
    @test occursin(TOKEN_HREF, sprint(showerror, err))
end

@testset "a stack reports the auth that would fetch each href" begin
    auth = BearerToken("s3cret")
    io = defaultstack(auth)
    @test authfor(io, "https://example.com/B4.tif") === auth
    @test authfor(io, "http://example.com/B4.tif") === auth
    @test authfor(io, "/data/B4.tif") == NoAuth()
    @test authfor(io, "s3://bucket/B4.tif") == NoAuth()
    @test authfor(STAC.PathIO(), "/data/B4.tif") == NoAuth()
end
