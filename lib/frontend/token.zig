//! Class 1 — Lexical tokens. LRM ch2 (§2.5 operators, §2.6 numbers, §2.7
//! strings, §2.8 identifiers/keywords/system-names), annex B (keywords).
//!
//! DOD: a token stored is only `{tag: Tag, start: u32}` (5 bytes). The end
//! offset is RECOMPUTED on demand by re-lexing from `start` — never stored.
//! Token streams live in a MultiArrayList (SoA), owned by the lexer's arena.
//!
//! Layout invariant: `Tag` is ordered `invalid, eof, <literals>, <symbols>,
//! <keywords>` and the keyword block is CONTIGUOUS AND LAST. `isKeyword` is a
//! single `>=` compare because of that. Do not interleave.
//!
//! Naming invariant: every keyword tag is `kw_` ++ its exact source spelling.
//! `keyword_map` is derived from the enum at comptime, so a tag and its lexeme
//! can never drift apart — add the tag and the keyword is live.

const std = @import("std");

/// Every lexical token kind. LRM §2.5 (operators), §2.8.2/annex B (keywords).
///
/// Scope: the Verilog-A analog subset (annex C). Annex B reserves ~215
/// keywords; ~135 of them are in scope and get a tag here. The remaining
/// reserved-but-out-of-scope keywords (digital primitives, specify blocks,
/// config files, and the annex C.16 exclusion list) all lex to the single
/// `kw_reserved` tag: they are still reserved words (never identifiers, per
/// annex B), but the parser rejects them with one shared diagnostic.
pub const Tag = enum(u8) {
    invalid,
    eof,

    // ---- literals & identifiers — §2.6, §2.7, §2.8 --------------------------
    identifier, // §2.8
    escaped_identifier, // §2.8.1  (\literally.anything<ws>)
    system_identifier, // §2.8.3  ($name)
    int_literal, // §2.6.1  (incl. sized/based: 4'b1101, 'h1f)
    real_literal, // §2.6.2  (incl. exponent and SI scale suffix)
    string_literal, // §2.7

    // ---- operators — §2.5, table 4-1 ---------------------------------------
    // arithmetic §4.2.4
    plus,
    minus,
    star,
    slash,
    percent,
    star_star, // '**'  power §4.2.4
    // contribution §5.6 / assignment §5.5
    contribute, // '<+'
    arrow, // '->'  §5.10.4 event_trigger (A.6.5)
    assign_eq, // '='
    // relational §4.2.5
    lt,
    gt,
    lt_eq,
    gt_eq,
    // equality §4.2.7 / case equality §4.2.6 (lexed, rejected in Verilog-A per C.5)
    eq_eq,
    bang_eq,
    eq_eq_eq, // '==='
    bang_eq_eq, // '!=='
    // logical §4.2.8
    bang,
    amp_amp,
    pipe_pipe,
    // bitwise §4.2.9 / reduction §4.2.10 (same lexemes; distinguished by parse position)
    tilde,
    amp,
    pipe,
    caret,
    tilde_caret, // '~^'  xnor
    caret_tilde, // '^~'  xnor
    tilde_amp, // '~&'  reduction nand
    tilde_pipe, // '~|'  reduction nor
    // shifts §4.2.11
    lt_lt,
    gt_gt,
    lt_lt_lt, // '<<<' arithmetic shift (not legal in an analog block)
    gt_gt_gt, // '>>>'
    // conditional §4.2.12
    question,
    colon,

    // ---- punctuation -------------------------------------------------------
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace, // §4.2.13 concatenation / §5.x block delimiters are begin/end
    rbrace,
    semicolon,
    comma,
    dot, // hierarchical names §6.x, named port/param association
    at, // event control §5.10
    hash, // parameter override / delay §6.x
    apostrophe_lbrace, // "'{"  assignment pattern §4.2.14
    attr_open, // '(*'  attribute instance §2.9
    attr_close, // '*)'  §2.9

    // ---- the two directives the preprocessor hands to the parser — §10.6 ----
    // Every other compiler directive dies in the preprocessor. These two do
    // not: they select the reserved-keyword set for the design elements that
    // follow, and §10.6 requires them to sit outside a design element — a fact
    // only the parser can check. See `KeywordSet`.
    dir_begin_keywords, // '`begin_keywords'
    dir_end_keywords, // '`end_keywords'

    // ---- keywords — §2.8.2 / annex B ---------------------------------------
    // FIRST KEYWORD. Everything from here to the end of the enum is a keyword;
    // `isKeyword` depends on it. Tag name = "kw_" ++ source spelling, always.

    // module & source-text structure §6.2, §6.4, annex A.1
    kw_module,
    kw_macromodule,
    // A.1.2 `module_keyword ::= module | macromodule | connectmodule`. §7.6
    // gives a connect module the module_declaration production and nothing
    // else, so its terminator is `endmodule` like the other two spellings —
    // annex B reserves `endconnectrules` and there is no `endconnectmodule`.
    kw_connectmodule,
    kw_endmodule,
    kw_paramset,
    kw_endparamset,
    kw_function,
    kw_endfunction,
    kw_analog, // §5.2
    kw_initial, // 'analog initial' §5.2, and A.6.2 initial_construct
    // A.6.2 `always_construct ::= always statement`.
    kw_always,
    // A.6.1 `continuous_assign ::= assign [ drive_strength ] [ delay3 ]
    // list_of_net_assignments ;` — the structural driver of a net (§6.1). It
    // gets a tag instead of staying `.kw_reserved` for the same reason `reg`
    // and `initial` did: the digital executor runs it. Everywhere else it is
    // still refused, by `parseModuleItem`'s E0205 outside a digital run and by
    // A.6.4 offering no analog statement production for the procedural form.
    kw_assign,
    kw_begin,
    kw_end,
    kw_generate, // §6.9
    kw_endgenerate,
    kw_defparam, // §6.3.1 parameter_override (A.1.4)

    // connect specifications §7.7, annex A.1.8 — the `connectrules` design
    // element (an A.1.2 description alternative) and the keywords of its two
    // item forms. All six are Verilog-AMS-only words — none is on
    // an IEEE 1364 list — so `isReserved` defaults them to `.vams_2_3`,
    // which is exactly what the same spellings answered from the reserved
    // list; §10.6 membership is keyed by spelling and does not move.
    // `exclude` (A.1.8 discipline_identifier_or_exclude) already has a tag:
    // §3.4.2 value ranges spend the same keyword, see `kw_exclude` below.
    kw_connectrules,
    kw_endconnectrules,
    kw_connect,
    kw_resolveto,
    kw_merged, // §7.7.4 connect_mode
    kw_split,

    // declarations §3.x
    kw_parameter, // §3.4
    kw_localparam, // §3.4.4
    kw_aliasparam, // §3.4.5
    kw_integer, // §3.3
    kw_real,
    kw_string, // §3.3.3
    kw_realtime,
    kw_time,
    kw_reg,
    kw_event, // §3.3 named event (declared; analog events are @-driven)
    kw_genvar, // §3.11
    kw_branch, // §3.10 branch declaration

    // ports & net types §3.5, §6.5, annex A.2.1.3
    kw_input,
    kw_output,
    kw_inout,
    kw_wire,
    kw_tri,
    kw_tri0,
    kw_tri1,
    kw_triand,
    kw_trior,
    kw_trireg,
    kw_wand,
    kw_wor,
    kw_uwire,
    kw_supply0,
    kw_supply1,
    kw_signed,
    kw_unsigned,
    kw_scalared,
    kw_vectored,

    // A.4.1 `pass_switchtype ::= tran | rtran`, the unconditional bidirectional
    // switch. Both stay reserved — they are on the
    // 1364-1995 list, which `keyword_intro` keys by spelling.
    //
    // The rest of A.4.1's gate types have no tag: they are still `.kw_reserved`
    // and still E0205. What separates them is not effort but §6.2.2's meaning —
    // an `and` gate computes a logic value, so accepting one and modelling
    // nothing would be a wrong answer, while `tran` and `rtran` add no equation
    // of their own (see `parsePassSwitch`).
    kw_tran,
    kw_rtran,

    // disciplines & natures §3.6, §3.9, annex D
    kw_discipline,
    kw_enddiscipline,
    kw_nature,
    kw_endnature,
    kw_domain, // §3.6.2.2
    kw_continuous, // §3.6.2.2
    kw_discrete, // §3.6.2.2 — an error in Verilog-A (annex C.4), still lexed
    kw_potential, // §3.6.2.1
    kw_flow,
    kw_abstol, // §3.9.1
    kw_access,
    kw_units,
    kw_ddt_nature,
    kw_idt_nature,
    kw_ground, // §3.10.2

    // parameter value ranges §3.4.2
    kw_from,
    kw_exclude,
    kw_inf,

    // control flow §5.7, §5.8
    kw_if,
    kw_else,
    kw_case,
    kw_casex, // not supported in Verilog-A (annex C.7) — lexed, then rejected
    kw_casez, // ditto
    kw_endcase,
    kw_default,
    kw_for,
    kw_while,
    kw_repeat,
    kw_forever,
    kw_return, // §5.9 analog function return
    kw_break,
    kw_continue,
    kw_disable,

    // event expressions §5.10
    kw_or, // '@(a or b)' — event or; also the digital gate type
    kw_initial_step,
    kw_final_step,
    kw_cross, // §5.10.3
    kw_above, // §5.10.4
    kw_timer, // §5.10.5
    kw_absdelta, // §5.10.6
    // A.6.5 `event_expression ::= … | driver_update expression` — a DIGITAL
    // event, so it is not in `isEventFunction` and never reachable from an
    // analog block; §9.22.4 defines it, and §9.22 paragraph 3 confines the
    // whole family to a connect module.
    kw_driver_update,
    // §5.10.1 digital edges. Like `driver_update` above, they are legal only
    // inside an `event_expression`, so they are not `isEventFunction` members.
    kw_posedge,
    kw_negedge,

    // analog operators & filters §4.5
    kw_ddt,
    kw_ddx, // §4.5.9
    kw_idt,
    kw_idtmod,
    kw_absdelay, // §4.5.2
    kw_transition, // §4.5.3
    kw_slew, // §4.5.4
    kw_last_crossing, // §4.5.5
    kw_laplace_zd, // §4.5.6
    kw_laplace_zp,
    kw_laplace_nd,
    kw_laplace_np,
    kw_zi_zd, // §4.5.7
    kw_zi_zp,
    kw_zi_nd,
    kw_zi_np,
    // small-signal / noise sources §4.6
    kw_analysis,
    kw_ac_stim,
    kw_white_noise,
    kw_flicker_noise,
    kw_noise_table,
    kw_noise_table_log,

    // math functions §4.3.2 (with domain tables) / §4.3.3 transcendental
    kw_abs,
    kw_max,
    kw_min,
    kw_pow,
    kw_sqrt,
    kw_exp,
    kw_limexp, // §4.5.13 — bounded-derivative exp (a FILTER, A.8.2); never synthesized by us
    kw_ln,
    kw_log,
    kw_expm1,
    kw_ln1p,
    kw_hypot,
    kw_floor,
    kw_ceil,
    kw_sin,
    kw_cos,
    kw_tan,
    kw_asin,
    kw_acos,
    kw_atan,
    kw_atan2,
    kw_sinh,
    kw_cosh,
    kw_tanh,
    kw_asinh,
    kw_acosh,
    kw_atanh,

    /// Any annex B reserved keyword that is out of the analog subset's scope
    /// (digital primitives, specify/table, config files, and the annex C.16
    /// exclusions). Reserved — never an identifier — but not parseable. The
    /// spelling is not recoverable from the tag; slice the source at `start`.
    kw_reserved,

    /// First keyword tag. Keeps `isKeyword` a single compare (see file header).
    pub const first_keyword: Tag = .kw_module;

    /// Source spelling, for diagnostics. `null` when the text is not implied by
    /// the tag (identifiers, literals, `kw_reserved`) — slice the source then.
    pub fn lexeme(tag: Tag) ?[]const u8 {
        return switch (tag) {
            .invalid, .eof, .kw_reserved => null,
            .identifier,
            .escaped_identifier,
            .system_identifier,
            .int_literal,
            .real_literal,
            .string_literal,
            => null,

            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .percent => "%",
            .star_star => "**",
            .contribute => "<+",
            .arrow => "->",
            .assign_eq => "=",
            .lt => "<",
            .gt => ">",
            .lt_eq => "<=",
            .gt_eq => ">=",
            .eq_eq => "==",
            .bang_eq => "!=",
            .eq_eq_eq => "===",
            .bang_eq_eq => "!==",
            .bang => "!",
            .amp_amp => "&&",
            .pipe_pipe => "||",
            .tilde => "~",
            .amp => "&",
            .pipe => "|",
            .caret => "^",
            .tilde_caret => "~^",
            .caret_tilde => "^~",
            .tilde_amp => "~&",
            .tilde_pipe => "~|",
            .lt_lt => "<<",
            .gt_gt => ">>",
            .lt_lt_lt => "<<<",
            .gt_gt_gt => ">>>",
            .question => "?",
            .colon => ":",
            .lparen => "(",
            .rparen => ")",
            .lbracket => "[",
            .rbracket => "]",
            .lbrace => "{",
            .rbrace => "}",
            .semicolon => ";",
            .comma => ",",
            .dot => ".",
            .at => "@",
            .hash => "#",
            .apostrophe_lbrace => "'{",
            .attr_open => "(*",
            .attr_close => "*)",
            .dir_begin_keywords => "`begin_keywords",
            .dir_end_keywords => "`end_keywords",

            // Every keyword tag is "kw_" ++ its spelling (naming invariant).
            else => @tagName(tag)[3..],
        };
    }

    /// `lexeme` in backticks — what a diagnostic prints when it has to name the
    /// character the user must type. Derived from `lexeme` at comptime, through
    /// `inline else`, so the two spellings cannot drift apart and no second
    /// table exists to forget.
    pub fn quoted(tag: Tag) ?[]const u8 {
        return switch (tag) {
            inline else => |t| comptime blk: {
                const l = lexeme(t) orelse break :blk null;
                break :blk "`" ++ l ++ "`";
            },
        };
    }
};

/// SoA row. Keep it 5 bytes; do not add fields (recompute, don't store).
pub const Stored = struct {
    tag: Tag,
    start: u32,
};

/// Keyword lookup. LRM §2.8.2 / annex B. Comptime-built, no allocation.
/// Derived from `Tag` — see the naming invariant in the file header.
///
/// NOT O(1), and not a hash map: read `std/static_string_map.zig`. It buckets
/// the keys by LENGTH (`len_indexes[str.len]`, and a `min_len`/`max_len`
/// prefilter before that) and then LINEARLY SCANS the bucket, comparing
/// byte-at-a-time. With 217 keywords the five-byte bucket holds 39 of them, so
/// an ordinary five-byte identifier is compared against all 39 before the miss
/// is known. So this is the DEFINITION and the reference; `lookupKeyword` is
/// what the lexer calls, and it reaches the same keys through their first byte.
pub const keyword_map = std.StaticStringMap(Tag).initComptime(keyword_kvs);

/// Lane count for the bucket scan, from the target — never hardcoded. `null`
/// on a target with no useful `u8` vector, and then the scalar loop is the
/// whole implementation.
const kw_lanes = std.simd.suggestVectorLength(u8);

/// The FIRST BYTE of each keyword, in `keyword_map.keys()` order — 217 bytes,
/// four cache lines, against the 3,472 bytes of `[]const u8` headers the map's
/// own scan walks to read the same information.
///
/// MEASURED from the table itself: 217 keywords, lengths 2..19, 23 distinct
/// first bytes, 118 of the 23×18 (first byte, length) pairs occupied, at most 6
/// keywords in any one pair. `StaticStringMap` already buckets by length, so
/// the first byte is the dimension it is missing and this is the whole of it.
///
/// Padded by one lane with 0, which no keyword starts with, so a full-width
/// load at any index below `keys().len` is in bounds and the extra lanes cannot
/// match. That is what lets the chunk loop below run past a bucket's end and
/// mask, instead of needing a second scalar loop for every bucket's tail.
const kw_first: [keyword_map.keys().len + (kw_lanes orelse 1)]u8 = blk: {
    var t = [_]u8{0} ** (keyword_map.keys().len + (kw_lanes orelse 1));
    for (keyword_map.keys(), 0..) |k, i| t[i] = k[0];
    break :blk t;
};

/// Longest keyword, from the table. `kw_len_start[L]..kw_len_start[L+1]` is the
/// run of keys of length L, which exists only because `StaticStringMap` sorts
/// its keys by length — the loop below `@compileError`s if a stdlib change ever
/// stops it doing that, rather than silently mis-slicing the runs.
const kw_max_len: usize = keyword_map.max_len;

const kw_len_start: [kw_max_len + 2]u16 = blk: {
    const keys = keyword_map.keys();
    for (keys[1..], keys[0 .. keys.len - 1]) |b, a| {
        if (b.len < a.len) @compileError("StaticStringMap no longer sorts keys by length");
    }
    var t: [kw_max_len + 2]u16 = undefined;
    for (keyword_map.len_indexes[0 .. kw_max_len + 1], 0..) |off, len| {
        t[len] = @intCast(off);
    }
    t[kw_max_len + 1] = keys.len;
    break :blk t;
};

/// LRM §2.8.2 / annex B. What the lexer calls: `keyword_map.get(name)`, reached
/// through the first byte instead of by walking the whole length bucket.
///
/// `keyword_map` stays the reference — the tags and spellings come out of it,
/// the index into `kw_first` IS its key index, and the differential test below
/// asserts this function agrees with `get` on every keyword, every near miss of
/// one, and 20,000 random spellings.
///
/// WHY THIS IS HAND-ROLLED and not `std.mem.indexOfScalarPos`. That is the
/// stdlib's SIMD scan and it was tried first (rung 3 of the ladder), but it
/// cannot reach its vector path here: `findScalarPos` needs `2*block_len < len`
/// — >64 bytes on AVX2 — and the biggest bucket is 39, so it runs its byte loop,
/// which is no cheaper than the map's own walk over ~13 keys. One masked block
/// is. MEASURED, three implementations over identical work (callgrind, total Ir,
/// `vera --lint` on `annex_e_spice/primitive_vsine.va` WITHOUT `-I`, which stops
/// at the missing `check.vh` and therefore lexes the prelude and nothing else —
/// a lexer microbenchmark with no parser in it):
///
///     keyword_map.get                              2,240,522
///     + a (first byte, length) bitmask in front    2,191,152   −2.2%
///     std.mem.indexOfScalarPos over the bucket     2,163,929   −3.4%
///     the masked block below                       2,092,721   −6.6%
///
/// The bitmask is the cheap idea and it is the one that failed: the prelude's
/// identifiers are mostly keywords or keyword-shaped, so ~80% of them passed the
/// filter and paid for it. A filter only helps misses; shortening the walk helps
/// hits too, and the prelude is nearly all hits.
///
/// MEASURED on a WHOLE compilation (callgrind, ReleaseFast -Dcpu=x86_64_v3,
/// `vera --emit-zig -I tests/fixtures annex_e_spice/primitive_vpulse.va`):
/// 7,911,240 → 7,618,237 Ir, −3.7%, of which the lookup itself is 501,720 →
/// 208,663 (−58%: 87,246 here, 42,083 more inside `Lexer.next`, 79,334 in
/// `std.mem.eql` — that last is now the biggest half and is where the next
/// bite is, if there is ever a reason to take it). Before this it was the
/// single largest entry in the profile at 6.34%.
///
/// MEASURED end to end (`zig build bench -Doptimize=ReleaseFast -- fixtures`,
/// min of 25, best of 3 runs): `lint` 181.2 → 170.6 ms, `codegen` 199.4 → 188.0
/// ms, both −5.8%; `pp` unchanged, as it must be — it never lexes.
pub fn lookupKeyword(name: []const u8) ?Tag {
    // One compare rejects the empty string and everything longer than the
    // longest keyword; `name[0]` is in bounds after it.
    if (name.len -% 1 >= kw_max_len) return null;
    const lo: usize = kw_len_start[name.len];
    const hi: usize = kw_len_start[name.len + 1];

    if (kw_lanes) |lanes| {
        const V = @Vector(lanes, u8);
        const Mask = std.meta.Int(.unsigned, lanes);
        const needle: V = @splat(name[0]);
        var i = lo;
        while (i < hi) : (i += lanes) {
            const block: V = kw_first[i..][0..lanes].*;
            var m: Mask = @bitCast(block == needle);
            // Lanes past this bucket belong to the next length and must not
            // match. The padding covers the lanes past the table itself.
            const valid = hi - i;
            if (valid < lanes) m &= (@as(Mask, 1) << @intCast(valid)) - 1;
            while (m != 0) : (m &= m - 1) {
                const k = i + @ctz(m);
                if (std.mem.eql(u8, keyword_map.keys()[k], name)) return keyword_map.values()[k];
            }
        }
        return null;
    }
    return lookupKeywordScalar(name, lo, hi);
}

/// The reference implementation, and the fallback on a target with no vectors.
/// Kept because the vector loop above is only correct if it agrees with this on
/// every input — which is what the differential test checks.
fn lookupKeywordScalar(name: []const u8, lo: usize, hi: usize) ?Tag {
    for (kw_first[lo..hi], lo..) |first, i| {
        if (first == name[0] and std.mem.eql(u8, keyword_map.keys()[i], name)) {
            return keyword_map.values()[i];
        }
    }
    return null;
}

// ---- §10.6 `begin_keywords: which words are RESERVED ----------------------

/// LRM §10.6 version_specifier: "specifies the valid set of reserved keywords
/// in effect when a design unit is parsed". The five specifiers an
/// implementation "must also support" form a chain, oldest first:
///
///     1364-1995 ⊂ 1364-2001 ⊂ 1364-2005 ⊂ VAMS-2.3 ⊂ VAMS-2023
///
/// so one `keyword_intro` datum per keyword decides membership in all five:
/// a word is reserved in set `s` iff it was introduced no later than `s`.
///
/// SCOPE (§10.6, verbatim): "The `begin_keywords and `end_keywords directives
/// only specify the set of identifiers that are reserved as keywords. The
/// directives do not affect the semantics, tokens, and other aspects of the
/// Verilog-AMS language." So the LEXER IS UNAFFECTED — `sin` keeps lexing to
/// `kw_sin` under every set. What changes is whether the parser will accept
/// that token where an identifier is expected (`Parser.identLike`). That is
/// also the only reading under which the §10.6 worked example composes: a
/// module using `analog` (a VAMS-only annex B keyword) under
/// `begin_keywords "1364-2005" still parses, while `input sin;` becomes legal.
pub const KeywordSet = enum(u8) {
    v1364_1995,
    v1364_2001,
    v1364_2005,
    vams_2_3,
    vams_2023,

    /// §10.6 version_specifier string → set. `null` for anything else; the LRM
    /// names exactly these five, so an unknown specifier is an error.
    pub fn fromSpecifier(text: []const u8) ?KeywordSet {
        return specifier_map.get(text);
    }
};

/// The implementation's default set when no `begin_keywords is in effect
/// (§10.6: "the implementation's default set of reserved keywords").
pub const default_keyword_set: KeywordSet = .vams_2023;

const specifier_map = std.StaticStringMap(KeywordSet).initComptime(.{
    .{ "1364-1995", KeywordSet.v1364_1995 },
    .{ "1364-2001", KeywordSet.v1364_2001 },
    .{ "1364-2005", KeywordSet.v1364_2005 },
    .{ "VAMS-2.3", KeywordSet.vams_2_3 },
    .{ "VAMS-2023", KeywordSet.vams_2023 },
});

/// LRM §10.6 / annex B. Is the keyword spelled `name` a reserved word under
/// `set`? Only meaningful for a spelling that is in `keyword_map` at all.
pub fn isReserved(name: []const u8, set: KeywordSet) bool {
    return @intFromEnum(keyword_intro.get(name) orelse .vams_2_3) <= @intFromEnum(set);
}

// ---- predicates the lexer/parser want ------------------------------------

/// LRM §2.8.2 / annex B. Escaped identifiers are never keywords (§2.8.1); the
/// lexer must not consult `keyword_map` for them.
pub fn isKeyword(tag: Tag) bool {
    return @intFromEnum(tag) >= @intFromEnum(Tag.first_keyword);
}

/// LRM §3.5 / §6.5 port direction.
pub fn isPortDirection(tag: Tag) bool {
    return switch (tag) {
        .kw_input, .kw_output, .kw_inout => true,
        else => false,
    };
}

/// LRM §3.7 / annex A.2.1.3 net type (optional prefix on a discipline decl).
pub fn isNetType(tag: Tag) bool {
    return switch (tag) {
        .kw_wire,
        .kw_tri,
        .kw_tri0,
        .kw_tri1,
        .kw_triand,
        .kw_trior,
        .kw_trireg,
        .kw_wand,
        .kw_wor,
        .kw_uwire,
        .kw_supply0,
        .kw_supply1,
        => true,
        else => false,
    };
}

/// LRM §4.3.2/§4.3.3 — built-in math functions. EXACTLY annex A.8.2
/// `analog_built_in_function_name` (26 names); the parser turns these into
/// `Ast.ExprTag.builtin_call`. These are the tags whose domains `proof.zig`
/// must discharge at compile time (invariant 5).
///
/// NOTE `limexp` is NOT here: A.8.2 lists it under
/// `analog_filter_function_call` (§4.5.13), so it is a filter function —
/// see `isFilterFunction`.
pub fn isMathFunction(tag: Tag) bool {
    return switch (tag) {
        .kw_abs,
        .kw_max,
        .kw_min,
        .kw_pow,
        .kw_sqrt,
        .kw_exp,
        .kw_ln,
        .kw_log,
        .kw_expm1,
        .kw_ln1p,
        .kw_hypot,
        .kw_floor,
        .kw_ceil,
        .kw_sin,
        .kw_cos,
        .kw_tan,
        .kw_asin,
        .kw_acos,
        .kw_atan,
        .kw_atan2,
        .kw_sinh,
        .kw_cosh,
        .kw_tanh,
        .kw_asinh,
        .kw_acosh,
        .kw_atanh,
        => true,
        else => false,
    };
}

/// LRM §4.5 — analog filter operators. EXACTLY annex A.8.2
/// `analog_filter_function_call` (17 names, `limexp` included); the parser
/// turns these into `Ast.ExprTag.filter_call`. Each occurrence owns runtime
/// state (§4.5.1).
/// Filters and small-signal functions may not appear in a conditional/loop
/// whose controlling expression is not constant (§4.5.1, §5.8.4).
pub fn isFilterFunction(tag: Tag) bool {
    return switch (tag) {
        .kw_ddt,
        .kw_ddx,
        .kw_idt,
        .kw_idtmod,
        .kw_absdelay,
        .kw_transition,
        .kw_slew,
        .kw_last_crossing,
        .kw_limexp, // §4.5.13 — A.8.2 lists it here, not with the math builtins
        .kw_laplace_zd,
        .kw_laplace_zp,
        .kw_laplace_nd,
        .kw_laplace_np,
        .kw_zi_zd,
        .kw_zi_zp,
        .kw_zi_nd,
        .kw_zi_np,
        => true,
        else => false,
    };
}

/// LRM §4.6 — small-signal / noise sources. EXACTLY annex A.8.2
/// `analog_small_signal_function_call` minus `analysis` (which A.8.2 gives its
/// own production and which the parser folds into `Ast.ExprTag.sys_call`).
/// These become `Ast.ExprTag.noise_call`.
pub fn isSmallSignalFunction(tag: Tag) bool {
    return switch (tag) {
        .kw_ac_stim,
        .kw_white_noise,
        .kw_flicker_noise,
        .kw_noise_table,
        .kw_noise_table_log,
        => true,
        else => false,
    };
}

/// LRM §5.10.3 — EXACTLY annex A.6.5 `analog_event_functions` (4 names), legal
/// only inside an `@( ... )` event control. These become
/// `Ast.ExprTag.event_function`.
///
/// NOTE `initial_step`/`final_step` are NOT here: A.6.5 gives them their own
/// `analog_event_expression` alternatives (an optional list of *string*
/// analysis names, not expressions) and the AST gives them their own tags
/// `event_initial_step` / `event_final_step`.
pub fn isEventFunction(tag: Tag) bool {
    return switch (tag) {
        .kw_cross,
        .kw_above,
        .kw_timer,
        .kw_absdelta,
        => true,
        else => false,
    };
}

/// A keyword that starts a call-like expression: `name ( args )`. Union of the
/// math (§4.3), filter (§4.5), small-signal (§4.6) and event (§5.10.3) groups
/// plus `analysis` (§4.6.1) and the §5.10.2 step events.
pub fn isBuiltinFunction(tag: Tag) bool {
    return switch (tag) {
        .kw_analysis, .kw_initial_step, .kw_final_step => true,
        else => isMathFunction(tag) or isFilterFunction(tag) or isSmallSignalFunction(tag) or isEventFunction(tag),
    };
}

// ---- keyword table construction ------------------------------------------

const KV = struct { []const u8, Tag };

/// Annex B keywords that are reserved but out of the analog subset's scope:
/// IEEE 1364 digital primitives/gates, specify + table, config-file keywords,
/// and the annex C.16 "not used by Verilog-A" list. All lex to `.kw_reserved`.
/// Keeping them in the map is what makes them unusable as identifiers (annex B).
const reserved_keywords = [_][]const u8{
    // annex C.16 — not used by Verilog-A
    // `net_resolution` appears in no production at all, and `wreal` (§3.7)
    // declares a discrete
    // real net there is no digital kernel to drive.
    "net_resolution", "wreal",
    // digital behavior / structural §IEEE1364
    //
    // `assert` earns its place the way `net_resolution` above it does: Table
    // B.1 reserves the spelling and Verilog-AMS 2.4 then spends it on nothing
    // — no statement, no system function, no production in annex A. Being
    // unavailable as an identifier is the whole of what the word does.
    // `assign` left this list when A.6.1 got a tag (`kw_assign`) — §10.6
    // membership is keyed by spelling, so it is still reserved everywhere it
    // was, and `keyword_intro` still finds it through `kw_1364_1995`.
    "and",                "assert",
    "automatic",          "buf",           "bufif0",       "bufif1",
    "cmos",               "deassign",      "edge",
    "endprimitive",       "endspecify",    "endtable",     "endtask",
    "force",              "fork",          "highz0",       "highz1",
    "ifnone",             "join",          "large",        "medium",
    // `posedge`/`negedge` are no longer here: §5.10.1 gives them their own
    // tags, because an event expression has to tell the two apart.
    "nand",               "nmos",          "nor",
    "noshowcancelled",    "not",           "notif0",       "notif1",
    "pmos",               "primitive",     "pull0",
    "pull1",              "pulldown",      "pullup",       "pulsestyle_ondetect",
    "pulsestyle_onevent", "rcmos",         "release",      "rnmos",
    // The `tranif`/`rtranif` spellings below stay here — a pass ENABLE switch
    // is a three-terminal gate
    // whose conduction is a logic value, which is a different construct.
    "rpmos",              "rtranif0",      "rtranif1",
    "showcancelled",      "small",         "specify",      "specparam",
    "strong0",            "strong1",       "table",        "task",
    "tranif0",            "tranif1",       "wait",
    "weak0",              "weak1",         "xnor",         "xor",
    // configuration / library (IEEE 1364 clause 13)
    "cell",               "config",        "design",       "endconfig",
    "incdir",             "include",       "instance",     "liblist",
    "library",            "use",
};

/// IEEE Std 1364-1995 reserved words (102). The oldest set §10.6 names, and a
/// subset of every later one.
const kw_1364_1995 = [_][]const u8{
    "always",    "and",          "assign",     "begin",
    "buf",       "bufif0",       "bufif1",     "case",
    "casex",     "casez",        "cmos",       "deassign",
    "default",   "defparam",     "disable",    "edge",
    "else",      "end",          "endcase",    "endfunction",
    "endmodule", "endprimitive", "endspecify", "endtable",
    "endtask",   "event",        "for",        "force",
    "forever",   "fork",         "function",   "highz0",
    "highz1",    "if",           "ifnone",     "initial",
    "inout",     "input",        "integer",    "join",
    "large",     "macromodule",  "medium",     "module",
    "nand",      "negedge",      "nmos",       "nor",
    "not",       "notif0",       "notif1",     "or",
    "output",    "parameter",    "pmos",       "posedge",
    "primitive", "pull0",        "pull1",      "pulldown",
    "pullup",    "rcmos",        "real",       "realtime",
    "reg",       "release",      "repeat",     "rnmos",
    "rpmos",     "rtran",        "rtranif0",   "rtranif1",
    "scalared",  "small",        "specify",    "specparam",
    "strong0",   "strong1",      "supply0",    "supply1",
    "table",     "task",         "time",       "tran",
    "tranif0",   "tranif1",      "tri",        "tri0",
    "tri1",      "triand",       "trior",      "trireg",
    "vectored",  "wait",         "wand",       "weak0",
    "weak1",     "while",        "wire",       "wor",
    "xnor",      "xor",
};

/// Added by IEEE Std 1364-2001 (21): generate/config/library and signedness.
const kw_1364_2001 = [_][]const u8{
    "automatic",          "cell",          "config",          "design",
    "endconfig",          "endgenerate",   "generate",        "genvar",
    "incdir",             "include",       "instance",        "liblist",
    "library",            "localparam",    "noshowcancelled", "pulsestyle_ondetect",
    "pulsestyle_onevent", "showcancelled", "signed",          "unsigned",
    "use",
};

/// Added by IEEE Std 1364-2005 (1).
const kw_1364_2005 = [_][]const u8{"uwire"};

/// Verilog-AMS keywords that postdate the "VAMS-2.3" specifier, per annex G
/// tables G.6 (v2.3.1→v2.4) and G.7 (v2.4→VAMS-2023): `$noise_table_log`
/// (G.6 item 4349), `absdelta` (G.6 item 4803), `return`/`break`/`continue`
/// (G.7 item 830) and `expm1`/`ln1p` (G.7 item 7780). Every other VAMS keyword
/// defaults to `.vams_2_3` — see `isReserved`.
const kw_vams_2023 = [_][]const u8{
    "absdelta", "break", "continue", "expm1", "ln1p", "noise_table_log", "return",
};

const keyword_intro = std.StaticStringMap(KeywordSet).initComptime(intro_kvs);

const IntroKV = struct { []const u8, KeywordSet };

const intro_kvs = kvs: {
    @setEvalBranchQuota(20_000);
    const n = kw_1364_1995.len + kw_1364_2001.len + kw_1364_2005.len + kw_vams_2023.len;
    var out: [n]IntroKV = undefined;
    var i: usize = 0;
    for (.{ kw_1364_1995, kw_1364_2001, kw_1364_2005, kw_vams_2023 }, [_]KeywordSet{
        .v1364_1995, .v1364_2001, .v1364_2005, .vams_2023,
    }) |names, set| {
        for (names) |name| {
            out[i] = .{ name, set };
            i += 1;
        }
    }
    break :kvs out;
};

const keyword_kvs = kvs: {
    @setEvalBranchQuota(20_000);
    const fields = @typeInfo(Tag).@"enum".fields[@intFromEnum(Tag.first_keyword)..@intFromEnum(Tag.kw_reserved)];
    const n = reserved_keywords.len + fields.len;

    var out: [n]KV = undefined;
    var i: usize = 0;
    for (fields) |f| {
        out[i] = .{ f.name[3..], @field(Tag, f.name) };
        i += 1;
    }
    for (reserved_keywords) |name| {
        out[i] = .{ name, .kw_reserved };
        i += 1;
    }
    break :kvs out;
};

// ---- checks ---------------------------------------------------------------

test "layout invariant: keyword block is contiguous and last" {
    // Every kw_* tag is >= first_keyword, and nothing before it is a keyword.
    @setEvalBranchQuota(20_000);
    inline for (@typeInfo(Tag).@"enum".fields) |f| {
        const is_kw_name = comptime std.mem.startsWith(u8, f.name, "kw_");
        try std.testing.expectEqual(is_kw_name, isKeyword(@field(Tag, f.name)));
    }
    try std.testing.expect(!isKeyword(.eof));
    try std.testing.expect(!isKeyword(.attr_close));
    // Tag must stay in u8 (enum(u8)); this fails loudly if the set outgrows it.
    try std.testing.expect(@typeInfo(Tag).@"enum".fields.len <= 256);
}

test "keyword_map: spelling round-trips through lexeme" {
    for (keyword_map.keys(), keyword_map.values()) |key, tag| {
        if (tag == .kw_reserved) continue;
        try std.testing.expectEqualStrings(key, Tag.lexeme(tag).?);
    }
    try std.testing.expectEqual(Tag.kw_module, keyword_map.get("module").?);
    try std.testing.expectEqual(Tag.kw_initial_step, keyword_map.get("initial_step").?);
    try std.testing.expectEqual(Tag.kw_posedge, keyword_map.get("posedge").?);
    try std.testing.expectEqual(Tag.kw_reserved, keyword_map.get("primitive").?);
    // Not keywords: system function names (§2.8.3) and ordinary identifiers.
    try std.testing.expectEqual(@as(?Tag, null), keyword_map.get("temperature"));
    try std.testing.expectEqual(@as(?Tag, null), keyword_map.get("V"));
}

test "lookupKeyword: differential against keyword_map, which stays the reference" {
    // Every spelling is checked three ways: the vector loop that ships, the
    // scalar reference next to it, and `keyword_map.get`, which is §2.8.2's
    // actual definition. A miscompare here is a silent miscompile — a keyword
    // read as an identifier, or the reverse.
    const check = struct {
        fn all(s: []const u8) !void {
            const want = keyword_map.get(s);
            try std.testing.expectEqual(want, lookupKeyword(s));
            if (s.len >= 1 and s.len <= kw_max_len) {
                const lo: usize = kw_len_start[s.len];
                const hi: usize = kw_len_start[s.len + 1];
                try std.testing.expectEqual(want, lookupKeywordScalar(s, lo, hi));
            }
        }
    }.all;

    // 1. Every keyword is still found. This is the only way the scan can be
    //    WRONG in the direction that matters: a missed keyword changes the
    //    parse of legal source.
    for (keyword_map.keys()) |key| try check(key);

    // 2. Random spellings. Lengths sweep 0 .. 3× the lane count (32 lanes on
    //    x86_64_v3 → 0..96), so every bucket boundary, the empty case and
    //    everything past the longest keyword are exercised.
    var prng: std.Random.DefaultPrng = .init(0x2820); // §2.8, §2.0
    const rand = prng.random();
    var buf: [3 * 64 + 2]u8 = undefined;
    const max_len = 3 * (kw_lanes orelse 32);
    const alphabet = "abcdefghijklmnopqrstuvwxyz_0123456789ABZ";
    for (0..20_000) |_| {
        const len = rand.intRangeAtMost(usize, 0, max_len);
        for (buf[0..len]) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        try check(buf[0..len]);
    }
    try check("");
    try check("\xffodule");
    try check("m" ** 32);

    // 3. Near misses, where a scan that stops one lane early actually shows up:
    //    every keyword with one byte dropped, one appended, and its first byte
    //    replaced by one no keyword starts with.
    for (keyword_map.keys()) |key| {
        @memcpy(buf[0..key.len], key);
        try check(buf[0 .. key.len - 1]);
        buf[key.len] = '_';
        try check(buf[0 .. key.len + 1]);
        buf[0] = 'q';
        try check(buf[0..key.len]);
    }
}

test "§10.6 keyword sets nest, and the intro table cannot drift from annex B" {
    // Anti-drift: every name that has an introduction date must actually be a
    // keyword. A typo here would silently un-reserve nothing at all.
    for (keyword_intro.keys()) |name| {
        if (keyword_map.get(name) == null) {
            std.debug.print("keyword_intro names a non-keyword: {s}\n", .{name});
            return error.NotAKeyword;
        }
    }
    // Counts straight from the standards (see the array doc comments).
    try std.testing.expectEqual(102, kw_1364_1995.len);
    try std.testing.expectEqual(21, kw_1364_2001.len);

    // The five sets are a chain: reserved in an older set ⇒ reserved in every
    // newer one. `sin` is the LRM §10.6 worked example.
    for (keyword_map.keys()) |name| {
        var prev = false;
        for ([_]KeywordSet{ .v1364_1995, .v1364_2001, .v1364_2005, .vams_2_3, .vams_2023 }) |s| {
            const now = isReserved(name, s);
            try std.testing.expect(!prev or now); // monotone
            prev = now;
        }
        try std.testing.expect(isReserved(name, .vams_2023)); // annex B is the union
    }
    try std.testing.expect(!isReserved("sin", .v1364_2005));
    try std.testing.expect(isReserved("sin", .vams_2_3));
    try std.testing.expect(isReserved("module", .v1364_1995));
    try std.testing.expect(!isReserved("localparam", .v1364_1995));
    try std.testing.expect(isReserved("localparam", .v1364_2001));
    try std.testing.expect(!isReserved("uwire", .v1364_2001));
    try std.testing.expect(isReserved("uwire", .v1364_2005));
    try std.testing.expect(!isReserved("ln1p", .vams_2_3)); // annex G.7 item 7780
    try std.testing.expect(isReserved("ln1p", .vams_2023));
    // §10.6 version_specifier strings, all five of them.
    try std.testing.expectEqual(KeywordSet.v1364_1995, KeywordSet.fromSpecifier("1364-1995").?);
    try std.testing.expectEqual(KeywordSet.v1364_2001, KeywordSet.fromSpecifier("1364-2001").?);
    try std.testing.expectEqual(KeywordSet.v1364_2005, KeywordSet.fromSpecifier("1364-2005").?);
    try std.testing.expectEqual(KeywordSet.vams_2_3, KeywordSet.fromSpecifier("VAMS-2.3").?);
    try std.testing.expectEqual(KeywordSet.vams_2023, KeywordSet.fromSpecifier("VAMS-2023").?);
    try std.testing.expectEqual(@as(?KeywordSet, null), KeywordSet.fromSpecifier("1800-2017"));
}

test "call groups match annex A.8.2/A.6.5 exactly and are disjoint" {
    // One group per Ast.ExprTag the parser produces. Counts come straight from
    // the grammar: analog_built_in_function_name = 26, analog_filter_function_
    // call = 17, analog_small_signal_function_call = 5, analog_event_functions
    // = 4. If a tag lands in two groups the parser would pick the wrong tag.
    var counts = [_]u32{ 0, 0, 0, 0 };
    inline for (@typeInfo(Tag).@"enum".fields) |f| {
        const t: Tag = @field(Tag, f.name);
        var n: u32 = 0;
        if (isMathFunction(t)) {
            counts[0] += 1;
            n += 1;
        }
        if (isFilterFunction(t)) {
            counts[1] += 1;
            n += 1;
        }
        if (isSmallSignalFunction(t)) {
            counts[2] += 1;
            n += 1;
        }
        if (isEventFunction(t)) {
            counts[3] += 1;
            n += 1;
        }
        try std.testing.expect(n <= 1);
        if (n == 1) try std.testing.expect(isBuiltinFunction(t));
    }
    try std.testing.expectEqual([_]u32{ 26, 17, 5, 4 }, counts);
    // §4.5.13: limexp is a filter, never a math builtin (proof.zig must not
    // put a domain on it, codegen must give it state).
    try std.testing.expect(isFilterFunction(.kw_limexp) and !isMathFunction(.kw_limexp));
    // §5.10.2 step events are their own Ast tags, not `event_function`s.
    try std.testing.expect(!isEventFunction(.kw_initial_step) and isBuiltinFunction(.kw_initial_step));
}

test "Stored stays 5 bytes of payload (SoA columns, no len field)" {
    try std.testing.expectEqual(2, @typeInfo(Stored).@"struct".fields.len);
    try std.testing.expectEqual(1, @sizeOf(Tag));
    try std.testing.expectEqual(4, @sizeOf(u32));
}
