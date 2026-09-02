import STAC
using Documenter, DocumenterVitepress

# Loading the bridges gives the Rasters and DuckDB pages methods to document and examples to
# run; without them `Raster(asset)` is a name the session does not have.
import ArchGDAL, DuckDB, Rasters

# `import STAC` alone, which is how every example in the docs is written: a name this package
# owns is spelled `STAC.foo` whether or not it is exported. Each page that needs more says so
# in its own `DocTestSetup`, so a docstring example stays runnable in a reader's session.
DocMeta.setdocmeta!(STAC, :DocTestSetup, :(import STAC); recursive = true)

makedocs(;
    modules = [STAC],
    authors = "Anshul Singhvi <anshulsinghvi@gmail.com> and contributors",
    sitename = "STAC.jl",
    repo = Documenter.Remotes.GitHub("asinghvi17", "STAC.jl"),
    format = DocumenterVitepress.MarkdownVitepress(
        repo = "github.com/asinghvi17/STAC.jl",
        devbranch = "main",
        devurl = "dev",
    ),
    pages = [
        "Home" => "index.md",
        "Guide" => [
            "Reading a catalog" => "objects.md",
            "Searching" => "search.md",
            "Fetching and credentials" => "io.md",
            "Items as features and tables" => "features.md",
            "Spatial selection" => "spatial.md",
            "Opening assets as rasters" => "rasters.md",
            "Extensions" => "extensions.md",
            "Bulk formats" => "formats.md",
            "Static compilation" => "compilation.md",
        ],
        "API reference" => "api.md",
    ],
    checkdocs = :all,
    doctest = true,
)

DocumenterVitepress.deploydocs(;
    repo = "github.com/asinghvi17/STAC.jl",
    devbranch = "main",
    push_preview = true,
)
