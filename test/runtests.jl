using Test, SafeTestsets

# One testset file per source concern. `Pkg.test(test_args = ["parse", "write"])` runs a
# subset; with no arguments every file runs, and the `--trim=safe` programs under
# `test/compile/` run when they are named or `STAC_COMPILE_TESTS=1` is set.
const TESTS = ["aqua", "objects", "parse", "write", "extensions", "real_world"]

selected(name) = isempty(ARGS) || name in ARGS

@testset "STAC.jl" begin
    for name in TESTS
        selected(name) || continue
        @eval @safetestset $name begin
            include($(name * ".jl"))
        end
    end
    if "compile" in ARGS || get(ENV, "STAC_COMPILE_TESTS", "0") == "1"
        @testset "compile" begin
            include(joinpath(@__DIR__, "compile", "runtests.jl"))
        end
    end
end
