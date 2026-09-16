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
//! `@tagName` replaces a name table.

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
    // E0114 was "unsupported compiler directive". Retired: it had exactly two
    // subjects left, §10.7's `__FILE__ and `__LINE__, and both are now
    // expanded (preprocessor.zig `expand`). Every other backtick word VerA
    // does not know is an undefined MACRO, which is E0115. The number is not
    // reused.
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
    /// §10.2 Syntax 10-1: the operands of `default_discipline.
    E0127,
    /// IEEE 1364 §19.7: the operands of `line.
    E0128,
    /// §10.3 Syntax 10-2: the operand of `default_transition.
    E0129,
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
    /// Syntax 6-8 / A.4.2: a bare `begin ... end` where a module_or_generate_item
    /// belongs — a generate_block is only ever the body of a for or an if.
    E0221,
    /// §7.3.1 Table 7-1: a discrete bit grouping wider than 31 bits. A class-2
    /// number for a chapter-7 rule because the parser is the only stage that
    /// ever sees a `reg` declaration — see its entry.
    E0222,
    /// A.8.1 / §4.2.14: the replication count of an assignment pattern is not
    /// a literal.
    E0223,
    /// §4.7.1 bullet list: an analog function with no formal argument.
    E0224,
    /// §4.7.1 bullet list: a formal argument with no block item declaration
    /// giving its data type.
    E0225,
    /// §4.7.1 bullet list: a named block inside an analog function body.
    E0226,
    /// §4.7.2.2: `return` with no expression inside an analog function.
    E0227,
    /// §6.6 / A.4.2: a `generate` region below another `generate` — the region
    /// is a `module_item` and `module_or_generate_item` does not list it.
    E0228,
    /// §6.6 / Syntax 6-8: a `parameter` declaration inside a generate region or
    /// block, where `module_or_generate_item` admits only `localparam`.
    E0229,
    /// §6.6.1/§6.6.2/§6.8: a named generate block's name collides with another
    /// declaration of the enclosing scope, or with a block of another generate
    /// construct. A class-2 number for a scope rule on E0222's precedent: the
    /// parser is the only stage that can tell a `generate_block`'s name from a
    /// §5.3.2 statement label, so it is the only stage that can judge this.
    E0230,
    /// A.9.3 `hierarchical_identifier` — a per-segment `[ index ]` that is not
    /// a constant expression the parser can fold. A class-2 number on E0222's
    /// precedent: the parser is the only stage that CAN judge it, because it
    /// spells the index into the interned path text (`u[0].g`), the same string
    /// elaboration keys its flat names by.
    E0231,
    /// A.4.1 `pass_switchtype pass_switch_instance` — a `tran`/`rtran` instance
    /// is accepted and stamps nothing. A class-2 number on E0222's precedent:
    /// the parser is the only stage that ever sees a gate instantiation.
    W0250,

    // ---------------------------------------------------------------- class 3
    // Declarations, types, disciplines — lower.zig.
    // E0301 was "vector ports are not supported" and E0302 "vector nets are
    // not supported". Retired together: §3.6.3 vector nets and §6.5.2 vector
    // ports now elaborate, scalarised into one node per element, so neither
    // condition exists to report. Their successors are E0350 (§6.5.2.2 the two
    // declarations disagree), E0351 and E0352 (the element reference itself).
    // The numbers are not reused.
    //
    // E0304 was "port branches are not supported" and E0305 "branch arrays are
    // not supported". Retired on the same terms: §3.12.1 `branch (<p>) name;`
    // now resolves to the §5.4.3 port-flow unknown `I(<p>)` already carries, and
    // A.2.3 `branch (p,n) pair[0:1];` expands into one branch per element under
    // the scalarised name `pair[k]`. Neither condition exists to report. Reading
    // an element out of range is E0352 and reading the bare base name is E0351,
    // both shared with vector nets. The numbers are not reused.
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
    /// §6.5.2.2 a port whose direction and type declarations give ranges that
    /// do not evaluate to the same value.
    E0350,
    /// §5.5.2 a bit select of something that is not a vector net, or a whole
    /// vector net where a scalar signal is required.
    E0351,
    /// §3.6.3/§5.5.2 a vector index that is not constant, or is outside the
    /// declared range.
    E0352,
    /// §3.12 a branch whose two terminals are vectors of different sizes.
    E0353,
    /// §3.3/§3.4.1 a string value assigned to a numeric variable.
    E0354,
    /// §3.11/§3.11.1 two nets whose disciplines are incompatible, used as the
    /// two arguments of an access function (§3.11) or as the two terminals of a
    /// branch declaration (§3.12).
    E0355,
    /// §3.2 a reference that supplies fewer or more subscripts than the array's
    /// declaration has dimensions.
    E0356,
    /// §2.9 Syntax 2-4 an attribute value that is not a constant expression.
    E0357,
    /// §2.9.2 a standard attribute (`desc`, `units`, `op`, `multiplicity`) with
    /// a value outside the domain the clause fixes for it.
    E0358,
    /// §5.5.3 a nature attribute reference (`n.potential.abstol`) naming an
    /// attribute whose value is not a constant expression.
    E0359,
    /// §1.3.4.1/§1.3.4.2 a net of signal-flow discipline bound to an `inout`
    /// port. The sibling of E0425, which is about the contribution target.
    E0360,
    /// §3.4.2 an OVERRIDDEN parameter value falls outside its declared
    /// `from`/`exclude` value range. The sibling of E0347, which judges the
    /// range's own bounds; this one needs a value somebody supplied, which only
    /// §6.3 elaboration produces.
    E0361,
    /// §6.8 one identifier declares two items in one scope.
    E0362,
    /// §3.4/A.2.4 a parameter default that reads simulation state — `$abstime`,
    /// `$temperature`, an access function, `$random`, … — where the grammar
    /// requires a constant_mintypmax_expression.
    E0363,
    /// Known mixed-signedness shift comparison needs missing context typing.
    E0364,

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
    /// §6.6 a generate scheme — an if-generate condition or a case-generate
    /// selector — that is not a constant expression.
    E0428,
    /// §5.7 a whole-array assignment between arrays that are not assignment
    /// compatible: a different number of dimensions, a different number of
    /// elements in one of them, or a different element type.
    E0429,
    /// §4.7.3/§7.3.7 an analog user-defined function called from the discrete
    /// context — an `initial` or `always` block.
    E0430,
    /// §5.2.1 a discrete-owned (digital) value read from an `analog initial`
    /// block.
    E0431,
    /// §7.2.2 a variable assigned in BOTH the continuous and the discrete
    /// context.
    E0432,
    /// A.6.2 a statement in a digital `initial` block that is not an assignment
    /// of a constant expression to a module variable — the one shape a compiler
    /// with no event queue can lower.
    E0433,

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
    /// §4.5.12 a Z-filter with a zero transition time contributed straight to a
    /// branch — the abrupt discontinuity the clause allows in a VARIABLE, put
    /// where the solver has to differentiate it.
    E0518,
    /// §4.6.4.3/.4 a `noise_table`/`noise_table_log` argument that is not a
    /// usable (frequency, power) table — codegen.zig.
    E0519,
    /// §4.6.4 + §1.3.1.1 a noise generator on a ground-ground branch, which has
    /// no row and no column to name — codegen.zig.
    E0520,

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
    /// RETIRED — was "unsupported system function", a capability class whose
    /// list is now empty. Not reused; see the `explain`.
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
    /// §9.15 `$simparam` on a name this engine does not know, with no fallback.
    E0811,
    /// §9.20 misuse of `$analog_node_alias` / `$analog_port_alias`.
    E0812,
    /// §9.5.3/§9.5.4.2 `$swrite`/`$sformat`/`$sscanf` argument or conversion.
    E0813,
    /// §9.17.3 a `$limit` user-defined limiter with a formal that is not `input`.
    E0814,
    /// §9.21 a `$table_model` data source, control string or dimensionality that
    /// VerA cannot compile into a lookup.
    E0815,
    /// §9.13.1/§9.13.2 a probabilistic distribution argument that breaks one of
    /// the clause's own rules: the seed's type, an out-of-domain distribution
    /// parameter, the uniform's start/end order, or the paramset-only
    /// `type_string`.
    E0816,
    /// §9.16 a `$simprobe` whose instance/parameter pair resolves to nothing and
    /// that supplied no fallback expression.
    E0817,
    /// §9.22/§9.23 a driver access function called outside a connect module.
    E0818,
    /// §9.4.3 a format conversion whose operand has a type the display path
    /// cannot render through it: `%s` over a number, `%c` or a real conversion
    /// over a string.
    E0819,
    /// §9.4 display task dropped, because the artifact being built is a device.
    W0850,
    /// §9.4 display task under a conditional — not emitted even into an exe.
    W0851,
    /// §2.8.3/§12.32 an UNREGISTERED system function: a `$name` the language
    /// defines nowhere, whose meaning §12.32 hands to a VPI host the emitted
    /// artifact has none of. Reads 0.0, out loud.
    W0852,

    // ---------------------------------------------------------------- class 9
    // Hierarchy and elaboration — lower.zig, elaborate.zig.
    E0901,
    /// §7.4.4/F.2.1 step 3 more than one discipline declaration for one net.
    E0902,
    /// F.2.1/F.2.2 step 4.b, fourth bullet: a net whose discipline resolution
    /// came out UNKNOWN — more than one candidate, no matching `resolveto` —
    /// and which connects through a port to a segment of a different domain.
    /// Was RESERVED (a hole in this enum) while the multi-candidate arm did
    /// not exist; the number was promised to the rule the whole time, which is
    /// why the fixture's `//! reject` line never had to change.
    E0903,
    /// §6.2.2 an instance names a module (or paramset) the file never declares.
    E0904,
    /// §6.2.2 a module instantiates itself, directly or through a cycle.
    E0905,
    /// §6.2.2 the port connections do not match the module's port list.
    E0906,
    /// §6.3 an override names nothing the instantiated module declares.
    E0907,
    /// §3.4.7 a parameter and its `aliasparam` are both overridden.
    E0908,
    /// §6.2.2 an instance array range is not an elaboration-time constant.
    E0909,
    /// §6.7.1 an analog variable may not be accessed hierarchically.
    E0910,
    /// §6.4.2 no paramset of an overload set admits an instance's values.
    E0911,
    /// §6.3.6 a flow contribution is explicitly multiplied by `$mfactor`.
    E0912,
    /// §7.6/§7.7 a connect module is instantiated by name.
    E0913,
    /// §6.4.2 more than one paramset is still applicable after the clause's
    /// tie-breaking rules.
    E0914,
    /// §7.7.1 a connect insertion statement names no `connectmodule`.
    E0915,
    /// §7.7.2 a connect resolution statement names no declared discipline.
    E0916,
    /// §7.7.2 disciplines a `resolveto exclude` rule deems incompatible are
    /// found on one net.
    E0917,

    // --------------------------------------------------------------- class 10
    // Runtime / artifact contract — codegen.zig, root.zig.
    E1001,
    E1002,
    /// The device's `U` is `enum(u8)`, so it holds at most 256 unknowns.
    E1003,
    /// §6.3.4 a numeric default cannot be derived after host parameter writes.
    E1004,
    /// Shared-frontend digital execution boundary.
    E1100,
    /// §3.4 a parameter whose default has no compile-time value and no
    /// `derive()` line either, so the model card field ships as 0.
    W1050,
    /// §7.7.2.1 multiple discipline resolution rules match.
    W0950,
    /// §9.17.1 the only permitted negative discontinuity degree is -1.
    E0820,

    /// Rendered spelling — the tag name IS the code, so no name table exists.
    pub fn name(self: Code) []const u8 {
        return @tagName(self);
    }
};

/// Documentation for a code — one indexed load, no jump table.
///
/// `Code`'s values are dense (0..N-1, asserted below), so the lookup is
/// `table[@intFromEnum(c)]`. `table` is built at COMPTIME by evaluating the
/// exhaustive switch in `infoOf` once per code, which is what keeps both
/// properties at once: the switch still refuses to compile when a code arrives
/// without an arm, and it still binds a code to its text BY NAME, so no entry
/// can slide onto the wrong code the way a hand-written array literal allows.
/// The switch itself never reaches the binary — in a Debug build it was 16.8 KB
/// of `.text` for what is now a load.
pub fn info(c: Code) Info {
    return table[@intFromEnum(c)];
}

const table = build: {
    const fields = @typeInfo(Code).@"enum".fields;
    // Density is what makes a tag value usable as an index. Codes are never
    // renumbered and retired ones keep their slot (see RULES above), so this
    // holds by construction — it is asserted rather than assumed because the
    // indexing above is silently wrong if it ever stops holding.
    for (fields, 0..) |f, i| {
        if (f.value != i) @compileError("Code values must be dense: " ++ f.name ++ " is out of sequence");
    }
    @setEvalBranchQuota(100 * fields.len);
    var t: [fields.len]Info = undefined;
    for (fields) |f| t[f.value] = infoOf(@enumFromInt(f.value));
    break :build t;
};

fn retiredInfo(explanation: []const u8) Info {
    return .{
        .title = "(retired)",
        .lrm = "",
        .explain = explanation,
    };
}

/// The catalogue proper. Exhaustive by construction: adding a `Code` without an
/// arm here is a compile error, which is the point. Called only by `table`'s
/// comptime initializer, so it costs nothing at runtime.
fn infoOf(c: Code) Info {
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
        .E0127 => .{
            .title = "malformed `default_discipline qualifier",
            .lrm = "10.2",
            .explain =
            \\Syntax 10-1 spells the directive
            \\
            \\    `default_discipline [ discipline_identifier [ qualifier ] ]
            \\
            \\and the qualifier is a CLOSED alternation of fifteen data-type
            \\names: integer, real, reg, wreal, wire, tri, wand, triand, wor,
            \\trior, trireg, tri0, tri1, supply0, supply1.
            \\
            \\A discipline name in that slot is the common typo, because the
            \\two operands are adjacent identifiers. The qualifier selects
            \\WHICH nets the default claims, so more than one directive can be
            \\in force at once "provided each differs in qualifier"; it is not
            \\a second discipline and not free text.
            ,
        },
        .E0128 => .{
            .title = "malformed `line directive",
            .lrm = "10.7",
            .explain =
            \\LRM 10.7 defers to IEEE Std 1364 for `line, whose 19.7 spells it
            \\
            \\    `line number ["filename" [level]]
            \\
            \\The number is mandatory and is the line number given to the line
            \\FOLLOWING the directive; it is what `__LINE__ then counts from.
            \\A directive with no number remaps nothing, so it is a typo
            \\rather than a no-op.
            ,
        },
        .E0129 => .{
            .title = "malformed `default_transition directive",
            .lrm = "10.3",
            .explain =
            \\LRM 10.3 Syntax 10-2 is
            \\
            \\    `default_transition transition_time
            \\    transition_time ::= constant_expression
            \\
            \\with no brackets round the operand, so it is mandatory. A bare
            \\`default_transition is NOT a request for the simulator default:
            \\10.3 already states that case ("If a `default_transition
            \\directive is not used in the description, transition_time is
            \\controlled by the simulator"), so reading the operand-less form
            \\as it would silently discard a line the author wrote.
            \\
            \\The directive is read in the text stage, before there is a
            \\parser to fold a general constant_expression, so what it accepts
            \\is one LRM 2.6 number — with a Table 2-1 scale factor if you
            \\want one: `default_transition 4n.
            ,
        },
        .E0130 => .{
            .title = "literal requires digital value support in the execution backend",
            .lrm = "2.6.1",
            .explain =
            \\The frontend preserves Verilog-AMS four-state and wide integer
            \\literals. The current analog execution backend stores two-state
            \\integers in 64 bits and cannot execute this literal exactly.
            \\
            \\This diagnostic marks an implementation boundary, not a claim
            \\that the literal is forbidden by full Verilog-AMS.
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
        .E0203 => retiredInfo(
            \\"named event declaration is not implemented". Retired: A.2.1.3
            \\`event_declaration` now parses and 5.10.4's trigger/detect pair
            \\lowers, so the condition does not exist to report. A named event is
            \\an ANALOG event — 5.10 lists it as one of three kinds — so refusing
            \\the declaration was refusing part of the subset annex C.2 grants.
            \\
            \\What replaced it: E0705, for a `@(ev)` or `-> ev` naming something
            \\no `event` declaration introduced. The number is not reused.
        ),
        .E0204 => retiredInfo(
            \\"module instantiation is not supported". Retired: A.4.1
            \\module_instantiation now parses and `ir/elaborate.zig` flattens the
            \\instance tree into the one device VerA emits, so the condition does
            \\not exist to report. Annex C.8 keeps clause 6 hierarchy inside the
            \\Verilog-A subset, which made refusing an instance a refusal of part
            \\of the subset.
            \\
            \\What replaced it: E0904 (the instance names no module), E0905 (the
            \\instantiation is recursive), E0906 (the port connections do not
            \\match the port list) and E0907 (an override names no parameter).
            \\The number is not reused.
        ),
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
        .E0215 => retiredInfo(
            \\"expected an operand". Retired: a parser-recovery artifact that
            \\named no rule — it fired for ANY token that cannot begin an
            \\operand, and by dying first it made the codes that DO state a
            \\rule unreachable. Its one documented customer was reduction xor,
            \\which A.8.6 now parses so that lowering can report the real
            \\4.2.10/annex-C rule as E0320 (see parseUnary's note and
            \\ch04_expressions/07_reduction_xor_rejected.va, which pinned the
            \\replacement).
            \\
            \\What replaced it: E0209 for a token that genuinely cannot begin
            \\an expression, E0320/E0416 where this artifact was the accidental
            \\messenger. The number is not reused.
        ),
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
        .E0221 => .{
            .title = "a generate block is not a module item",
            .lrm = "6.6",
            .explain =
            \\Syntax 6-8:
            \\
            \\    generate_region ::= generate { module_or_generate_item }
            \\                        endgenerate
            \\    generate_block  ::= module_or_generate_item
            \\                      | begin [ : generate_block_identifier ]
            \\                          { module_or_generate_item } end
            \\
            \\`generate_block` is reached from exactly two places — the body of
            \\a loop_generate_construct and an arm of a
            \\conditional_generate_construct. It is not itself a
            \\module_or_generate_item, so a naked `begin ... end` has no
            \\derivation either directly in a generate region or at module
            \\scope. 6.6 says the same in prose: a generate region is "a textual
            \\span in the module description where generate constructs may
            \\appear", and a named block on its own is not a generate construct.
            \\
            \\Either give the block the `for` or `if` that generates it, or drop
            \\the `begin`/`end` and write the items directly — 6.6 makes the
            \\region itself optional and imposes no scope of its own.
            ,
        },
        .E0222 => .{
            .title = "discrete bit grouping wider than 31 bits",
            .lrm = "7.3.1",
            .explain =
            \\LRM 7.3.1 Table 7-1, the `bit` row: a discrete bit grouping read
            \\from a continuous context becomes an integer, "the lowest bit of
            \\the bit grouping is mapped to the zeroth bit of the integer", and
            \\"the sign bit (bit 31) of the integer is always set to zero (0)".
            \\
            \\That is why the row ends "access of discrete bit groupings with
            \\greater than 31 bits is illegal": bit 31 of a 32-bit grouping has
            \\nowhere left to land. 31 bits is the widest legal grouping, and it
            \\reads as at most +2147483647.
            \\
            \\Why a class-2 (parser) number for a chapter-7 semantic rule: the
            \\declared RANGE is the only evidence of a width, and nothing below
            \\the parser keeps it — a `reg` becomes one integer variable, which
            \\is Table 7-1's own mapping. It follows that the bounds have to be
            \\literals here; the check moves down to lowering, and gains the
            \\constant folder, the day a `reg` keeps its bits.
            ,
        },

        .E0223 => .{
            .title = "replication count in an assignment pattern is not a literal",
            .lrm = "4.2.14",
            .explain =
            \\A.8.1's second alternative for an assignment pattern is
            \\
            \\    '{ constant_expression { expression { , expression } } }
            \\
            \\and 4.2.14's own example is `'{ 5{0.0} }`. The count says how many
            \\ELEMENTS the pattern has, so it is unrolled while the pattern is
            \\parsed — which is before any parameter has a value.
            \\
            \\Write the digits, or write the elements out.
            \\
            \\A constant_expression naming a localparam is legal Verilog-AMS and
            \\this is VerA's limit, not the LRM's: the unroll moves to lowering,
            \\where the constant folder lives, the day one is needed. The
            \\CONCATENATION form `{n{...}}` has no such limit — 3.3 Table 3-3
            \\allows even a nonconstant multiplier there, and lowering handles
            \\it, because a concatenation is one value and not a list of them.
            ,
        },
        // 4.7.1's bullet list, and 4.7.2.2's one sentence about `return`, are
        // four separate rules and four separate codes. They are class 2 and not
        // class 5 for the reason class 2 is named after parser.zig: each is a
        // property of the DECLARATION, and lowering only ever sees a function
        // that is called (4.7.3 inlines at the call site), so a violating
        // function nobody calls would go undiagnosed there.
        .E0224 => .{
            .title = "an analog function declares no formal argument",
            .lrm = "4.7.1",
            .explain =
            \\4.7.1's bullet list, verbatim: an analog function "shall have at
            \\least one input argument declared". A.8.2 says the same from the
            \\call side — `analog_function_call ::= analog_function_identifier
            \\( analog_expression { , analog_expression } )` requires at least
            \\one actual.
            \\
            \\A function of no arguments is a constant. Write a localparam.
            ,
        },
        .E0225 => .{
            .title = "an analog function formal argument has no data type",
            .lrm = "4.7.1",
            .explain =
            \\4.7.1's bullet list, verbatim: "all formal arguments shall have an
            \\associated block item declaration specifying the data type of the
            \\argument".
            \\
            \\    analog function real scale;
            \\      input x;
            \\      real x;        // <- this line
            \\      scale = 2.0 * x;
            \\    endfunction
            \\
            \\`input real x;` is the other legal spelling (A.2.7 task_port_type).
            \\
            \\4.7.1's "if unspecified, the default is real" does NOT apply here:
            \\that sentence is about `analog_function_type`, the FUNCTION's
            \\return type. The bullet list grants a formal no default, it
            \\requires the declaration.
            ,
        },
        .E0226 => .{
            .title = "a named block is not allowed in an analog function",
            .lrm = "4.7.1",
            .explain =
            \\4.7.1's bullet list, verbatim: an analog function "shall not use
            \\named blocks".
            \\
            \\The hazard is concrete. 4.7.2.1 makes the function's own name an
            \\implicitly declared variable holding the return value, and a named
            \\block (5.3.2) may carry its own declarations — one spelled with the
            \\function's name would shadow the return variable and the function
            \\would hand back the initial 0. The LRM bans the construct rather
            \\than specifying the shadowing.
            \\
            \\Drop the label: an unnamed `begin ... end` is unrestricted.
            ,
        },
        .E0227 => .{
            .title = "a return statement in an analog function specifies no expression",
            .lrm = "4.7.2.2",
            .explain =
            \\4.7.2.2, verbatim: "When the return statement is used, the function
            \\shall specify an expression with the return of the correct type for
            \\the function."
            \\
            \\A bare `return;` specifies none. This is not the same rule as
            \\4.7.2.1's default: that clause covers a function which never
            \\returns explicitly at all and says the result is the identifier
            \\variable's value. An explicit return of nothing is a third thing,
            \\and 4.7.2.2 makes it an error rather than a spelling of the
            \\default.
            \\
            \\Write `return <expr>;`, or assign to the function name and fall off
            \\the end.
            ,
        },
        .E0228 => .{
            .title = "a generate region inside another generate region",
            .lrm = "6.6",
            .explain =
            \\LRM 6.6, verbatim: "Generate regions do not nest, and they may only
            \\occur directly within a module."
            \\
            \\Annex A.4.2 says it a second way, by placement: `generate_region`
            \\is a `module_item`, and `module_or_generate_item` — everything a
            \\region or a generate block may contain — does not list it. So an
            \\inner `generate` has no derivation, whether it sits in another
            \\region or in the block of a for- or if-generate.
            \\
            \\The keywords buy nothing inside: 6.6 makes the region "optional"
            \\with "no semantic difference in the module when a generate region is
            \\used", so drop the inner pair. Generate CONSTRUCTS do nest — "all
            \\other module items, including other generate constructs, are allowed
            \\in a generate block" — it is only the region that may not.
            ,
        },
        .E0229 => .{
            .title = "a parameter declaration inside a generate region or block",
            .lrm = "6.6",
            .explain =
            \\LRM 6.6, verbatim: "A generate block is a collection of one or more
            \\module items. A generate block may not contain port declarations,
            \\parameter declarations, specify blocks, or specparam declarations."
            \\
            \\Syntax 6-8 states it structurally: `module_or_generate_item`
            \\admits `local_parameter_declaration ;` and no
            \\`parameter_declaration`.
            \\
            \\The reason is elaboration order. A parameter is what a generate
            \\scheme is allowed to READ — 6.6's own framing is "the ability for
            \\parameter values to affect the structure of the model" — so a
            \\parameter created BY a generate block is a value the elaborator
            \\needs before it exists. 6.3's override would have nothing to attach
            \\to either.
            \\
            \\Write `localparam` instead. It is the form the grammar keeps,
            \\precisely because it carries no override.
            ,
        },
        .E0230 => .{
            .title = "a generate block name collides with another declaration",
            .lrm = "6.6.1",
            .explain =
            \\A named generate block's name is a DECLARATION, not a label.
            \\
            \\LRM 6.6.1, for a loop generate: "If the generate block is named, it
            \\is a declaration of an array of generate block instances ... It
            \\shall be an error if the name of a generate block instance array
            \\conflicts with any other declaration, including any other generate
            \\block instance array."
            \\
            \\LRM 6.6.2, for a conditional one: "its name declares a generate
            \\block instance and is the name for the scope it creates ... Named
            \\generate blocks may not have the same name as any other declaration
            \\in the same scope. Named generate blocks may not have the same name
            \\as blocks in any other generate construct in the same scope, even
            \\if not selected for instantiation."
            \\
            \\"Even if not selected" is why the scheme is never consulted: the
            \\name is declared by the TEXT of the construct. 6.8 states the same
            \\rule generally and repeats the point — "For generate blocks, this
            \\rule applies regardless of whether the generate block is
            \\instantiated".
            \\
            \\What IS permitted, and is not reported here: two blocks in
            \\different arms of ONE conditional generate construct may share a
            \\name, "since at most one is instantiated" (6.6.2), and that extends
            \\through direct nesting — an `else if` chain.
            \\
            \\Rename the block, or rename the declaration it shadows.
            ,
        },
        .E0231 => .{
            .title = "hierarchical index is not a constant expression",
            .lrm = "A.9.3",
            .explain =
            \\A.9.3: `hierarchical_identifier ::= { identifier [ [
            \\constant_expression ] ] . } identifier` — the bracketed index that
            \\selects one element of an instance array is a CONSTANT expression,
            \\and it sits on a segment followed by `.` (the final identifier
            \\takes none).
            \\
            \\VerA folds the index at parse time, because the whole dotted path
            \\is interned as ONE string (`u[0].g`) — the same spelling
            \\elaboration gives the flattened element — and a value that cannot
            \\be folded has no digits to spell. The parser folds literals and
            \\the +,-,*,/ arithmetic over them; a parameter read is not in that
            \\set, and nothing else the grammar admits here is constant at all.
            ,
        },
        .W0250 => .{
            .title = "switch primitive accepted, and it stamps nothing",
            .lrm = "A.4.1",
            .explain =
            \\`tran` and `rtran` are A.4.1's `pass_switchtype`, and the source is
            \\legal: A.1.4 makes `gate_instantiation` a module_or_generate_item,
            \\so the module around it compiles and its analog block runs.
            \\
            \\What the instance does NOT do is contribute to the device. LRM
            \\8.5.3.5 puts switch processing in the DISCRETE simulation cycle: a
            \\pass switch propagates logic values and strengths between its two
            \\terminals, and the LRM gives it no continuous behavior at all. So
            \\there is no equation to stamp, and writing one anyway — a zero-volt
            \\source across the terminals is the obvious guess — would freeze a
            \\convention of VerA's into a model as if the standard had asked for
            \\it.
            \\
            \\This warning exists because the other option is worse. Dropping the
            \\instance in silence gives you a device in which the two nets the
            \\switch was meant to tie are simply unconnected, and nothing in the
            \\output says so.
            \\
            \\  --deny=W0250    refuse the module instead, for a model whose
            \\                  answer depends on the switch conducting
            \\  --allow=W0250   silence it, for a switch that only matters to the
            \\                  digital half a host simulator runs
            \\
            \\The rest of A.4.1's gate types are still E0205, and deliberately:
            \\an `and` gate or a `pullup` COMPUTES a value, so accepting one and
            \\modelling nothing would be a wrong answer rather than an absent
            \\connection.
            ,
        },

        // ------------------------------------------------------------ class 3
        .E0301, .E0302 => retiredInfo(
            \\"vector ports are not supported" (E0301) and "vector nets are not
            \\supported" (E0302). Both retired: 3.6.3 vector nets and 6.5.2
            \\vector ports now elaborate. Each element becomes its own solver
            \\unknown, named `p[0]`, so the flat node list never learns about
            \\ranges and nothing downstream changed.
            \\
            \\What replaced them: E0350 for 6.5.2.2 (the port's two declarations
            \\give different ranges), E0351 and E0352 for the element reference
            \\itself. The numbers are not reused.
        ),
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
        .E0304, .E0305 => retiredInfo(
            \\"port branches are not supported" (E0304) and "branch arrays are
            \\not supported" (E0305). Both retired: 3.12.1 `branch (<p>) name;`
            \\resolves to the same 5.4.3 port-flow unknown `I(<p>)` reads, and
            \\A.2.3 `branch (p, n) pair[0:1];` expands into one branch per
            \\element registered under the scalarised name `pair[k]`.
            \\
            \\What replaced them: nothing for the declarations, which are legal.
            \\A port branch left of `<+` is E0407 (5.4.3 forbids the position,
            \\not the name); an out-of-range element is E0352 and the bare base
            \\name is E0351, both shared with vector nets.
        ),
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
            \\A part select `x[msb:lsb]` slices a vector. 3.6.3 vector nets do
            \\elaborate — one node per element — but only a single-element BIT
            \\select names one of them, so there is nothing a slice could
            \\evaluate to. Write the elements out, or index them from a 5.9.3
            \\analog `for`.
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
        .E0350 => .{
            .title = "the two declarations of a vector port give different ranges",
            .lrm = "6.5.2.2",
            .explain =
            \\LRM 6.5.2.2: "A port can be declared in both a port type
            \\declaration and a port direction declaration. If a port is
            \\declared as a vector, the range specification between the two
            \\declarations of a port shall be identical."
            \\
            \\The rule is EVALUATE-equal, not spell-equal — the clause prints
            \\
            \\    input [0:3] in;
            \\    electrical [0:4-1] in;   // valid
            \\
            \\as legal, because `4-1` folds to `3`. Both bounds are folded here
            \\before they are compared, so only a genuine difference in width
            \\or in direction (`[3:0]` against `[0:3]`) is reported.
            ,
        },
        .E0351 => .{
            .title = "not an element of a vector net",
            .lrm = "5.5.2",
            .explain =
            \\LRM 5.5.2: "the access functions can only be applied to scalars
            \\or individual elements of a vector. The scalar element of a
            \\vector is selected with an index, e.g., V(in[1]) accesses the
            \\voltage in[1]."
            \\
            \\Two shapes break that, and both land here:
            \\
            \\  - an index on a net that was declared without a range, where
            \\    there is no element to select;
            \\  - a bare vector name where one signal is required — a vector
            \\    net is a set of nodes, and 1.3.1 gives a potential to each
            \\    one, not to the set.
            \\
            \\Write the index, or declare the net with a range.
            ,
        },
        .E0352 => .{
            .title = "vector index is not a constant inside the declared range",
            .lrm = "3.6.3",
            .explain =
            \\A vector net is scalarised at elaboration — 3.6.3's `electrical
            \\[3:0] p` is four independent nets — so every index must be
            \\decidable then. 5.5.2 says so directly for the looping case: "The
            \\index must be a constant expression, though it may include genvar
            \\variables."
            \\
            \\So an index built from a run-time variable has no element to name,
            \\and an index outside the declared range names a net that was never
            \\declared. Use a literal, a parameter, or the genvar of an
            \\enclosing 5.9.3 analog `for`.
            ,
        },
        .E0353 => .{
            .title = "branch terminals are vectors of different sizes",
            .lrm = "3.12",
            .explain =
            \\LRM 3.12: "If one of the terminals of a branch is a vector net,
            \\then the other terminal shall either be a scalar net or a vector
            \\net of the same size."
            \\
            \\Two vectors of the same size pair one-to-one (Figure 3-1) and a
            \\vector against a scalar fans in (Figure 3-2). Two vectors of
            \\DIFFERENT sizes are neither: there is no pairing the declaration
            \\could mean, so the branch has no size of its own and no element
            \\can be indexed out of it.
            ,
        },

        .E0354 => .{
            .title = "a string value cannot be assigned to a numeric variable",
            .lrm = "3.3",
            .explain =
            \\LRM 3.4.1 states the conversion rule and its one exception: "No
            \\conversion shall be applied for strings; it shall be an error to
            \\assign a numeric value to a parameter declared as string or to
            \\assign a string value to a real parameter." E0345 is that sentence
            \\on a parameter; this is the same rule on a variable, where 3.3
            \\puts strings in their own type alongside integer and real.
            \\
            \\3.3's own worked example is where it bites hardest:
            \\
            \\    b = {5{"Hi"}};     // OK          (b is a string)
            \\    a = {i{"Hi"}};     // OK          (a is a string)
            \\    r = {i{"Hi"}};     // invalid     (r is integral)
            \\
            \\Table 3-3's Replication row says why the third line is the invalid
            \\one: "if multiplier is nonconstant or Str is of type string, the
            \\result is a string containing N concatenated copies". A string has
            \\no width, and an integral target is nothing but a width.
            \\
            \\Declare the target `string`, or compare rather than assign — 3.3's
            \\relational operators on strings yield an integer.
            ,
        },
        .E0355 => .{
            .title = "incompatible disciplines",
            .lrm = "3.11.1",
            .explain =
            \\LRM 3.11: "Certain operations can be done on nets only if the two
            \\(or more) nets are compatible. For example, if an access function
            \\has two nets as arguments, they must be compatible." 3.12 states
            \\the same requirement for the two terminals of a branch
            \\declaration, and 7.4.3 for a continuous-time port connection.
            \\
            \\3.11.1 decides it. Two disciplines are compatible when:
            \\
            \\  - they are the same discipline                (Self Rule);
            \\  - either is DOMAINLESS — declares no `domain` and binds no
            \\    nature                                      (Domainless Rule);
            \\  - otherwise: they agree on domain, and each half's natures are
            \\    compatible. A discipline that binds no nature for a half is
            \\    compatible with anything there    (Non-Existent Binding Rule),
            \\    which is what makes a natureless discipline universal.
            \\
            \\Two natures are compatible when they are the same nature, when one
            \\is derived from the other, when both derive from one base nature,
            \\or when they declare the same `units` string (Units Value Rule).
            \\
            \\3.11.1's own worked case is the one that bites: "electrical and
            \\rotational are incompatible disciplines because the natures for
            \\both potential and flow are not derived from the same base
            \\natures."
            \\
            \\Two nets of different DOMAINS are not joined by fixing a nature.
            \\7.4 says what to write instead: a `connect` statement, so the
            \\elaborator inserts a connect module between the two.
            ,
        },
        .E0356 => .{
            .title = "wrong number of array subscripts",
            .lrm = "3.2",
            .explain =
            \\LRM 3.2 declares an array with one `dimension` per subscript:
            \\
            \\    integer flag_array[0:8][0:3];   // 9 rows of 4
            \\
            \\so `flag_array[3]` names a whole ROW and not a cell. Verilog-AMS
            \\has no array-valued expression outside 3.4.8's assignment patterns
            \\and 5.7's whole-array assignment, so a partial subscript list has
            \\nowhere to be used and is reported here rather than read as the
            \\first element.
            ,
        },
        .E0357 => .{
            .title = "illegal attribute value",
            .lrm = "2.9",
            .explain =
            \\LRM 2.9, Syntax 2-4:
            \\
            \\    attr_spec ::= attr_name [ = constant_expression ]
            \\
            \\Both of the clause's rules about that value land here, because both
            \\say it is not a legal constant_expression.
            \\
            \\1. IT MUST BE CONSTANT. An attribute carries "properties about
            \\objects, statements and groups of statements in the HDL source that
            \\can be used by various tools" — a tool that is not a simulator,
            \\reading the source without solving it. A variable's value exists
            \\only during a solve, so there is no value for such a tool to read.
            \\A parameter IS a constant expression here (A.8.4 constant_primary),
            \\so `(* q = gain *)` is accepted; `(* q = z *)` with `real z` is not.
            \\
            \\2. IT MAY NOT CONTAIN AN ATTRIBUTE INSTANCE. "Nesting of attribute
            \\instances is disallowed. It shall be illegal to specify the value of
            \\an attribute with a constant expression that contains an attribute
            \\instance." A.8.3 gives operators their own attribute slot, so
            \\`(* outer = (1 + (* inner *) 2) *)` is refused by this rule and not
            \\by the grammar.
            ,
        },
        .E0358 => .{
            .title = "standard attribute value is outside its domain",
            .lrm = "2.9.2",
            .explain =
            \\LRM 2.9.2 standardizes four attribute names and fixes the value of
            \\each with a "must":
            \\
            \\    desc          must be assigned a string
            \\    units         must be assigned a string
            \\    op            "yes" or "no"
            \\    multiplicity  "multiply", "divide" or "none"
            \\
            \\These are not free-form tool hints: `multiplicity` picks the
            \\$mfactor scaling of an operating-point report, so a value outside
            \\the listed set has no reading at all.
            \\
            \\Any OTHER attribute name is a tool convention and is not checked —
            \\2.9 leaves its meaning to the tool that reads it.
            ,
        },
        .E0359 => .{
            .title = "nature attribute reference has no constant value",
            .lrm = "5.5.3",
            .explain =
            \\LRM 5.5.3, Syntax 5-4:
            \\
            \\    nature_attribute_reference ::=
            \\        net_identifier . potential_or_flow . nature_attribute_identifier
            \\
            \\and the sentence after it: "This syntax shall not be used for the
            \\access, ddt_nature, or idt_nature attributes of a nature, nor any
            \\other attribute whose value is not a constant expression."
            \\
            \\Those three attributes name an IDENTIFIER — `access` is the access
            \\function itself (`V`), not a number — so there is no value for the
            \\reference to stand for. The same goes for an attribute the nature
            \\never declared.
            \\
            \\`n.potential.abstol` is the form the clause's own twocap example
            \\uses, and it works.
            ,
        },
        .E0360 => .{
            .title = "signal-flow discipline on an `inout` port",
            .lrm = "1.3.4.1",
            .explain =
            \\LRM 1.3.4.1: "Nets of potential signal flow disciplines in modules
            \\may only be bound to `input` or `output` ports of the module, not
            \\to `inout` ports." 1.3.4.2 says the same of flow signal-flow
            \\disciplines.
            \\
            \\A signal-flow net carries ONE nature, so its port direction is the
            \\direction of that one quantity: `input` means the netlist supplies
            \\it, `output` means this module does. `inout` claims both at once,
            \\and there is no conservation law here to reconcile them — that is
            \\what 1.3.1's conserved potential/flow PAIR is for, and a
            \\single-nature discipline has no such pair.
            \\
            \\Declare the port `input` or `output`, or give the net a
            \\conservative discipline (both natures) if it really is a terminal.
            \\
            \\Contributing to an `input` signal-flow port is the sibling rule,
            \\E0425.
            ,
        },
        .E0361 => .{
            .title = "overridden parameter value is outside its range",
            .lrm = "3.4.2",
            .explain =
            \\LRM 3.4.2: "The parameter value shall be within the range from the
            \\smallest value specified to the largest value specified", and an
            \\`exclude` removes a value or an interval from what is left.
            \\
            \\This is the half of 3.4.2 that needs a VALUE. A declared default is
            \\judged only for whether its own bounds are well formed (E0347) —
            \\6.3 makes the interesting value the one an INSTANCE supplied, and a
            \\module compiled on its own has no instance. The check therefore runs
            \\on parameters whose value came from a `#(...)` override, which is
            \\where a model card meets a model's declared legal range.
            \\
            \\3.4.2 states the error at simulation time; VerA elaborates the
            \\instance at compile time, so it is reported here.
            ,
        },
        .E0362 => .{
            .title = "identifier is declared twice in one scope",
            .lrm = "6.8",
            .explain =
            \\LRM 6.8: "An identifier shall be used to declare only one item
            \\within a scope. This rule means it is illegal to declare two or more
            \\variables which have the same name, or to name a task the same as a
            \\variable within the same module, or to give an instance the same name
            \\as the name of the net connected to its output."
            \\
            \\SHADOWING IS NOT THIS. 6.8 lists what opens a scope — modules, named
            \\blocks, analog functions, generate blocks — and an inner scope may
            \\reuse an outer name freely. Only two declarations at the SAME level
            \\are this error, because the second one has no way to be reached.
            \\
            \\What VerA checks is the first clause of that sentence: two variable
            \\declarations of one name in one module or one block. Rename one of
            \\them, or delete it if it was a repeat of the same declaration.
            ,
        },
        .E0363 => .{
            .title = "parameter default is not a constant expression",
            .lrm = "3.4",
            .explain =
            \\A.2.4 gives a parameter assignment a constant_mintypmax_expression,
            \\and 3.4 explains why: "The default_value may not be changed at
            \\runtime" — a parameter is a value fixed before the solve, settable
            \\only per instance (6.3). An expression that reads simulation state
            \\— $abstime, $temperature, $vt, $random, an access function like
            \\V(a,b), an analog operator — has a different value at every point
            \\of the solve, so there is no single number a model card could
            \\carry for it and no moment the default could honestly be read.
            \\
            \\A default MAY reference other parameters (3.4/6.3.4: an update of
            \\the base parameter automatically updates the dependent one); it is
            \\the operating point it may not reference.
            \\
            \\Compute the value in the analog block instead, into a variable:
            \\
            \\    parameter real tj0 = 27;          // overridable constant
            \\    real tj;
            \\    analog tj = $temperature - `P_CELSIUS0;
            ,
        },

        .E0364 => .{
            .title = "mixed signedness around a shift is not implemented",
            .lrm = "4.2.11",
            .explain =
            \\The analog MIR does not preserve enough expression signedness to
            \\apply an unsigned comparison context to a signed shift operand.
            \\For example, (a >> n) > 32'h1 with integer a = -1 and n = 0
            \\requires unsigned comparison; comparing the signed i64 carrier
            \\would silently give the wrong result. VerA rejects this known
            \\mixed case until context typing is implemented. This is an
            \\implementation limitation, not an illegal Verilog-AMS expression.
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
        .E0428 => .{
            .title = "a generate scheme is not a constant expression",
            .lrm = "6.6",
            .explain =
            \\LRM 6.6, verbatim: "All expressions in generate schemes shall be
            \\constant expressions, deterministic at elaboration time."
            \\
            \\A generate scheme decides what the module CONTAINS, so it has to be
            \\answerable before there is a solution to read: an if-generate
            \\condition, a case-generate selector, and a loop generate's
            \\initialization, condition and step (E0417-E0419). A module variable
            \\or a probe is none of those — the LRM gives such a construct no
            \\semantics at all, which is why this is an error and not a fallback
            \\to a run-time branch.
            \\
            \\A `parameter` IS a constant expression here (A.8.4
            \\constant_primary, and 6.6's whole purpose is "the ability for
            \\parameter values to affect the structure of the model"), so a
            \\parameterized scheme is accepted.
            \\
            \\For a choice that depends on a solver value, write an ordinary
            \\`if` or `case` inside the analog block — but note 5.8.1's
            \\restrictions on analog operators under a non-constant condition.
            ,
        },
        .E0429 => .{
            .title = "incompatible array assignment",
            .lrm = "5.7",
            .explain =
            \\LRM 5.7: "Array assignments shall only be done with arrays that are
            \\compatible. An array, or a slice of such an array, shall be
            \\assignment compatible with any other such array or slice if all the
            \\following conditions are satisfied:
            \\
            \\  - The element types of source and target shall be equivalent.
            \\  - Every dimension of the source array shall have the same number
            \\    of elements as the target array."
            \\
            \\The count is of ELEMENTS, not of indices, which is the clause's own
            \\worked example:
            \\
            \\    int A[10:1];   int B[0:9];   int C[24:1];
            \\    A = B;         // ok. Compatible type and same size
            \\    A = C;         // type check error: different sizes
            \\
            \\Assign the elements one at a time if the shapes genuinely differ —
            \\there is no truncating or padding form of this statement.
            ,
        },
        .E0430 => .{
            .title = "analog function called outside the analog context",
            .lrm = "4.7.3",
            .explain =
            \\LRM 4.7.3: an analog user-defined function "shall only be called
            \\within the analog context, either from an analog block or from
            \\within another analog user-defined function". LRM 7.3.7 states the
            \\mixed-signal half: an analog function is not available to a
            \\discrete process.
            \\
            \\The restriction follows from what an analog function IS. LRM 4.7.1
            \\denies it access functions, filters and contribution statements
            \\precisely so that it is a pure value computation ON THE ANALOG
            \\SOLVER'S TIMELINE. An `initial` block runs once before the solve
            \\and an `always` block runs on the digital kernel's own events, so
            \\neither has a timepoint at which the function's value is defined.
            \\
            \\Move the call into the analog block, or into another analog
            \\function that the analog block calls.
            ,
        },
        .E0431 => .{
            .title = "digital value read from an analog initial block",
            .lrm = "5.2.1",
            .explain =
            \\LRM 5.2.1: "Additionally, digital values cannot be accessed from
            \\the analog initial block as they have not yet been assigned when
            \\the analog initial block is executed."
            \\
            \\The rule is about ORDER, not about types. LRM 7.2.2 gives a
            \\variable the domain of the context that assigns it, so a variable
            \\written by an `initial` or `always` block is digital-owned; the
            \\analog initial block runs before any digital process has run, so
            \\such a read has no value to return and would silently produce the
            \\type's zero.
            \\
            \\Read it from the ordinary analog block instead — LRM 7.3.1 Table
            \\7-1 defines that direction — or make the value a parameter or a
            \\localparam if it is genuinely constant.
            ,
        },
        .E0432 => .{
            .title = "variable assigned in both contexts",
            .lrm = "7.2.2",
            .explain =
            \\LRM 7.2.2: "A given variable can be assigned values only in one
            \\context or the other, but not in both. The domain of a variable is
            \\that of the context from which its value is assigned", stated again
            \\two paragraphs later as "It shall be an error to assign to a given
            \\variable in both contexts."
            \\
            \\The two contexts are the CONTINUOUS one (statements in an `analog`
            \\block) and the DISCRETE one (statements in an `initial` or `always`
            \\block). A variable written from both has no domain, so no rule in
            \\clause 7 can say when its value is defined or which kernel owns its
            \\storage.
            \\
            \\Pick one writer. Reading a variable from the other context stays
            \\legal, and is what LRM 7.3.1 Table 7-1 is the conversion table for.
            ,
        },
        .E0433 => .{
            .title = "statement in an initial block is not a constant assignment",
            .lrm = "7.2.2",
            .explain =
            \\A.6.2's `initial_construct ::= initial statement` is legal
            \\Verilog-AMS and VerA accepts it, in ONE shape: assignments of
            \\constant expressions to module variables. That shape has a meaning
            \\a compiler can honour on its own — LRM 7.2.2's "the domain of a
            \\variable is that of the context from which its value is assigned"
            \\gives the target to the discrete context, the block runs once
            \\before the analysis, so the variable simply holds that constant for
            \\the whole analysis and LRM 7.3.1 Table 7-1 says how the continuous
            \\context reads it.
            \\
            \\Everything else in a digital process needs a digital process: a
            \\delay or an event control needs a time queue to suspend on, a loop
            \\or a conditional needs values that change during the run to be worth
            \\writing, and a non-constant right-hand side needs whatever it reads
            \\to have been computed by something. VerA implements no discrete
            \\kernel (LRM 8.5 has no analog counterpart here), so it refuses those
            \\rather than picking one of their several possible readings.
            \\
            \\If the value is genuinely fixed, write it as a constant — or as a
            \\parameter (LRM 3.4), which is the language's own name for a value
            \\determined before the analysis starts.
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
            \\LRM 4.5.15 names the three conditional forms it covers — "inside
            \\conditional (if, case, or ?:) statements" — so an operator in an
            \\ARM of a `?:` is this rule too, and for the sharpest reason: 4.2.3
            \\makes `?:` short-circuiting, so the arm that is not selected is
            \\not evaluated at all.
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
        .E0518 => .{
            .title = "a zero-transition-time Z-filter cannot be contributed to a branch",
            .lrm = "4.5.12",
            .explain =
            \\LRM 4.5.12, verbatim: "If the transition time is specified as zero
            \\(0), then the output is abruptly discontinuous. A Z-filter with
            \\zero (0) transition time shall not be directly assigned to a
            \\branch."
            \\
            \\The zero transition time is not the error. The same clause makes
            \\the argument optional and "nonnegative", and reading the
            \\discontinuous output into a variable is legal:
            \\
            \\    real y;
            \\    analog begin
            \\      y = zi_zp(V(p, n), '{0.0, 0.0}, '{0.5, 0.0}, 1u, 0.0);
            \\      I(p, n) <+ y;
            \\    end
            \\
            \\What the clause bans is the discontinuity landing directly in the
            \\equation system, where a branch quantity that steps
            \\instantaneously has no derivative for Newton-Raphson to work with.
            ,
        },
        .E0519 => .{
            .title = "noise table is not a usable (frequency, power) table",
            .lrm = "4.6.4.3",
            .explain =
            \\LRM 4.6.4.3: "When the input is a vector it contains pairs of real
            \\numbers: the first number in each pair is the frequency in Hertz
            \\and the second is the power. The vector can either be specified as
            \\an array parameter or an array assignment pattern." And: "Each
            \\frequency value must be unique."
            \\
            \\So a table is an EVEN number of values, at least one pair, with
            \\distinct positive frequencies and non-negative powers. Ordering is
            \\NOT one of the rules — the same clause says "the simulator shall
            \\internally sort the pairs into ascending frequency if required",
            \\and VerA sorts at compile time, so a descending table compiles.
            \\
            \\4.6.4.4's noise_table_log interpolates log(power), so it wants
            \\every power strictly positive as well; log(0) is not a point on a
            \\log-log line.
            \\
            \\The table is exported as `noise_tables` — comptime data beside
            \\`noise_gens` — so every value in it has to be a compile-time
            \\constant. Two legal spellings are refused for that reason:
            \\
            \\  - the file form, `noise_table("noise.tbl")`. Reading the file at
            \\    compile time is the upgrade path; nothing does it today.
            \\  - an array PARAMETER, whose values a model card may override
            \\    after this compiler has gone. Folding through the declared
            \\    default would silently ignore the override, which is the same
            \\    trap E0515 describes; refusing is the honest answer until a
            \\    per-model table can be built.
            \\
            \\Write the pairs as an assignment pattern of literals:
            \\
            \\    I(p, n) <+ noise_table('{1.0, 1e-18, 1e6, 1e-24});
            ,
        },
        .E0520 => .{
            .title = "noise generator has no branch to sit on",
            .lrm = "4.6.4",
            .explain =
            \\LRM 1.3.1.1 makes ground the reference node: it is not an unknown
            \\of the system, so it has no row and no column. A contribution
            \\between ground and ground therefore names NO branch — there is
            \\nothing for a current to flow through and nothing for a voltage to
            \\be measured across.
            \\
            \\For the large-signal residual that is harmless, and VerA drops
            \\such a contribution silently: KCL at the reference node is the one
            \\equation the solver does not write. A NOISE generator is different
            \\because it is EXPORTED — `noise_gens` names the (row, col) a host
            \\stamps the generator into, and this one has neither. Dropping it
            \\would delete a declared noise source from the model without
            \\telling anyone, and inventing a row would put noise on a branch
            \\the model never wrote.
            \\
            \\Contribute the source to a real branch: give the generator a node
            \\that is an unknown of the system, even if the other end is ground.
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
        .E0608 => retiredInfo(
            \\"argument of tan is at a pole". Retired: 4.3.2 makes tan
            \\undefined at odd multiples of pi/2, but those are irrational
            \\points and every IEEE double is rational, so no representable
            \\argument — not even a compile-time constant — is ever provably
            \\AT a pole. The reject arm of the prover's three-way domain split
            \\(proof.zig, checkDomain) is empty by construction, and an
            \\argument range that merely SPANS a pole contains pole-free
            \\points, so rejecting it would violate the straddle policy: such
            \\a tan is accepted and the unit compiles `.strict`, where the
            \\near-pole value is a defined IEEE result (W0650 reports the
            \\cost). A code that cannot fire is a lie in the catalogue.
            \\
            \\Nothing replaced it; the condition does not exist to report.
            \\The number is not reused.
        ),
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
            .title = "not a declared named event",
            .lrm = "5.10.4",
            .explain =
            \\`@ <identifier>` (A.6.5) and `-> <identifier>` (5.10.4) both name a
            \\hierarchical_event_identifier, and the only declaration that
            \\introduces one is A.2.1.3
            \\
            \\    event tick;
            \\
            \\A variable, net or parameter of the same name is not an event: 2.8
            \\gives an event a name but no value, so there is nothing for `@` to
            \\test on one. A misspelling lands here too.
            ,
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
        .E0801 => retiredInfo(
            \\"unsupported system function". Retired: it was a CAPABILITY CLASS —
            \\one code for every ch9 function VerA declined to implement — and the
            \\list is now empty, so the diagnostic could not fire.
            \\
            \\Each name left it for the same reason. `$table_model` (LRM 9.21) got
            \\an interpolator (E0815 covers what it can compile). `$random`,
            \\`$arandom` and the `$dist_*`/`$rdist_*` family (LRM 9.13) turned out
            \\to be pure functions of an inout seed, so a draw cannot vary between
            \\Newton iterations at one point. `$simprobe` (LRM 9.16) is defined for
            \\the analog context by Table 9-13, and its unresolvable case has a
            \\value whenever the clause's fallback argument is supplied — E0817 is
            \\what is left of it, the case with no fallback.
            \\
            \\A function this compiler cannot host now gets a code that names the
            \\rule: E0806 for a digital-only name (LRM 9.2), E0808 for a spelling
            \\the language does not define. The number is not reused.
        ),
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
        .E0820 => .{
            .title = "$discontinuity degree must be nonnegative or -1",
            .lrm = "9.17.1",
            .explain = "Nonnegative degrees describe a discontinuity in a derivative of the constitutive equation. The special degree -1 requests another Newton iteration; smaller degrees have no defined meaning.",
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
        .E0811 => .{
            .title = "simulation parameter is not known",
            .lrm = "9.15",
            .explain =
            \\LRM 9.15 states $simparam in three sentences, one per branch:
            \\"If param_name is known, its value is returned. If param_name is
            \\not known, and the optional expression is not supplied, then an
            \\error is generated. If the optional expression is supplied, its
            \\value is returned if param_name is not known and no error is
            \\generated."
            \\
            \\This is the middle branch. The reason it is an error rather than
            \\a default is that the two are indistinguishable at the call site:
            \\a silent 0.0 reads exactly like a simulator that really does
            \\carry the parameter and really does report zero for it, and a
            \\model that divides by it or compares against it is then wrong
            \\with nothing to point at.
            \\
            \\Two fixes, and the LRM prints both:
            \\
            \\    gmin = $simparam("gmin");                  // must be known
            \\    sourcescale = $simparam("sourceScaleFactor", 1.0);
            \\
            \\The second form is legal for EVERY name, known or not — Table
            \\9-27 is prefaced "simulators shall accept the strings ... if they
            \\support the parameter" — so a model that wants to stay portable
            \\across tools writes the fallback.
            \\
            \\Only a literal name is checked. 9.15 also allows a string
            \\parameter or a string variable, whose value is not available
            \\here, and the fallback is the user's cover for that case.
            ,
        },
        .E0812 => .{
            .title = "invalid use of a node alias system function",
            .lrm = "9.20",
            .explain =
            \\LRM 9.20 states $analog_node_alias() and $analog_port_alias() as
            \\a validity list, and this code carries all of it. One number,
            \\because the six sentences are one rule with one reason: an alias
            \\makes the named node "refer to the same circuit matrix position"
            \\as the hierarchical reference, so it is a TOPOLOGY edit, and
            \\topology is fixed before a solve runs.
            \\
            \\    integer ok;
            \\    electrical local;
            \\    analog initial ok = $analog_node_alias(local, "$root.top.a");
            \\
            \\What the clause requires, in the order it is checked:
            \\
            \\  1. "It shall be an error for the ... system functions to be
            \\     used outside the analog initial block." An ordinary analog
            \\     block runs inside the Newton loop.
            \\  2. They "shall not be used inside conditional (if, case, or
            \\     ?:) statements unless the conditional expression ...
            \\     consists of terms which can not change during the course of
            \\     a simulation". A parameter guard is fine; $abstime is not.
            \\  3. The analog_net_reference "shall be either a scalar or vector
            \\     continuous node declared in the module containing the system
            \\     function call".
            \\  4. "It shall be an error for the analog_net_reference to be a
            \\     port or to be involved in port connections" — a port is
            \\     already bound by the instantiating netlist.
            \\  5. A vector "shall reference the full vector node, it shall be
            \\     an error for it to be a bit select or part select". The
            \\     scalar element goes on the OTHER side of the call.
            \\  6. The hierarchical_reference_string "shall be a constant
            \\     string value (string literal or string parameter)", and it
            \\     shall not name a node that is already the
            \\     analog_net_reference of another alias call.
            \\
            \\An unresolvable reference is NOT an error: the same clause makes
            \\that a return value, "one (1) if the hierarchical_reference_string
            \\points to a valid continuous node and zero (0) otherwise".
            ,
        },
        .E0813 => .{
            .title = "invalid argument to a string formatting or scanning task",
            .lrm = "9.5.3",
            .explain =
            \\LRM 9.5.3 puts the destination first — "the first argument to
            \\$swrite shall be a string variable to which the resulting string
            \\shall be written, instead of a variable specifying the file to
            \\which to write" — and 9.5.4.2 gives $sscanf its output
            \\arguments, one per non-suppressed conversion.
            \\
            \\    string text;  real x;  integer code;
            \\    $sformat(text, "v=%10.4e", V(p,n));
            \\    code = $sscanf(text, "v=%e", x);
            \\
            \\So this fires when a destination is not something that can be
            \\assigned to: a $swrite/$sformat first argument that is not a
            \\`string` variable, an output argument that is a literal or an
            \\expression, or one of the two writers used in expression
            \\position, where it has no destination at all.
            \\
            \\It also fires on a conversion code VerA does not scan. 9.5.4.2's
            \\own list is %d %o %h %x %b %c %f %e %g %s, with the assignment
            \\suppression * and a maximum field width; the strength, 4-state
            \\and timeformat codes (%v, %z, %t) describe values an analog
            \\device does not have. Refusing one is deliberate: a code that
            \\scanned as garbage would still be COUNTED in the return value,
            \\so the model would read a plausible number and never find out.
            ,
        },
        .E0814 => .{
            .title = "a $limit limiter argument is not `input`",
            .lrm = "9.17.3",
            .explain =
            \\LRM 9.17.3, on Syntax 9-12's third form
            \\`$limit(access_function_reference, analog_function_identifier,
            \\arg_list)`: "The arguments of the user-defined function shall all be
            \\declared input."
            \\
            \\The simulator supplies every one of them — "The first argument of
            \\the user-defined function shall be the value of the access function
            \\reference for the current iteration. The second argument shall be
            \\the appropriate internal state; generally, this is the value that
            \\was returned by the $limit() function on the previous iteration" —
            \\so they are the solver's iteration history handed inward. An
            \\`output` or `inout` formal would write back into that history
            \\mid-Newton-step, and 9.17.3 gives that no meaning.
            \\
            \\Return the limited value as the function's own return variable
            \\(4.7.1), which is what $limit() reads.
            ,
        },
        .E0816 => .{
            .title = "a $9.13 probabilistic distribution argument",
            .lrm = "9.13",
            .explain =
            \\Table 9-10's 17 names are supported in the analog context, and
            \\9.13.1/9.13.2 state four rules about their arguments. This fires on
            \\all four, because they are one clause and the message says which:
            \\
            \\THE SEED'S TYPE. "For each system function, the seed argument shall
            \\be an integer", and Syntax 9-9 spells the same rule as grammar:
            \\
            \\    seed ::= integer_variable_identifier
            \\           | integer_parameter_identifier
            \\           | [ sign ] decimal_number
            \\
            \\A real is none of the three, and no coercion is available: an
            \\integer VARIABLE seed is an inout argument, so the function needs a
            \\place to write an updated integer back to.
            \\
            \\THE DOMAIN. "For the $rdist_exponential, $rdist_poisson,
            \\$rdist_chi_square, $rdist_t, and $rdist_erlang functions, the
            \\arguments mean, degree_of_freedom, and k_stage shall be greater
            \\than zero (0). Otherwise an error shall be reported." Not a
            \\warning, not a clamp — and IEEE 1364 17.9.2 states the same domain
            \\for the integer $dist_ twins.
            \\
            \\THE UNIFORM'S ORDER. "In $rdist_uniform, the start and end
            \\arguments are real inputs which bound the values returned. The
            \\start value shall be smaller than the end value." An interval with
            \\start above end is empty, so there is no value to draw from it.
            \\
            \\THE type_string. Syntax 9-8/9-9's optional trailing string
            \\("instance" or "global") says which paramset override owns the
            \\stream, so it is meaningful only inside a 6.4 paramset.
            ,
        },
        .E0818 => .{
            .title = "driver access function outside a connect module",
            .lrm = "9.22",
            .explain =
            \\LRM 9.22, paragraph 3, both sentences: "The driver access functions
            \\described here only access drivers found in ordinary modules and not
            \\to those found in connect modules. Driver access functions can only
            \\be called from connect modules." 9.23 fences its four supplementary
            \\functions the same way and one step tighter — they are "supported in
            \\the digital context of connectmodules" — and Table 9-19 gives every
            \\member of both families "Supported in analog context of
            \\connectmodule: No".
            \\
            \\The two sentences are not in tension: the functions REPORT on
            \\drivers found in ordinary modules, but they may only be CALLED from
            \\a connect module. So the call site alone decides this, with no
            \\netlist, no elaboration and no driver: an ordinary `module` is not a
            \\`connectmodule`, and a call in one is illegal on sight.
            \\
            \\VerA has no `connectmodule` design element, so EVERY call site in a
            \\file VerA can compile is outside one and this diagnostic fires on
            \\every one of them. That is the conforming behaviour, not a
            \\limitation standing in for one: the alternative VerA used to ship
            \\was to answer the constant 0, and a plausible wrong number is the
            \\worst thing a compiler can hand back — 9.22.2/9.22.3/9.23.x take a
            \\driver_index "between 0 and N-1", which for N = 0 is an EMPTY range
            \\with no element 0 to have a value.
            \\
            \\When VerA grows connect modules the rule does not move: it narrows
            \\from "no module has drivers" to "this module is not a connect
            \\module", which is the same test on a wider language.
            ,
        },
        .E0819 => .{
            .title = "format conversion does not match the operand's type",
            .lrm = "9.4.3",
            .explain =
            \\9.4.3 pairs each consuming conversion with the expression argument
            \\that follows the format string. VerA's formatter renders three
            \\operand types — real, integer, string — and most conversions have a
            \\reading for each: %d/%b/%o/%h round a real, and a string operand
            \\under them takes 2.7's "unsigned constant number" view, one byte
            \\per character. Three pairings have no rendering VerA emits:
            \\
            \\    %s over a real, or an integral expression whose width the
            \\    current backend cannot preserve. Integer operands with a known
            \\    supported width render as 9.4.5's sequence of 8-bit ASCII codes.
            \\    Remaining numeric cases are implementation limitations.
            \\
            \\    %c over a string. Table 9-22's %c displays the low byte of an
            \\    INTEGER as a character; a string is not a code. Use %s for the
            \\    text, or index a code out of it.
            \\
            \\    %e/%f/%g/%r (and the %t/%u/%z/%v defaults) over a string.
            \\    There is no numeric field to format; %s prints the text, %d
            \\    prints 2.7's integer view.
            \\
            \\The diagnostic points to the operand before generated code is
            \\compiled. An unsupported pairing is not necessarily illegal
            \\Verilog-AMS; consult the conformance backlog for implementation gaps.
            ,
        },
        .E0817 => .{
            .title = "$simprobe resolves to nothing and has no fallback",
            .lrm = "9.16",
            .explain =
            \\    $simprobe ( inst_name , param_name [, expression] )
            \\
            \\LRM 9.16: "If either the inst_name or param_name cannot be resolved,
            \\and the optional expression is not supplied, then an error shall be
            \\generated. If the optional expression is supplied, its value will be
            \\returned in lieu of raising an error." This is the first sentence.
            \\
            \\VerA resolves the pair as one flat name — `inst_name.param_name` —
            \\against the elaborated design, which is the same identity every 6.7
            \\out-of-module reference uses: a flattened child's parameter is named
            \\by its hierarchical path. So the names that resolve are the ones a
            \\path could reach from this device.
            \\
            \\A name built at run time cannot resolve here. That is what the third
            \\argument is for, and supplying it is also what makes a probe of
            \\something OUTSIDE this device — a sibling instance the compiler never
            \\sees — a legal call with a defined value.
            ,
        },
        .E0815 => .{
            .title = "$table_model data source or control string",
            .lrm = "9.21",
            .explain =
            \\    $table_model ( table_inputs , table_data_source
            \\                   [, table_control_string] )
            \\
            \\One lookup expression per dimension, then either a file name or one
            \\array per dimension followed by an output array (9.21.1), then an
            \\optional control string (9.21.2).
            \\
            \\    real y[0:11], x[0:11], f_xy[0:11];
            \\    f = $table_model(0.25, 3.5, y, x, f_xy);
            \\    g = $table_model(0.25, V(a,b), "sample.dat", "1LL,1LL;1");
            \\
            \\This fires on a call whose shape does not add up — a file that
            \\cannot be read or does not hold a rectangular block of numbers,
            \\arrays of differing lengths (they are COLUMNS of one table), fewer
            \\columns than the inputs need, fewer samples than 9.21's "at least
            \\two points per dimension (2^N for N dimensions)", or a dependent
            \\selector naming a column the data source does not have.
            \\
            \\It also fires on an interpolation scheme VerA does not implement.
            \\Table 9-30's `1` (linear) is the one implemented; `D`, `2` and `3`
            \\(closest point, quadratic and cubic splines) and `I` (ignore this
            \\column) are refused rather than substituted, as is Table 9-31's `E`
            \\— "an extrapolation error is reported if the $table_model function
            \\is requested to evaluate a point beyond the interpolation region",
            \\and a compiled residual has no channel to report one on. Extrapolating
            \\anyway is precisely the wrong-number failure `E` exists to prevent.
            \\Table 9-31's `C` and `L` both work.
            ,
        },
        .W0850 => .{
            .title = "task dropped: a device does not print and has no file table",
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
            \\The LRM 9.5 file family is on the same list, for the same reason
            \\one step further out: a descriptor operation is a side effect, and
            \\`eval` has to stay a pure function of x or the solver's Newton
            \\iteration cannot converge. 9.5.9 agrees — "the file write
            \\operations shall not be performed unless the iteration is
            \\accepted" — so those calls are sequenced in the same per-point
            \\`display()` phase, and a device without one has no file table.
            \\
            \\That is not a stub: 9.5.1 reserves zero for "if a file cannot be
            \\opened", and a device with no table genuinely cannot open one. So
            \\`$fopen` answers 0, and every later call on that 0 has a defined
            \\answer of its own (9.5.4.1's "code is set to zero", 9.5.7's zero
            \\errno with an empty description, 9.5.8's zero).
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
        .W0852 => .{
            .title = "unregistered system function is left to a VPI host",
            .lrm = "12.32.3",
            .explain =
            \\This `$name` is not a Chapter 9 system function and not an Annex D
            \\or §4.5 operator. LRM 2.8.3 still makes it grammatical, and lists
            \\"defined using the VPI as described in Clause 11 and Clause 12" as
            \\one of the places a system function may come from — §12.32's
            \\vpi_register_analog_systf() is that place, and it hands the
            \\APPLICATION a compiletf routine so the application, not the
            \\compiler, decides what the name means.
            \\
            \\So the source is legal and VerA may not reject it. §12.32.3's own
            \\illustration is a contribution:
            \\
            \\    V(out) <+ $sampler(V(in), period);
            \\
            \\VerA has nothing to ask, so it does not answer: the name is
            \\exported in the device's `systf_calls` table and the call site
            \\reads its value — and its derivatives — from the application the
            \\HOST binds into `Instance.systf`. `contract.validateHost` refuses
            \\to build a host that binds none, so an unregistered systf cannot
            \\reach a simulation with no value behind it.
            \\
            \\WHY A HOST CALL AND NOT A SUBSTITUTE. Everywhere else a substitute
            \\value would contradict a number the LRM fixes, so the unit is
            \\refused outright (E0515, the filter families) rather than quietly
            \\made wrong. An unregistered systf has no such number: the language
            \\defines no value for it at all — §12.32.3's listing never even
            \\initializes sampler->value before the first update callback, and
            \\hands that field straight back through vpi_put_value(). So there
            \\is nothing to be wrong about, only somebody else to ask, and the
            \\artifact carries the question instead of inventing an answer.
            \\
            \\`vera --run` is itself a host and answers zero with zero partials,
            \\which is why a fixture over one of these asserts what does not
            \\depend on the value (§5.3.1: the block runs straight through).
            \\
            \\That is not a licence to be silent, which is what this warning is
            \\for: a misspelled `$abstmie` would otherwise become a binding the
            \\host is asked for. One warning per call site, naming the name.
            \\
            \\  --deny=W0852    refuse the unit instead (the old behaviour)
            \\  --allow=W0852   silence it for a model you know needs a host
            ,
        },

        // ------------------------------------------------------------ class 9
        .E0901 => .{
            .title = "hierarchical name names nothing in the elaborated design",
            .lrm = "6.7",
            .explain =
            \\A dotted name that resolves to no net, branch, parameter or
            \\constant.
            \\
            \\This is NOT "hierarchy is unsupported" any more — that was E0204,
            \\retired. §6.2.2 instantiation elaborates and `ir/elaborate.zig`
            \\flattens the tree, and because a flattened entity's name IS its
            \\hierarchical path (`Elaborate.sep`), resolving a §6.7 reference is
            \\the ordinary lookup under the joined name. So this fires when the
            \\path is simply wrong: a misspelled instance name, an instance that
            \\was never declared, or a name that exists in a sibling rather than
            \\the module named.
            \\
            \\It is deliberately not an implicit net either. §3.6.5 creates one
            \\for an undeclared SIMPLE name in this module; a path naming nothing
            \\names no net anywhere in the design, and inventing one would turn a
            \\typo into a floating node.
            \\
            \\Two neighbours draw the boundary: E0910 is a path that resolves to
            \\a child's VARIABLE, which §6.7.1 forbids outright, and E0904 is an
            \\instance whose MODULE does not exist.
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
        .E0903 => .{
            .title = "unknown discipline on a net with a mixed-port connection",
            .lrm = "F.2.1",
            .explain =
            \\Annex F.2.1 step 4.b (printed verbatim in F.2.2 4.b and 5.b)
            \\resolves an UNDECLARED net from the disciplines of its child
            \\segments whose domain matches the net's. One candidate resolves
            \\the net; more than one is resolved only by a matching connect
            \\statement — "if there is more than one discipline in the list and
            \\the contents of the list match the discipline list of a
            \\resolution connect statement, the net is of the resolved
            \\discipline given by the statement" (7.7.2's
            \\`connect a, b resolveto c;`). "Otherwise the discipline is
            \\unknown. This is legal provided the net has no mixed-port
            \\connections (i.e., it does not connect through a port to a
            \\segment of a different domain). Otherwise this is an error."
            \\
            \\This net is that error: its matching-domain candidates resolve to
            \\no single discipline, no `connect ... resolveto` statement lists
            \\exactly that candidate set, and one of its segments is of the
            \\OTHER domain — so the bridge the insertion phase (7.8) would have
            \\to place has no discipline to bridge to.
            \\
            \\A 7.7.1 INSERTION statement (`connect some_connectmodule;`) does
            \\not help: it names a bridging module and resolves nothing, which
            \\is the difference between the two connectrules_item forms.
            \\Either declare the net's discipline, or add a resolution
            \\statement whose list matches the candidates.
            ,
        },
        .E0904 => .{
            .title = "instance names no module",
            .lrm = "6.2.2",
            .explain =
            \\A module_instantiation's module_or_paramset_identifier has to name a
            \\module (or paramset) declared somewhere in the compilation unit.
            \\A.1.2 puts no order on the descriptions of a source_text, so the
            \\definition may follow the use — but it has to exist.
            \\
            \\VerA compiles one file at a time; a child in another file has to be
            \\`include`d, or the parent has to be compiled with it.
            ,
        },
        .E0905 => .{
            .title = "recursive module instantiation",
            .lrm = "6.2.2",
            .explain =
            \\A module instantiates itself, directly or around a cycle. Verilog-AMS
            \\elaboration builds a finite instance TREE, so a cycle has no
            \\elaboration: each level would create another level forever.
            \\
            \\This is not a depth limit being hit by a deep design — the cycle is
            \\reported by name, with the instance path that closes it.
            ,
        },
        .E0906 => .{
            .title = "port connections do not match the module's ports",
            .lrm = "6.2.2",
            .explain =
            \\Either the ordered connection list is longer than the module's port
            \\list, or a named connection names a port the module does not
            \\declare, or the two forms are mixed in one list.
            \\
            \\6.2.2 permits FEWER connections than ports: an omitted port and a
            \\blank one are both "not to be connected", and 9.19
            \\`$port_connected` returns 0 for them. What it does not permit is a
            \\connection with no port to attach to.
            ,
        },
        .E0907 => .{
            .title = "override names no parameter of the module",
            .lrm = "6.3",
            .explain =
            \\A `#(...)` parameter value assignment either names a parameter by
            \\name (`.gain(2.0)`) or supplies values "in the order of their
            \\declaration". A name that is not a parameter of the instantiated
            \\module overrides nothing, and an ordered list longer than the
            \\module's parameter list has values with nowhere to go.
            \\
            \\A `localparam` (3.4.5) is deliberately not overridable, so naming
            \\one here is this error too.
            ,
        },
        .E0908 => .{
            .title = "a parameter and its aliasparam are both overridden",
            .lrm = "3.4.7",
            .explain =
            \\3.4.7: "It shall be an error to specify a value for both the
            \\original parameter and its alias in the same module instantiation
            \\or paramset."
            \\
            \\An aliasparam is a second NAME for one storage location, not a
            \\second parameter, so two overrides are two values for one thing and
            \\the LRM does not pick a winner. Delete one.
            ,
        },
        .E0909 => .{
            .title = "instance array range is not an elaboration-time constant",
            .lrm = "6.2.2",
            .explain =
            \\`name_of_module_instance ::= module_instance_identifier [ range ]`
            \\creates one instance per element, so both bounds have to be known
            \\when the instance tree is built.
            \\
            \\VerA's elaboration folds integer literals and the arithmetic over
            \\them. A bound that reads a parameter is not yet supported: the
            \\parameter table is built by lowering, which runs after this pass.
            ,
        },
        .E0910 => .{
            .title = "analog variable accessed hierarchically",
            .lrm = "6.7.1",
            .explain =
            \\LRM 6.7.1, fifth bullet: "It shall be an error to access analog
            \\variables hierarchically."
            \\
            \\The neighbouring bullets in the same list expressly PERMIT it for
            \\branch potentials and flows, for parameters and for analog user
            \\defined functions, so the prohibition is about variables
            \\specifically: a variable is per-evaluation state of one module's
            \\analog block, and reading it from outside makes the answer depend on
            \\which block ran first — which nothing in Clause 5 orders.
            \\
            \\A parameter or a branch probe of the same instance is legal. If the
            \\value really has to cross the boundary, it is an output of the
            \\module, not a variable of it.
            ,
        },
        .E0911 => .{
            .title = "no paramset admits this instance's parameter values",
            .lrm = "6.4.2",
            .explain =
            \\LRM 6.4.2 lets several paramsets share one name — "multiple
            \\paramsets can be declared using the same paramset_identifier" — and
            \\has the elaborator "choose an appropriate paramset from the set that
            \\shares a given name for every instance that references that name".
            \\That is BINNING: one paramset per geometry range, and the instance's
            \\dimensions pick the bin.
            \\
            \\Every candidate here was ruled out by the clause's selection rules:
            \\an override must name an overridable parameter the paramset
            \\declares, every parameter's value — overridden or defaulted — must
            \\lie within that paramset's own declared `from`/`exclude` ranges,
            \\and the module the paramset specializes must declare a port for
            \\each port the instance connects. So either an override or a
            \\connection is misspelled for this set, or the instance falls in a
            \\gap between the bins.
            \\
            \\The OPPOSITE failure — several paramsets still applicable after
            \\6.4.2's tie-breaking rules — is E0914.
            ,
        },
        .E0912 => .{
            .title = "flow contribution scaled by $mfactor twice",
            .lrm = "6.3.6",
            .explain =
            \\LRM 6.3.6, first bullet: "All contributions to a branch flow
            \\quantity in the analog block shall be multiplied by $mfactor", and
            \\the clause adds that "Verilog-AMS does not provide a method to
            \\disable" it. The scaling is the simulator's, and it always happens.
            \\
            \\So an explicit `* $mfactor` (or `/ $mfactor`) in the contributed
            \\value cannot be an opt-out — it is the clause's own `badres`
            \\example, of which 6.3.6 says: "the contributed current would be
            \\multiplied by $mfactor twice, once by the explicit multiplication
            \\and once by the automatic scaling rule. The simulator will generate
            \\an error for this module."
            \\
            \\READING $mfactor is always legal. The clause's companion example
            \\`parares` uses it in a guard — `if (r/$mfactor < 1e-3)` — and says
            \\no error is generated there. Only a multiplicative factor in the
            \\value being contributed is this error, and only for a FLOW: a
            \\potential contribution is not scaled automatically, so there is
            \\nothing for a factor to double.
            ,
        },
        .E0913 => .{
            .title = "a connect module cannot be instantiated by name",
            .lrm = "7.6",
            .explain =
            \\A `connectmodule` is accepted — LRM A.1.2 makes it the third
            \\alternative of `module_keyword`, so it declares a module — but it is
            \\not a module you instantiate. LRM 7.7: "Any number of connect
            \\modules can be defined. The designer can choose and specialize those
            \\in the design via the connect specification statements", and 7.8 has
            \\the tool insert the chosen one AUTOMATICALLY at each mixed port.
            \\7.6's own note that "the disciplines of mixed nets are determined
            \\prior to the connect module insertion phase" puts that insertion
            \\after discipline resolution, which is nothing a source can spell.
            \\
            \\A connect module is therefore never elaborated on its own account
            \\either: a source_text whose only design element is one has no device
            \\to compile (E1001).
            \\
            \\Refusing this rather than inlining it is deliberate. A connect module
            \\bridges a discrete side, and its digital half lives in `initial` /
            \\`always` blocks that VerA records and does not execute. Inlining one
            \\would stamp its continuous half into the device with the digital half
            \\silently absent — a plausible-looking wrong device, which is worse
            \\than a refusal that names the reason.
            ,
        },
        .E0914 => .{
            .title = "more than one paramset is still applicable",
            .lrm = "6.4.2",
            .explain =
            \\LRM 6.4.2 chooses among same-named paramsets in two phases. The
            \\selection rules ("When choosing an appropriate paramset, the
            \\following rules shall be enforced") cut the overload set down to
            \\the applicable candidates; then "The rules above may not be
            \\sufficient for the simulator to pick a unique paramset, in which
            \\case the following rules shall be applied in order until a unique
            \\paramset has been selected":
            \\
            \\  1. "The paramset with the fewest number of un-overridden
            \\     parameters shall be selected."
            \\  2. "The paramset with the greatest number of local parameters
            \\     with specified ranges shall be selected."
            \\  3. "The paramset with the fewest ports not connected in the
            \\     instance line shall be selected."
            \\
            \\And then: "It shall be an error if there are still more than one
            \\applicable paramset for an instance after application of these
            \\rules." This is that error — the candidates named in the message
            \\tie on all three counts, so the language gives the elaborator no
            \\way to prefer one. Narrow a `from` range, or override one more
            \\parameter, until the instance's values land in exactly one bin.
            \\
            \\ZERO applicable paramsets is the other failure, E0911.
            ,
        },
        .E0915 => .{
            .title = "connect insertion names no connect module",
            .lrm = "7.7.1",
            .explain =
            \\A connect module auto-insertion statement,
            \\`connect connectmodule_identifier ... ;` (A.1.8
            \\connect_insertion), "declares which connect modules are
            \\automatically inserted when mixed nets of the appropriate types
            \\are encountered" — so the identifier has to name a module
            \\declared with the `connectmodule` keyword (7.6, A.1.2's third
            \\module_keyword alternative).
            \\
            \\Either nothing in the compilation declares the name, or the name
            \\is an ordinary module — the message says which. An ordinary
            \\module cannot be an insertion target for the reason E0913 gives
            \\for the reverse mistake: a connect module's discrete half lives
            \\in behavioral code the insertion phase owns, and 7.6's port
            \\disciplines are what "define the default type of disciplines
            \\which shall be bridged".
            ,
        },
        .E0916 => .{
            .title = "connect resolution names no discipline",
            .lrm = "7.7.2",
            .explain =
            \\In `connect d1, d2 resolveto d3;` (A.1.8 connect_resolution)
            \\every identifier is a discipline_identifier: "the discipline
            \\identifiers before the resolveto keyword are the list of
            \\compatible disciplines and the discipline identifier after is
            \\the discipline to be used". A name no discipline declaration
            \\introduces can neither be matched against a net's candidate list
            \\nor assigned to the net, so the whole statement is dead — and a
            \\misspelled discipline here would otherwise silently turn a
            \\resolving design into an E0903 one.
            \\
            \\`exclude` after `resolveto` is not a discipline and is not this
            \\error: it is the keyword that deems the listed disciplines
            \\incompatible (E0917 when they then meet).
            ,
        },
        .E0917 => .{
            .title = "disciplines excluded by a connect resolution share a net",
            .lrm = "7.7.2",
            .explain =
            \\LRM 7.7.2: "If the keyword exclude follows resolveto rather than
            \\a discipline identifier, then the otherwise compatible
            \\disciplines are deemed to be incompatible and an error is
            \\indicated if they are found on the same net." The clause's own
            \\example is two supply families —
            \\
            \\    connect logic18 logic32 resolveto exclude ;
            \\    connect electrical18 electrical32 resolveto exclude ;
            \\
            \\— "these connect statements prevent ports associated with one
            \\supply voltage to be connected to nets associated with the
            \\other."
            \\
            \\The candidate disciplines of this undeclared net (annex F.2.1
            \\step 4.b's list) match an exclude rule's discipline list
            \\under 7.7.2.1, so the connection the rule exists to forbid is present.
            \\Separate the nets, or delete the exclude rule.
            ,
        },

        // ----------------------------------------------------------- class 10
        .W0950 => .{
            .title = "multiple discipline resolution rules match",
            .lrm = "7.7.2.1",
            .explain = "The first matching rule is used. Exact matches take precedence over subset matches. Remove the ambiguity to silence this warning.",
        },
        .E1001 => .{
            .title = "source contains no module declaration",
            .lrm = "6.2",
            .explain =
            \\A compilation unit must declare at least one `module`. If the
            \\file holds only `discipline`, `nature` or `` `define `` items, it
            \\is a header — include it from a module instead of compiling it.
            \\
            \\If the file DOES contain a design element, it is one that is not a
            \\device. `primitive` and `library` have no parser at all, and the
            \\earlier diagnostics name which one. A `connectmodule` parses and is
            \\accepted (LRM 7.6, A.1.2's third `module_keyword`) but is still not
            \\a device: LRM 7.6 makes it the bridge the connect module INSERTION
            \\PHASE places on a mixed net, so it is instantiated by the tool and
            \\never elaborated on its own. A `connectrules` block (LRM 7.7)
            \\parses too, and is configuration for that same phase — a source of
            \\connect modules and connect rules alone still has no device. Put
            \\the module that uses them in the same compilation.
            \\
            \\A `paramset` is NOT one of them any more (LRM 6.4), but it is not a
            \\module either: it is a bundle of parameter values FOR a module, so a
            \\file of paramsets alone still has no device to compile. Compile the
            \\file that declares the module and instantiate the paramset from it.
            ,
        },
        .E1002 => retiredInfo(
            \\"generated identifier is too long". Retired: the condition is
            \\real — code generation builds a structural key per unit from the
            \\module name, the role and the target, and a key can overflow the
            \\fixed name buffer (never truncated: truncation would break the
            \\injectivity two distinct units rely on) — but no diagnostic with
            \\this code is ever built. The refusal is codegen's
            \\error.NameTooLong, which the CLI prints as "codegen failed:
            \\NameTooLong" with the input path; shortening the module or node
            \\names involved is still the fix. A catalogue entry for a code
            \\that never renders only misleads `--explain`.
            \\
            \\If codegen ever reports the overflow through the bag, with a
            \\source location, that report takes a NEW number. This one is not
            \\reused.
        ),
        .E1003 => .{
            .title = "more solver unknowns than the device contract can hold",
            .lrm = "",
            .explain =
            \\An engine limit, not a language rule. The emitted device declares
            \\its solver unknowns as `pub const U = enum(u8)`, and
            \\`tools/contract.zig`'s `isDenseEnum` requires exactly that tag
            \\type, so a device carries at most 256 of them — ports (LRM 6.5)
            \\first, then LRM 3.6.3 internal nets, then LRM 5.4.2 branch-flow
            \\unknowns.
            \\
            \\The refusal is here rather than in the host's build because the
            \\alternative was silence: the 257th member is `enum tag value '256'
            \\too large for type 'u8'`, an error against a line of GENERATED Zig
            \\with nothing pointing back at the model that produced it.
            \\
            \\The bound is on the device VerA emits, not on the circuit a host
            \\may solve — instantiate this module several times, or split it, and
            \\each instance stamps its own rows into the host's matrix.
            \\
            \\Note the count is not the net count: LRM 6.5.2 expands a vector port
            \\to one unknown per element, and every LRM 5.6 potential contribution
            \\adds a branch-flow unknown for its own current.
            ,
        },
        .E1100 => .{
            .title = "digital source execution failed",
            .lrm = "8.5",
            .explain = "The digital executor supports a documented subset of source processes. Unsupported forms are diagnosed before simulation; timing and capacity failures stop execution explicitly. This does not make legal unsupported Verilog-AMS forms illegal.",
        },
        .E1004 => .{
            .title = "unsupported dependent parameter expression",
            .lrm = "6.3.4",
            .explain =
            \\A dependent parameter must follow the final values of the parameters
            \\it references. VerA cannot yet render this expression for the host's
            \\derive callback, so retaining its declared-default value would be wrong.
            \\
            \\Pure two-way conditional expressions and short-circuit logical
            \\operators are supported. Arbitrary constant-function control flow,
            \\loop-carried or multiway values, unsupported operators and expressions
            \\beyond the renderer's recursion limit remain implementation gaps.
            ,
        },
        .W1050 => .{
            .title = "parameter default has no compile-time value",
            .lrm = "3.4.1",
            .explain =
            \\LRM 3.4.1 makes a parameter's default a `constant_expression`. This
            \\one is not: it reads a quantity only the simulator has, such as
            \\9.10's `$temperature` or 9.18's `$simparam`. There is nothing to
            \\fold, so the generated `Model` field initializer is 0.
            \\
            \\That is not always wrong — the host writes the model card and can
            \\put the real value in the field before the first solve. It IS
            \\wrong if you expected `Model{}` alone to be usable, because a
            \\temperature of 0 K or a gmin of 0 will not converge.
            \\
            \\A default that is an arithmetic expression over OTHER parameters
            \\does not reach here: 6.3.4 makes it a `derive()` line, and calling
            \\`derive` after writing the card gives it its value.
            \\
            \\Fix it by giving the parameter a constant default and reading the
            \\simulator quantity in the analog block instead, where 9.10 and
            \\9.18 say it is evaluated. Or take the field as the host's to
            \\write, and `--allow=W1050`.
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

// A "codes are unique" test used to sit here: 235 x 235 unrolled comparisons of
// every field value and name against every other, costing 38 MB of test binary
// and 1.2 s of build to assert two things the language already guarantees —
// duplicate enum field NAMES are a compile error, and auto-numbered VALUES are
// unique by construction. It could never fail. What is worth asserting is
// DENSITY, since that is what `info`'s indexing rests on and it is not
// guaranteed by anything; `table` does that with one comptime loop.
