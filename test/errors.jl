using STAC, Test, JSON, GeoJSON, Dates, Extents, DE9IM
using STAC: ArgumentShapeError, DocumentError, EndpointError, LookupError, STACError,
            STACStyle, Metadata, Provider, Link
import GeometryOps as GO

include("fixtures.jl")

message(e) = sprint(showerror, e)

# One row per exception type: a value, the group it belongs to, and the parts of its message
# a reader needs to find the problem.
const EXCEPTIONS = [
    (STAC.NotSTACDocument("Point"), DocumentError, ["Point", "Feature", "Catalog"]),
    (STAC.NotSTACDocument(nothing), DocumentError, ["no `type` key"]),
    (STAC.WrongDocumentType("Catalog{Metadata}", "Item"), DocumentError,
     ["Catalog{Metadata}", "Item"]),
    (STAC.WrongJSONType(:object, "Item{Any}"), DocumentError, ["object", "Item{Any}"]),
    (STAC.WrongJSONType(:array, "Vector{Link}"), DocumentError, ["array", "Vector{Link}"]),
    (STAC.MissingField("Provider", :name), DocumentError, ["name", "Provider"]),
    (STAC.UnknownGeometryType("Point", "Union{Nothing, Polygon}"), DocumentError,
     ["Point", "Union{Nothing, Polygon}"]),
    (STAC.UnknownGeometryType(nothing, "Union{Nothing, Polygon}"), DocumentError,
     ["type", "Union{Nothing, Polygon}"]),
    (STAC.BadDateTime("yesterday"), DocumentError, ["RFC 3339", "yesterday"]),
    (STAC.MissingCollections("https://example.com/collections"), DocumentError,
     ["https://example.com/collections", "collections"]),
    (STAC.MissingLink("https://example.com", "data"), LookupError,
     ["https://example.com", "data"]),
    (STAC.NoOrigin("./item.json"), LookupError, ["./item.json", "STAC.sethref"]),
    (STAC.MissingExtension("Sat", "sat", "Item"), LookupError, ["Sat", "sat:", "Item"]),
    (STAC.MissingColumn(:nosuchcolumn), LookupError, ["nosuchcolumn"]),
    (STAC.MissingAsset("B04", "red, green, blue"), LookupError, ["B04", "red, green, blue"]),
    (STAC.MissingDatetime("undated"), LookupError, ["undated", "start_datetime"]),
    (STAC.NotAGeometry("String"), ArgumentShapeError, ["intersects", "String"]),
    (STAC.NotQueryable("String"), ArgumentShapeError, ["String", "SphericalCap"]),
    (STAC.BadBBox(3), ArgumentShapeError, ["4 or 6", "3"]),
    (STAC.BadInterval(1), ArgumentShapeError, ["datetime", "two values", "1"]),
    (STAC.EmptyPredicate("Within"), ArgumentShapeError, ["Within()", "Within(polygon)"]),
    (STAC.NotGeoJSONAsset("GDALDriver", "Rasters, ArchGDAL", "s3://b/B4.tif"),
     ArgumentShapeError, ["GDALDriver", "import Rasters, ArchGDAL", "s3://b/B4.tif"]),
    (STAC.NotARasterAsset("GeoJSONDriver", "/d/f.geojson"), ArgumentShapeError,
     ["GeoJSONDriver", "/d/f.geojson", "STAC.read(asset)"]),
    (STAC.MixedResolution(["B04", "B11"], ["10980×10980", "5490×5490"]), ArgumentShapeError,
     ["B04", "B11", "10980×10980", "5490×5490"]),
    (STAC.BadOption("links", "absolute", ":self_contained or :absolute_published"),
     ArgumentShapeError,
     ["links = :absolute", ":self_contained", ":absolute_published"]),
    (STAC.MissingRootHref("relative_published"), ArgumentShapeError,
     ["relative_published", "root_href", ":self_contained"]),
    (STAC.NoConformance("https://example.com", "item-search#filter", "`filter =`", 12),
     EndpointError, ["https://example.com", "item-search#filter", "`filter =`", "12"]),
    (STAC.NoRoute("s3", "s3://bucket/catalog.json"), EndpointError,
     ["s3", "s3://bucket/catalog.json", "StreamRouterIO"]),
    (STAC.MethodUnsupported("PathIO", "POST"), EndpointError, ["PathIO", "GET", "POST"]),
    (STAC.NoToken("https://example.com/token/a/c"), EndpointError,
     ["https://example.com/token/a/c", "token"]),
    (STAC.NoDriverPackage("DuckDBDriver", "DuckDB", "s3://b/items.parquet"), EndpointError,
     ["DuckDBDriver", "import DuckDB", "s3://b/items.parquet"]),
]

@testset "every exception is a STACError and prints the values it carries" begin
    for (e, group, fragments) in EXCEPTIONS
        @test e isa group
        @test e isa STACError
        @test e isa Exception
        m = message(e)
        for fragment in fragments
            @test occursin(fragment, m)
        end
    end

    # The four groups partition the package's exceptions, so a caller can branch on one.
    for (e, group, _) in EXCEPTIONS
        others = filter(!=(group), [DocumentError, LookupError, ArgumentShapeError,
                                    EndpointError])
        @test !any(g -> e isa g, others)
    end
end

@testset "a document the parse cannot build names the type it was filling" begin
    err = try
        JSON.parse("[1, 2]", Link; style = STACStyle())
    catch e
        e
    end
    @test err isa STAC.WrongJSONType
    @test err.expected === :object
    # A type prints qualified or not depending on which module is doing the printing.
    @test endswith(err.target, "Link")

    err = try
        JSON.parse("{\"a\": 1}", Vector{Link}; style = STACStyle())
    catch e
        e
    end
    @test err isa STAC.WrongJSONType
    @test err.expected === :array

    err = try
        JSON.parse("{\"description\": \"no name\"}", Provider; style = STACStyle())
    catch e
        e
    end
    @test err isa STAC.MissingField
    @test err.field === :name
    @test endswith(err.type, "Provider")
end

@testset "a geometry outside the declared union names both" begin
    point = """
        {"type": "Feature", "stac_version": "1.1.0", "id": "p", "properties": {},
         "links": [], "assets": {},
         "geometry": {"type": "Point", "coordinates": [1.0, 2.0]}}"""

    # The default union is Polygon and MultiPolygon, so a Point item needs `ANY_GEOMETRY`.
    err = try
        STAC.parse(point)
    catch e
        e
    end
    @test err isa STAC.UnknownGeometryType
    @test err.type == "Point"
    @test occursin("Polygon", err.allowed)
    @test STAC.parse(point; geometry = STAC.ANY_GEOMETRY).geometry isa GeoJSON.Point

    typeless = replace(point, "\"type\": \"Point\", " => "")
    err = try
        STAC.parse(typeless)
    catch e
        e
    end
    @test err isa STAC.UnknownGeometryType
    @test err.type === nothing
end

@testset "a bbox of the wrong length says how many numbers it had" begin
    doc = """
        {"type": "Feature", "stac_version": "1.1.0", "id": "b", "properties": {},
         "links": [], "assets": {}, "geometry": null, "bbox": [1.0, 2.0, 3.0]}"""
    err = try
        STAC.parse(doc)
    catch e
        e
    end
    @test err isa STAC.BadBBox
    @test err.n == 3
end

@testset "each throw helper builds the exception its call site names" begin
    @test_throws STAC.MissingCollections("https://example.com/collections") STAC._nocollections("https://example.com/collections")
    @test_throws STAC.NoOrigin("./item.json") STAC.resolve("./item.json", nothing)
    @test_throws STAC.NotQueryable("Int64") STAC.lift(GO.Spherical(), 1)
    @test_throws STAC.BadInterval(3) STAC.datetime_interval([1, 2, 3])
    @test_throws STAC.MethodUnsupported("PathIO", "DELETE") STAC.request(STAC.PathIO(), "DELETE", "x")
    @test_throws STAC.NoRoute("s3", "s3://b/k") STAC.read(StreamRouterIO(("" => STAC.PathIO(),)), "s3://b/k")
    @test_throws STAC.BadDateTime("nope") STAC.parse_rfc3339("nope")
    @test_throws STAC.NoDriverPackage("DuckDBDriver", "DuckDB", "/d/x.pq") STAC._nodriverpackage(STAC.DuckDBDriver(), "/d/x.pq")
end
