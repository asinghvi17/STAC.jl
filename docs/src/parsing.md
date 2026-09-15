```@meta
CurrentModule = STAC
DocTestSetup = quote
    import STAC
end
```

# Typed parsing and trimming

The parser turns known JSON keys directly into typed fields and preserves unfamiliar keys in metadata tails. Its central input is `STAC.ParseOptions{E,G,M}`: the extension layout, accepted geometry types, and metadata policy. Those parameters determine the item type before its values arrive.

This page explains the implementation choices. [Extensions](extensions.md) shows how to define a schema; [Static compilation](compilation.md) shows how to build a binary.

## Why each extension is a struct

An extension struct is a small schema. Its field names identify JSON keys after the prefix; its field types tell the parser how to construct their values. `STAC.EO` and `STAC.Projection` can evolve independently, and callers can select either without putting every extension's fields on every item.

The selected structs become a **named-tuple type**. Each slot allows its extension or `nothing`, so items with different metadata can share one layout:

```jldoctest
julia> E = STAC.extensiontype((STAC.EO, STAC.Projection));

julia> fieldnames(E)
(:eo, :proj)

julia> fieldtype(E, :eo) === Union{Nothing,STAC.EO}
true
```

The parser uses that layout to generate a finite set of key comparisons and typed constructors. For `eo:cloud_cover`, the route already knows the destination is the `cloud_cover` field of `STAC.EO`; it does not consult a runtime registry to discover a type.

**Trimming requires statically resolvable calls, not structs specifically.** The structs provide this implementation's schemas; the concrete named tuple and parse options make the selected schemas known to the compiler. A struct hidden behind an unresolved runtime type choice would not provide the same guarantee.

| Choice | Reason |
|---|---|
| One struct per extension | Field names, types, and constructor describe one schema |
| One named-tuple type for the eager set | The parser knows every possible eager destination |
| Optional extension slots | Missing extensions keep the same item type |
| Optional fields within each struct | Producers can supply only part of an extension |
| Separate `schema` method | Declaration queries can inspect producer claims independently of parsing |

Nullable fields solve a data-model problem; they are not a trimming trick. Likewise, `stac_extensions` does not choose the parse layout. The caller chooses the eager set, and the keys in the document supply the values.

## One property object fills three destinations

The item-property sink routes each key in this order:

1. A core property field, such as `datetime`.
2. A field of an eagerly selected extension, such as `eo:cloud_cover`.
3. The property tail, for everything else.

This avoids building a complete intermediate dictionary and then scanning it once per extension. Document and geometry discrimination can make an earlier scan for `type`; the single-pass property routing is the useful guarantee here.

An extension outside the eager set remains accessible through the tail. `get(item, STAC.EO)` uses the eager slot when available; otherwise it looks up each field and constructs a fresh value. It does not cache that reconstruction.

`NoMetadata` makes the sink skip unrecognized values in the parameterized document and property tails. Eager values survive. Nested objects such as assets and links still have their own fixed `Metadata` tails. The shipped extension schemas also leave nested extension objects on tails; typing one would require its own parse and write support.

## Why the parser has callable sinks and generated ladders

`StructUtils.applyeach` walks the JSON source and calls a *sink* for each key/value pair. STAC's sinks are callable structs whose type parameters carry the target and metadata policy.

The source can look more elaborate than a generic recursive parser. Each piece keeps a particular call resolvable:

| Pattern | What it gives the compiler |
|---|---|
| Callable sink structs | Specialized call targets through the forwarding `applyeach` path, where closure-based sinks left unresolved calls |
| Generated key and field ladders | Literal key comparisons and statically named field types |
| Distinct `make` methods for nested targets | Separate parse paths where shared recursive construction left unresolved invokes |
| `StructUtils.lift(style, Any, value)` for tails | JSON's generic materializer with explicit value-type handling |
| Integer-key methods on object sinks | A resolvable error branch when JSON dispatch considers an array |

These are constraints observed in this parser's integration with StructUtils and JSON.jl, not blanket rules against Julia closures or recursion. Some method families use `@eval`; other paths are handwritten. The property that matters is the resulting call graph.

Temporary slots can still contain `Any`. Construction reads each slot with its known field type. The same principle applies elsewhere: an `Any` value needs narrowing at the call site before a typed operation; merely adding more methods does not tell the caller which one to invoke.

Read [`parse/sinks.jl`](https://github.com/asinghvi17/STAC.jl/blob/main/src/parse/sinks.jl) in this order: `makefield!`, `construct`, `extkeyindex`, `makeextfield!`, `PropSink`, then the item `make` method.

## Error paths are part of the program

The verifier follows failure branches too. Package exceptions live under `STACError` in [`errors.jl`](https://github.com/asinghvi17/STAC.jl/blob/main/src/errors.jl), with four groups: document, lookup, argument-shape, and endpoint errors.

An exception stores the values its message needs as strings, integers, or symbols. Throw helpers convert a statically known type to a string; `showerror` prints stored fields one argument at a time. This keeps dynamic type formatting and interpolation out of the error-reporting path. Small `@noinline` throw helpers also keep failure construction out of the caller's inlined code.

## Reading and writing have different trim boundaries

The typed reader has a destination type at each known field. The writer lowers values to `JSON.Object{String,Any}` and asks JSON.jl to serialize them. That reintroduces unresolved calls even when metadata retention is disabled. Typed extensions therefore help the read path without making the writer trim-safe.

The eager tuple defines an item's layout, not every extension method a binary can contain. A statically named tail lookup may bring additional constructors into the call graph; arbitrary runtime discovery is a separate question. Check the actual program with the verifier.

The [compile tests](https://github.com/asinghvi17/STAC.jl/tree/main/test/compile) make this distinction executable: the read and static-search programs must link without verifier errors; the API program has a budget for known unresolved statements. An ordinary inference test is useful, but it does not replace that whole-program check.

## Where a model change belongs

| Change | Edits that keep the layers in agreement |
|---|---|
| Add a core struct with a tail | Struct definition, synthetic-field count, its parse method, writer lowering, fixture and round-trip test |
| Add a STAC extension schema | Nullable-field struct, prefix and schema methods, module include, access-path tests; choose deliberately whether it belongs in the default eager set |
| Add a nested typed extension value | Its construction and lowering methods as well as the containing field |
| Add a failure mode | Exception and display method in `errors.jl`, throw helper, failure-path test |

Keep each concern in its own source file. Verify the public behavior first, then run the relevant trim program when a change reaches a supported static path.
