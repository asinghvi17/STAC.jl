```@meta
CurrentModule = STAC
```

# API reference

Everything the package documents, grouped by the file it lives in. The guide pages link into
this one; this one is the exhaustive listing.

```@index
```

```@docs
STAC.STAC
```

## Objects

```@autodocs
Modules = [STAC]
Pages = ["objects.jl", "metadata.jl"]
```

## Extensions

```@autodocs
Modules = [STAC]
Pages = ["extensions/interface.jl", "extensions/eo.jl", "extensions/proj.jl",
         "extensions/raster.jl", "extensions/sat.jl", "extensions/view.jl",
         "extensions/sci.jl"]
```


## Documents, traversal, and the API client

```@autodocs
Modules = [STAC]
Pages = ["document.jl", "traverse.jl", "client.jl"]
```


## Search

```@autodocs
Modules = [STAC]
Pages = ["search/interface.jl", "search/backends.jl"]
```

## Geometry and the spatial index

```@autodocs
Modules = [STAC]
Pages = ["geo.jl", "spatialindex.jl"]
```


## Tables, metadata, and printing

```@autodocs
Modules = [STAC]
Pages = ["tables.jl", "dataapi.jl", "show.jl"]
```


## Fetching and credentials

```@autodocs
Modules = [STAC]
Pages = ["io/interface.jl", "io/auth.jl", "io/resolve.jl", "io/path.jl", "io/http.jl",
         "io/caching.jl", "io/router.jl", "io/s3.jl", "io/default.jl"]
```


## Parsing and writing JSON

```@autodocs
Modules = [STAC]
Pages = ["parse/options.jl", "parse/style.jl", "parse/sinks.jl", "parse/write.jl"]
```

## Drivers and bulk formats

```@autodocs
Modules = [STAC]
Pages = ["drivers.jl", "ndjson.jl", "publish.jl"]
```

## Errors

```@autodocs
Modules = [STAC]
Pages = ["errors.jl"]
```
