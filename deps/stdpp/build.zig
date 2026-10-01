//! Vendored from /home/omare/Documents/Projects/Trial/ZvsRust (stdpp 0.1.0).
//! Re-sync: copy that tree's src/*.zig, build.zig.zon and README.md over this
//! directory. This build.zig is trimmed to the `stdpp` module: the upstream
//! test, ISA and Rust-benchmark steps need tests/ and bench/, not vendored.
//! No target or optimize: the module inherits its importer's, so a
//! ReleaseFast `vera` gets a ReleaseFast stdpp.
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("stdpp", .{ .root_source_file = b.path("src/root.zig") });
}
