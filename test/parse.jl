using STAC, Test, JSON, Dates, GeoJSON
using STAC: Item, Catalog, Collection, ItemCollection, STACStyle, ParseOptions, itemtype

include("fixtures.jl")

const TYPEOF_DOCTYPE = Dict(
    "Feature" => Item,
    "FeatureCollection" => ItemCollection,
    "Catalog" => Catalog,
    "Collection" => Collection,
)

@testset "every stac-spec example parses into the type its `type` key names" begin
    for path in jsonfiles(SPEC_DIR)
        raw = JSON.parse(read(path))
        obj = STAC.read(path)
        @test obj isa TYPEOF_DOCTYPE[raw["type"]]
        @test obj.href == abspath(path)
    end
end

@testset "extended-item fills the declared extensions" begin
    item = STAC.read(joinpath(SPEC_DIR, "extended-item.json"))
    @test item.extensions.eo.cloud_cover isa Float64
    @test item.extensions.eo.cloud_cover == 1.2
    @test item.extensions.proj.code isa String
    @test item.extensions.proj.code == "EPSG:32659"
    @test item.extensions.proj.shape == [5558, 9559]
    @test item.extensions.view.sun_elevation == 54.9
    @test item.extensions.sci.doi == "10.5061/dryad.s2v81.2/27.2"
    # Keys of extensions with no struct stay reachable on the property tail.
    @test haskey(item.properties.other, "rd:sat_id")
end

@testset "the typed parse is inferable" begin
    bytes = read(joinpath(SPEC_DIR, "extended-item.json"))
    T = itemtype(ParseOptions())
    @test @inferred(JSON.parse(bytes, T; style = STACStyle())) isa T
end

@testset "hand-item exercises the shapes the spec examples miss" begin
    item = STAC.read(joinpath(HAND_DIR, "hand-item.json"))
    @test item.geometry isa GeoJSON.MultiPolygon{2,Float64}
    @test item.bbox === (0.0, 0.0, -1.0, 1.0, 1.0, 5.0)

    # Six fractional digits truncate to milliseconds; offsets are applied.
    @test item.properties.datetime == DateTime(2024, 6, 12, 18, 59, 21, 123)
    @test item.properties.start_datetime == DateTime(2024, 6, 12, 18, 59, 21)
    @test item.properties.end_datetime == DateTime(2024, 6, 12, 16, 59, 21)

    @test item.extensions.eo.cloud_cover == 3.5
    @test item.extensions.proj.epsg == 4326
    @test item.extensions.proj.code === nothing
    @test item.extensions.sat.orbit_state == "ascending"
    @test isempty(item.properties.other)

    @test collect(keys(item.metadata)) == ["stac_version", "custom_top", "zzz"]
    @test item.collection === nothing
    @test collect(keys(item.links[1].metadata)) == ["extra", "nested"]
    @test collect(keys(item.assets["data"].metadata)) == ["checksum:multihash"]
end

@testset "metadata = false skips the tails" begin
    item = STAC.read(joinpath(HAND_DIR, "hand-item.json"); metadata = false)
    @test item.metadata === STAC.NoMetadata()
    @test item.properties.other === STAC.NoMetadata()
    @test item.properties.datetime == DateTime(2024, 6, 12, 18, 59, 21, 123)
    @test item.extensions.eo.cloud_cover == 3.5
end

@testset "extensions = () keeps every prefixed key on the property tail" begin
    item = STAC.read(joinpath(HAND_DIR, "hand-item.json"); extensions = ())
    @test item isa Item{Any}
    @test item.extensions === nothing
    @test haskey(item.properties.other, "eo:cloud_cover")
    @test haskey(item.properties.other, "proj:epsg")
end

@testset "parse accepts bytes, strings, and a named target type" begin
    bytes = read(joinpath(SPEC_DIR, "simple-item.json"))
    T = itemtype(ParseOptions())
    @test STAC.parse(bytes) isa Item
    @test STAC.parse(String(copy(bytes))) isa Item
    @test STAC.parse(bytes, T) isa T
    @test STAC.parse(bytes).href === nothing
end

@testset "a document with no usable `type` is rejected" begin
    @test_throws ArgumentError STAC.parse("{\"id\": \"x\"}")
    @test_throws ArgumentError STAC.parse("{\"type\": \"Point\"}")
end

@testset "RFC 3339 parsing covers the forms the spec allows" begin
    @test STAC.parse_rfc3339("2024-06-12T18:59:21Z") == DateTime(2024, 6, 12, 18, 59, 21)
    @test STAC.parse_rfc3339("2024-06-12t18:59:21z") == DateTime(2024, 6, 12, 18, 59, 21)
    @test STAC.parse_rfc3339("2024-06-12T18:59:21.5Z") == DateTime(2024, 6, 12, 18, 59, 21, 500)
    @test STAC.parse_rfc3339("2024-06-12T18:59:21.123456789Z") ==
          DateTime(2024, 6, 12, 18, 59, 21, 123)
    @test STAC.parse_rfc3339("2024-06-12T18:59:21-03:30") == DateTime(2024, 6, 12, 22, 29, 21)
    @test STAC.parse_rfc3339("2024-06-12") == DateTime(2024, 6, 12)
    @test_throws ArgumentError STAC.parse_rfc3339("2024-06-12T18:59:21+0000")
    @test_throws ArgumentError STAC.parse_rfc3339("yesterday")
end

@testset "format_rfc3339 writes what parse_rfc3339 reads" begin
    for s in ("2024-06-12T18:59:21Z", "2024-06-12T18:59:21.123Z")
        @test STAC.format_rfc3339(STAC.parse_rfc3339(s)) == s
    end
end
