//! The diagnostic system: stage events -> one `Bag` of `Record` rows -> text
//! on a writer, or JSON for a tool.
//!
//! Every stage reports into one collector with one location currency (`Span`,
//! a byte range in the preprocessed text), so diagnostics from different stages
//! sort into source order. A code's severity is its first letter (`E`/`W`).
//!
//! The spine, one diagnostic at a time:
//!   `Bag.build` -> `Builder` parts -> `Builder.emit` (level, cap, dedupe)
//!   -> `Bag.records` + `Bag.string_bytes`
//! and once per compilation: `Bag.detach` (optional) -> `render`/`renderJson`,
//! which sort the rows and resolve spans through `Bag.map` and `Bag.files`.
//!
//! This file only aliases what other modules call; that list IS the API.

const code_table = @import("diag_code.zig");

pub const Code = code_table.Code;
pub const info = code_table.info;

// Levels: a code -> how hard it fails — diag/level.zig
const diag_level = @import("diag/level.zig");
pub const Severity = diag_level.Severity;
pub const severityOf = diag_level.severityOf;
pub const Level = diag_level.Level;
pub const Levels = diag_level.Levels;

// Locations: byte offset to line and column, spans and labels — diag/location.zig
const diag_location = @import("diag/location.zig");
pub const Span = diag_location.Span;
pub const FileId = diag_location.FileId;
pub const Segment = diag_location.Segment;
pub const StripMark = diag_location.StripMark;
pub const LineIndex = diag_location.LineIndex;

// Entries: the wire format and its decoded views — diag/entry.zig
const diag_entry = @import("diag/entry.zig");
pub const Stage = diag_entry.Stage;
pub const Note = diag_entry.Note;
pub const Label = diag_entry.Label;
pub const max_children = diag_entry.max_children;
pub const Entry = diag_entry.Entry;

// The bag: every diagnostic of one compilation, collected, deduplicated and sorted — diag/bag.zig
const diag_bag = @import("diag/bag.zig");
pub const Bag = diag_bag.Bag;
pub const Builder = diag_bag.Builder;

// Name suggestions for "unknown name" diagnostics — diag/suggest.zig
const diag_suggest = @import("diag/suggest.zig");
pub const didYouMean = diag_suggest.didYouMean;
pub const didYouMeanMap = diag_suggest.didYouMeanMap;

// Rendering: the bag as terminal text or JSON — diag/render.zig
const diag_render = @import("diag/render.zig");
pub const renderJson = diag_render.renderJson;
pub const explain = diag_render.explain;
pub const render = diag_render.render;

test {
    _ = diag_level;
    _ = diag_location;
    _ = diag_entry;
    _ = diag_bag;
    _ = diag_suggest;
    _ = diag_render;
    _ = @import("diag/test.zig");
}
