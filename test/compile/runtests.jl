using Test

# Static compilation is a supported target: each program here builds with
# `juliac --experimental --trim=safe` and then runs, so a trim regression surfaces as a
# verifier error in this testset rather than at release time.

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

if VERSION < v"1.12"
    @info "skipping the --trim=safe programs: juliac needs Julia 1.12" VERSION
else
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
    end
end
