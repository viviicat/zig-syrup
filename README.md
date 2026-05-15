This is a partially-implemented Zig Syrup implementation.

This library still needs work, and hasn't been checked for security issues. Use at your own risk.

See [The Syrup Specification](https://github.com/ocapn/syrup/blob/master/draft-specification.md) for details.

# Documentation

I'll probably add some build script for this, but for now, to browse documentation:

1. `zig build-lib -femit-docs src/root.zig` to build docs into docs/
2. `python -m http.server 8080 -d docs/` (or some other similar minimal web server)
3. Go to [localhost:8080](http://localhost:8080) (idk why i'm even explaining this)

# Implemented data types

## Reader

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

## Writer

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
- [ ] enum literals
- [x] arrays
- [x] slices (only slices of Value)
- [x] vectors
- [x] `[]const u8`
- [x] structs 
  - [x] as Record (label is the type name)
  - [x] as Sequence (just the field values)
  - [x] as Dictionary (key is the field name)
- [ ] unions
- [ ] tuples
- [ ] error sets
- [x] general pointers

### Reader

- [ ] integers (any length)
- [ ] f32
- [ ] f64
- [ ] comptime integers
- [ ] comptime float (as f64)
- [ ] optionals
- [ ] enum literals
- [ ] arrays
- [ ] slices (only slices of Value)
- [ ] vectors
- [ ] `[]const u8`
- [ ] structs
  - [ ] as Record (label is the type name)
  - [ ] as Sequence (just the field values)
  - [ ] as Dictionary (key is the field name)
- [ ] unions
- [ ] tuples
- [ ] error sets
- [ ] general pointers


# TODO

- [x] **ZON to syrup conversion** - Zig's ZON format could possibly be converted to Syrup, if we so pleased.
- [x] **Serializing Zig structures** - Use comptime to convert Zig structs, slices, etc to Syrup format
- [ ] **Fuzz testing** - Zig has fuzz testing support in the standard library we could play with.
- [ ] **`jsyrup` support** - human readable syrup format
- [ ] **syrupify** - Add support for user function to transform zig struct
- [ ] **`libsyrup`** - a C API for the low level syrup serialization
- [ ] **CLI tool** - to quickly pretty-print syrup structure and convert to jsyrup (maybe from jsyrup, though I think that's non-deterministic due to floats), unsure if converting ZON to syrup is useful here without type information, maybe it's possible/useful.
