module STACGeoParquetExt

# The flat GeoParquet route. An asset in this format is one table of features with a WKB
# geometry column — a published footprint set, a field boundary file — which GeoParquet.jl
# reads whole, unlike the nested stac-geoparquet a catalog is *stored* as, whose reader is
# `ext/STACDuckDBExt.jl`.

import GeoParquet
import STAC

STAC.route(::STAC.GeoParquetDriver, asset::STAC.Asset, io::STAC.AbstractIO) =
    (filename = STAC.rewrite(STAC.authfor(io, STAC.assethref(asset)), STAC.assethref(asset)),
     source = :geoparquet, config = STAC.NO_OPTIONS)

"""
    STAC.read(asset::Asset; io = STAC.default_io())

The table a flat GeoParquet asset holds, as GeoParquet.jl's `GeoDataFrame`: one row per
feature, with the geometry column typed and every other column as the producer wrote it.

```julia
using STAC, GeoParquet

asset = Asset(abspath("test/fixtures/geoparquet/footprints.parquet"),
              "application/vnd.apache.parquet", nothing, nothing, ["data"], nothing,
              NoMetadata())
df = STAC.read(asset)
names(df)                       # ["id", "datetime", "geometry"]
```
"""
STAC.readasset(d::STAC.GeoParquetDriver, asset::STAC.Asset, io::STAC.AbstractIO) =
    GeoParquet.read(STAC.route(d, asset, io).filename)

end # module STACGeoParquetExt
