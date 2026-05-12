This is a partially-implemented Zig Syrup implementation.

This library has not been tidied up, documented, or checked for security issues. Use at your own risk

See [The Syrup Specification](https://github.com/ocapn/syrup/blob/master/draft-specification.md) for details.

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
- [ ] Dictionaries
- [x] Sequences
- [x] Records
- [ ] Sets

# TODO

## Set and dictionary key uniqueness

Dictionaries and sets must be unique *and must be sorted by key*, but keys are allowed to be any type. This results in an inefficiency when implementing a writer, as the writer must store previous keys in order to perform the sort. This means that allocation is needed, which we otherwise have been able to avoid in the writer.

This will likely recall some sort of tree structure, though I need to think about it a bit more and remember what I was thinking when I was working on this last.
