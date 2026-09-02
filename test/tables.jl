using STAC, Test, Tables, DataFrames, DataAPI, Dates, JSON, OrderedCollections
using STAC: Item, ItemCollection, Link, Asset, Metadata, EO, Projection

include("fixtures.jl")

const PAGE = STAC.read(joinpath(REAL_DIR, "es.search.json"))
const ITEMS = PAGE.features

@testset "a vector of items is a row table" begin
    @test Tables.istable(typeof(ITEMS))
    @test Tables.rowaccess(typeof(ITEMS))
    rows = Tables.rows(ITEMS)
    @test length(rows) == length(ITEMS)
    @test Tables.getcolumn(first(rows), :id) == first(ITEMS).id
    @test Tables.getcolumn(first(rows), 1) == first(ITEMS).id
    @test :datetime in Tables.columnnames(first(rows))
    @test_throws STAC.MissingColumn(:nosuchcolumn) Tables.getcolumn(first(rows), :nosuchcolumn)
end

@testset "the schema is the stac-geoparquet column layout" begin
    schema = Tables.schema(ITEMS)
    types = Dict(zip(schema.names, schema.types))

    # The typed fields, in the order the layout lists them.
    @test Tuple(schema.names)[1:5] == (:id, :stac_extensions, :geometry, :collection, :bbox)
    @test types[:id] == String
    @test types[:geometry] == fieldtype(eltype(ITEMS), :geometry)
    @test types[:collection] == Union{String,Nothing}
    @test types[:bbox] == Union{Nothing,STAC.BBox4,STAC.BBox6}

    # Every common-metadata field keeps its own type; `other` is not a column.
    @test types[:datetime] == Union{DateTime,Nothing}
    @test types[:gsd] == Union{Float64,Nothing}
    @test types[:instruments] == Union{Vector{String},Nothing}
    @test !haskey(types, :other)

    # One column per field of each declared extension, prefix kept.
    @test types[Symbol("eo:cloud_cover")] == Union{Float64,Nothing}
    @test types[Symbol("proj:shape")] == Union{Vector{Int},Nothing}

    # Keys only the rows know about, then the two nested columns, then the item tails.
    @test types[Symbol("s2:product_type")] == Any
    @test types[:links] == Vector{Link}
    @test types[:assets] == OrderedDict{String,Asset}
    @test length(schema.names) == length(unique(schema.names))
end

@testset "the row values are the item's own" begin
    item = first(ITEMS)
    row = first(Tables.rows(ITEMS))
    @test Tables.getcolumn(row, :datetime) === item.properties.datetime
    @test Tables.getcolumn(row, :geometry) === item.geometry
    @test Tables.getcolumn(row, :links) === item.links
    @test Tables.getcolumn(row, Symbol("eo:cloud_cover")) == item.extensions.eo.cloud_cover
    @test Tables.getcolumn(row, Symbol("s2:product_type")) == item.properties.other["s2:product_type"]

    bbox = Tables.getcolumn(row, :bbox)
    @test bbox == STAC.BBox4(item.bbox)
    @test (bbox.xmin, bbox.ymin, bbox.xmax, bbox.ymax) == item.bbox

    # A six-number bbox keeps its elevation bounds.
    hand = STAC.read(joinpath(HAND_DIR, "hand-item.json"))
    @test Tables.getcolumn(first(Tables.rows([hand])), :bbox) == STAC.BBox6(hand.bbox)
end

@testset "a key no other item carried reads as missing" begin
    hand = STAC.read(joinpath(HAND_DIR, "hand-item.json"))
    both = [hand, STAC.sethref(STAC.read(joinpath(SPEC_DIR, "core-item.json")), nothing)]
    rows = collect(Tables.rows(both))
    @test Tables.getcolumn(rows[1], Symbol("custom_top")) == hand.metadata["custom_top"]
    @test Tables.getcolumn(rows[2], Symbol("custom_top")) === missing
end

@testset "an ItemCollection is the same table" begin
    @test Tables.istable(typeof(PAGE))
    @test Tuple(Tables.schema(PAGE).names) == Tuple(Tables.schema(ITEMS).names)
    @test length(Tables.rows(PAGE)) == length(ITEMS)
end

@testset "DataFrame columns keep the parsed types" begin
    df = DataFrame(ITEMS)
    @test nrow(df) == length(ITEMS)
    @test eltype(df.id) == String
    @test eltype(df.datetime) == Union{DateTime,Nothing}
    @test eltype(df[!, "eo:cloud_cover"]) == Union{Float64,Nothing}
    @test df.id == [item.id for item in ITEMS]
    @test df[1, :bbox].xmin == first(ITEMS).bbox[1]
end

@testset "a column names the extension it comes from" begin
    @test DataAPI.colmetadata(ITEMS, Symbol("eo:cloud_cover"), "stac_extension") ==
          STAC.schema(EO)
    @test DataAPI.colmetadata(ITEMS, Symbol("proj:code"), "stac_extension") ==
          STAC.schema(Projection)
    # A producer key that merely looks prefixed names no schema.
    @test DataAPI.colmetadatakeys(ITEMS, Symbol("s2:product_type")) == ()
    @test DataAPI.colmetadata(ITEMS, :id, "stac_extension", nothing) === nothing

    # DataFrames copies `:note` metadata from any table that reports it.
    df = DataFrame(ITEMS)
    @test colmetadata(df, Symbol("eo:cloud_cover"), "stac_extension") == STAC.schema(EO)
    @test colmetadatakeys(df, :id) == ()
end

@testset "an object's own tail answers DataAPI.metadata" begin
    col = STAC.read(joinpath(REAL_DIR, "pc.collection.json"))
    @test DataAPI.metadatasupport(typeof(col)) == (read = true, write = false)
    @test "msft:storage_account" in DataAPI.metadatakeys(col)
    @test DataAPI.metadata(col, "msft:storage_account") ==
          col.metadata["msft:storage_account"]
    @test DataAPI.metadata(col, "msft:storage_account"; style = true)[2] === :note
    @test DataAPI.metadata(col, "nosuchkey", missing) === missing
    @test_throws KeyError DataAPI.metadata(col, "nosuchkey")

    item = first(ITEMS)
    @test collect(DataAPI.metadatakeys(item)) == collect(keys(item.metadata))

    # `metadata = false` kept no tail, so there is nothing to report.
    bare = STAC.read(joinpath(HAND_DIR, "hand-item.json"); metadata = false)
    @test isempty(DataAPI.metadatakeys(bare))
end

@testset "a tail key never shadows a column the layout already has" begin
    raw = JSON.parse(Base.read(joinpath(SPEC_DIR, "core-item.json"), String))
    raw["properties"]["links"] = "not the item's links"
    item = STAC.parse(JSON.json(raw))
    @test item.properties.other["links"] == "not the item's links"

    row = first(Tables.rows([item]))
    @test Tables.getcolumn(row, :links) === item.links
    @test count(==(:links), Tables.columnnames(row)) == 1
end
