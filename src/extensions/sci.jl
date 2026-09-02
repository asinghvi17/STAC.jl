"""
    Scientific

The Scientific Citation extension, version 1.0.0: how to cite the data.

`sci:publications`, a list of `{doi, citation}` objects, has no typed slot and stays on the
tail. Collections carry these keys at the top level, so `Scientific(collection)` reads them
from the collection's metadata while `Scientific(item)` reads them from its properties.
"""
struct Scientific <: Extension
    doi::Union{String,Nothing}
    citation::Union{String,Nothing}
end

prefix(::Type{Scientific}) = "sci"
schema(::Type{Scientific}) = "https://stac-extensions.github.io/scientific/v1.0.0/schema.json"
