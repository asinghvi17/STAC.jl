using Test

# Static compilation is a supported target: `read_item.jl` and `search_index.jl` build with
# `juliac --experimental --trim=safe` and then run, so a trim regression surfaces as a
# verifier error here rather than at release time. `api_search.jl` is the API path, which
# does not link yet; it runs as a script and its verifier errors are held to a budget, so the
# cost of a request is a number this testset reports rather than a surprise.

const COMPILE_DIR = @__DIR__
const FIXTURES = joinpath(dirname(COMPILE_DIR), "fixtures")
const JULIAC = joinpath(Sys.BINDIR, "..", "share", "julia", "juliac", "juliac.jl")

"""
    build(program) -> (path, log)

`program` compiled to an executable under a temporary directory, together with the build
log. A verifier error leaves the log with `Verifier error` lines in it.
"""
function build(program::String, outdir::String)
    exe = joinpath(outdir, first(splitext(program)))
    # `Pkg.test` exports a JULIA_LOAD_PATH pinned to its own temporary environment; juliac
    # loads LazyArtifacts and needs the default path plus this directory's project.
    cmd = addenv(`$(Base.julia_cmd()) --project=$COMPILE_DIR $JULIAC
                  --output-exe $exe --experimental --trim=safe $(joinpath(COMPILE_DIR, program))`,
                 "JULIA_LOAD_PATH" => nothing, "JULIA_PROJECT" => nothing)
    log = IOBuffer()
    ok = success(pipeline(cmd; stdout = log, stderr = log))
    return exe, ok, String(take!(log))
end

"""
    interpret(program, args...) -> String

`program` run as an ordinary script through this directory's project, and what it printed.
This is what says the program does the right thing; `build` says what it costs.
"""
function interpret(program::String, args::AbstractString...)
    cmd = addenv(`$(Base.julia_cmd()) --project=$COMPILE_DIR
                  $(joinpath(COMPILE_DIR, program)) $args`,
                 "JULIA_LOAD_PATH" => nothing, "JULIA_PROJECT" => nothing)
    return read(cmd, String)
end

"""
    verifiererrors(log) -> Vector{String}

The distinct unresolved statements a build log reports: one statement is one call the trim
verifier could not resolve, and the log lists each error twice.
"""
verifiererrors(log::String) =
    unique([replace(l, r"^Verifier error #\d+: " => "")
            for l in split(log, '\n') if startswith(l, "Verifier error")])

"""
    resolveenv()

Bring `test/compile/`'s manifest in line with the package's current dependencies. The
manifest is not checked in, and this environment tracks `../..` through `[sources]`, so a
dependency added to the package reaches the trim programs only after this runs.
"""
function resolveenv()
    cmd = addenv(`$(Base.julia_cmd()) --project=$COMPILE_DIR -e
                  "using Pkg; Pkg.resolve(); Pkg.instantiate()"`,
                 "JULIA_LOAD_PATH" => nothing, "JULIA_PROJECT" => nothing)
    log = IOBuffer()
    success(pipeline(cmd; stdout = log, stderr = log)) || println(String(take!(log)))
    return nothing
end

if VERSION < v"1.12"
    @info "skipping the --trim=safe programs: juliac needs Julia 1.12" VERSION
else
    resolveenv()
    mktempdir() do outdir
        @testset "read_item.jl builds under --trim=safe" begin
            exe, ok, log = build("read_item.jl", outdir)
            @test !occursin("Verifier error", log)
            @test ok
            ok || println(log)

            if ok
                out = read(`$exe $(joinpath(FIXTURES, "hand", "hand-item.json"))
                            $(joinpath(FIXTURES, "stac-spec", "catalog.json"))
                            $(joinpath(FIXTURES, "stac-spec", "collection.json"))`, String)
                @test split(strip(out), '\n') == ["hand-1", "examples", "simple-collection"]
            end
        end

        @testset "search_index.jl builds under --trim=safe" begin
            exe, ok, log = build("search_index.jl", outdir)
            @test !occursin("Verifier error", log)
            @test ok
            ok || println(log)

            if ok
                out = read(`$exe $(joinpath(FIXTURES, "hand", "antimeridian-catalog",
                                            "catalog.json"))`, String)
                # The catalog's id, the one item the search across the antimeridian finds,
                # and the one hit the index reports for the same box.
                @test split(strip(out), '\n') == ["antimeridian", "straddle", "1"]
            end
        end

        # The API path does not link, and this is the measurement of what stands in the way.
        # A STAC API carries JSON documents in the request as well as the response — the
        # search body, a `next` link's body and header map — and a JSON document's values are
        # `Any`, so each call that touches one is a dynamic dispatch the verifier reports.
        #
        # | Statement | Where | What would close it |
        # |---|---|---|
        # | `STAC.queryvalue(::Any)` | a link's header map, a `GET` search's query string | a body whose values are a closed set of JSON types |
        # | `STAC.jsonobject(::Any)` | a `next` link's body, from two page states | `Link.body` typed `JSON.Object{String,Any}` |
        # | `StructUtils.lower`, `JSON.WriteClosure`, four of them | JSON.jl writing the POST body | a writer that narrows a JSON value before lowering it |
        #
        # Six statements, eight calls. A number below the budget means one of the three lifted
        # upstream: lower the budget and record which one.
        @testset "api_search.jl measures the API path under --trim=safe" begin
            endpoint = joinpath(FIXTURES, "endpoints", "planetary-computer")
            out = interpret("api_search.jl", endpoint)
            # The endpoint's id, the four items two recorded pages carry, and the one item of
            # those four whose footprint meets the query box.
            @test split(strip(out), '\n') ==
                  ["microsoft-pc",
                   "S2B_MSIL2A_20240604T235129_R073_T59UPV_20240605T022336",
                   "S2B_MSIL2A_20240604T235129_R073_T59UPU_20240605T022357",
                   "S2B_MSIL2A_20240604T235129_R073_T59UPT_20240605T022129",
                   "S2B_MSIL2A_20240604T235129_R073_T59UNV_20240605T022341",
                   "1"]

            _, ok, log = build("api_search.jl", outdir)
            errors = verifiererrors(log)
            known(e) = occursin("STAC.queryvalue", e) || occursin("STAC.jsonobject", e) ||
                       occursin("StructUtils.lower", e) || occursin("JSON.WriteClosure", e)
            @test all(known, errors)
            @test length(errors) <= 6
            all(known, errors) || println(join(filter(!known, errors), '\n'))
            # The day the count reaches zero this program links, and the assertion becomes
            # the one the other two make.
            ok && @test isempty(errors)
        end
    end
end
