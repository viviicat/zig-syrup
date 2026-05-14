/// Enum for the types of nested collections that Syrup knows about.
pub const CollectionMode = enum {
    sequence,
    record,
    dictionary,
    set,
};
