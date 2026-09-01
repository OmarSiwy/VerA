//! Test fixtures for the elaboration unit: source text → a parsed
//! `Ast.SourceFile` plus the `Ctx` `elaborate` takes, through the lexer,
//! parser and (for Annex E's prelude) preprocessor the compiler runs, so a
//! test of any `elaborate/` file starts from Verilog-AMS text. Test-only:
//! only `test` blocks reach it. LRM Annex E (the prelude).

const std = @import("std");
const elaborate = @import("../elaborate.zig");
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const Parser = @import("frontend").Parser;
const Preprocessor = @import("frontend").Preprocessor;
const diag = @import("diag");

/// One compilation for a test: the arena every parse and elaboration row
/// lives in, the parsed file and its diagnostics. Free with `deinit`.
pub const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    file: Ast.SourceFile = .empty,
    bag: diag.Bag = undefined,
    src: []const u8 = "",
    starts: []const u32 = &.{},

    /// Frees the parse, every elaboration of it and the bag.
    pub fn deinit(self: *Fixture) void {
        self.arena.deinit();
    }

    /// Returns the `Ctx` that elaborates this fixture: basic discipline
    /// resolution, no `--param` overrides. Its bag is undefined until a
    /// `parse*` has run.
    pub fn ctx(self: *Fixture) elaborate.Ctx {
        return .{
            .arena = self.arena.allocator(),
            .file = &self.file,
            .src = self.src,
            .tok_starts = self.starts,
            .bag = &self.bag,
        };
    }
};

/// Parses `text` into `out` with no prelude, so only the disciplines and
/// modules `text` declares exist. `text` must outlive `out`.
pub fn parse(out: *Fixture, text: []const u8) !void {
    const arena = out.arena.allocator();
    out.src = text;
    out.bag = diag.Bag.init(arena);
    var toks = try Lexer.Lexer.tokenize(arena, text);
    out.starts = toks.items(.start);
    var p = Parser.Parser.init(arena, text, toks.items(.tag), out.starts, &out.bag);
    out.file = try p.parseSourceFile();
}

/// Annex E: the prelude is a prefix of `modules` only if the preprocessor ran,
/// so this goes through it and sets `builtin_modules` as `root.zig` stage 3
/// does. `text` must outlive `out`.
pub fn parseWithPrelude(out: *Fixture, text: []const u8) !void {
    const arena = out.arena.allocator();
    out.bag = diag.Bag.init(arena);
    out.src = (try Preprocessor.process(arena, text, .{ .bag = &out.bag })).text;
    var toks = try Lexer.Lexer.tokenize(arena, out.src);
    out.starts = toks.items(.start);
    var p = Parser.Parser.init(arena, out.src, toks.items(.tag), out.starts, &out.bag);
    out.file = try p.parseSourceFile();
    out.file.builtin_modules = Preprocessor.spice_module_count;
}
