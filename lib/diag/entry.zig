//! Entries: the stored per-diagnostic record and the typed views rendering reads.
//!
//! In: a `Builder`'s parts. Out: one fixed-size `Record` per diagnostic, whose text
//! lives in `Bag.string_bytes`, and the by-value `Entry`/`Label`/`Note` views of it.

const diag = @import("../diag.zig");
const diag_location = @import("location.zig");
const Code = diag.Code;
const Severity = diag.Severity;

/// Which stage produced the diagnostic. Kept for filtering and for the JSON
/// output; the code's class digits say the same thing, but a stage is what a
/// person debugging the ENGINE wants to filter on.
pub const Stage = enum(u8) { preprocess, parse, lower, proof, codegen };

/// Index into `Bag.string_bytes`, at the first byte of a NUL-terminated
/// string. 0 means "no string": byte 0 of the pool is a sentinel NUL, so no
/// real string can begin there.
pub const String = u32;

/// Labels or notes on ONE diagnostic. More than four of either is not clearer
/// for it, and the cap is what lets a `Record` hold them inline.
pub const max_children = 4;

/// One diagnostic as `Bag.records` stores it. Offsets, not pointers, so
/// `detach` copies the rows and the string pool and fixes nothing up.
pub const Record = struct {
    code: Code,
    severity: Severity,
    stage: Stage,
    /// Set only by the preprocessor, whose offsets are file-local because it
    /// fails before a preprocessed text exists to map them through.
    file: ?diag_location.FileId,
    span: diag_location.Span,
    message: String,
    point: String,
    n_labels: u8,
    n_notes: u8,
    labels: [max_children]LabelRec,
    notes: [max_children]NoteRec,
};

pub const LabelRec = struct {
    span: diag_location.Span,
    text: String,
};

/// `fix_repl == 0` means "no fix": a fix whose replacement is EMPTY is a
/// deletion and stays distinguishable from no fix at all.
pub const NoteRec = struct {
    kind: Note.Kind,
    text: String,
    fix_repl: String,
    fix_span: diag_location.Span,
};

// ---------------------------------------------------------------------------
// Views
// ---------------------------------------------------------------------------
//
// Produced BY VALUE from a `Record` and never stored. The strings are slices
// into `Bag.string_bytes`, valid exactly as long as the bag is.

/// A machine-applicable rewrite. `span` is what to replace; a zero-width span
/// inserts. The renderer draws `+` under an insertion and `~` under a
/// replacement, like rustc.
pub const Fix = struct {
    span: diag_location.Span,
    replacement: []const u8,
};

pub const Note = struct {
    pub const Kind = enum(u8) { note, help };

    kind: Kind,
    text: []const u8,
    fix: ?Fix = null,
};

/// A secondary span with its own text: "this is the parameter that is
/// unconstrained", pointing somewhere other than the primary span.
pub const Label = struct {
    span: diag_location.Span,
    text: []const u8,
};

pub const Entry = struct {
    /// Row in `Bag.records` — what `Bag.labels`/`Bag.notes` read. Valid until
    /// the next `Bag.sort`.
    index: u32,
    code: Code,
    severity: Severity,
    stage: Stage,
    /// Primary span — where the caret goes. May be `Span.none` only for a
    /// whole-file condition such as E1001.
    span: diag_location.Span,
    /// Set ONLY by the preprocessor; every other stage leaves it null and
    /// resolves through `Bag.map`. See `Record.file`.
    file: ?diag_location.FileId = null,
    /// The headline under `Info.title`; when empty the renderer prints the
    /// title alone.
    message: []const u8,
    /// Short text drawn beside the primary caret. Usually empty: repeating the
    /// headline next to the caret is noise, and rustc only labels the primary
    /// span when the label says something the headline does not.
    point: []const u8 = "",
    n_labels: u32 = 0,
    n_notes: u32 = 0,
};
