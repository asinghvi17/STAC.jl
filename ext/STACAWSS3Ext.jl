module STACAWSS3Ext

# The `s3` route. AWSS3.jl already resolves credentials the way the AWS CLI does — the
# environment, the shared credentials file, then the instance metadata service — so this is
# an `AbstractIO` wrapping one `S3Path` read.

import AWSS3
import STAC

"""
    STACAWSS3Ext.AWSS3IO(config)

What [`S3IO`](@ref) builds: the transport that reads an `s3://` href through AWSS3.jl.
`config` is an `AWS.AWSConfig` or `nothing` for the credentials AWS.jl discovers.
"""
struct AWSS3IO{C} <: STAC.AbstractIO
    config::C
end

STAC.S3IO(; config = nothing) = AWSS3IO(config)

STAC.read(io::AWSS3IO, href::AbstractString) =
    Base.read(AWSS3.S3Path(href; config = io.config))

end # module STACAWSS3Ext
