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

# TODO

- [ ] **ZON to syrup conversion** - Zig's ZON format could possibly be converted to Syrup, if we so pleased.
- [ ] **Serializing Zig structures** - Use comptime to convert Zig structs, slices, etc to Syrup format
- [ ] **Fuzz testing** - Zig has fuzz testing support in the standard library we could play with.

## Serializing Zig structure

[Some insight here](https://ziglang.org/documentation/0.16.0/std/#std.json.Stringify.write)

If we want to be able to convert raw Zig types effectively, we need a good way to hint to `writeString` when a bytearray is a string, symbol, or data. There's no obvious differentiation between these types, and we need to support them. Of course the C# way is to use attributes, but I don't think there's really an equivalent here.

One option could be to use a DBus-style wire format. If we specified such a string with a standard name, it could be used as a way to differentiate. Default could be string as that's the common case, but if it needs to be something more clever, we just add the wire format.

```zig
const Foo = struct {
    const wire_format = .{
      .type_name = .{ .record = .symbol },
      .fields = &[_]Field{
          .string,
          .default,
          .symbol,
          .data,
    }};

    // A string
    name: []const u8,
    // just normal number
    age: i64,
    // A symbol
    id: []const u8,
    // A data
    buffer: []const u8,
};
```
