This is a partially-implemented Zig Syrup implementation.

This library has not been tidied up, documented, or checked for security issues. Use at your own risk

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

# TODO

- [ ] **ZON to syrup conversion** - Zig's ZON format could possibly be converted to Syrup, if we so pleased.
- [ ] **Serializing Zig structures** - Use comptime to convert Zig structs, slices, etc to Syrup format
- [ ] **Fuzz testing** - Zig has fuzz testing support in the standard library we could play with.
