//! Class 0 — the diagnostic code catalogue.
//!
//! One stable identifier per diagnosable condition, plus the LRM citation and
//! the long-form explanation `--explain` prints. This file has NO imports on
//! purpose: it is pure data, so every stage can name a code without pulling in
//! the renderer, and `diag.zig` can import it without a cycle.
//!
//! RULES (read before adding a code)
//!   - Codes are STABLE. Fixtures, docs and user build scripts pin them. A code
//!     is never renumbered and never reused after retirement; retire by leaving
//!     the enum field in place and marking the title `(retired)`.
//!   - The FIRST LETTER carries the severity: `E` = error, `W` = warning.
//!     `diag.severityOf` reads it from `@tagName`, so there is no second table
//!     to keep in sync.
//!   - The NUMBER's leading digits are the engine's stage class, so a code says
//!     which stage owns it:
//!       01xx class 1  lexical + preprocessing      (preprocessor.zig, lexer.zig)
//!       02xx class 2  syntax / annex A             (parser.zig)
//!       03xx class 3  types, disciplines, decls    (lower.zig)
//!       04xx class 4  behavioral semantics         (lower.zig)
//!       05xx class 5  analog operators + math      (lower.zig)
//!       06xx class 6  numerical safety / proof     (proof.zig)
//!       07xx class 7  events + timing              (lower.zig)
//!       08xx class 8  system tasks and functions   (lower.zig)
//!       09xx class 9  hierarchy + elaboration      (lower.zig)
//!       10xx class 10 runtime / artifact contract  (codegen.zig)
//!   - The LRM citation lives HERE, once, not copied into a format string. A
//!     message that still spells "(LRM 3.2.2)" inline is a bug: the renderer
//!     prints `Info.lrm` under every diagnostic already.
//!
//! DOD: `Code` is an `enum(u16)` whose tag name IS the rendered spelling, so
//! `@tagName` replaces a name table. `info` is one exhaustive `switch`, which
//! the compiler turns into a jump table AND — the reason it is a switch and not
//! an array — refuses to compile if a new code arrives without an entry.

/// Static per-code documentation. All three fields are comptime string
/// literals; nothing here is ever allocated.
pub const Info = struct {
    /// Short noun phrase, no trailing punctuation, no code, no location. This
    /// is the headline: `error[E0313]: <title>`. Keep it stable-ish — fixtures
    /// pin the CODE, so prose may be improved, but a title that changes meaning
    /// wants a new code.
    title: []const u8,
    /// LRM clause, e.g. `"5.6.1"`, `"A.6.4"`, `"C.7"`. Empty when the condition
    /// is an engine limit rather than a language rule (say so in `explain`).
    lrm: []const u8,
    /// Long form for `--explain`. Convention: what the rule is, why it exists,
    /// then how to satisfy it. Wrapped at ~76 columns by the caller.
    explain: []const u8,
};

/// Every diagnosable condition VerA can report. See the class ranges above.
pub const Code = enum(u16) {
    // ---------------------------------------------------------------- class 1
    // Preprocessing directives (LRM 10) — preprocessor.zig.
    E0101,
    E0102,
    E0103,
    E0104,
    E0105,
    E0106,
    E0107,
    E0108,
    E0109,
    E0110,
    E0111,
    E0112,
    E0113,
    E0114,
    E0115,
    E0116,
    E0117,
    E0118,
    E0119,
    E0120,
    E0121,
    E0122,
    E0123,
    E0124,
    E0125,
    E0126,
    // Lexical (LRM 2) — reported by parser.zig against a lexer `.invalid` token
    // or a `ValueError` from `Lexer.decode*`.
    E0130,
    E0131,
    E0132,
    E0133,
    E0134,
    E0135,
    E0136,
    // E0137 was "unterminated `begin_keywords". Retired: §10.6 gives the
    // directive scope "even across source code file boundaries", so an open
    // pair at end of file is the clause working, not an error. The number is
    // not reused.
    E0138,
    /// §10.4: the macro TEXT may not begin with __VAMS_.
    E0139,

    // ---------------------------------------------------------------- class 2
    // Syntax / annex A — parser.zig.
    E0201,
    E0202,
    E0203,
    E0204,
    E0205,
    E0206,
    E0207,
    E0208,
    E0209,
    E0210,
    E0211,
    E0212,
    E0213,
    E0214,
    E0215,
    E0216,
    E0217,
    /// §6.2 a port declared in the header's list of port declarations, declared
    /// a second time in the module body.
    E0218,
    /// A.6.2/A.6.3, annex G.2.2: a null statement where the grammar has none.
    E0219,
    /// A.6.5, annex G Table G.2 item 13: `initial_step()`/`final_step()` with
    /// an empty analysis list.
    E0220,

    // ---------------------------------------------------------------- class 3
    // Declarations, types, disciplines — lower.zig.
    E0301,
    E0302,
    E0303,
    E0304,
    E0305,
    E0306,
    E0307,
    E0308,
    E0309,
    E0310,
    E0311,
    E0312,
    E0313,
    E0314,
    E0315,
    E0316,
    E0317,
    E0318,
    E0319,
    E0320,
    E0321,
    E0322,
    E0323,
    E0324,
    E0325,
    E0326,
    E0327,
    E0328,
    E0329,
    E0330,
    E0331,
    /// §3.6.1/§3.6.1.2 a base nature missing a required attribute.
    E0332,
    /// §3.6.1.2 a derived nature that defines or changes `units`.
    E0333,
    /// §3.6.1.2 a derived nature that changes `access`.
    E0334,
    /// §3.13.2 two base natures claiming the same access function.
    E0335,
    /// §3.13.1 a nature and a discipline sharing one global-scope identifier.
    E0336,
    /// §3.6.3/§6.5.2.1 a net with no declared discipline used behaviorally.
    E0337,
    /// §3.6.2.1 a conservative discipline binding one nature to both halves.
    E0338,
    /// §3.6.2.2 `domain discrete` on a discipline that binds natures.
    E0339,
    /// §3.6.1.2/§3.6.1.3 a nature attribute value of the wrong form.
    E0340,
    /// §3.6.1.2 `idt_nature` naming no nature, or an unrelated one.
    E0341,
    /// §3.6.1/§3.6.2 a nature or a discipline declared twice.
    E0342,
    /// §3.6.1.3 the same user attribute declared twice in one nature.
    E0343,
    /// §3.6.4 `ground` on a net whose discipline is not continuous.
    E0344,
    /// §3.4.1 a string value on a numeric parameter, or a numeric value on a
    /// `string` parameter — the one type pairing that gets no conversion.
    E0345,
    /// §3.4.1/§3.4.4/§3.4.6 an array or string parameter left untyped.
    E0346,
    /// §3.4.2 a value range whose first bound is not smaller than its second.
    E0347,
    /// §4.2.10 a reduction operator inside the analog block.
    E0348,
    /// §3.4/§4.2.14 an array parameter initialised without the `'{ }` pattern.
    E0349,

    // ---------------------------------------------------------------- class 4
    // Behavioral semantics: statements and contributions — lower.zig.
    E0401,
    E0402,
    E0403,
    E0404,
    E0405,
    E0406,
    E0407,
    E0408,
    E0409,
    E0410,
    E0411,
    E0412,
    E0413,
    E0414,
    E0415,
    E0416,
    E0417,
    E0418,
    E0419,
    E0420,
    E0421,
    E0422,
    /// §1.3.1/§5.4.2.1 both quantities of a probe branch read in one module.
    E0423,
    /// §7.3.2.1 a contribution whose value folds to an infinity or a NaN.
    E0424,
    /// §1.3.4.1/§1.3.4.2 a contribution to an `input` signal-flow port.
    E0425,
    /// §5.9 a contribution inside a `repeat`/`while`/non-genvar `for`.
    E0426,
    /// §5.8.3 more than one `default` arm in one case statement.
    E0427,

    // ---------------------------------------------------------------- class 5
    // Analog operators and math functions — lower.zig.
    E0501,
    E0502,
    E0503,
    E0504,
    E0505,
    E0506,
    E0507,
    E0508,
    E0509,
    E0510,
    E0511,
    E0512,
    E0513,
    /// §5.8.1/§5.9 an analog operator whose branch can change during the solve.
    E0514,
    /// §4.5 an operator CONTROL argument (delay, rate, initial condition) that
    /// is neither constant nor an expression over parameters — codegen.zig.
    E0515,
    /// §4.5.5-§4.5.10 an analog operator control argument outside the bound the
    /// LRM states for it (modulus, td, rise/fall time, slew rate, direction).
    E0516,
    /// §5.10.3.1/§5.10.3.2 a `cross`/`above` argument that is the wrong type,
    /// out of range, or a tolerance with no direction beside it.
    E0517,

    // ---------------------------------------------------------------- class 6
    // Numerical safety / finiteness — proof.zig.
    E0601,
    E0602,
    E0603,
    E0604,
    E0605,
    E0606,
    E0607,
    E0608,
    E0609,
    /// The requested finiteness warning. See `Info` below for the full story.
    W0650,
    W0651,
    W0652,

    // ---------------------------------------------------------------- class 7
    // Events and timing — lower.zig.
    E0701,
    E0702,
    E0703,
    E0704,
    E0705,
    E0706,
    /// §5.8/§5.9/§5.10.3.1 an event control statement that is not on the
    /// straight-line spine of the analog block.
    E0707,

    // ---------------------------------------------------------------- class 8
    // System tasks and functions — lower.zig.
    E0801,
    E0802,
    E0803,
    E0804,
    E0805,
    /// §9.2 Tables 9-1/9-2/9-3/9-5/9-6/9-7/9-8 "supported in analog context: No".
    E0806,
    /// §9.7.2 `$stop` inside an `analog initial` block.
    E0807,
    /// Annex G Table G.1 the retired OVI Verilog-A v1.0 spelling `$limexp`.
    E0808,
    /// §9.17.3 a `$limit` call missing the arguments its named algorithm needs.
    E0809,
    /// §9.4.3 fewer arguments than the format string has consuming specifiers.
    E0810,
    /// §9.4 display task dropped, because the artifact being built is a device.
    W0850,
    /// §9.4 display task under a conditional — not emitted even into an exe.
    W0851,

    // ---------------------------------------------------------------- class 9
    // Hierarchy and elaboration — lower.zig.
    E0901,
    /// §7.4.4/F.2.1 step 3 more than one discipline declaration for one net.
    E0902,

    // --------------------------------------------------------------- class 10
    // Runtime / artifact contract — codegen.zig, root.zig.
    E1001,
    E1002,

    /// Rendered spelling — the tag name IS the code, so no name table exists.
    pub fn name(self: Code) []const u8 {
        return @tagName(self);
    }
};

/// Documentation for a code. Exhaustive by construction: adding a `Code`
/// without an arm here is a compile error, which is the point.
pub fn info(c: Code) Info {
    return switch (c) {
        // ------------------------------------------------------------ class 1
        .E0101 => .{
            .title = "unterminated `ifdef",
            .lrm = "10.5",
            .explain =
            \\A `ifdef, `ifndef or `elsif block reached end of file without a
            \\matching `endif. Conditional compilation blocks do not close
            \\implicitly, and they may nest, so a missing `endif silently
            \\swallows the rest of the file.
            \\
            \\The reported location is the end of the source; the unclosed
            \\directive itself is named in the attached note.
            ,
        },
        .E0102 => .{
            .title = "unterminated block comment",
            .lrm = "2.4",
            .explain =
            \\A `/*` comment reached end of file without a closing `*/`.
            \\
            \\LRM 2.4: "Block comments shall not be nested." A `/*` inside a
            \\block comment is therefore ordinary comment text and does NOT
            \\open a second comment, so exactly one `*/` closes the comment
            \\that a given `/*` opened.
            ,
        },
        .E0103 => .{
            .title = "expected a directive or macro name after '`'",
            .lrm = "10",
            .explain =
            \\A backtick must be followed immediately by a compiler directive
            \\keyword (`define, `include, `ifdef, ...) or by the name of a
            \\macro to expand. Whitespace or a non-identifier character after
            \\the backtick has no meaning.
            ,
        },
        .E0104 => .{
            .title = "conditional directive requires a macro name",
            .lrm = "10.5",
            .explain =
            \\`ifdef and `ifndef each take exactly one macro name:
            \\
            \\    `ifdef  NAME
            \\    `ifndef NAME
            \\
            \\The name is not expanded — it is only tested for existence.
            ,
        },
        .E0105 => .{
            .title = "`else / `elsif without `ifdef",
            .lrm = "10.5",
            .explain =
            \\`else and `elsif may only appear inside a conditional block
            \\opened by `ifdef or `ifndef. Check for an extra `endif above
            \\this line that closed the block early.
            ,
        },
        .E0106 => .{
            .title = "`else / `elsif after `else",
            .lrm = "10.5",
            .explain =
            \\A conditional block has at most one `else, and it must be the
            \\last arm. Every `elsif has to precede it.
            ,
        },
        .E0107 => .{
            .title = "`elsif requires a macro name",
            .lrm = "10.5",
            .explain =
            \\`elsif takes exactly one macro name to test, exactly like
            \\`ifdef. Bare `elsif is not a synonym for `else.
            ,
        },
        .E0108 => .{
            .title = "`endif without `ifdef",
            .lrm = "10.5",
            .explain =
            \\This `endif closes a conditional block that was never opened.
            \\Usually one `endif too many, or an `ifdef that was deleted
            \\without its partner.
            ,
        },
        .E0109 => .{
            .title = "`define requires a macro name",
            .lrm = "10.4",
            .explain =
            \\`define takes a macro name, then an optional parenthesised
            \\formal argument list, then the replacement text:
            \\
            \\    `define NAME            text
            \\    `define NAME(a, b)      text using a and b
            \\
            \\LRM 10.4 also reserves the `__VAMS_` prefix for predefined
            \\macros; do not define a macro whose text begins with it.
            ,
        },
        .E0110 => .{
            .title = "malformed formal argument list for `define",
            .lrm = "10.4",
            .explain =
            \\The parentheses after a function-like macro name must contain a
            \\comma-separated list of plain identifiers. Defaults, types and
            \\nested parentheses are not part of the grammar.
            ,
        },
        .E0111 => .{
            .title = "unterminated formal argument list for `define",
            .lrm = "10.4",
            .explain =
            \\The '(' that opened a function-like macro's formal argument list
            \\has no matching ')' before the end of the definition. Remember
            \\that a `define body ends at the first unescaped newline, so a
            \\list continued onto the next line needs a trailing backslash.
            ,
        },
        .E0112 => .{
            .title = "expected ',' or ')' in `define argument list",
            .lrm = "10.4",
            .explain =
            \\Formal arguments of a function-like macro are separated by
            \\commas and closed by a single ')'.
            ,
        },
        .E0113 => .{
            .title = "`undef requires a macro name",
            .lrm = "10.4",
            .explain =
            \\`undef takes exactly one macro name.
            \\
            \\LRM 10.4: `undef "shall have no effect" on a PREDEFINED macro.
            \\Undefining a name that was never defined is likewise harmless —
            \\this error is only about the missing name.
            ,
        },
        .E0114 => .{
            .title = "unsupported compiler directive",
            .lrm = "10.7",
            .explain =
            \\VerA implements the directives that affect the text of a
            \\compiled module: `define, `undef, `ifdef/`ifndef/`elsif/`else/
            \\`endif, `include, `begin_keywords/`end_keywords, and the
            \\predefined macros of LRM 10.
            \\
            \\The remaining LRM 10.7 directives (`resetall, `timescale,
            \\`celldefine, `unconnected_drive, `default_transition, ...)
            \\configure a full-simulator environment that a compiled device
            \\artifact does not have. Delete the directive, or guard it with
            \\`ifdef so the same source still feeds other tools.
            ,
        },
        .E0115 => .{
            .title = "undefined macro",
            .lrm = "10.4",
            .explain =
            \\This name was used with a leading backtick but never `define'd,
            \\and it is not one of the predefined `__VAMS_*` macros.
            \\
            \\If the definition lives in another file, add an `include for it,
            \\or pass the directory holding it via the include search path.
            ,
        },
        .E0116 => .{
            .title = "function-like macro used without an argument list",
            .lrm = "10.4",
            .explain =
            \\This macro was defined with a formal argument list, so every use
            \\must supply actual arguments in parentheses. A function-like
            \\macro named without '(' is not a shorthand for its body.
            ,
        },
        .E0117 => .{
            .title = "macro argument count mismatch",
            .lrm = "10.4",
            .explain =
            \\A function-like macro must be invoked with exactly as many
            \\actual arguments as it declares formals. Arguments are split on
            \\top-level commas only: a comma inside nested parentheses, or
            \\inside a string, belongs to the argument that contains it.
            ,
        },
        .E0118 => .{
            .title = "recursive macro expansion",
            .lrm = "10.4",
            .explain =
            \\A macro's expansion refers to the macro currently being expanded.
            \\Text substitution has no fixed point here, so the preprocessor
            \\stops instead of looping.
            \\
            \\The chain of expansions that led back to this macro is listed in
            \\the attached notes.
            ,
        },
        .E0119 => .{
            .title = "macro expansion nested too deeply",
            .lrm = "10.4",
            .explain =
            \\Expansion exceeded the engine's nesting limit. This is an
            \\implementation bound, not a language rule: it exists so that a
            \\mutually recursive pair of macros terminates even when neither
            \\macro is directly self-referential.
            ,
        },
        .E0120 => .{
            .title = "unterminated macro argument list",
            .lrm = "10.4",
            .explain =
            \\The '(' opening a function-like macro's actual arguments has no
            \\matching ')'. Unlike a `define body, an argument list may span
            \\newlines, so the scan ran to end of file.
            ,
        },
        .E0121 => .{
            .title = "`include requires a file name",
            .lrm = "10.3",
            .explain =
            \\`include takes one double-quoted file name:
            \\
            \\    `include "disciplines.vams"
            ,
        },
        .E0122 => .{
            .title = "`include file name must be quoted",
            .lrm = "10.3",
            .explain =
            \\LRM 10.3 spells the argument of `include as a double-quoted
            \\string. The angle-bracket form C uses is not part of the
            \\Verilog-AMS grammar; the search path is configured by the tool,
            \\not by the quoting style.
            ,
        },
        .E0123 => .{
            .title = "unterminated `include file name",
            .lrm = "10.3",
            .explain =
            \\The opening double quote of an `include file name has no closing
            \\quote on the same line. LRM 2.7 confines a string literal to one
            \\line.
            ,
        },
        .E0124 => .{
            .title = "empty `include file name",
            .lrm = "10.3",
            .explain = "`include \"\" names no file.",
        },
        .E0125 => .{
            .title = "`include nested too deeply",
            .lrm = "10.3",
            .explain =
            \\Include nesting exceeded the engine's limit, which almost always
            \\means a cycle: a file that includes itself, directly or through
            \\a chain. The include chain is listed in the attached notes.
            \\
            \\Guard headers with the usual idiom:
            \\
            \\    `ifndef MY_HEADER
            \\    `define MY_HEADER
            \\    ...
            \\    `endif
            ,
        },
        .E0126 => .{
            .title = "cannot find include file",
            .lrm = "10.3",
            .explain =
            \\The named file was not found relative to the including file, in
            \\any configured include directory, or among the built-in annex D
            \\standard definitions (disciplines.vams, constants.vams).
            \\
            \\Note that annex D headers are built in: including them works
            \\with no search path configured at all.
            ,
        },
        .E0130 => .{
            .title = "x/z digit in a number literal",
            .lrm = "2.6.1",
            .explain =
            \\Verilog-AMS admits the four-state digits x, z and ? in a sized
            \\literal, but the analog subset has no four-state value to hold
            \\one: LRM annex C removes 4-state nets and the === / !== operators
            \\along with them, and an unknown bit has no meaning in a
            \\continuous equation.
            \\
            \\Use a definite value, or a parameter the model card supplies.
            ,
        },
        .E0131 => .{
            .title = "expected a numeric base after the apostrophe",
            .lrm = "2.6.1",
            .explain =
            \\A sized literal is <size>'<base><digits>, where <base> is one of
            \\b/B, o/O, d/D or h/H:
            \\
            \\    8'hFF   4'b1010   16'd65535
            ,
        },
        .E0132 => .{
            .title = "expected a numeric digit after the base",
            .lrm = "2.6.1",
            .explain =
            \\The base specifier must be followed by at least one digit valid
            \\in that base.
            \\
            \\LRM 2.6.1 also makes a sign here illegal: "A plus or minus
            \\operator between the base format and the number is an illegal
            \\syntax", so 8'd -6 must be written -8'd6.
            ,
        },
        .E0133 => .{
            .title = "invalid number literal",
            .lrm = "2.6",
            .explain =
            \\The literal does not match any LRM 2.6 form. The usual causes:
            \\
            \\  - a digit outside the declared base (8'b2)
            \\  - a real without a digit on both sides of the point: LRM 2.6.2
            \\    requires "at least one digit on each side", so .12, 9. and
            \\    4.E3 are all invalid
            \\  - a leading underscore: legal "anywhere in a number except as
            \\    the first character"
            \\  - a scale factor with a space before it, or on an integer:
            \\    LRM 2.6.2 permits no space, and scale factors attach to
            \\    reals only
            ,
        },
        .E0134 => .{
            .title = "number literal is too long",
            .lrm = "2.6",
            .explain =
            \\The literal exceeds the engine's decoding buffer. An analog
            \\model has no use for a value that long: a Verilog-A integer is
            \\32 bits (LRM 3.2.1) and a real is an IEEE double, which holds
            \\about 17 significant decimal digits.
            ,
        },
        .E0135 => .{
            .title = "unsupported keyword set",
            .lrm = "10.2",
            .explain =
            \\`begin_keywords takes a quoted version specifier naming the
            \\keyword set to make active. VerA recognises the Verilog-AMS
            \\and IEEE 1364 sets listed in LRM annex B; an unknown specifier
            \\would silently change which identifiers are reserved.
            ,
        },
        .E0136 => .{
            .title = "`end_keywords without `begin_keywords",
            .lrm = "10.2",
            .explain =
            \\`end_keywords pops the keyword set that `begin_keywords pushed.
            \\This one has nothing to pop.
            ,
        },
        .E0138 => .{
            .title = "a string literal may not span lines",
            .lrm = "2.7",
            .explain =
            \\LRM 2.7: "A string literal is a sequence of characters enclosed
            \\by double quotes (") and contained on a single line." Table 2-2
            \\then lists every escape a string may hold -- \n, \t, \\, \" and
            \\\ddd -- and a backslash before a newline is not one of them.
            \\
            \\Continuing a string across a line break is a SystemVerilog
            \\addition (IEEE 1800 5.9). Verilog-AMS is derived from IEEE
            \\1364-2005 (LRM 1.1), whose 3.6 carries the same single-line
            \\rule, so a model that relies on the continuation is using a
            \\vendor extension that this LRM does not grant.
            \\
            \\Keep the literal on one line. A newline in the OUTPUT is what
            \\\n is for:
            \\
            \\    $strobe("first line\nsecond line");
            ,
        },
        .E0139 => .{
            .title = "macro text may not begin with __VAMS_",
            .lrm = "10.4",
            .explain =
            \\LRM 10.4: "To avoid conflicts with predefined Verilog-AMS macros
            \\(10.5), the `define compiler directive's macro text shall not
            \\begin with __VAMS_."
            \\
            \\Syntax 10-3 is what fixes the target of that sentence:
            \\
            \\    text_macro_definition ::= `define text_macro_name macro_text
            \\
            \\macro_text is the SECOND operand, so the prohibition is on the
            \\body. The NAME is unrestricted -- `define __VAMS_MY_FLAG 1 is
            \\legal -- and the rationale agrees: only a body can expand INTO a
            \\10.5 predefined macro and shadow it.
            ,
        },

        // ------------------------------------------------------------ class 2
        .E0201 => .{
            .title = "construct is not in the supported subset",
            .lrm = "C",
            .explain =
            \\VerA compiles the Verilog-A analog subset of annex C. This
            \\construct belongs to full Verilog-AMS or to IEEE 1364 digital
            \\Verilog, both of which need a discrete-event kernel that a
            \\compiled analog device artifact does not contain.
            ,
        },
        .E0202 => .{
            .title = "directive is only legal outside a design element",
            .lrm = "10.2",
            .explain =
            \\`begin_keywords and `end_keywords change which identifiers are
            \\reserved words, so LRM 10.2 confines them to the space between
            \\design elements. Placing one inside a module would change the
            \\keyword set halfway through parsing it.
            ,
        },
        .E0203 => .{
            .title = "named event declaration is not implemented",
            .lrm = "5.10.4",
            .explain =
            \\Named events (A.2.1.3 event_declaration, triggered with `->` and
            \\awaited with `@`) are a discrete-event feature. The analog kernel
            \\VerA targets schedules on the LRM 5.10 analog events —
            \\initial_step, final_step, cross, above, timer — which are
            \\supported.
            ,
        },
        .E0204 => .{
            .title = "module instantiation is not supported",
            .lrm = "6.2.2",
            .explain =
            \\VerA compiles ONE flat module into one device artifact, so
            \\there is no elaboration step to bind a child instance's ports or
            \\to flatten its equations into the parent's system.
            \\
            \\Inline the child's behaviour, or compile it as its own device and
            \\instantiate it in the netlist instead of in Verilog-A.
            ,
        },
        .E0205 => .{
            .title = "unsupported module item",
            .lrm = "A.1.4",
            .explain =
            \\This item is not one of the module_item alternatives the analog
            \\subset admits: parameter, net/port declarations, branch and
            \\variable declarations, analog function definitions, and the
            \\analog block itself.
            ,
        },
        .E0206 => .{
            .title = "identifier is not a port of this module",
            .lrm = "6.5.1",
            .explain =
            \\A port direction declaration (input/output/inout) names an
            \\identifier that does not appear in the module's port list.
            \\
            \\LRM 6.2 also forbids the reverse mistake: "Ports declared in the
            \\list of port declarations shall not be redeclared within the
            \\body of the module."
            ,
        },
        .E0207 => .{
            .title = "unexpected token",
            .lrm = "A",
            .explain =
            \\The parser needed one specific token here and found another. The
            \\message names both.
            \\
            \\When the expected token is a semicolon or a closing bracket, the
            \\real mistake is usually one construct earlier — look at the end
            \\of the previous statement first.
            ,
        },
        .E0208 => .{
            .title = "expected an identifier",
            .lrm = "2.8",
            .explain =
            \\A declaration or reference needs a name here. LRM 2.8: an
            \\identifier is a letter or underscore followed by letters, digits,
            \\underscores and dollar signs — "The first character of an
            \\identifier shall not be a digit or $".
            \\
            \\A name that must not obey those rules can be written as an
            \\escaped identifier: a backslash, the characters, then whitespace.
            ,
        },
        .E0209 => .{
            .title = "expected an expression",
            .lrm = "A.8.3",
            .explain =
            \\An operand was required here and the token found cannot begin
            \\one. Common causes: a trailing binary operator, an empty pair of
            \\parentheses, or a stray comma in an argument list.
            ,
        },
        .E0210 => .{
            .title = "expected ')'",
            .lrm = "A.8.3",
            .explain = "A parenthesised group or argument list is not closed.",
        },
        .E0211 => .{
            .title = "expected 'potential' or 'flow'",
            .lrm = "3.6.2.1",
            .explain =
            \\A discipline body binds its two natures by name:
            \\
            \\    discipline electrical
            \\      potential Voltage;
            \\      flow      Current;
            \\    enddiscipline
            \\
            \\LRM 3.6.2: "Conservative disciplines shall not have the same
            \\nature specified for both the potential and the flow."
            ,
        },
        .E0212 => .{
            .title = "expected 'continuous' or 'discrete'",
            .lrm = "3.6.2.2",
            .explain =
            \\A discipline's domain binding is one of the two keywords
            \\`continuous` and `discrete`.
            \\
            \\Note that annex C.4 makes `discrete` an error in Verilog-A, and
            \\LRM 3.6.2.2 makes it an error for a discrete discipline to carry
            \\nature bindings at all.
            ,
        },
        .E0213 => .{
            .title = "expected a discipline item",
            .lrm = "3.6.2",
            .explain =
            \\Inside `discipline`/`enddiscipline` the legal items are a domain
            \\binding, a potential binding, a flow binding, and attribute
            \\assignments. LRM 3.6.2 forbids nesting: discipline declarations
            \\do not appear inside another discipline, a nature, or a module.
            ,
        },
        .E0214 => .{
            .title = "expected '<+' or '='",
            .lrm = "5.6",
            .explain =
            \\A statement that begins with an access function must continue as
            \\a contribution (`<+`) or as the left side of an indirect
            \\assignment (`==` inside a `V(a,b) : expr == expr` form).
            \\
            \\Plain `=` assigns to a variable, never to a branch.
            ,
        },
        .E0215 => .{
            .title = "expected an operand",
            .lrm = "4.2.10",
            .explain =
            \\An operand was required and the token found cannot begin one.
            \\
            \\If the token is `^`, `~^` or `^~`: reduction xor is outside the
            \\analog subset (see E0320), and the parser reports the missing
            \\operand rather than guessing which of the two was meant.
            ,
        },
        .E0216 => .{
            .title = "concatenation operand has no bit width",
            .lrm = "4.2.13",
            .explain =
            \\LRM 4.2.13: "Unsized constant numbers shall not be allowed in
            \\concatenations." A concatenation's result width is the sum of its
            \\operand widths, so every operand must state one.
            \\
            \\Write 8'd5 rather than 5.
            ,
        },
        .E0217 => .{
            .title = "concatenation is wider than an integer",
            .lrm = "3.2.1",
            .explain =
            \\LRM 3.2.1 fixes the Verilog-A `integer` at 32 bits, and a
            \\concatenation evaluates to an integer. A wider result has nowhere
            \\to live.
            ,
        },
        .E0218 => .{
            .title = "port redeclared in the module body",
            .lrm = "6.2",
            .explain =
            \\LRM 6.2: "Ports declared in the list of port declarations shall
            \\not be redeclared within the body of the module."
            \\
            \\Syntax 6-1 gives a module header EITHER a `list_of_ports` (bare
            \\identifiers, whose direction and discipline then arrive in the
            \\body, 6.5.2) OR a `list_of_port_declarations` (direction and
            \\discipline in the header). The two are exclusive:
            \\
            \\    module m(p);                  // body MUST declare p
            \\      inout electrical p;
            \\
            \\    module m(inout electrical p); // body must NOT
            \\
            \\Delete the body line, or strip the header down to the bare name.
            \\
            \\The mirror-image mistake — a direction declaration naming an
            \\identifier that is not a port at all — is E0206.
            ,
        },
        .E0219 => .{
            .title = "a null statement is not an analog statement",
            .lrm = "A.6.4",
            .explain =
            \\Annex G.2.2 NULL: "This statement is no longer supported. Certain
            \\functions such as case, conditionals and the event statement do
            \\allow null statements as defined by the syntax."
            \\
            \\The syntax is where that is normative. A.6.4 lists every
            \\`analog_statement` alternative and none of them is `;`; the null
            \\lives only in
            \\
            \\    analog_statement_or_null ::= analog_statement
            \\                               | { attribute_instance } ;
            \\
            \\which is reached from a conditional arm, a case item and an event
            \\statement — and nowhere else. `analog_seq_block` (A.6.3) takes
            \\`{ analog_statement }` and `analog_construct` (A.6.2) takes one,
            \\so a free-standing `;` in either is underivable.
            \\
            \\Delete it. A deliberately empty conditional arm keeps its `;`.
            ,
        },
        .E0220 => .{
            .title = "empty analysis list on a step event",
            .lrm = "A.6.5",
            .explain =
            \\A.6.5:
            \\
            \\    analog_event_expression ::= ...
            \\      | initial_step [ ( " analysis_identifier "
            \\                         { , " analysis_identifier " } ) ]
            \\      | final_step   [ ( " analysis_identifier "
            \\                         { , " analysis_identifier " } ) ]
            \\
            \\The list inside the parentheses is non-empty and the whole
            \\parenthesised group is what is optional, so `final_step()` has no
            \\derivation. Annex G Table G.2 item 13 states the same conclusion
            \\directly: "@(final_step) without arguments should not have
            \\parenthesis".
            \\
            \\Drop the parentheses, or name at least one analysis (5.10.2,
            \\Table 5-1: "ac", "dc", "tran", "noise", ...).
            ,
        },

        // ------------------------------------------------------------ class 3
        .E0301 => .{
            .title = "vector ports are not supported",
            .lrm = "6.5.2",
            .explain =
            \\Each port of a compiled device maps to one solver unknown, so a
            \\vector port would need an elaboration step to expand into
            \\scalars. Declare the bits individually:
            \\
            \\    input a0, a1, a2;
            ,
        },
        .E0302 => .{
            .title = "vector nets are not supported",
            .lrm = "3.6.3",
            .explain =
            \\A net declared with a range would expand to several solver
            \\unknowns during elaboration, which the flat single-module
            \\pipeline does not run. Declare the nets individually.
            ,
        },
        .E0303 => .{
            .title = "aliasparam target is not a parameter",
            .lrm = "3.4.7",
            .explain =
            \\`aliasparam` gives a second name to an existing parameter, so its
            \\target must be a parameter declared in the same module.
            \\
            \\LRM 3.4.7 adds two rules worth knowing: the alias identifier
            \\"shall not occur anywhere else in the module", and it is an error
            \\to override one parameter through both its original name and an
            \\alias.
            ,
        },
        .E0304 => .{
            .title = "port branches are not supported",
            .lrm = "3.12",
            .explain =
            \\A port branch — `branch (<p>)` — names the flow into a port
            \\rather than a node pair. Read it with the port access function
            \\`I(<p>)` (LRM 5.4.3) instead, which is supported.
            ,
        },
        .E0305 => .{
            .title = "branch arrays are not supported",
            .lrm = "3.12",
            .explain =
            \\A ranged branch declaration expands to several branches during
            \\elaboration. Declare each branch separately.
            ,
        },
        .E0306 => .{
            .title = "expected a net identifier",
            .lrm = "3.12",
            .explain =
            \\A branch declaration names one or two nets:
            \\
            \\    branch (a, b) ab;      // between two nets
            \\    branch (a)    a_gnd;   // net to ground
            \\
            \\Expressions, constants and ports-by-index are not net names.
            ,
        },
        .E0307 => .{
            .title = "multi-dimensional arrays are not supported",
            .lrm = "3.2.2",
            .explain =
            \\VerA scalarizes one-dimensional arrays at compile time. A
            \\second dimension would need an index-flattening pass that the
            \\engine does not run.
            ,
        },
        .E0308 => .{
            .title = "array bound is not a constant expression",
            .lrm = "3.2.2",
            .explain =
            \\LRM 3.2.2: both array indices "shall be constant expressions".
            \\Arrays are scalarized at compile time, so the bounds must be
            \\known then — they may depend on parameters, since parameters are
            \\resolved before elaboration, but not on variables or probes.
            ,
        },
        .E0309 => .{
            .title = "identifier is not an array",
            .lrm = "3.2.2",
            .explain =
            \\This name was indexed with `[...]` but was declared as a scalar.
            \\Check for a shadowing declaration in an inner block.
            ,
        },
        .E0310 => .{
            .title = "array index is out of bounds",
            .lrm = "3.2.2",
            .explain =
            \\The index lies outside the declared range. Because arrays are
            \\scalarized at compile time, every index is known at compile time
            \\too — so an out-of-range access is a compile error, never a
            \\runtime one.
            ,
        },
        .E0311 => .{
            .title = "array index is not a constant expression",
            .lrm = "3.2.2",
            .explain =
            \\Arrays are scalarized, so each access must resolve to one element
            \\at compile time. An index that depends on a variable or a probe
            \\cannot.
            \\
            \\A genvar index works: genvar loops are unrolled (LRM 6.6.1), so
            \\the index is constant in each unrolled copy.
            ,
        },
        .E0312 => .{
            .title = "cannot assign to a parameter",
            .lrm = "3.4",
            .explain =
            \\Parameters are constants of an instance: they are set by the
            \\model card or by a defparam before the analog block runs, and
            \\stay fixed for the whole solve.
            \\
            \\Declare a `real` or `integer` variable for a value that changes.
            ,
        },
        .E0313 => .{
            .title = "unknown variable",
            .lrm = "6.8",
            .explain =
            \\No variable, parameter or genvar with this name is visible here.
            \\Verilog-A scopes are lexical: a name declared inside a named
            \\block (LRM 5.3.2) is not visible outside it.
            ,
        },
        .E0314 => .{
            .title = "unknown identifier",
            .lrm = "6.8",
            .explain =
            \\Nothing with this name is declared in scope — not a variable, a
            \\parameter, a net, a branch, a discipline, or a function.
            ,
        },
        .E0315 => .{
            .title = "net must be read through an access function",
            .lrm = "4.4",
            .explain =
            \\A net names a point in a conservative system, not a number. Ask
            \\for one of its two signals explicitly:
            \\
            \\    V(n)      potential of n relative to ground
            \\    V(a, b)   potential across the branch a-b
            \\    I(a, b)   flow through the branch a-b
            \\
            \\LRM 4.4 also forbids `V(n1, n1)`: a flow access whose two net
            \\expressions name the same signal has no branch to flow through.
            ,
        },
        .E0316 => .{
            .title = "unsupported assignment target",
            .lrm = "5.7",
            .explain =
            \\LRM 5.7: "The left-hand side of a procedural assignment shall be
            \\scalar" — a variable, or one element of a scalarized array.
            ,
        },
        .E0317 => .{
            .title = "a concatenation is not an assignment target",
            .lrm = "5.7",
            .explain =
            \\A concatenation builds a value; it does not name storage. LRM
            \\4.2.13 makes the related rule explicit for replications:
            \\"expressions containing replications shall not appear on the
            \\left-hand side of an assignment".
            \\
            \\Assign to each variable separately.
            ,
        },
        .E0318 => .{
            .title = "bitwise operator requires integer operands",
            .lrm = "4.2.9",
            .explain =
            \\LRM 4.2.1: with a real operand "all other operators are
            \\considered illegal" — bitwise and reduction operators among them.
            \\A real is an IEEE double whose bit pattern is not a modelled
            \\value in Verilog-A.
            \\
            \\Convert explicitly if that is really the intent; LRM 4.2.1.1
            \\rounds a real to integer, away from zero on an exact .5.
            ,
        },
        .E0319 => .{
            .title = "reduction operator requires an integer operand",
            .lrm = "4.2.10",
            .explain =
            \\A reduction folds an operand's bits into one bit, so the operand
            \\must have bits. See E0318.
            ,
        },
        .E0320 => .{
            .title = "xor reduction is not in the analog subset",
            .lrm = "C",
            .explain =
            \\`^`, `~^` and `^~` as unary reductions are removed from the
            \\Verilog-A subset along with the rest of the four-state operator
            \\set. Compute the parity you need arithmetically, or with the
            \\binary bitwise operators, which are supported on integers.
            ,
        },
        .E0321 => .{
            .title = "arithmetic on a string operand",
            .lrm = "3.3",
            .explain =
            \\Strings are message and file-name payloads. They compare and
            \\concatenate; they do not take part in arithmetic.
            \\
            \\LRM 3.4: "It shall be an error to assign a numeric value to a
            \\parameter declared as string or to assign a string value to a
            \\real parameter."
            ,
        },
        .E0322 => .{
            .title = "bitwise and shift operators require integer operands",
            .lrm = "4.2.9",
            .explain =
            \\See E0318. Shifts additionally need an integer shift count: a
            \\fractional shift distance has no meaning.
            ,
        },
        .E0323 => .{
            .title = "case equality is not in the analog subset",
            .lrm = "C.5",
            .explain =
            \\`===` and `!==` compare x and z bit-for-bit, which requires the
            \\four-state value system that annex C.5 removes from Verilog-A.
            \\
            \\Use `==` and `!=`. For reals, prefer a tolerance comparison —
            \\`abs(a - b) < tol` — over exact equality.
            ,
        },
        .E0324 => .{
            .title = "arithmetic shifts are not in the analog subset",
            .lrm = "C",
            .explain =
            \\`<<<` and `>>>` are the signed-shift operators of IEEE 1364.
            \\Use `<<` and `>>`.
            ,
        },
        .E0325 => .{
            .title = "operator is not in the analog subset",
            .lrm = "C",
            .explain =
            \\This operator belongs to full Verilog-AMS or IEEE 1364 Verilog.
            \\Annex C lists what the Verilog-A analog subset keeps.
            ,
        },
        .E0326 => .{
            .title = "empty concatenation",
            .lrm = "4.2.13",
            .explain = "`{}` has no operands, so it has no width and no value.",
        },
        .E0327 => .{
            .title = "concatenation operand has no bit width",
            .lrm = "4.2.13",
            .explain =
            \\LRM 4.2.13 accepts only sized constants (LRM 2.6.1) and strings
            \\(LRM 3.3) as concatenation operands, because the result width is
            \\the sum of the operand widths.
            \\
            \\A replication constant must additionally be "a non-negative,
            \\non-x and non-z constant expression".
            ,
        },
        .E0328 => .{
            .title = "string concatenation requires constant operands",
            .lrm = "3.3",
            .explain =
            \\A concatenation of strings is folded at compile time into one
            \\string literal, so each operand must be known then. There is no
            \\runtime string buffer in a compiled device.
            ,
        },
        .E0329 => .{
            .title = "part selects are not supported",
            .lrm = "4.2.13",
            .explain =
            \\A part select `x[msb:lsb]` slices a vector. The analog subset has
            \\no vector nets or vector ports (see E0301, E0302), so there is
            \\nothing to slice.
            ,
        },
        .E0330 => .{
            .title = "unsupported index expression",
            .lrm = "3.2.2",
            .explain =
            \\Indexing is supported on scalarized arrays with a constant index.
            \\See E0309, E0310 and E0311 for the specific cases.
            ,
        },
        .E0331 => .{
            .title = "aliasparam name is already a parameter",
            .lrm = "3.4.7",
            .explain =
            \\LRM 3.4.7: "The alias_identifier shall not occur anywhere else in
            \\the module; in particular, it shall not conflict with a different
            \\parameter_identifier".
            \\
            \\An `aliasparam` is a second NAME for one parameter, not a second
            \\parameter. Pointing it at a name that is already declared silently
            \\rebinds that name for the rest of the module, so
            \\
            \\    parameter real a = 1.0;
            \\    parameter real b = 7.0;
            \\    aliasparam a = b;
            \\    analog I(p,n) <+ V(p,n) * a;    // reads b: gain 7, not 1
            \\
            \\computes with `b` while the source says `a`, and the model card's
            \\`a` field becomes dead — writing it changes nothing.
            \\
            \\Rename the alias, or delete the parameter it collides with.
            ,
        },
        .E0332 => .{
            .title = "base nature is missing a required attribute",
            .lrm = "3.6.1.2",
            .explain =
            \\LRM 3.6.1: "Each nature definition ... shall include all the
            \\required attributes specified in 3.6.1.2", and 3.6.1.2 says of
            \\abstol, access and units that each "is required for all base
            \\natures".
            \\
            \\    nature Voltage;
            \\      units  = "V";
            \\      access = V;
            \\      abstol = 1e-6;
            \\    endnature
            \\
            \\A nature that means to inherit them is a DERIVED nature and says
            \\so with a parent: `nature High_Voltage : Voltage;`.
            ,
        },
        .E0333 => .{
            .title = "derived nature redefines `units`",
            .lrm = "3.6.1.2",
            .explain =
            \\LRM 3.6.1.2, units: "It is illegal for a derived nature to define
            \\or change the units; the derived nature always inherits its parent
            \\nature units."
            \\
            \\Units are what makes the parent's tolerance and the child's
            \\comparable at all, so a child in different units is not a
            \\refinement of its parent — it is a different quantity, and wants a
            \\base nature of its own.
            \\
            \\Contrast abstol, which 3.6.1.2 explicitly allows a derived nature
            \\to change.
            ,
        },
        .E0334 => .{
            .title = "derived nature changes `access`",
            .lrm = "3.6.1.2",
            .explain =
            \\LRM 3.6.1.2, access: "It is illegal for a derived nature to change
            \\the access attribute; the derived nature always inherits the
            \\access attribute of its parent nature."
            \\
            \\The access function is how source text names the quantity (LRM
            \\4.4). A derived nature narrows the TOLERANCE of its parent's
            \\quantity, not its spelling, so `V(n)` keeps working on a net whose
            \\discipline binds the derived nature.
            ,
        },
        .E0335 => .{
            .title = "two base natures share an access function",
            .lrm = "3.13.2",
            .explain =
            \\LRM 3.13.2: "the access function of each base nature shall be
            \\unique". The name in an access function call (LRM 4.4) has to
            \\identify one nature, and with two claiming it there is no reading
            \\of `MyAccess(n)` that a compiler could pick.
            \\
            \\Two natures that are meant to be the same quantity are spelled as
            \\one base nature plus a derived nature (LRM 3.6.1.1), which
            \\inherits the access name instead of re-declaring it.
            ,
        },
        .E0336 => .{
            .title = "identifier is already declared as a nature or a discipline",
            .lrm = "3.13.1",
            .explain =
            \\LRM 3.13.1: "Natures and disciplines are defined at the same level
            \\of scope as modules. Thus, identifiers defined as natures or
            \\disciplines have a global scope" — one namespace, and LRM 3.6.1
            \\adds that each nature "shall have a unique identifier".
            \\
            \\The ambiguity is real, not cosmetic: annex A takes a bare
            \\identifier for both `parent_nature ::= nature_identifier` and
            \\`net_declaration ::= discipline_identifier ...`, so a name bound to
            \\both kinds leaves those productions with no unique reading.
            ,
        },
        .E0337 => .{
            .title = "net has no declared discipline",
            .lrm = "3.6.3",
            .explain =
            \\LRM 3.6.3: "Nets declared with a natureless discipline or declared
            \\without a discipline do not have declared natures, so such nets
            \\can not be used in analog behavioral descriptions (because the
            \\access functions are not known)." LRM 6.5.2.1 says the same of a
            \\port: an undeclared type leaves it usable "only in a structural
            \\description".
            \\
            \\This fires on the ACCESS, not on the declaration — LRM 3.6.5
            \\implicit nets are legal right up to the point where behavioral
            \\code asks for a potential or a flow they do not have.
            \\
            \\Declare a discipline for the net: `electrical n;`.
            ,
        },
        .E0338 => .{
            .title = "conservative discipline binds one nature to both halves",
            .lrm = "3.6.2.1",
            .explain =
            \\LRM 3.6.2.1: "Conservative disciplines shall not have the same
            \\nature specified for both the potential and the flow."
            \\
            \\The same clause makes the potential nature's `access` the
            \\potential access function and the flow nature's the flow access
            \\function, so one nature on both bindings gives one name two
            \\meanings and no way to tell them apart at a call site.
            ,
        },
        .E0339 => .{
            .title = "`domain discrete` on a discipline that binds a nature",
            .lrm = "3.6.2.2",
            .explain =
            \\LRM 3.6.2.2: "It is an error for a discipline to have a domain
            \\binding of discrete if it has nature bindings."
            \\
            \\A discrete-domain net is solved by the digital kernel, which has
            \\no continuous quantity for a nature to describe. Drop the nature
            \\binding, or make the domain continuous (which is the default for
            \\a discipline that binds natures).
            ,
        },
        .E0340 => .{
            .title = "nature attribute value of the wrong form",
            .lrm = "3.6.1.2",
            .explain =
            \\LRM 3.6.1.2 fixes the form of each attribute's value:
            \\
            \\  - `access` — "shall be an identifier (by name, not as a
            \\    string)", because it introduces a callable name;
            \\  - `units` — "shall be a string", because LRM 3.11.1's Units
            \\    Value Rule compares two natures on it;
            \\  - `idt_nature`/`ddt_nature` — "the name (not a string) of a
            \\    nature".
            \\
            \\LRM 3.6.1.3 adds of a user-defined attribute that "the value being
            \\assigned to the attribute shall be constant": a nature lives
            \\outside every module (LRM 3.13.1), so no runtime name is in scope
            \\to assign from.
            ,
        },
        .E0341 => .{
            .title = "`idt_nature` does not name a related nature",
            .lrm = "3.6.1.2",
            .explain =
            \\LRM 3.6.1.2: "If specified, the constant expression assigned to
            \\idt_nature shall be the name (not a string) of a nature which is
            \\defined elsewhere." A derived nature may override the parent's
            \\value, but "the nature thus specified shall be related (share the
            \\same base nature) to the nature the parent uses for its
            \\idt_nature".
            \\
            \\`idt(access(...))` takes its tolerance from that nature, so a
            \\dangling or unrelated name leaves the integral with no tolerance
            \\the solver can use.
            ,
        },
        .E0342 => .{
            .title = "nature or discipline is already declared",
            .lrm = "3.13.1",
            .explain =
            \\LRM 3.6.1: "Each nature definition shall have a unique identifier
            \\as the name of the nature." LRM 3.6.2 says the same of a
            \\discipline, and LRM 3.13.1 puts both in one global scope, so the
            \\second declaration has nowhere to live.
            \\
            \\Two declarations of one name give a net of it two different sets
            \\of access functions. A nature that means to reuse another's
            \\attributes derives from it (LRM 3.6.1.1): `nature b : a;
            \\endnature`.
            ,
        },
        .E0343 => .{
            .title = "duplicate user-defined nature attribute",
            .lrm = "3.6.1.3",
            .explain =
            \\LRM 3.6.1.3: "The name of the attribute shall be unique in the
            \\nature being defined and the value being assigned to the
            \\attribute shall be constant."
            \\
            \\Two assignments to one attribute name leave `<nature>.<attr>`
            \\with no single reading.
            ,
        },
        .E0344 => .{
            .title = "`ground` net is not of a continuous discipline",
            .lrm = "3.6.4",
            .explain =
            \\LRM 3.6.4: "Each ground declaration is associated with an already
            \\declared net of continuous discipline. ... The net must be
            \\assigned a continuous discipline to be declared ground."
            \\
            \\The global reference node is the zero of a potential. A discrete
            \\discipline binds no nature (LRM 3.6.2.2), so there is no potential
            \\for it to be the reference of.
            ,
        },

        .E0345 => .{
            .title = "parameter initializer type conflicts with the parameter's type",
            .lrm = "3.4.1",
            .explain =
            \\LRM 3.4.1: "No conversion shall be applied for strings; it shall
            \\be an error to assign a numeric value to a parameter declared as
            \\string or to assign a string value to a real parameter, whether
            \\that parameter was declared as real or had its type derived from
            \\the type of the value of the constant expression."
            \\
            \\The sentence BEFORE it is the general rule and it is why this one
            \\has to be written down: "If the type of the parameter is specified
            \\as integer or real, and the value assigned to the parameter
            \\conflicts with the type of the parameter, the value is converted
            \\to the type of the parameter." `parameter real size = 10;` is
            \\legal by that rule. String is the one type the conversion does not
            \\reach, in either direction.
            ,
        },
        .E0346 => .{
            .title = "array or string parameter needs an explicit type",
            .lrm = "3.4.1",
            .explain =
            \\LRM 3.4.1: "If the type of a parameter is not specified, it is
            \\derived from the type of the final value assigned to the
            \\parameter, after any value overrides have been applied ... Note
            \\that the type of a string parameter (see 3.4.6) and any of the
            \\array parameters (see 3.4.4) is mandatory." LRM 3.4.4 states the
            \\array half again inside the restriction list it closes with
            \\"Failure to follow these restrictions shall result in an error".
            \\
            \\Inference is defined over the value AFTER overrides, so an untyped
            \\parameter has no type until elaboration — and the two rules that
            \\have to hold before then, 3.4.1's ban on string conversion and
            \\3.4.4's element type, would have nothing to test. An array's
            \\initializer is an assignment pattern, which is not a scalar value
            \\and has no type to derive in the first place.
            \\
            \\    parameter real c[0:3] = '{1.0, 2.0, 3.0, 4.0};
            \\    parameter string kind = "npn";
            ,
        },
        .E0347 => .{
            .title = "value range bounds are in the wrong order",
            .lrm = "3.4.2",
            .explain =
            \\LRM 3.4.2: "The first expression in the range shall be numerically
            \\smaller than the second expression in the range."
            \\
            \\`from [10:1]` describes the empty set — no value is both >= 10 and
            \\<= 1 — so the parameter can never take a legal value, including
            \\its own default. This is decidable from the declaration alone; it
            \\is not the separate question of whether a given override falls
            \\inside a well-formed range.
            ,
        },
        .E0348 => .{
            .title = "reduction operators cannot be used inside the analog block",
            .lrm = "4.2.10",
            .explain =
            \\LRM 4.2.10, the whole clause: "The reduction operators can not be
            \\used inside the analog block and only have meaning when used in
            \\the digital context."
            \\
            \\There is no carve-out and no analog form: `&`, `|`, `~&` and `~|`
            \\are banned exactly as `^`, `~^` and `^~` are (those get E0320,
            \\which also carries annex C.5's separate removal of the four-state
            \\operators from Verilog-A).
            \\
            \\A reduction folds a BIT VECTOR, and an analog value is a real
            \\number on a continuous net. Write the test you mean: `x != 0`
            \\for `|x`, `x == -1` for `&x` on a two's-complement integer.
            ,
        },
        .E0349 => .{
            .title = "array parameter initialiser is not an assignment pattern",
            .lrm = "3.4",
            .explain =
            \\LRM 3.4: "For parameters defined as arrays, the initializer shall
            \\be a constant_assignment_pattern expression ... using an
            \\assignment pattern (see 4.2.14), i.e. within '{ and } delimiters."
            \\3.4.4 prints the form:
            \\
            \\    parameter real poles[0:3] = '{ 1.0, 3.198, 4.554, 1.0 };
            \\
            \\The apostrophe is not decoration. Annex G Table G.4 item 2 records
            \\why v2.3 added it: "to distinguish a list of values from the
            \\concatenation operator". Without it `{2.1, 4.5}` is the 4.2.13
            \\concatenation, a different production with a different meaning,
            \\and a front end that accepts it as an initialiser cannot tell the
            \\two apart.
            ,
        },

        // ------------------------------------------------------------ class 4
        .E0401 => .{
            .title = "`disable` is not an analog statement",
            .lrm = "A.6.4",
            .explain =
            \\A.6.4 derives `analog_statement` without a `disable_statement`
            \\alternative. The only form an analog block admits is the event
            \\statement
            \\
            \\    @(<event>) disable <named_block>;
            \\
            \\which A.6.4 spells as analog_event_statement.
            ,
        },
        .E0402 => .{
            .title = "`disable` is not implemented",
            .lrm = "A.6.5",
            .explain =
            \\The event form of `disable` parses but has no lowering: aborting
            \\a named block mid-solve would leave the contributions it had
            \\already made in the system of equations.
            ,
        },
        .E0403 => .{
            .title = "`return` outside an analog function",
            .lrm = "4.7.1",
            .explain =
            \\LRM 5.11 jump statements are confined to an analog function body.
            \\The analog block itself has no caller to return to — it runs to
            \\completion on every solver evaluation.
            ,
        },
        .E0404 => .{
            .title = "`break` or `continue` outside a loop",
            .lrm = "5.9",
            .explain =
            \\These statements need an enclosing `for`, `while` or `repeat` in
            \\the same function or analog block.
            ,
        },
        .E0405 => .{
            .title = "contribution is not allowed in this context",
            .lrm = "5.2.1",
            .explain =
            \\`<+` adds a term to the system of equations, so it belongs in the
            \\analog block. LRM 4.7.2 keeps analog functions pure: a function
            \\body may compute, but it may not contribute, probe, or use analog
            \\operators.
            \\
            \\Return the value and contribute it at the call site.
            ,
        },
        .E0406 => .{
            .title = "contribution inside an event statement",
            .lrm = "5.10",
            .explain =
            \\The body of an `@(...)` event statement runs only at the instants
            \\the event fires, while a contribution must hold continuously —
            \\the solver re-evaluates it at every iteration of every timepoint.
            \\
            \\Set a variable in the event body and contribute it outside.
            ,
        },
        .E0407 => .{
            .title = "port access function cannot be a contribution target",
            .lrm = "5.4.3",
            .explain =
            \\LRM 5.5.1: "The port access function shall not be used on the
            \\left side of a contribution operator <+."
            \\
            \\`I(<p>)` MEASURES the flow into port p; it does not name a branch
            \\that could receive a contribution. Contribute to the branch
            \\instead: `I(p, gnd) <+ ...`.
            ,
        },
        .E0408 => .{
            .title = "contribution target must be a branch access",
            .lrm = "5.6",
            .explain =
            \\The left side of `<+` is one access function applied to a branch
            \\or a node pair:
            \\
            \\    I(a, b) <+ expr;
            \\    V(br)   <+ expr;
            \\
            \\Not a variable, not a general expression, not a bare net.
            ,
        },
        .E0409 => .{
            .title = "branch is already indirectly assigned",
            .lrm = "5.6.7.2",
            .explain =
            \\A branch is defined either by accumulated `<+` contributions or
            \\by one indirect assignment, never both: LRM 5.6.1.3 accumulates
            \\every contributing path into one value, while LRM 5.6.7 replaces
            \\the branch's equation with the stated constraint.
            \\
            \\Mixing them leaves the branch with two contradictory equations.
            ,
        },
        .E0410 => .{
            .title = "indirect contribution is not allowed in this context",
            .lrm = "5.2.1",
            .explain =
            \\An indirect contribution states a constraint on the whole system,
            \\so it belongs in the analog block. See E0405 for why an analog
            \\function may not contain one.
            ,
        },
        .E0411 => .{
            .title = "indirect contribution inside an event statement",
            .lrm = "5.10",
            .explain =
            \\See E0406: an event body runs at instants, a constraint must hold
            \\continuously.
            ,
        },
        .E0412 => .{
            .title = "indirect contribution in a conditional or loop",
            .lrm = "5.6.7",
            .explain =
            \\LRM 5.6.7: "Indirect branch contributions shall not be used in
            \\conditional or looping statements, unless the conditional
            \\expression is a constant expression."
            \\
            \\A constraint that exists only on some solver iterations changes
            \\the size of the equation system between iterations, which no
            \\Newton solver can follow. A constant condition is fine — it is
            \\resolved at compile time and the branch simply is or is not
            \\emitted.
            ,
        },
        .E0413 => .{
            .title = "indirect contribution target must be a branch access",
            .lrm = "5.6.7",
            .explain =
            \\The left of the `:` names the unknown the constraint solves for:
            \\
            \\    V(out) : I(out) == 0;
            ,
        },
        .E0414 => .{
            .title = "invalid left side of '==' in an indirect contribution",
            .lrm = "5.6.7",
            .explain =
            \\The `==` names the quantity driven to the right-hand value. It
            \\must be an access function, or `ddt`, `idt` or `idtmod` applied
            \\to one:
            \\
            \\    V(out) : I(out)      == 0;
            \\    V(out) : ddt(V(cap)) == i/c;
            ,
        },
        .E0415 => .{
            .title = "branch already has a direct contribution",
            .lrm = "5.6.7.2",
            .explain = "The mirror image of E0409 — see that code.",
        },
        .E0416 => .{
            .title = "casex/casez are not in the analog subset",
            .lrm = "C.7",
            .explain =
            \\`casex` and `casez` treat x and z as wildcards, which needs the
            \\four-state value system annex C removes from Verilog-A.
            \\
            \\Use `case`, or an if/else chain.
            ,
        },
        .E0417 => .{
            .title = "genvar loop bound is not a constant expression",
            .lrm = "6.6.1",
            .explain =
            \\A genvar loop is unrolled at compile time, so its initial value,
            \\its condition and its step must all be constant expressions.
            \\
            \\For a loop whose trip count depends on a solver value, use an
            \\ordinary `integer` loop variable — but note that its body may not
            \\contain analog operators (LRM 4.5.15).
            ,
        },
        .E0418 => .{
            .title = "genvar loop condition is not a constant expression",
            .lrm = "6.6.1",
            .explain = "See E0417.",
        },
        .E0419 => .{
            .title = "genvar loop step is not a constant expression",
            .lrm = "6.6.1",
            .explain =
            \\See E0417. LRM 6.6.1 additionally requires that "both the
            \\initialization and iteration assignments shall assign to the same
            \\genvar".
            ,
        },
        .E0420 => .{
            .title = "genvar loop did not terminate",
            .lrm = "6.6.1",
            .explain =
            \\LRM 6.6.1: "It shall be an error if the loop does not terminate."
            \\Unrolling hit the engine's iteration cap, which means the step
            \\never drives the condition false.
            \\
            \\LRM 6.6.1 also forbids a repeated genvar value across iterations.
            ,
        },
        .E0421 => .{
            .title = "access function is not allowed in this context",
            .lrm = "4.7.2",
            .explain =
            \\LRM 4.7.2 keeps analog functions pure: the body "shall not
            \\contain" branch contributions, access functions, or analog
            \\operators, because a function is evaluated as a value, not as
            \\part of the equation system.
            \\
            \\Pass the probed value in as an argument.
            ,
        },
        .E0422 => .{
            .title = "analog operator is not allowed in this context",
            .lrm = "4.5.15",
            .explain =
            \\Analog operators (ddt, idt, transition, slew, laplace_*, zi_*,
            \\...) carry state across timepoints, so they must be evaluated
            \\once per timepoint at a fixed place in the block.
            \\
            \\LRM 4.5.15 therefore bars them from analog function bodies and
            \\from any context whose execution count is not fixed. LRM 5.8.4
            \\states the related rule for conditionals: an analog filter may
            \\not sit inside a conditionally executed contribution.
            ,
        },
        .E0423 => .{
            .title = "both quantities of a probe branch are read",
            .lrm = "5.4.2.1",
            .explain =
            \\LRM 1.3.1: "The potential and flow of a probe branch may not both
            \\appear in expressions in a given module." LRM 5.4.2.1 repeats it
            \\with the word: "Using both the potential and the flow of a probe
            \\branch is illegal."
            \\
            \\A branch is a probe when nothing is contributed to it (LRM
            \\1.3.1). LRM 5.4.2.1 then pins ONE of its quantities at zero — the
            \\potential of a flow probe, the flow of a potential probe — and
            \\which one is decided by which the module reads. Reading both asks
            \\for two zeros at once and no branch satisfies that.
            \\
            \\Contribute to the branch to make it a source (LRM 5.4.2.2 then
            \\makes both quantities accessible), or read only one.
            ,
        },

        .E0424 => .{
            .title = "a special floating point value reaches a branch",
            .lrm = "7.3.2.1",
            .explain =
            \\LRM 7.3.2.1: "Floating point arithmetic can produce special values
            \\representing plus and minus infinity and Not-a-Number (NaN) to
            \\represent a bad value. While use of these special numbers in
            \\digital expressions is not an error, it is illegal to assign these
            \\values to a branch through contribution in the analog context."
            \\
            \\A branch value is a row of the residual the solver factors. An
            \\infinity or a NaN in that row destroys the whole matrix, not just
            \\the one entry, so the clause bans it at the contribution rather
            \\than leaving it to be discovered at the first Newton step.
            \\
            \\Only the case that FOLDS is caught here: 1.0/0.0, -1.0/0.0 and
            \\0.0/0.0 are IEEE 754 results of the source's own arithmetic and
            \\are known at compile time. A value that only becomes infinite at
            \\runtime is the finiteness proof's business (see W0650), which is a
            \\warning about what cannot be ruled out and not this rule.
            ,
        },
        .E0425 => .{
            .title = "contribution to an `input` signal-flow port",
            .lrm = "1.3.4.1",
            .explain =
            \\LRM 1.3.4.1: "In that case, potential contributions may not be
            \\made to `input` ports." 1.3.4.2: "Flow contributions may not be
            \\made to input ports in this case."
            \\
            \\A signal-flow port carries one quantity, so its direction IS the
            \\direction of that quantity: an `input` is a value the enclosing
            \\netlist supplies and the module reads. A contribution drives it,
            \\which would make the module and its driver two sources of one
            \\value with nothing to reconcile them — the conservation law that
            \\settles that argument on a conservative net (1.3.1) does not exist
            \\here.
            \\
            \\Contribute to an `output` port instead, and read the input.
            \\
            \\The DECLARATION is legal: a signal-flow discipline on a directional
            \\port is exactly the intended shape. Only the contribution target
            \\is wrong.
            ,
        },
        .E0426 => .{
            .title = "contribution inside a runtime loop",
            .lrm = "5.9",
            .explain =
            \\LRM 5.9, the third of three blanket restrictions on `repeat`,
            \\`while` and the non-genvar `for`: "Contribution statements are
            \\not allowed."
            \\
            \\A device's set of branches is fixed before the solve begins, and
            \\a runtime trip count is not — the number of equations may not
            \\depend on data. The 5.9.3 genvar `for` is exempt because its trip
            \\count is known at elaboration and the loop is unrolled, so the
            \\branches it stamps are all there before the first iteration.
            \\
            \\Accumulate into a variable in the loop and contribute once after
            \\it, or make the loop a genvar loop.
            ,
        },
        .E0427 => .{
            .title = "more than one `default` arm in a case statement",
            .lrm = "5.8.3",
            .explain =
            \\LRM 5.8.3: "The default statement is optional. Use of multiple
            \\default statements in one case statement is illegal."
            \\
            \\Nothing in the clause orders the arms, so a second `default`
            \\leaves the fall-through undefined rather than merely redundant.
            \\Merge them, or give one of them its own label list.
            ,
        },

        // ------------------------------------------------------------ class 5
        .E0501 => .{
            .title = "unknown access function",
            .lrm = "3.6.1.4",
            .explain =
            \\An access function name comes from the `access` attribute of a
            \\nature (LRM 3.6.1.2), reached through the discipline bound to the
            \\net. `V` and `I` come from annex D's `disciplines.vams`.
            \\
            \\LRM 4.4 requires that "the access function name shall match the
            \\discipline declaration for the nets, ports, or branch": using
            \\`V` on a net whose discipline binds a differently-named potential
            \\nature is this error, not a silent coercion.
            ,
        },
        .E0502 => .{
            .title = "ddt() requires an argument",
            .lrm = "4.5.3",
            .explain = "`ddt(expr)` differentiates its operand with respect to time.",
        },
        .E0503 => .{
            .title = "ddt() must be a linear factor of a contribution",
            .lrm = "5.6.1.2",
            .explain =
            \\A contribution splits into a resistive part and a reactive part,
            \\and the reactive part is what `ddt` produces. The solver needs
            \\that split to build the charge/flux vector separately from the
            \\residual, so `ddt(...)` must appear as a term or as a linear
            \\factor of one:
            \\
            \\    I(a,b) <+ c * ddt(V(a,b));       // ok
            \\    I(a,b) <+ ddt(V(a,b)) / r;       // ok
            \\    I(a,b) <+ sin(ddt(V(a,b)));      // not a linear factor
            \\
            \\Assign the derivative to a variable first if the nonlinear form
            \\is really what the model needs.
            ,
        },
        .E0504 => .{
            .title = "ddx() second argument must be an access function",
            .lrm = "4.5.6",
            .explain =
            \\`ddx(expr, V(n))` takes the symbolic partial derivative of expr
            \\with respect to one probe, so the second argument names that
            \\probe and nothing else.
            ,
        },
        .E0505 => .{
            .title = "analog operator does not accept an empty argument",
            .lrm = "4.5.14",
            .explain =
            \\An omitted argument in an analog operator's list means "use the
            \\default". This operator has no default for that position.
            ,
        },
        .E0506 => .{
            .title = "wrong number of arguments to a math function",
            .lrm = "4.3",
            .explain =
            \\LRM 4.3 tables 4-14 and 4-15 fix each math function's arity.
            \\Note `atan2(y, x)` and `hypot(x, y)` take two, while `min`, `max`
            \\and `pow` also take two.
            ,
        },
        .E0507 => .{
            .title = "port access function must be a flow access",
            .lrm = "5.4.3",
            .explain =
            \\`I(<p>)` reads the flow INTO port p from outside the module. A
            \\potential has no such directional meaning at a port boundary, so
            \\the `<...>` form exists only for the flow access function of the
            \\port's discipline.
            \\
            \\For a potential, probe the node: `V(p)`.
            ,
        },
        .E0508 => .{
            .title = "port access function names a net that is not a port",
            .lrm = "5.4.3",
            .explain =
            \\`I(<p>)` measures flow across the module boundary, so p must be
            \\in the module's port list. An internal net has no outside.
            ,
        },
        .E0509 => .{
            .title = "concatenation is only supported as a filter coefficient list",
            .lrm = "4.5.11",
            .explain =
            \\The `{...}` form is accepted where LRM 4.5.11 and 4.5.12 expect a
            \\vector of Laplace or Z-transform coefficients. Elsewhere it is a
            \\bit concatenation (LRM 4.2.13), which the analog subset has no
            \\vector operands for.
            ,
        },
        .E0510 => .{
            .title = "recursive analog function",
            .lrm = "4.7.1",
            .explain =
            \\Analog functions are inlined at every call site, so recursion has
            \\no base case to stop the inliner. A compiled device has no call
            \\stack at run time.
            \\
            \\Rewrite as a loop, or unroll to a fixed depth.
            ,
        },
        .E0511 => .{
            .title = "wrong number of arguments to an analog function",
            .lrm = "4.7.2",
            .explain =
            \\An analog function call supplies exactly one actual argument per
            \\declared formal, in order. There are no defaults and no varargs.
            ,
        },
        .E0512 => .{
            .title = "unknown function",
            .lrm = "4.7",
            .explain =
            \\No analog function, math function or analog operator with this
            \\name is in scope. An analog function must be defined in the same
            \\module, before use.
            ,
        },
        .E0513 => .{
            .title = "absdelta() is not implemented",
            .lrm = "4.5.14",
            .explain =
            \\`absdelta` requests timestep control from the simulator based on
            \\an expression's change. A compiled device artifact reports
            \\residuals and charges; it does not drive the timestep controller.
            \\
            \\`$bound_step` (LRM 9.17.2) is the supported way to ask for a
            \\maximum timestep.
            ,
        },
        .E0514 => .{
            .title = "analog operator under a condition that can change during the solve",
            .lrm = "5.8.1",
            .explain =
            \\LRM 5.8.1: "If any of the conditionally-executed statements
            \\contains an analog operator, the conditional expression shall be
            \\a analysis_or_constant_expression." LRM 5.9 states the same ban
            \\for `repeat`, `while` and non-genvar `for`, without the carve-out.
            \\
            \\An analog operator is a STATE MACHINE, not a function: `ddt`,
            \\`idt`, `transition`, `slew`, `absdelay`, `laplace_*` and `zi_*`
            \\each carry history from one accepted timestep to the next. The
            \\generated device advances that history once per step, on the
            \\straight-line spine of the analog block. When the operator sits
            \\under a runtime branch, the step on which the branch is off feeds
            \\it the type's zero instead of the real input, so its history is
            \\wrong from then on — and it stays wrong after the branch comes
            \\back. Nothing about the residual looks unusual; the answer is
            \\just no longer the one the source describes.
            \\
            \\THREE CONDITIONS ARE LEGAL and do not warn:
            \\
            \\    if (analysis("dc"))  ...   // analysis_function_call
            \\    if (some_parameter)  ...   // constant_primary: a parameter
            \\    for (i = 0; i < 4; i = i + 1) ...   // genvar: unrolled
            \\
            \\None of them can change while the solve is running, so the
            \\operator's branch is decided once and its history stays whole.
            \\
            \\TO FIX: hoist the operator out of the branch and switch its
            \\RESULT instead of its execution —
            \\
            \\    tmp = ddt(V(a));               // always stepped
            \\    if (en) I(a) <+ tmp;           // only the use is conditional
            \\
            \\`--deny=E0514` makes this the error LRM 5.8.1 says it is. It is a
            \\warning by default only because rejecting it outright would stop
            \\compiling foundry models that have shipped with the bug for years.
            ,
        },
        .E0515 => .{
            .title = "analog operator control argument is not a constant or parameter expression",
            .lrm = "4.5",
            .explain =
            \\The CONTROL arguments of a §4.5 analog operator — the delay of
            \\`absdelay`, the rise/fall times of `transition`, the slew rates of
            \\`slew`, the initial condition of `idt`/`idtmod`, the period of a
            \\`zi_*` filter — are evaluated by the HOST, outside the derivative
            \\domain the residual is computed in. VerA renders them as plain
            \\f64 expressions over `Model`, so they may be built from literals
            \\and parameters and from +, -, *, /, abs, sqrt, min, max and pow
            \\over those. Anything else has no value at that point.
            \\
            \\A control argument that depends on a NODE VOLTAGE is the usual
            \\cause, and it is not a spelling problem: the operator's history is
            \\advanced once per accepted timestep, before the Newton iteration
            \\that would produce such a value.
            \\
            \\    absdelay(V(a), V(b))       // no: the delay is a solve result
            \\    absdelay(V(a), len*sqrt(l*c))   // yes: parameters only
            \\
            \\A delay assigned into a `real` variable first is fine — the
            \\expression is resolved through SSA, not by spelling — but one that
            \\merges two different values on two arms of a runtime `if` is not.
            \\
            \\NOTE on §4.5.7: a time-VARYING `absdelay` delay is legal in the
            \\LRM when a `maxdelay` argument is given. VerA does not
            \\implement it; without `maxdelay` the LRM freezes td at its first
            \\evaluation, which is exactly the constant this code requires.
            ,
        },
        .E0516 => .{
            .title = "analog operator argument is outside the range the LRM allows",
            .lrm = "4.5",
            .explain =
            \\Each §4.5 operator states the bound on its control arguments in
            \\one sentence, and each bound is what makes the operator's contract
            \\satisfiable at all:
            \\
            \\  4.5.5  idtmod        "The modulus shall be an expression which
            \\                       evaluates to a positive value." The output
            \\                       range is offset <= idtmod < offset+modulus,
            \\                       which is empty unless modulus > 0.
            \\  4.5.7  absdelay      "In all cases td shall be a positive
            \\                       number." A negative delay asks a history
            \\                       buffer for the future.
            \\  4.5.8  transition    "td, rise_time, fall_time, and time_tol are
            \\                       optional, but if specified shall be
            \\                       non-negative." Zero is allowed and 4.5.8
            \\                       says what each zero means; negative would
            \\                       end a ramp before it starts.
            \\  4.5.9  slew          "max_pos_slew_rate shall be greater than
            \\                       zero (0) and max_neg_slew_rate shall be
            \\                       less than zero (0)." The signs are what say
            \\                       which limit is which.
            \\  4.5.10 last_crossing "The optional direction indicator shall
            \\                       evaluate to an integer expression +1, -1,
            \\                       or 0." An enumeration, not a range.
            \\
            \\Only arguments that FOLD are checked. These slots are typed
            \\analog_expression, so a rise time written over a parameter is
            \\legal and its sign is not knowable here; VerA stays silent rather
            \\than reject what it cannot prove.
            ,
        },
        .E0517 => .{
            .title = "cross()/above() argument is the wrong type or out of range",
            .lrm = "5.10.3.1",
            .explain =
            \\LRM 5.10.3.1 types cross()'s optional arguments in three
            \\sentences:
            \\
            \\  "The dir and enable arguments, if specified, shall evaluate to
            \\   integers." 0 or absent is both edges, +1 rising, -1 falling.
            \\  "The tolerances (time_tol and expr_tol) ... shall be
            \\   non-negative." A tolerance is the window the crossing time is
            \\   narrowed into; a negative one names an empty window.
            \\  "If either or both tolerances are defined, then the direction
            \\   shall also be defined." A tolerance selects how precisely a
            \\   crossing is resolved, and which crossings count is the
            \\   direction's job — a tolerance without one narrows nothing.
            \\
            \\LRM 5.10.3.2 gives above() the same tolerances and no direction.
            \\
            \\Eliding a slot is not itself an error: Syntax 5-16 types them
            \\analog_expression_or_null and 5.10.3.1's own `sh` example writes
            \\`cross(V(smpl) - thresh, dir, , , en === 1'b1)`.
            ,
        },

        // ------------------------------------------------------------ class 6
        .E0601 => .{
            .title = "divisor cannot be proven non-zero",
            .lrm = "4.2.4",
            .explain =
            \\LRM 4.2.8: "It shall be an error to pass zero (0) as the second
            \\argument to the modulus operator." Integer `/` is the same case:
            \\an integer has no infinity to represent the result, and the
            \\generated code would execute illegal behaviour.
            \\
            \\Note that REAL division by zero is NOT an error here — x/0.0 is a
            \\well-defined IEEE infinity, so VerA accepts it and the unit
            \\forfeits its finiteness proof instead (see W0650). That is what
            \\lets `I <+ V/r` compile for an unranged parameter r.
            \\
            \\To satisfy this code, give the divisor a range that excludes zero
            \\(LRM 3.4.2):
            \\
            \\    parameter integer n = 1 from [1:inf);
            \\    parameter integer m = 1 exclude 0;
            \\
            \\or guard the division with an `if` the prover can see.
            ,
        },
        .E0602 => .{
            .title = "argument of ln/log must be positive",
            .lrm = "4.3.1",
            .explain =
            \\Table 4-14 gives ln(x) and log10(x) the domain x > 0. LRM 4.3.2:
            \\"Input values outside of the valid range for the operator shall
            \\report an error."
            \\
            \\VerA proves this by interval analysis and reports only when
            \\the argument is provably outside the domain — an argument it
            \\cannot decide is accepted and costs the unit its finiteness
            \\proof (W0650), never a rejection.
            \\
            \\Constrain the parameter with `from (0:inf)` (LRM 3.4.2), or guard
            \\the call with `if (x > 0)`.
            ,
        },
        .E0603 => .{
            .title = "argument of ln1p must be greater than -1",
            .lrm = "4.3.1",
            .explain =
            \\ln1p(x) computes ln(1+x), so its domain is x > -1. See E0602 for
            \\how the proof works and how to satisfy it.
            ,
        },
        .E0604 => .{
            .title = "argument of sqrt must be non-negative",
            .lrm = "4.3.1",
            .explain =
            \\Table 4-14 gives sqrt(x) the domain x >= 0. See E0602.
            \\
            \\Constrain with `from [0:inf)`, or write `sqrt(abs(x))` if the
            \\magnitude is what the model means.
            ,
        },
        .E0605 => .{
            .title = "argument of asin/acos must be within [-1, 1]",
            .lrm = "4.3.2",
            .explain =
            \\Table 4-15 gives asin and acos the domain -1 <= x <= 1. See
            \\E0602. Constrain with `from [-1:1]`, or clamp the argument with
            \\`min`/`max` before the call.
            ,
        },
        .E0606 => .{
            .title = "argument of atanh must be within (-1, 1)",
            .lrm = "4.3.2",
            .explain =
            \\Table 4-15 gives atanh the OPEN domain -1 < x < 1; the endpoints
            \\are poles, not values. Constrain with `from (-1:1)` — note the
            \\round brackets, which LRM 3.4.2 uses for an excluded bound.
            ,
        },
        .E0607 => .{
            .title = "argument of acosh must be at least 1",
            .lrm = "4.3.2",
            .explain =
            \\Table 4-15 gives acosh the domain x >= 1. Constrain with
            \\`from [1:inf)`. See E0602.
            ,
        },
        .E0608 => .{
            .title = "argument of tan is at a pole",
            .lrm = "4.3.2",
            .explain =
            \\tan(x) is undefined at odd multiples of pi/2, where cos(x) is
            \\zero. The prover reports only an argument it can show lands on a
            \\pole.
            ,
        },
        .E0609 => .{
            .title = "pow() arguments violate the sign rule",
            .lrm = "4.3.1",
            .explain =
            \\Table 4-14 constrains pow(x, y): with x < 0, y must be an
            \\integer, because a negative base raised to a fractional power has
            \\no real value; and with x == 0, y must be non-negative.
            \\
            \\Use `pow(abs(x), y)` with an explicit sign, or constrain the base
            \\with `from [0:inf)`.
            ,
        },
        .W0650 => .{
            .title = "unit is not provably finite, so it compiles in strict float mode",
            .lrm = "4.3",
            .explain =
            \\THE FINITENESS WARNING. This is not a correctness problem — the
            \\model is legal, it compiles, and it will simulate correctly. It
            \\reports what the model COSTS.
            \\
            \\VerA proves, per source unit (one `<+` target: an access
            \\function plus a node pair), whether every value in that unit's
            \\backward slice is a finite IEEE double. A unit that is proven
            \\finite compiles with @setFloatMode(.optimized), which asserts
            \\"no NaN, no Inf" and lets the backend reassociate, fuse and
            \\vectorize the residual. A unit that is not proven finite compiles
            \\with @setFloatMode(.strict), where infinity is a legal, IEEE-
            \\defined value — correct, but measurably slower, and it does not
            \\vectorize in the batch evaluator.
            \\
            \\LRM 4.3.2 makes exp's domain "All x", and LRM 4.5.13 makes
            \\`limexp` optional, so a model that can overflow to infinity is
            \\CONFORMANT. VerA never rejects one and never inserts a clamp
            \\or a limexp behind your back. It tells you instead.
            \\
            \\The attached notes name the value that broke the proof — a
            \\parameter with no range, a probe with unbounded magnitude, an
            \\unmodelled call — and where it was defined.
            \\
            \\Common causes, and what recovers .optimized:
            \\
            \\  - An unranged parameter feeding exp/sinh/cosh/pow. Add a range
            \\    (LRM 3.4.2): `parameter real vt = 0.026 from (0:1];`
            \\  - A raw probe inside a transcendental: exp(V(a,b)) overflows at
            \\    V > 710. Either bound the argument in the model, or tell the
            \\    engine the solver's compliance limit, which is a property of
            \\    your solver and not of the language:
            \\        proof.Options{ .unknown_bound = 100.0 }
            \\  - A division whose divisor may be zero: real x/0.0 is legal
            \\    (see E0601) but yields an infinity, so it forfeits the proof.
            \\    `exclude 0` on the divisor's parameter recovers it.
            \\  - A parameter whose range explicitly ADMITS infinity, e.g.
            \\    `from [0:inf]`. Closing the bound — `from [0:inf)` — keeps
            \\    the same values and restores finiteness. See W0651.
            \\  - A call the prover does not model (an analog operator, a ch9
            \\    system function). Unmodelled always costs .strict rather than
            \\    risking a wrong .optimized. See W0652.
            \\
            \\If strict mode is what you want for this model, silence the
            \\warning with `--allow=W0650`.
            ,
        },
        .W0651 => .{
            .title = "parameter range admits infinity",
            .lrm = "3.4.2",
            .explain =
            \\A range whose bound is a CLOSED infinity — `from [0:inf]` — says
            \\that infinity is an acceptable value for this parameter, so the
            \\prover must treat it as a possible input and every unit
            \\downstream forfeits its finiteness proof (W0650).
            \\
            \\This is almost never intended. Writing the bound open,
            \\`from [0:inf)`, admits exactly the same finite values and keeps
            \\the proof:
            \\
            \\    parameter real r = 1k from (0:inf);
            \\
            \\See W0650 for what the proof buys.
            ,
        },
        .W0652 => .{
            .title = "call is not modelled by the finiteness prover",
            .lrm = "4.5",
            .explain =
            \\The prover has an abstract range for the LRM 4.3 math functions
            \\and for the handful of system functions whose range the LRM fixes
            \\($vt, $temperature, ...). Everything else — analog operators
            \\carrying state, other ch9 system functions — is treated as
            \\unbounded.
            \\
            \\That is deliberate: an unmodelled call costs the unit .strict
            \\(W0650), never a wrong .optimized, which would be silent
            \\Release-only undefined behaviour.
            \\
            \\Assign the call's result to a variable and constrain it with a
            \\guard the prover can see, if the value really is bounded.
            ,
        },

        // ------------------------------------------------------------ class 7
        .E0701 => .{
            .title = "event expression outside '@()'",
            .lrm = "5.10",
            .explain =
            \\`cross`, `above`, `timer`, `initial_step` and `final_step` name
            \\events, not values. They belong in the parentheses of an event
            \\control statement:
            \\
            \\    @(initial_step) begin ... end
            ,
        },
        .E0702 => .{
            .title = "event control is not allowed in this context",
            .lrm = "5.2.1",
            .explain =
            \\An `@(...)` statement schedules work at instants, which only the
            \\analog block can do. LRM 4.7.2 keeps analog functions pure — see
            \\E0405.
            ,
        },
        .E0703 => .{
            .title = "nested event control statement",
            .lrm = "5.10",
            .explain =
            \\A.6.4 derives analog_event_statement with a plain statement body,
            \\so an event statement does not contain another one. Combine the
            \\conditions with `or` instead:
            \\
            \\    @(initial_step or cross(V(a) - 0.5, +1)) ...
            ,
        },
        .E0704 => .{
            .title = "posedge/negedge is digital-only",
            .lrm = "5.10.1",
            .explain =
            \\Edge events observe a discrete signal changing value. The analog
            \\equivalent is `cross`, which detects a continuous expression
            \\passing through zero in a stated direction:
            \\
            \\    @(cross(V(clk) - vth, +1)) ...    // rising
            ,
        },
        .E0705 => .{
            .title = "named events are not implemented",
            .lrm = "5.10.4",
            .explain = "See E0203.",
        },
        .E0706 => .{
            .title = "unsupported event expression",
            .lrm = "5.10",
            .explain =
            \\The supported analog events are `initial_step`, `final_step`,
            \\`cross`, `above` and `timer`, combined with `or`.
            ,
        },
        .E0707 => .{
            .title = "event control statement under a runtime condition or in a loop",
            .lrm = "5.8",
            .explain =
            \\LRM 5.8: "Event control statements (e.g.: timer, cross) cannot be
            \\used inside conditional statements unless the conditional
            \\expression is a constant expression." LRM 5.9 bans them in
            \\`repeat`, `while` and non-genvar `for` outright, and LRM 5.10.3.1
            \\repeats it for `cross` specifically: "it shall not be used inside
            \\an if, case, casex, or casez statement unless the conditional
            \\expression is a genvar expression."
            \\
            \\A monitored event is not a test the residual performs — it is a
            \\detector the kernel advances once per accepted timestep, outside
            \\the Newton loop. Its `prev`/`hit` state therefore moves whether or
            \\not the branch that encloses it ran, so the detector's history and
            \\the code that reads it drift apart. Worse, the enclosing condition
            \\is evaluated inside the residual, where it is re-evaluated several
            \\times per step at different operating points.
            \\
            \\NOTE this is STRICTER than E0514: `if (analysis("dc"))` licenses
            \\an analog operator but NOT an event control statement, because
            \\LRM 5.8 asks for a constant expression here and 5.10.3.1 asks for
            \\a genvar expression.
            \\
            \\TO FIX: put the `@(...)` on the spine of the analog block and make
            \\the STATEMENT it guards do the conditional work —
            \\
            \\    @(cross(V(clk) - 0.5, +1))
            \\      if (en) held = V(in);
            \\
            \\`--deny=E0707` makes this the error the LRM says it is.
            ,
        },

        // ------------------------------------------------------------ class 8
        .E0801 => .{
            .title = "unsupported system function",
            .lrm = "9",
            .explain =
            \\This ch9 system function has no meaning for a compiled device
            \\artifact, which computes residuals and charges for a host solver
            \\and owns neither a simulation session nor an RNG stream.
            \\
            \\Deliberately rejected rather than stubbed: `$random`, `$arandom`
            \\and the `$dist_*`/`$rdist_*` family (LRM 9.13), because silently
            \\returning a constant would make a model that looks stochastic
            \\behave deterministically. `$table_model` (LRM 9.21) is rejected
            \\for the same reason — it would need a file-backed interpolator at
            \\run time.
            ,
        },
        .E0802 => .{
            .title = "$bound_step takes exactly one argument",
            .lrm = "9.17.2",
            .explain = "`$bound_step(max_step)` — one real expression.",
        },
        .E0803 => .{
            .title = "$bound_step argument must be non-negative",
            .lrm = "9.17.2",
            .explain =
            \\The argument is a maximum timestep, so a negative value has no
            \\meaning; the solver would have no bound to honour.
            ,
        },
        .E0804 => .{
            .title = "$discontinuity takes at most one argument",
            .lrm = "9.17.1",
            .explain =
            \\`$discontinuity` optionally takes the degree of the discontinuity
            \\— `$discontinuity(0)` for a value step, `$discontinuity(1)` for a
            \\slope step.
            ,
        },
        .E0805 => .{
            .title = "$discontinuity argument is not a constant expression",
            .lrm = "9.17.1",
            .explain =
            \\The degree is a property of the model's structure, not of the
            \\current operating point, so it must be known at compile time.
            ,
        },
        .E0806 => .{
            .title = "system task is not supported in the analog context",
            .lrm = "9.2",
            .explain =
            \\Every Chapter 9 table has a "supported in analog context" column,
            \\and this name's cell says No. The prose subclauses are worded as
            \\PERMISSIONS — §9.5 "extends many of the file operation tasks so
            \\that they can be used in the analog context", §9.11 "extends the
            \\conversion functions ... so that $bitstoreal and $realtobits can
            \\be used in the analog context" — so the tables under §9.2 are
            \\where the prohibition actually lives.
            \\
            \\The families, and why each stops at the digital context:
            \\
            \\  Table 9-1 / 9-2 — the b/h/o radix variants of the display and
            \\  file-output tasks. The suffix only picks a DEFAULT radix for
            \\  arguments written without a format specification, which is a
            \\  statement about bit vectors; §9.4.3's per-argument `%b`/`%o`/
            \\  `%h` works fine in an analog block. $monitoron/$monitoroff
            \\  toggle the digital $monitor mechanism.
            \\
            \\  Table 9-2 also — $fgetc, $ungetc and $fread read bytes and bit
            \\  patterns; $readmemb/$readmemh load a memory array and
            \\  $sdf_annotate loads timing onto a digital netlist. Neither
            \\  object exists in the analog context.
            \\
            \\  Table 9-3 / 9-7 — $printtimescale, $timeformat, $time and
            \\  $stime are all about the timescale TICK. The analog kernel has
            \\  no tick: it advances by a continuously variable step. §9.10
            \\  adds $abstime, in seconds, for the analog context, and
            \\  deprecates $realtime there.
            \\
            \\  Table 9-5 / 9-6 — §9.8 and §9.9 are one sentence each: Verilog
            \\  AMS HDL "does not extend" the PLA modeling tasks, and "does not
            \\  extend" the stochastic analysis tasks.
            \\
            \\  Table 9-8 — $itor, $rtoi, $signed and $unsigned. §4.2.1.3
            \\  already promotes a mixed expression's integer operand, and
            \\  signedness reinterpretation presupposes a sized vector.
            ,
        },
        .E0807 => .{
            .title = "$stop shall not be used within an analog initial block",
            .lrm = "9.7.2",
            .explain =
            \\§9.7.2: "$stop causes simulation to be suspended at a converged
            \\time point", and an analog initial block runs before there is
            \\one — §5.2.1 executes it once per analysis, ahead of the first
            \\matrix solution.
            \\
            \\$finish is deliberately the opposite: §9.7.1 defines what it
            \\means there ("the simulator shall exit without performing the
            \\simulation"), so it stays legal in an analog initial block.
            \\$stop in an ordinary `analog` block is legal too.
            ,
        },
        .E0808 => .{
            .title = "retired Verilog-A v1.0 spelling",
            .lrm = "G.1",
            .explain =
            \\Annex G Table G.1, "Limiting exponential function": the OVI
            \\Verilog-A v1.0 spelling `$limexp( expression )` was replaced in
            \\v2.0 by `limexp( expression )`.
            \\
            \\It is not an alias. A `$` name is a system function (Clause 9),
            \\and `$limexp` appears in neither Table 9-11 nor A.8.2 — the name
            \\does not exist. 4.5.13 defines the analog operator under the bare
            \\name only.
            \\
            \\Drop the `$`.
            ,
        },
        .E0809 => .{
            .title = "$limit is missing an argument its algorithm requires",
            .lrm = "9.17.3",
            .explain =
            \\LRM 9.17.3 fixes the arity of the two algorithms it names:
            \\
            \\  "fetlim" — "One additional argument to the $limit() function is
            \\    required ...: the third argument to $limit() is generally the
            \\    threshold voltage of the MOS transistor."
            \\  "pnjlim" — "Two additional arguments ... are required ...: the
            \\    third argument ... indicates a step size vte and the fourth
            \\    argument is a critical voltage vcrit."
            \\
            \\This is not the unknown-string case. The same clause lets a
            \\simulator ignore a string it does not recognise ("just as if no
            \\string had been supplied"), and `$limit(V(a,b))` with no string
            \\at all is legal (Syntax 9-12). Naming one of these two is what
            \\imposes the arity.
            ,
        },
        .E0810 => .{
            .title = "not enough arguments for the format specifiers",
            .lrm = "9.4.3",
            .explain =
            \\LRM 9.4.3, stated again in 9.4.1: "for each % character (except
            \\%m, %% and %l) that appears in a string, a corresponding
            \\expression argument shall be supplied after the string."
            \\
            \\The parenthesis is what makes this checkable rather than a
            \\formatting preference: three specifiers consume no operand and
            \\every other one consumes exactly one, so the format string alone
            \\fixes how many arguments are required.
            \\
            \\The reverse is NOT an error. 9.4.3 gives extra arguments a
            \\meaning — "any expression argument with no corresponding format
            \\specification is displayed using the default decimal format" —
            \\so only a shortfall is diagnosed.
            \\
            \\Only a literal format string is counted. A format assembled at
            \\run time has no count to check against.
            ,
        },
        .W0850 => .{
            .title = "display task dropped: a device does not print",
            .lrm = "9.4",
            .explain =
            \\VerA makes two artifacts out of one .va, and this one is the
            \\DEVICE: a residual function the solver calls inside its Newton
            \\loop, on a batch of instances, possibly on a GPU.
            \\
            \\A print there is not a debugging aid, it is a per-iteration
            \\syscall on a hot loop that also happens not to compile for
            \\SPIR-V or PTX. So the display family (LRM 9.4.1) and the
            \\severity family (9.7.3) lower to void, exactly as they always
            \\have — this warning only says so out loud, once per call site.
            \\
            \\The model is CONFORMANT; nothing is wrong with it. If the text
            \\is what you wanted, build the other artifact:
            \\
            \\    vera --emit-exe FILE.va       # a runnable testbench
            \\    vera --display=emit ...       # or just the codegen knob
            \\
            \\which lowers the same tasks to `std.debug.print` and gives the
            \\device a `display()` entry point that runs them.
            \\
            \\Silence it for a model you know prints only under a debug flag
            \\with `--allow=W0850`.
            ,
        },
        .W0851 => .{
            .title = "display task under a conditional is not emitted",
            .lrm = "9.4.6",
            .explain =
            \\`--display=emit` hoists a module's display tasks into one unit
            \\that runs top to bottom, and a task inside an `if`, a `case` or a
            \\loop has no place in it: its operands are only defined on the arm
            \\that ran, so emitting it would print on a path the source did not
            \\take.
            \\
            \\LRM 9.4.6 makes emission a property of the SOLVE — text appears
            \\on accepted iterations — and a compiled device has no accepted
            \\iteration to consult. Rather than print unconditionally and be
            \\wrong, VerA drops the task and says so.
            \\
            \\Rewrite the condition as a value instead of a branch:
            \\
            \\    if (v > 0.0) $strobe("ok");        // dropped
            \\    $strobe("ok=%d", v > 0.0);         // printed: "ok=1"
            \\
            \\A comparison is an integer in Verilog-A (LRM 4.2.5), so the guard
            \\becomes part of the output instead of gating it — which is also
            \\what makes the line diffable against an expected transcript.
            ,
        },

        // ------------------------------------------------------------ class 9
        .E0901 => .{
            .title = "hierarchical name in a flat module",
            .lrm = "6.8",
            .explain =
            \\A dotted name reaches into another scope in the instance tree.
            \\VerA compiles one flat module with no children (see E0204), so
            \\there is no tree to walk.
            ,
        },
        .E0902 => .{
            .title = "more than one discipline declaration for one net",
            .lrm = "7.4.4",
            .explain =
            \\LRM 7.4.4, repeated verbatim as step 3 of the discipline
            \\resolution algorithm in F.2.1 and F.2.2: "More than one
            \\conflicting discipline declaration from the same context (in or
            \\out of context) for the same hierarchical segment of a signal is
            \\an error. In this case, conflicting simply means an attempt to
            \\declare more than one discipline regardless of whether the
            \\disciplines are compatible or not."
            \\
            \\So COMPATIBILITY IS NOT THE TEST. Two declarations naming the same
            \\natures, or two natureless `domain continuous` disciplines that
            \\3.11.1's Natureless Discipline Rule makes compatible, are still an
            \\error — the second declaration is the error, not the mismatch.
            \\3.10 says it from the other side: two disciplines at the same level
            \\of precedence for one net is not legal.
            \\
            \\Delete one of the declarations. If the two were meant to describe
            \\different segments, they need different nets.
            ,
        },

        // ----------------------------------------------------------- class 10
        .E1001 => .{
            .title = "source contains no module declaration",
            .lrm = "6.2",
            .explain =
            \\A compilation unit must declare at least one `module`. If the
            \\file holds only `discipline`, `nature` or `` `define `` items, it
            \\is a header — include it from a module instead of compiling it.
            \\
            \\If the file DOES contain a design element, it is one VerA does
            \\not compile: `connectmodule`, `connectrules`, `macromodule`,
            \\`primitive`, `library` and `paramset` are all outside annex C.
            \\The earlier diagnostics name which one.
            ,
        },
        .E1002 => .{
            .title = "generated identifier is too long",
            .lrm = "",
            .explain =
            \\An engine limit, not a language rule. Code generation builds a
            \\structural key per unit from the module name, the access function
            \\and the node names; this one overflowed the fixed name buffer.
            \\
            \\Shorten the module or node names involved.
            ,
        },
    };
}

test "every code has info and a well-formed name" {
    const std = @import("std");
    inline for (@typeInfo(Code).@"enum".fields) |f| {
        const c: Code = @enumFromInt(f.value);
        const i = info(c);

        // The tag name IS the rendered code: one letter, then four digits.
        try std.testing.expectEqual(@as(usize, 5), f.name.len);
        try std.testing.expect(f.name[0] == 'E' or f.name[0] == 'W');
        for (f.name[1..]) |ch| try std.testing.expect(ch >= '0' and ch <= '9');

        // A title that is empty, capitalised or punctuated renders wrong: it is
        // pasted straight after "error[E0313]: ".
        try std.testing.expect(i.title.len > 0);
        try std.testing.expect(i.title[i.title.len - 1] != '.');
        try std.testing.expect(!(i.title[0] >= 'A' and i.title[0] <= 'Z'));
        try std.testing.expect(i.explain.len > 0);
    }
}

test "codes are unique and ordered by class" {
    const std = @import("std");
    @setEvalBranchQuota(200_000);
    const fields = @typeInfo(Code).@"enum".fields;
    inline for (fields, 0..) |f, i| {
        inline for (fields[i + 1 ..]) |g| {
            try std.testing.expect(f.value != g.value);
            try std.testing.expect(!std.mem.eql(u8, f.name, g.name));
        }
    }
}
