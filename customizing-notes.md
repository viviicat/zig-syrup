# Customizing structures

It's possible to customize the format that types get written. This is how it's done.

- `WireFormat`: How a struct and its fields are represented, `syrup_format` type. Contains `ContainerFormat` for the struct.
- `StructFormat`: How a struct's container appears (union of record, dictionary or sequence)
- `EnumFormat`: How an enum is formatted (string, symbol, data) and if it's namespaced. Contains `StringFormat`
- `StringFormat`: How a string is formatted (string, symbol, data), and whether to include type name.
- `DictionaryFormat`: How a dictionary should be represented (key `SimpleFieldFormat` and value `SimpleFieldFormat`)
  - Can't use `FieldFormat` due to circular reference.
- `SetFormat`: How a set should be represented (`SimpleFieldFormat`)
- `FieldFormat`: union of `ContainerFormat`, `EnumFormat`, `StringFormat`, `DictionaryFormat`, default, depending on the type of field.
- `SimpleFieldFormat`: union of default, string, symbol, data.

```zig
const Foo = struct {
    // Type name: WireFormat
    // 1. Customize Foo's displaying, whether it writes as a Dictionary, Sequence, or Record. (ContainerFormat)
    //   If the parent specified a type through the field settings, that overrides this setting, but if the type matches, the other settings are used.
    //   If not specified, the default is Dictionary.
    //   Dictionary:
    //     Customize if keys are written as strings, symbol, data.
    //   Record:
    //     Customize the name to use for the type, if it's going as a Record.
    //     Customize if the name is written as string, symbol, data.
    //   Sequence: (no settings)
    // 2. Customize how each of the fields will be displayed (FieldFormat).
    const syrup_format = ...

    a: i32, // nothing custom to do, always just like '42'
    b: []const u8, // Could be string, data, or symbol. Default string (StringFormat)
    c: AnEnum // Could be string, data or symbol, could be namespaced. Default symbol, not namespaced. (EnumFormat)
    d: NestedStruct // Could be represented as Dictionary (keys and values), Sequence (just values) or Record. See above for precedence. (ContainerFormat)
    e: Tuple // Always a sequence.
    f: AutoHashMap(K, V) // customized with DictionaryFormat.
    f: AutoHashMap(K, void) // customized with SetFormat.
};

// We cannot customize the enum inside the enum itself
const AnEnum = enum {
    one,
    two,
    three
}
```
