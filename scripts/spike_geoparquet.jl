# What DuckDB.jl hands back for stac-geoparquet's nested columns, and which of the two read
# paths the design sketched survives contact with it. Run by hand:
#
#     julia scripts/spike_geoparquet.jl [path/to/items.parquet]
#
# It builds its own environment, so it needs the network once and nothing from the test env.
# The write-up is 09-spike-geoparquet-duckdb.md.

using Pkg

Pkg.activate(; temp = true)
Pkg.add(["DuckDB", "Tables"]; io = devnull)

using DuckDB, Tables
using DuckDB: DBInterface

const PATH = get(ARGS, 1, joinpath(@__DIR__, "..", "test", "fixtures", "geoparquet",
                                   "items.parquet"))

const con = DBInterface.connect(DuckDB.DB, ":memory:")

q(sql) = Tables.columntable(DBInterface.execute(con, sql))

banner(title) = println("\n", "─"^78, "\n", title, "\n", "─"^78)

source = string("read_parquet('", PATH, "')")

banner("1. DuckDB build: which extensions answer, and which are only downloadable")
e = q("SELECT extension_name, loaded, install_mode FROM duckdb_extensions()")
for i in eachindex(e.extension_name)
    e.loaded[i] && println("  loaded  ", rpad(e.extension_name[i], 16), e.install_mode[i])
end
st = q("SELECT count(*) AS n FROM duckdb_functions() WHERE function_name ILIKE 'st\\_%'")
println("  ST_ functions available without the spatial extension: ", st.n[1])

banner("2. The column types DuckDB reports")
d = q(string("DESCRIBE SELECT * FROM ", source))
for i in eachindex(d.column_name)
    println("  ", rpad(d.column_name[i], 22), first(d.column_type[i], 90))
end

banner("3. The Julia types DuckDB.jl materialises them as")
t = Tables.columntable(DBInterface.execute(con, string("SELECT * FROM ", source)))
for (k, v) in pairs(t)
    println("  ", rpad(String(k), 22), typeof(v))
end

banner("4. The preferred path: a nested value, column-wise")
println("  bbox[1]   = ", t.bbox[1])
println("  links[1]  = ", t.links[1][1])
println("  assets[1] keys = ", keys(t.assets[1]))
println("  assets[1].analytic :: ", typeof(t.assets[1].analytic))
println("  geometry[1] :: ", typeof(t.geometry[1]), ", ",
        length(t.geometry[1]), " bytes, first 5 = ",
        collect(UInt8, t.geometry[1])[1:5])

banner("5. The fallback path: to_json(t) per row")
j = q(string("SELECT to_json(t) AS j FROM ", source, " t"))
println("  column type: ", typeof(j.j))
println("  row 1, first 400 characters:\n    ", first(j.j[1], 400))
println("  nulls in row 1: ", length(collect(eachmatch(r":null", j.j[1]))))

banner("6. How far does DuckDB's own null-stripper reach?")
nested = "'{\"a\":1,\"b\":null,\"c\":{\"d\":null,\"e\":2},\"f\":[{\"g\":null,\"h\":3}]}'"
println("  in:  ", strip(nested, '\''))
println("  out: ", q(string("SELECT json_merge_patch('{}', ", nested, ")::VARCHAR AS r")).r[1])

banner("7. Timestamps: what reaches the parser, and in whose time zone")
ts = findall(i -> occursin("TIMESTAMP", d.column_type[i]), eachindex(d.column_name))
if !isempty(ts)
    name = d.column_name[first(ts)]
    col = string('"', name, '"')
    show(sql) = try
        r = q(string("SELECT ", sql, " AS v FROM ", source))
        println("    ", join(filter(!ismissing, collect(r.v)), "   "))
    catch e
        println("    raises: ", first(sprint(showerror, e), 120))
    end
    for tz in ("America/New_York", "UTC")
        DBInterface.execute(con, string("SET TimeZone='", tz, "'"))
        println("  TimeZone = ", tz, ", column ", name, " :: ", d.column_type[first(ts)])
        println("  ", col, "::VARCHAR")
        show(string(col, "::VARCHAR"))
        println("  strftime(", col, ", '%Y-%m-%dT%H:%M:%S.%fZ')")
        show(string("strftime(", col, ", '%Y-%m-%dT%H:%M:%S.%fZ')"))
        println("  strftime(", col, " AT TIME ZONE 'UTC', '%Y-%m-%dT%H:%M:%S.%fZ')")
        show(string("strftime(", col, " AT TIME ZONE 'UTC', '%Y-%m-%dT%H:%M:%S.%fZ')"))
    end
end

DBInterface.close!(con)
