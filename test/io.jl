using STAC, Test, HTTP
using STAC: BearerToken, CachingIO, Catalog, HTTPIO, Headers, NoAuth, PathIO, StreamRouterIO,
            default_io, headers, rewrite

include("fixtures.jl")

# One HTTP server over `fixtures/static/self-contained/`, recording what it was asked for and
# with what headers, plus a `/boom` route that always fails so retries are observable. The
# port is arbitrary, the host is the loopback, and nothing leaves the machine.
struct Recorder
    hits::Dict{String,Int}
    seen::Vector{Pair{String,String}}
end

Recorder() = Recorder(Dict{String,Int}(), Pair{String,String}[])

function handler(rec::Recorder, dir::String)
    return function (req::HTTP.Request)
        target = String(req.target)
        rec.hits[target] = get(rec.hits, target, 0) + 1
        empty!(rec.seen)
        for (k, v) in req.headers
            push!(rec.seen, String(k) => String(v))
        end
        target == "/boom" && return HTTP.Response(500, "boom")
        path = joinpath(dir, lstrip(target, '/'))
        isfile(path) || return HTTP.Response(404, "no such fixture")
        return HTTP.Response(200, ["Content-Type" => "application/json"]; body = Base.read(path))
    end
end

function withserver(f)
    rec = Recorder()
    server = HTTP.serve!(handler(rec, joinpath(STATIC_DIR, "self-contained")), 0; listenany = true)
    try
        f(rec, "http://127.0.0.1:$(HTTP.port(server))")
    finally
        close(server)
    end
end

function headervalue(rec::Recorder, name)
    i = findfirst(p -> lowercase(first(p)) == lowercase(name), rec.seen)
    return i === nothing ? nothing : last(rec.seen[i])
end

hasheader(rec::Recorder, name, value) =
    any(p -> lowercase(first(p)) == lowercase(name) && last(p) == value, rec.seen)

@testset "the default stack routes https, http, file, and paths" begin
    io = default_io()
    @test io isa CachingIO
    @test io.inner isa StreamRouterIO
    @test first.(io.inner.routes) == ("https", "http", "", "file")

    path = joinpath(STATIC_DIR, "self-contained", "catalog.json")
    @test STAC.read(io, path) == Base.read(path)
    @test STAC.read(io, "file://" * path) == Base.read(path)
    @test_throws ArgumentError STAC.read(io, "s3://bucket/catalog.json")
end

@testset "PathIO reads a path and a file URL" begin
    path = joinpath(STATIC_DIR, "self-contained", "catalog.json")
    @test STAC.read(PathIO(), path) == Base.read(path)
    @test STAC.read(PathIO(), "file://" * path) == Base.read(path)
    @test STAC.request(PathIO(), "GET", path) == Base.read(path)
    @test_throws ArgumentError STAC.request(PathIO(), "POST", path)
end

@testset "HTTPIO reads a document over a real socket" begin
    withserver() do rec, base
        io = HTTPIO()
        bytes = STAC.read(io, base * "/catalog.json")
        @test bytes == Base.read(joinpath(STATIC_DIR, "self-contained", "catalog.json"))
        @test rec.hits["/catalog.json"] == 1
        @test startswith(headervalue(rec, "User-Agent"), "STAC.jl/")

        cat = STAC.read(base * "/catalog.json"; io)
        @test cat isa Catalog
        @test [i.id for i in items(cat; io, recursive = true)] == STATIC_ITEM_IDS
    end
end

@testset "CachingIO answers the second read without a request" begin
    withserver() do rec, base
        io = CachingIO(HTTPIO())
        href = base * "/catalog.json"
        first_read = STAC.read(io, href)
        @test rec.hits["/catalog.json"] == 1
        @test STAC.read(io, href) == first_read
        @test rec.hits["/catalog.json"] == 1

        empty!(io)
        STAC.read(io, href)
        @test rec.hits["/catalog.json"] == 2
    end
end

@testset "a failing route is retried the configured number of times" begin
    withserver() do rec, base
        io = HTTPIO(; retries = 2)
        @test_throws HTTP.StatusError STAC.read(io, base * "/boom")
        @test rec.hits["/boom"] == 3            # the first attempt plus two retries

        rec.hits["/boom"] = 0
        @test_throws HTTP.StatusError STAC.read(HTTPIO(; retries = 0), base * "/boom")
        @test rec.hits["/boom"] == 1
    end
end

@testset "auth headers reach the server" begin
    withserver() do rec, base
        STAC.read(HTTPIO(BearerToken("s3cret")), base * "/catalog.json")
        @test hasheader(rec, "Authorization", "Bearer s3cret")

        STAC.read(HTTPIO(Headers("X-Api-Key" => "abc", "X-Tenant" => "acme")), base * "/catalog.json")
        @test hasheader(rec, "X-Api-Key", "abc")
        @test hasheader(rec, "X-Tenant", "acme")

        STAC.read(HTTPIO(), base * "/catalog.json")
        @test !hasheader(rec, "Authorization", "Bearer s3cret")
    end
end

@testset "an auth answers headers and rewriting per href" begin
    @test headers(NoAuth(), "https://example.com") == STAC.NO_HEADERS
    @test headers(BearerToken("t"), "https://example.com") == ["Authorization" => "Bearer t"]
    @test headers(Headers("A" => "b"), "https://example.com") == ["A" => "b"]
    for auth in (NoAuth(), BearerToken("t"), Headers("A" => "b"))
        @test rewrite(auth, "s3://bucket/key") == "s3://bucket/key"
    end
end

@testset "STAC.with rebinds the default for a block" begin
    outer = default_io()
    STAC.with(PathIO()) do
        @test default_io() isa PathIO
    end
    @test default_io() === outer
end

@testset "the router names the scheme it has no route for" begin
    router = StreamRouterIO(("" => PathIO(),))
    err = try
        STAC.read(router, "https://example.com/catalog.json")
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("https", err.msg)
end
