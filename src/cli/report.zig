//! `vera`'s stderr reports shared by `main.zig` and `cli/digital.zig`: a
//! diagnostic bag -> rendered text or JSON, and a source that could not be
//! read -> its one-line error (E1013 past `Preprocessor.max_text_bytes`).
//! The messages are user-visible and frozen.

const std = @import("std");
const vera = @import("vera");
const diag = vera.diag;
const Io = std.Io;

/// Renders `bag` on `w`, as JSON or as text coloured when `color`, and flushes
/// `w`. An empty bag prints nothing.
pub fn report(bag: *diag.Bag, w: *Io.Writer, json: bool, color: bool) !void {
    if (bag.isEmpty()) return;
    if (json) {
        try diag.renderJson(bag, w);
    } else {
        try diag.render(bag, w, .{ .palette = if (color) .on else .off });
    }
    try w.flush();
}

/// Reports that `path` could not be read: E1013 for a file past
/// `Preprocessor.max_text_bytes` (the u32 offsets the lexer uses), else the
/// error's name.
pub fn readFailed(w: *Io.Writer, path: []const u8, e: anyerror) !void {
    if (e == error.StreamTooLong)
        try w.print("error[E1013]: `{s}` is larger than {d} bytes; see `vera --explain E1013`\n", .{ path, vera.Preprocessor.max_text_bytes })
    else
        try w.print("error: cannot read `{s}`: {t}\n", .{ path, e });
}

test readFailed {
    var buf: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    // 2^32 - 1 is 4294967295 bytes.
    try readFailed(&w, "big.va", error.StreamTooLong);
    try readFailed(&w, "gone.va", error.FileNotFound);
    try std.testing.expectEqualStrings("error[E1013]: `big.va` is larger than 4294967295 bytes; see `vera --explain E1013`\n" ++
        "error: cannot read `gone.va`: FileNotFound\n", w.buffered());
}

test report {
    const gpa = std.testing.allocator;
    var bag: diag.Bag = .init(gpa);
    defer bag.deinit(gpa);
    var none: Io.Writer.Allocating = .init(gpa);
    defer none.deinit();
    try report(&bag, &none.writer, false, true);
    try std.testing.expectEqualStrings("", none.written());

    try bag.add(.parse, .E1104, .none, "`x.sv` is an IEEE 1800 source", .{});
    var json: Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    try report(&bag, &json.writer, true, true);
    try std.testing.expect(std.mem.startsWith(u8, json.written(), "{\"code\":\"E1104\""));
    var text: Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try report(&bag, &text.writer, false, false);
    try std.testing.expect(std.mem.find(u8, text.written(), "error[E1104]") != null);
    // No colour asked for: no escape byte.
    try std.testing.expect(std.mem.findScalar(u8, text.written(), 0x1b) == null);
}
