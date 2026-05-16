//! Tags for the supported serialization formats.

/// Syrup tags
pub const syrup = struct {
    pub const True = 't';
    pub const False = 'f';
    pub const int = struct {
        pub const Positive = '+';
        pub const Negative = '-';
    };
    pub const Float = 'F';
    pub const Double = 'D';
    pub const Data = ':';
    pub const String = '"';
    pub const Symbol = '\'';
    /// `syrup` dictionary tags
    pub const dictionary = struct {
        pub const Start = '{';
        pub const End = '}';
    };
    /// `syrup` sequence tags
    pub const sequence = struct {
        pub const Start = '[';
        pub const End = ']';
    };
    /// `syrup` record tags
    pub const record = struct {
        pub const Start = '<';
        pub const End = '>';
        pub const LabelSuffix = ' ';
    };
    /// `syrup` set types
    pub const set = struct {
        pub const Start = '#';
        pub const End = '$';
    };
};

/// `jsyrup` tags
/// See https://codeberg.org/spritely/goblins/src/branch/main/goblins/contrib/syrup.scm#L487
pub const jsyrup = struct {
    pub const True = "true";
    pub const False = "false";
    pub const NegativeInt = '-';
    pub const Data = '|';
    pub const String = '"';
    pub const Symbol = '`';
    pub const Delimiter = ", ";

    /// `jsyrup` dictionary tags
    pub const dictionary = struct {
        pub const Start = '{';
        pub const KeySuffix = ": ";
        pub const End = '}';
    };
    /// `jsyrup` sequence tags
    pub const sequence = struct {
        pub const Start = '[';
        pub const End = ']';
    };
    /// `jsyrup` record tags
    pub const record = struct {
        pub const Start = '<';
        pub const End = '>';
    };
    /// `jsyrup` set tags
    pub const set = struct {
        pub const Start = '(';
        pub const End = ')';
    };
};
