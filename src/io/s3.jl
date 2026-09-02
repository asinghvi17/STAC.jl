# The `s3` route. AWSS3.jl supplies the transport; core holds the name and the hint that
# names the package, so `S3IO()` in a session without it says what to load.

"""
    S3IO(; config = nothing)

The [`AbstractIO`](@ref STAC.AbstractIO) that reads `s3://` hrefs, defined by AWSS3.jl.
`config` is an `AWS.AWSConfig`; `nothing` uses the credentials AWS.jl discovers from the
environment, the shared credentials file, or the instance metadata service.

A public bucket reads anonymously, with the region named: AWS.jl resolves `nothing` to the
default region, and a bucket that lives elsewhere answers a request sent there with a
`PermanentRedirect`.

```julia
using STAC, AWSS3

io = S3IO(; config = AWSS3.AWS.AWSConfig(; creds = nothing, region = "us-west-2"))
item = STAC.read("s3://sentinel-cogs/sentinel-s2-l2a-cogs/32/T/QL/2024/6/S2B_32TQL_20240601_0_L2A/S2B_32TQL_20240601_0_L2A.json";
                 io = StreamRouterIO("s3" => io, "https" => HTTPIO(), "" => PathIO()))
item.id                     # "S2B_32TQL_20240601_0_L2A"
length(item.assets)         # 35
```
"""
function S3IO end

# Reached only when AWSS3 is unloaded: with it loaded, `S3IO(; config)` has a method.
function _s3hint(io::IO, exc::MethodError, @nospecialize(argtypes), @nospecialize(kwargs))
    exc.f === S3IO || return nothing
    print(io, "\n  AWSS3.jl defines `S3IO`. Run `import AWSS3` to add the `s3` route.")
    return nothing
end
