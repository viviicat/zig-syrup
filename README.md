# zig-syrup

This is a partially-implemented Zig Syrup implementation.

This library still needs work, and hasn't been checked for security issues. Use at your own risk.

See [The Syrup Specification](https://github.com/ocapn/syrup/blob/master/draft-specification.md) for details.

## Documentation

[Documentation](https://vvv.gay/docs/zig-syrup) is available using the standard Zig documentation browser.

## Implemented data types

### Reader

- [x] Booleans
- [x] Floats
- [x] Doubles
- [x] Positive integers
- [x] Negative integers
- [x] Binary data
- [x] Strings
- [x] Symbols
- [x] Dictionaries
- [x] Sequences
- [x] Records
- [x] Sets

### Writer

- [x] Booleans
- [x] Floats
- [x] Doubles
- [x] Positive integers
- [x] Negative integers
- [x] Binary data
- [x] Strings
- [x] Symbols
- [x] Dictionaries
- [x] Sequences
- [x] Records
- [x] Sets

## Zig types

Zig Types that can be (de)serialized to Syrup

### Writer

- [x] integers (any length)
- [x] f32
- [x] f64
- [x] comptime integers
- [x] comptime float (as f64)
- [x] optionals
- [x] enum literals
- [x] arrays
- [x] slices
- [x] vectors
- [x] `[]const u8`
- [ ] HashMap - need tests
- [ ] Set - need tests
- [x] structs
  - [x] as Record (label is the type name)
  - [x] as Sequence (just the field values)
  - [x] as Dictionary (key is the field name)
- [x] unions
- [x] tuples
- [x] general pointers
- [x] `dynamic.Value`

### Reader

- [x] integers (any length)
- [x] f32
- [x] f64
- [x] optionals
- [x] enum literals
- [x] arrays
- [x] slices
- [x] vectors
- [x] `[]const u8`
- [ ] HashMap
- [ ] Set
- [x] structs
  - [x] from Record (label is the type name)
  - [x] from Sequence (just the field values)
  - [x] from Dictionary (key is the field name)
- [x] unions
- [x] tuples
- [x] general pointers
- [x] `dynamic.Value`

## Benchmark

There is a benchmarking tool available at [zig-syrup-benchmark](https://codeberg.org/vivicat/zig-syrup-benchmark). This also serves an example of how to add the Syrup library to a project.

## TODO

- [x] **ZON to syrup conversion** - Zig's ZON format could possibly be converted to Syrup, if we so pleased.
- [x] **Serializing Zig structures** - Use comptime to convert Zig structs, slices, etc to Syrup format
- [x] **Benchmarking** - [`zig-syrup-benchmark`](https://codeberg.org/vivicat/zig-syrup-benchmark)
  - Could do more.
- [ ] **Fuzz testing** - Zig has fuzz testing support in the standard library we could play with.
- [x] **`jsyrup` support** - human readable syrup format
  - [ ] Indented `jsyrup`
- [x] **syrupify** - Add support for user function to transform zig struct
- [x] **[`libsyrup`](https://codeberg.org/vivicat/libsyrup)** - a C API for the low level syrup serialization
- [ ] **CLI tool** - to quickly pretty-print syrup structure and convert to jsyrup, unsure if converting ZON to syrup is useful here without type information, maybe it's possible/useful.

