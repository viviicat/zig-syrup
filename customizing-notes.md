# Customizing structures

It's possible to customize the format that types get written. This is how it's done.

- `WireFormat`: How a struct and its fields are represented, `syrup_format` type. Contains `Format.Struct` for the struct.
- `Format`: union of `StructFormat`, `EnumFormat`, `SimpleFormat`, `DictionaryFormat`, default, depending on the type of field.
- `Format.Struct`: How a struct's container appears (union of record, dictionary or sequence)
- `Format.Enum`: How an enum is formatted (string, symbol, data) and if it's namespaced. Contains `Format.Simple`
- `Format.Simple`: How a string is formatted (string, symbol, data), and whether to include type name.
- `Format.Dictionary`: How a dictionary should be represented (key `Format.Simple` and value `Format.Simple`)
  - Can't use `Format` due to circular reference.
- `Options`: Options for writing. Contains `Format`, nothing else, but maybe something later.

```zig
const Foo = struct {
    // Type name: WireFormat
    // 1. Customize Foo's displaying, whether it writes as a Dictionary, Sequence, or Record. (Format.Struct)
    //   If the parent specified a type through the field settings, that overrides this setting, but if the type matches, the other settings are used.
    //   If not specified, the default is Dictionary.
    //   Dictionary:
    //     Customize if keys are written as strings, symbol, data.
    //   Record:
    //     Customize the name to use for the type, if it's going as a Record.
    //     Customize if the name is written as string, symbol, data.
    //   Sequence: (no settings)
    // 2. Customize how each of the fields will be displayed (Format).
    const syrup_format = ...

    a: i32, // nothing custom to do, always just like '42'
    b: []const u8, // Could be string, data, or symbol. Default string (Format.Symbol)
    c: AnEnum // Could be string, data or symbol, could be namespaced. Default symbol, not namespaced. (Format.Enum)
    d: NestedStruct // Could be represented as Dictionary (keys and values), Sequence (just values) or Record. See above for precedence. (Format.Struct)
    e: Tuple // Always a sequence.
    f: AutoHashMap(K, V) // customized with Format.Dictionary.
    f: AutoHashMap(K, void) // customized with Format.Simple.
};
```
