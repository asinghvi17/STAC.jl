var documenterSearchIndex = {"docs":
[{"location":"","page":"Home","title":"Home","text":"CurrentModule = STAC","category":"page"},{"location":"#STAC","page":"Home","title":"STAC","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"Documentation for STAC, a Julia client implementation of the SpatioTemporal Asset Catalogs.","category":"page"},{"location":"#STAC-catalog","page":"Home","title":"STAC catalog","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"STAC.Catalog\nkeys(cat::Catalog)\ngetindex(cat::Catalog,child_id::AbstractString)\neachcatalog(catalog::Catalog)\neachitem(catalog::Catalog)\nSTAC.search\ntype(cat::Catalog)\nstac_version(cat::Catalog)\nstac_extensions(cat::Catalog)\nid(cat::Catalog)\ntitle(cat::Catalog)\ndescription(cat::Catalog)\nkeywords(cat::Catalog)\nlicense(cat::Catalog)\nproviders(cat::Catalog)\nextent(cat::Catalog)\nsummaries(cat::Catalog)","category":"page"},{"location":"#STAC.Catalog","page":"Home","title":"STAC.Catalog","text":"cat = STAC.Catalog(url)\n\nOpen a SpatioTemporal Asset Catalog (STAC) using the provided url. The url should point to a JSON object conforming to the STAC specification.\n\ncat behaves as a julia dictionary with all STAC subcatalogs. cat.items is a dictionary with all STAC items.\n\nusing STAC\nurl = \"https://raw.githubusercontent.com/sat-utils/sat-stac/master/test/catalog/catalog.json\"\ncat = STAC.Catalog(url)\nsubcat = cat[\"stac-catalog-eo\"]\nsubcat1 = subcat[\"landsat-8-l1\"]\n@show subcat1\n\nitem = subcat1.items[\"LC08_L1TP_152038_20200611_20200611_01_RT\"]\n@show href(item.assets[\"B4\"])\n\n\n\n\n\n","category":"type"},{"location":"#Base.keys-Tuple{STAC.Catalog}","page":"Home","title":"Base.keys","text":"child_ids = keys(cat::Catalog)\nsubcat = cat[child_id]\n\nReturns all subcatalog identifiers of the STAC catalog cat.\n\nurl = \"https://raw.githubusercontent.com/sat-utils/sat-stac/master/test/catalog/catalog.json\"\ncat = STAC.Catalog(url);\nkeys(cat)\n\n\n\n\n\n","category":"method"},{"location":"#Base.getindex-Tuple{STAC.Catalog, AbstractString}","page":"Home","title":"Base.getindex","text":"subcat = getindex(cat::Catalog,child_id::AbstractString)\nsubcat = cat[child_id]\n\nReturns the subcatalogs with the identifier child_id\n\nurl = \"https://raw.githubusercontent.com/sat-utils/sat-stac/master/test/catalog/catalog.json\"\ncat = STAC.Catalog(url);\nsubcat = cat[\"stac-catalog-eo\"]\n\n\n\n\n\n","category":"method"},{"location":"#STAC.eachcatalog-Tuple{STAC.Catalog}","page":"Home","title":"STAC.eachcatalog","text":"cats = eachcatalog(catalog::Catalog)\n\nReturns resursively all subcatalogs in catalog. This can take a long time for deeply nested catalogs.\n\nurl = \"https://raw.githubusercontent.com/sat-utils/sat-stac/master/test/catalog/catalog.json\"\n\ncat = STAC.Catalog(url)\nfor c in eachcatalog(cat)\n    @show id(c)\nend\n\n\n\n\n\n","category":"method"},{"location":"#STAC.eachitem-Tuple{STAC.Catalog}","page":"Home","title":"STAC.eachitem","text":"cats = eachitem(catalog::Catalog)\n\nReturns resursively all items in catalog. This can take a long time for deeply nested catalogs.\n\nurl = \"https://raw.githubusercontent.com/sat-utils/sat-stac/master/test/catalog/catalog.json\"\n\ncat = STAC.Catalog(url)\nfor c in eachitem(cat)\n    @show id(c)\nend\n\n\n\n\n\n","category":"method"},{"location":"#STAC.search","page":"Home","title":"STAC.search","text":"search(cat::Catalog, collections, lon_range, lat_range, datetime;\n       limit = 200,\n       filter = nothing,\n       query = nothing,\n)\n\nSearch items in a STAC.Catalog cat belong to the collections within the longitude range lon_range (start and end longitude), latitude range lat_range, and time range (start and end DateTime).\n\nThe optional filter parameter allows to filter the resuts using CQL2 (see example below). STACQL is also supported via the optional query parameter. It is recommended to use CQL2 instead of STACQL. This filter and query are experimental and currently only part of the STAC as a \"candiate\" or \"pilot\".\n\nThe function search returns an julia Channel with the search results over which one can only iterate once. If the results should be saved use search_results = collect(search(cat,...)).\n\nExample:\n\nusing STAC, Dates\ncollections = [\"landsat-8-c2-l2\"]\ntime_range = (DateTime(2018,01,01), DateTime(2018,01,02))\nlon_range = (2.51357303225, 6.15665815596)\nlat_range = (49.5294835476, 51.4750237087)\n\ncatalog = STAC.Catalog(\"https://planetarycomputer.microsoft.com/api/stac/v1\")\n\nsearch_results = collect(search(catalog, collections, lon_range, lat_range, time_range))\n\nExample with additional CQL2 filter\n\nfilter = Dict(\n   \"op\" => \"<=\",\n   \"args\" => [Dict(\"property\" => \"eo:cloud_cover\"), 61]\n)\n\nsearch_results = collect(\n        search(cat, collections,\n               lon_range, lat_range, time_range,\n               filter = filter,\n))\n\n\n\n\n\n","category":"function"},{"location":"#STAC.type-Tuple{STAC.Catalog}","page":"Home","title":"STAC.type","text":"data = type(cat::Catalog; default = nothing)\n\nGet the type of a STAC catalog (or default if it is not specified).\n\n\n\n\n\n","category":"method"},{"location":"#STAC.stac_version-Tuple{STAC.Catalog}","page":"Home","title":"STAC.stac_version","text":"data = stac_version(cat::Catalog; default = nothing)\n\nGet the stac version of a STAC catalog (or default if it is not specified).\n\n\n\n\n\n","category":"method"},{"location":"#STAC.stac_extensions-Tuple{STAC.Catalog}","page":"Home","title":"STAC.stac_extensions","text":"data = stac_extensions(cat::Catalog; default = nothing)\n\nGet the stac extensions of a STAC catalog (or default if it is not specified).\n\n\n\n\n\n","category":"method"},{"location":"#STAC.id-Tuple{STAC.Catalog}","page":"Home","title":"STAC.id","text":"data = id(cat::Catalog; default = nothing)\n\nGet the identifier of a STAC catalog (or default if it is not specified).\n\n\n\n\n\n","category":"method"},{"location":"#STAC.title-Tuple{STAC.Catalog}","page":"Home","title":"STAC.title","text":"data = title(cat::Catalog; default = nothing)\n\nGet the title of a STAC catalog (or default if it is not specified).\n\n\n\n\n\n","category":"method"},{"location":"#STAC.description-Tuple{STAC.Catalog}","page":"Home","title":"STAC.description","text":"data = description(cat::Catalog; default = nothing)\n\nGet the description of a STAC catalog (or default if it is not specified).\n\n\n\n\n\n","category":"method"},{"location":"#STAC.keywords-Tuple{STAC.Catalog}","page":"Home","title":"STAC.keywords","text":"data = keywords(cat::Catalog; default = nothing)\n\nGet the keywords of a STAC catalog (or default if it is not specified).\n\n\n\n\n\n","category":"method"},{"location":"#STAC.license-Tuple{STAC.Catalog}","page":"Home","title":"STAC.license","text":"data = license(cat::Catalog; default = nothing)\n\nGet the license of a STAC catalog (or default if it is not specified).\n\n\n\n\n\n","category":"method"},{"location":"#STAC.providers-Tuple{STAC.Catalog}","page":"Home","title":"STAC.providers","text":"data = providers(cat::Catalog; default = nothing)\n\nGet the providers of a STAC catalog (or default if it is not specified).\n\n\n\n\n\n","category":"method"},{"location":"#STAC.extent-Tuple{STAC.Catalog}","page":"Home","title":"STAC.extent","text":"data = extent(cat::Catalog; default = nothing)\n\nGet the extent of a STAC catalog (or default if it is not specified).\n\n\n\n\n\n","category":"method"},{"location":"#STAC.summaries-Tuple{STAC.Catalog}","page":"Home","title":"STAC.summaries","text":"data = summaries(cat::Catalog; default = nothing)\n\nGet the summaries of a STAC catalog (or default if it is not specified).\n\n\n\n\n\n","category":"method"},{"location":"#STAC-item","page":"Home","title":"STAC item","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"id(item::Item)\nbbox(item::Item)\nlinks(item::Item)\nproperties(item::Item)\nDateTime(item::Item)\ngeometry(item::Item)","category":"page"},{"location":"#STAC.id-Tuple{STAC.Item}","page":"Home","title":"STAC.id","text":" data = id(item)\n\nGet the identifier of STAC item.\n\n\n\n\n\n","category":"method"},{"location":"#STAC.bbox-Tuple{STAC.Item}","page":"Home","title":"STAC.bbox","text":" data = bbox(item)\n\nGet the bounding box of STAC item.\n\n\n\n\n\n","category":"method"},{"location":"#STAC.links-Tuple{STAC.Item}","page":"Home","title":"STAC.links","text":" data = links(item)\n\nGet the links of STAC item.\n\n\n\n\n\n","category":"method"},{"location":"#STAC.properties-Tuple{STAC.Item}","page":"Home","title":"STAC.properties","text":" data = properties(item)\n\nGet the properties of STAC item.\n\n\n\n\n\n","category":"method"},{"location":"#Dates.DateTime-Tuple{STAC.Item}","page":"Home","title":"Dates.DateTime","text":"dt = DateTime(item)\n\nGet the date time of STAC item as a Dates.DateTime (or nothing if this properties is not specified).\n\n\n\n\n\n","category":"method"},{"location":"#STAC.geometry-Tuple{STAC.Item}","page":"Home","title":"STAC.geometry","text":"data = geometry(item)\n\nGet the geometry of STAC item as a GeoJSON object\n\n\n\n\n\n","category":"method"},{"location":"#STAC-asset","page":"Home","title":"STAC asset","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"href(asset::Asset)\ntitle(asset::Asset)\ndescription(asset::Asset)\ntype(asset::Asset)","category":"page"},{"location":"#STAC.href-Tuple{STAC.Asset}","page":"Home","title":"STAC.href","text":" data = href(asset; default = nothing)\n\nGet the URI of a STAC asset (or default if it is not specified).\n\n\n\n\n\n","category":"method"},{"location":"#STAC.title-Tuple{STAC.Asset}","page":"Home","title":"STAC.title","text":" data = title(asset; default = nothing)\n\nGet the title of a STAC asset (or default if it is not specified).\n\n\n\n\n\n","category":"method"},{"location":"#STAC.description-Tuple{STAC.Asset}","page":"Home","title":"STAC.description","text":" data = description(asset; default = nothing)\n\nGet the description of a STAC asset (or default if it is not specified).\n\n\n\n\n\n","category":"method"},{"location":"#STAC.type-Tuple{STAC.Asset}","page":"Home","title":"STAC.type","text":" data = type(asset; default = nothing)\n\nGet the type of a STAC asset (or default if it is not specified).\n\n\n\n\n\n","category":"method"},{"location":"#Cache","page":"Home","title":"Cache","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"STAC.set_cache_max_size\nSTAC.empty_cache()","category":"page"},{"location":"#STAC.set_cache_max_size","page":"Home","title":"STAC.set_cache_max_size","text":"STAC.set_cache_max_size(cache_max_size::Integer)\n\nSet the maximum number of URLs saved in cache (permanentaly). The default is 1000.\n\n\n\n\n\n","category":"function"},{"location":"#STAC.empty_cache-Tuple{}","page":"Home","title":"STAC.empty_cache","text":"STAC.empty_cache()\n\nEmpty the URL cache.\n\n\n\n\n\n","category":"method"},{"location":"#Customize","page":"Home","title":"Customize","text":"","category":"section"},{"location":"","page":"Home","title":"Home","text":"The color scheme used of the STAC client can be customized by the following functions:","category":"page"},{"location":"","page":"Home","title":"Home","text":"STAC.set_catalog_color\nSTAC.set_asset_color\nSTAC.set_item_color\nSTAC.set_title_color","category":"page"},{"location":"#STAC.set_catalog_color","page":"Home","title":"STAC.set_catalog_color","text":"    STAC.set_catalog_color(color::Symbol)\n\nSet the catalog color. The default color is Base.info_color(). The color is saved using Preferences.jl.\n\n\n\n\n\n","category":"function"},{"location":"#STAC.set_asset_color","page":"Home","title":"STAC.set_asset_color","text":"    STAC.set_asset_color(color::Symbol)\n\nSet the asset color. The default color is Base.info_color(). The color is saved using Preferences.jl.\n\n\n\n\n\n","category":"function"},{"location":"#STAC.set_item_color","page":"Home","title":"STAC.set_item_color","text":"    STAC.set_item_color(color::Symbol)\n\nSet the item color. The default color is Base.info_color(). The color is saved using Preferences.jl.\n\n\n\n\n\n","category":"function"},{"location":"#STAC.set_title_color","page":"Home","title":"STAC.set_title_color","text":"    STAC.set_title_color(color::Symbol)\n\nSet the title color. The default color is Base.error_color(). The color is saved using Preferences.jl.\n\n\n\n\n\n","category":"function"}]
}
