//! Entries: the wire format and its decoded views.
//!
//! The packed per-diagnostic record the bag stores, and the typed views rendering reads.
//!
//! Cut verbatim from `diag.zig`.

const diag = @import("../diag.zig");
const diag_location = @import("location.zig");
const Code = diag.Code;
const Severity = diag.Severity;

// ---------------------------------------------------------------------------
// Entries: the wire format
// ---------------------------------------------------------------------------

/// Which stage produced the diagnostic. Kept for filtering and for the JSON
/// output; the code's class digits say the same thing, but a stage is what a
/// person debugging the ENGINE wants to filter on.
pub const Stage = enum(u8) { preprocess, parse, lower, proof, codegen };

/// Index into `Bag.extra` at the first word of a `Message` — the handle a
/// caller keeps, and what `Bag.get` decodes. Zig's `ErrorBundle.MessageIndex`
/// (ErrorBundle.zig:33).
pub const MessageIndex = enum(u32) { _ };

/// Index into `Bag.string_bytes`, at the first byte of a NUL-terminated
/// string. 0 means "no string": byte 0 of the pool is a sentinel NUL, so no
/// real string can begin there. Zig's `String`/`OptionalString`
/// (ErrorBundle.zig:22).
pub const String = u32;

/// Word 0 of a `Message`: everything that identifies the diagnostic. `Code` is
/// u16 and `Severity`/`Stage` are u8, so the three fill one word exactly.
pub const Head = packed struct(u32) {
    code: Code,
    severity: Severity,
    stage: Stage,
};

/// Word 1. The `Builder` caps both at `max_children`; u16 is just what half a
/// word gives, and there was nothing left in `Head` to steal.
pub const Counts = packed struct(u32) {
    labels_len: u16,
    notes_len: u16,
};

/// One diagnostic, as words in `Bag.extra`.
///
/// WHAT THIS CARRIES THAT ZIG'S `ErrorMessage` DOES NOT. Zig's row is
/// `{msg, count, src_loc, notes_len}` (ErrorBundle.zig:70) — a string and a
/// place. VerA also needs the `Code` (the catalogue key that `--explain`,
/// the lint levels and 809 fixtures all pin), the `Severity` (Zig's renderer
/// hardcodes "error"), the `Stage`, the `point` text drawn beside the primary
/// caret, and a count of secondary `Label`s. Every one of them is another
/// WORD in the same flat record — never a side table, which is the whole
/// reason this file has one storage shape instead of two.
///
/// NO `SourceLocation` INDIRECTION. Zig indexes a separate record
/// (ErrorBundle.zig:53) because several messages can share one location and a
/// `ReferenceTrace` points at one. Here it is 1:1 and never shared, so the
/// three fields are inlined: the index word alone would have cost as much as
/// two of them. The `.none` sentinel is not needed either — `Span.isNone()`
/// already means "no place", and `place()` already tests it.
///
/// LINE AND COLUMN ARE NOT STORED. Zig resolves them while building the bundle
/// (ErrorBundle.zig:539); we keep byte offsets and resolve at render through
/// `LineIndex`, because a span here is an offset into the PREPROCESSED text
/// and only `SourceMap` knows which file's line that is — and because the
/// common case by far is a bag nobody ever renders.
///
/// Trailing:
///   * `LabelRec` for each `counts.labels_len`
///   * `NoteRec` for each `counts.notes_len`
pub const Message = struct {
    head: Head,
    counts: Counts,
    msg: String,
    point: String,
    /// `FileId` + 1, or 0 for "resolve `span` through the `SourceMap`". Set
    /// only by the preprocessor, whose offsets are file-local because it fails
    /// before a preprocessed text exists to map them through.
    src_file: u32,
    span_start: u32,
    span_end: u32,
};

/// A secondary span drawn INSIDE the primary snippet. Zig has no equivalent:
/// its nearest thing is a note with its own `SourceLocation`, which renders as
/// a separate message on its own line.
pub const LabelRec = struct {
    span_start: u32,
    span_end: u32,
    text: String,
};

/// A note or help line, optionally carrying a machine-applicable rewrite.
///
/// Zig trails `MessageIndex`es (ErrorBundle.zig:69) because its notes ARE
/// messages and get written after the parent header (`reserveNotes`). Ours are
/// written inline: `Builder` holds the whole diagnostic before it commits, so
/// the indirection would buy nothing and cost a word each.
///
/// `fix_repl == 0` means "no fix" — which is exactly why `String` 0 is
/// reserved, since a fix whose replacement is EMPTY is a deletion and has to
/// stay distinguishable from no fix at all.
pub const NoteRec = struct {
    kind: Note.Kind,
    text: String,
    fix_repl: String,
    fix_start: u32,
    fix_end: u32,
};

pub fn wordCount(comptime T: type) u32 {
    return @typeInfo(T).@"struct".fields.len;
}

/// Every record field is exactly one `extra` word. Zig switches on the three
/// field types it uses (ErrorBundle.zig:135); switching on the KIND instead
/// means a new packed field type needs no arm here.
pub fn toWord(v: anytype) u32 {
    return switch (@typeInfo(@TypeOf(v))) {
        .int => v,
        .@"enum" => @intFromEnum(v),
        .@"struct" => @bitCast(v),
        else => @compileError("not an extra field type: " ++ @typeName(@TypeOf(v))),
    };
}

pub fn fromWord(comptime T: type, word: u32) T {
    return switch (@typeInfo(T)) {
        .int => word,
        .@"enum" => @enumFromInt(word),
        .@"struct" => @bitCast(word),
        else => @compileError("not an extra field type: " ++ @typeName(T)),
    };
}

// ---------------------------------------------------------------------------
// Entries: the decoded views
// ---------------------------------------------------------------------------
//
// Everything below is produced BY VALUE from the pools and never stored, the
// way `ErrorBundle.getErrorMessage` returns an `ErrorMessage` (ErrorBundle.zig
// :109). The strings are slices into `Bag.string_bytes`, so a view is free to
// make and valid exactly as long as the bag is.

/// A machine-applicable rewrite. `span` is what to replace; a zero-width span
/// inserts. The renderer draws `+` under an insertion and `~` under a
/// replacement, like rustc.
pub const Fix = struct {
    span: diag_location.Span,
    replacement: []const u8,
};

pub const Note = struct {
    pub const Kind = enum(u32) { note, help };

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

/// Labels or notes on ONE diagnostic. More than four of either is not clearer
/// for it, and the cap is what lets `Bag.labels`/`Bag.notes` decode into a
/// caller's array instead of allocating.
pub const max_children = 4;

pub const Entry = struct {
    /// Where this row lives in `extra` — what `Bag.labels`/`Bag.notes` need to
    /// find the trailing records.
    index: MessageIndex,
    code: Code,
    severity: Severity,
    stage: Stage,
    /// Primary span — where the caret goes. May be `Span.none` only for a
    /// whole-file condition such as E1001.
    span: diag_location.Span,
    /// Set ONLY by the preprocessor; every other stage leaves it null and
    /// resolves through `Bag.map`. See `Message.src_file`.
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
