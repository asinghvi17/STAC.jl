"""
    STAC.AbstractAuth

Supertype of the credentials an [`HTTPIO`](@ref STAC.HTTPIO) carries. An auth answers two
questions, both per href, so one stack can hold a token for a catalog's own host and stay
anonymous for the buckets its assets live in:

| Method | Answers |
|---|---|
| `STAC.headers(auth, href)` | the request headers to add |
| `STAC.rewrite(auth, href)` | the href a reader should see, e.g. one carrying a signed token |

`rewrite` defaults to the identity, so an auth that only adds headers implements `headers`
alone.

```julia
struct QueryToken <: STAC.AbstractAuth
    token::String
end
STAC.headers(::QueryToken, ::AbstractString) = STAC.NO_HEADERS
STAC.rewrite(a::QueryToken, href::AbstractString) = href * "?token=" * a.token

STAC.rewrite(QueryToken("abc"), "https://example.com/catalog.json")
# "https://example.com/catalog.json?token=abc"

HTTPIO(QueryToken("abc"))       # the transport that signs every href
```
"""
abstract type AbstractAuth end

"""
    STAC.headers(auth, href) -> STAC.RequestHeaders

The headers `auth` adds to a request for `href`, empty when it does not apply to that host.
"""
function headers end

"""
    STAC.rewrite(auth, href) -> String

`href` as a reader should see it. An auth that signs a URL returns the signed form; every
other auth returns `href` unchanged.
"""
rewrite(::AbstractAuth, href::AbstractString) = String(href)

"""
    NoAuth()

Anonymous access: no headers, no rewriting. The default of every stack
[`STAC.default_io`](@ref) builds.

```julia
STAC.headers(NoAuth(), "https://example.com")   # Pair{String,String}[]
```
"""
struct NoAuth <: AbstractAuth end

headers(::NoAuth, ::AbstractString) = NO_HEADERS

"""
    BearerToken(token)

`Authorization: Bearer <token>` on every request. [`STAC.Headers`](@ref) covers an endpoint
that wants a differently named header.

```julia
STAC.headers(BearerToken("s3cret"), "https://example.com")
# ["Authorization" => "Bearer s3cret"]
```

A [`Client`](@ref) takes one through `auth =`, and every later call carries it.
"""
struct BearerToken <: AbstractAuth
    token::String
end

headers(a::BearerToken, ::AbstractString) = RequestHeaders(["Authorization" => "Bearer " * a.token])

"""
    Headers(pairs)
    Headers("X-Api-Key" => "…", …)

A fixed header list added to every request, for the endpoints whose credential is neither a
bearer token nor a signed URL.

```julia
auth = STAC.Headers("X-Api-Key" => "k", "X-Tenant" => "acme")
STAC.headers(auth, "https://example.com")   # ["X-Api-Key" => "k", "X-Tenant" => "acme"]
HTTPIO(auth)                                # the transport that sends them
```
"""
struct Headers <: AbstractAuth
    headers::RequestHeaders
end

Headers(pairs::Pair...) = Headers(RequestHeaders([String(first(p)) => String(last(p)) for p in pairs]))

headers(a::Headers, ::AbstractString) = a.headers

# ---------------------------------------------------------------------------------------
# Credentials as GDAL sees them

"""
    STAC.GDALOptions

The GDAL configuration options one fetch needs: `name => value` pairs, applied to the path
prefix they belong to rather than to the process.
"""
const GDALOptions = Vector{Pair{String,String}}

const NO_OPTIONS = GDALOptions()

"""
    STAC.gdal_config(auth, href) -> STAC.GDALOptions

The GDAL configuration options that let GDAL fetch `href` with `auth`'s credentials, which is
the third question an auth answers, beside [`STAC.headers`](@ref) and
[`STAC.rewrite`](@ref).

The default turns whatever `headers` returns into one `GDAL_HTTP_HEADERS` option, CRLF
separated as GDAL wants it, so an auth that signs with headers needs no method here:

```julia
STAC.gdal_config(BearerToken("s3cret"), "https://example.com/b.tif")
# ["GDAL_HTTP_HEADERS" => "Authorization: Bearer s3cret"]

STAC.gdal_config(NoAuth(), "https://example.com/b.tif")     # Pair{String,String}[]
```

An auth that signs the href itself, [`PlanetaryComputerSAS`](@ref) among them, has nothing to
tell GDAL: the credential rides in the URL [`STAC.rewrite`](@ref) returns.
"""
function gdal_config(auth::AbstractAuth, href::AbstractString)
    hs = headers(auth, href)
    isempty(hs) && return NO_OPTIONS
    return GDALOptions(["GDAL_HTTP_HEADERS" => join((k * ": " * v for (k, v) in hs), "\r\n")])
end

# ---------------------------------------------------------------------------------------
# Signing a Planetary Computer href

"""
    STAC.PC_SAS_URL

The Planetary Computer's SAS token service, which mints a read token per storage account and
container.
"""
const PC_SAS_URL = "https://planetarycomputer.microsoft.com/api/sas/v1/token"

const PC_BLOB_HOST = ".blob.core.windows.net"

@noinline _notoken(url) = throw(NoToken(String(url)))

"""
    PlanetaryComputerSAS(; subscription_key = nothing, url = STAC.PC_SAS_URL, io = HTTPIO(),
                         margin = Minute(5))

Signs a Microsoft Planetary Computer blob href with a shared access signature, one token per
storage account and container, held until it expires.

| Keyword | Meaning |
|---|---|
| `subscription_key` | the account key sent as `Ocp-Apim-Subscription-Key` on the token request |
| `url` | the token service; `<url>/<account>/<container>` is what one request asks for |
| `io` | the transport the token request goes through |
| `margin` | how long before a token's stated expiry it is refreshed |

Anonymous token requests work: the service answered one without a subscription key when this
fixture was recorded (2026-09-02), giving a token good for 45 minutes. A key raises the rate
limit and lengthens that window; a key the service does not recognise is ignored rather than
rejected.

[`STAC.rewrite`](@ref) appends the token to a `*.blob.core.windows.net` href and returns
every other href unchanged, so one stack can sign Planetary Computer assets and stay
anonymous for the rest:

```julia
auth = PlanetaryComputerSAS()
STAC.rewrite(auth, "https://sentinel2l2a01.blob.core.windows.net/sentinel2-l2/x/B04.tif")
# "https://sentinel2l2a01.blob.core.windows.net/sentinel2-l2/x/B04.tif?st=…&se=…&sig=…"

STAC.rewrite(auth, "s3://usgs-landsat/collection02/B4.TIF")   # unchanged

client = Client("https://planetarycomputer.microsoft.com/api/stac/v1"; auth)
```
"""
struct PlanetaryComputerSAS{I<:AbstractIO} <: AbstractAuth
    url::String
    subscription_key::Union{String,Nothing}
    io::I
    margin::Second
    tokens::Dict{String,Tuple{String,DateTime}}
    lock::ReentrantLock
end

function PlanetaryComputerSAS(; subscription_key::Union{AbstractString,Nothing} = nothing,
                              url::AbstractString = PC_SAS_URL, io::AbstractIO = HTTPIO(),
                              margin::Period = Minute(5))
    return PlanetaryComputerSAS(String(url),
                                subscription_key === nothing ? nothing : String(subscription_key),
                                io, Second(margin),
                                Dict{String,Tuple{String,DateTime}}(), ReentrantLock())
end

headers(::PlanetaryComputerSAS, ::AbstractString) = NO_HEADERS

gdal_config(::PlanetaryComputerSAS, ::AbstractString) = NO_OPTIONS

"""
    STAC.blobparts(href) -> Union{Tuple{String,String},Nothing}

The storage account and container of an Azure Blob Storage href
(`https://<account>.blob.core.windows.net/<container>/<path>`), or `nothing` for an href that
names no blob. This is what picks the token [`PlanetaryComputerSAS`](@ref) signs with.

```jldoctest
julia> STAC.blobparts("https://sentinel2l2a01.blob.core.windows.net/sentinel2-l2/x/B04.tif")
("sentinel2l2a01", "sentinel2-l2")

julia> STAC.blobparts("https://example.com/b.tif") === nothing
true
```
"""
function blobparts(href::AbstractString)
    uri = try
        URIs.URI(href)
    catch e
        e isa URIs.ParseError || rethrow()
        return nothing
    end
    (uri.scheme == "https" || uri.scheme == "http") || return nothing
    endswith(uri.host, PC_BLOB_HOST) || return nothing
    account = SubString(uri.host, 1, lastindex(uri.host) - lastindex(PC_BLOB_HOST))
    isempty(account) && return nothing
    segments = split(lstrip(uri.path, '/'), '/'; limit = 2)
    (isempty(segments) || isempty(segments[1])) && return nothing
    return (String(account), String(segments[1]))
end

"""
    STAC.sastoken(auth::PlanetaryComputerSAS, account, container) -> String

The query string that signs one container, from the cache when it is still valid and from the
token service otherwise. Concurrent callers share one request per container.
"""
function sastoken(auth::PlanetaryComputerSAS, account::AbstractString, container::AbstractString)
    key = account * "/" * container
    return Base.lock(auth.lock) do
        cached = get(auth.tokens, key, nothing)
        (cached !== nothing && Dates.now(Dates.UTC) + auth.margin < cached[2]) &&
            return cached[1]
        fresh = fetchsastoken(auth, account, container)
        auth.tokens[key] = fresh
        return fresh[1]
    end
end

"""
    STAC.fetchsastoken(auth, account, container) -> (token, expiry)

One `GET <url>/<account>/<container>`, parsed into the query string it returns and the
instant it stops working.
"""
function fetchsastoken(auth::PlanetaryComputerSAS, account::AbstractString,
                       container::AbstractString)
    url = rstrip(auth.url, '/') * "/" * account * "/" * container
    extra = auth.subscription_key === nothing ? NO_HEADERS :
            RequestHeaders(["Ocp-Apim-Subscription-Key" => auth.subscription_key])
    doc = JSON.parse(request(auth.io, "GET", url; headers = extra))
    token = get(doc, "token", nothing)
    token isa AbstractString || _notoken(url)
    expiry = get(doc, "msft:expiry", nothing)
    return (String(token),
            expiry isa AbstractString ? parse_rfc3339(expiry) : Dates.now(Dates.UTC))
end

function rewrite(auth::PlanetaryComputerSAS, href::AbstractString)
    parts = blobparts(href)
    parts === nothing && return String(href)
    occursin("sig=", href) && return String(href)
    token = sastoken(auth, parts[1], parts[2])
    return String(href) * (occursin('?', href) ? "&" : "?") * token
end

# ---------------------------------------------------------------------------------------
# NASA Earthdata

"""
    STAC.EARTHDATA_HOSTS

The host suffixes [`EarthdataLogin`](@ref) sends its token to. NASA's DAACs redirect a data
request to a signed URL on a host that rejects an `Authorization` header it did not expect,
so the token goes to Earthdata hosts alone.

One suffix covers every DAAC that answers under NASA's own domain — `cmr.earthdata.nasa.gov`
and `data.lpdaac.earthdatacloud.nasa.gov` among them. A DAAC that does not, such as NSIDC's
`n5eil01u.ecs.nsidc.org` or ASF's `sentinel1.asf.alaska.edu`, takes a [`STAC.Headers`](@ref)
naming the hosts it does answer under.
"""
const EARTHDATA_HOSTS = (".nasa.gov",)

"""
    EarthdataLogin(token)

`Authorization: Bearer <token>` for NASA Earthdata hosts, both on this package's own requests
and, through [`STAC.gdal_config`](@ref), on the ones GDAL makes for an asset.

Mint the token at <https://urs.earthdata.nasa.gov/profile>, under "Generate Token".

```julia
auth = EarthdataLogin(ENV["EARTHDATA_TOKEN"])
STAC.headers(auth, "https://data.lpdaac.earthdatacloud.nasa.gov/x/B04.tif")
# ["Authorization" => "Bearer …"]
STAC.headers(auth, "https://example.com/b.tif")   # Pair{String,String}[]

client = Client("https://cmr.earthdata.nasa.gov/stac/LPCLOUD"; auth)
```
"""
struct EarthdataLogin <: AbstractAuth
    token::String
end

"""
    STAC.isearthdata(href) -> Bool

Whether `href` names a NASA Earthdata host, which is where [`EarthdataLogin`](@ref) sends its
token.
"""
function isearthdata(href::AbstractString)
    host = try
        URIs.URI(href).host
    catch e
        e isa URIs.ParseError || rethrow()
        return false
    end
    return any(suffix -> endswith(host, suffix), EARTHDATA_HOSTS)
end

headers(a::EarthdataLogin, href::AbstractString) =
    isearthdata(href) ? RequestHeaders(["Authorization" => "Bearer " * a.token]) : NO_HEADERS
