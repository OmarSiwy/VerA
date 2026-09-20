// IEEE 1364-2005 §§18.1-18.2, the standard VCD file — the conformance plan's
// 18.1-18.2 row, and the row docs/CLAUSE-AUDIT.md:357 already records as "There
// is no VCD code, no VCD fixture, and no VCD rejection fixture". The only
// occurrence of the string $dumpvars anywhere in the tree is an unrelated
// doc-comment example at src/frontend/preprocessor.zig:289. Verilog-AMS does
// not extend these tasks, so the inherited definition governs in full.
//
// The tasks used here:
//   $dumpfile(name)       names the dump file; one per simulation.
//   $dumpvars(levels, scope)
//                         selects what to dump. `levels` 0 means the named
//                         scope and EVERY level below it.
//
// The file structure §18.2 requires, in order: a header section, the variable
// definitions, $enddefinitions, and then value-change sections keyed by
// #<time> records. Every variable gets a short printable-ASCII identifier code
// that stands in for its name in every later value change.
//
// HAND DERIVATION of 11_vcd_dumpvars.expected.vcd:
//
//   Header. The directive is `timescale 1ns/1ns`, so the $timescale record
//   carries 1ns.
//
//   Definitions. Two variables are declared, in source order:
//     reg a          -> size 1, scalar, no range
//     reg [3:0] v    -> size 4, vector, range [3:0]
//   Identifier codes are assigned in declaration order from the first
//   printable ASCII character, so a gets `!` (ASCII 33) and v gets `"` (34).
//   See the CONVENTION note below.
//
//   Value changes. All four steps of the initial block:
//     t=0  $dumpfile and $dumpvars run, then a <- 0 and v <- 0000. §18.2
//          emits ONE record per time step, after the step's values have
//          settled, so the #0 record shows the settled 0 and 0000 and not the
//          X the variables held when $dumpvars was called.
//            #0
//            $dumpvars
//            0!
//            b0 "
//            $end
//          A vector value is written as `b<binary> <code>` with leading zeros
//          suppressed, so 4'b0000 is `b0` and not `b0000`.
//     t=1  a <- 1 only. v did not change, so v contributes nothing: §18.2
//          records CHANGES, not state.
//            #1
//            1!
//     t=2  v <- 4'b1010 only. Leading digit is 1, nothing to suppress.
//            #2
//            b1010 "
//     t=3  a <- 1'bx and v <- 4'bz01x in the same step. Both appear under one
//          #3 record, in declaration order.
//            #3
//            x!
//            bz01x "
//          `z01x` is written in full: suppression only removes a leading run
//          that repeats the leftmost character's extension, and here the
//          leftmost z is followed by 0, so all four characters stay.
//          These are the four-state encodings: scalar x is the single
//          character `x` prefixed to the code with NO separating space, while
//          a vector always has the `b` prefix and a space before the code.
//     $finish(0) then runs in that same step. The #3 record must already be
//     in the file: §18.1 provides $dumpflush precisely so a program can force
//     an EARLY flush, which would be meaningless if the final one were
//     optional. So the file ends after `bz01x "` with no further record.
//
// CONVENTION, stated so a reviewer is not misled. §18.2 does not mandate WHICH
// printable-ASCII codes a writer picks, nor the exact whitespace inside a
// header command, nor the $date/$version text. This golden therefore fixes:
//   - codes assigned sequentially from `!` in $var declaration order;
//   - comparison performed after NORMALIZATION: the $date, $version and
//     $comment sections are deleted wherever they occur and however they are
//     broken across lines, and the body of the $timescale section has its
//     whitespace removed, so a writer emitting `1 ns` and one emitting `1ns`
//     both normalise to `$timescale 1ns $end`. Every other line is compared
//     byte for byte. SPEC.md carries the normaliser itself; it is token-based
//     rather than line-based, because a line-oriented `sed` range mis-deletes
//     when `$date … $end` lands on a single line.
// Everything else in this golden — the record kinds, their order, the value
// encodings, the timestamps and the one-record-per-step rule — is normative.
//
//! lrm inherited IEEE 1364-2005 18.1 ($dumpfile, $dumpvars)
//! lrm inherited IEEE 1364-2005 18.2 (VCD format, identifier codes, value changes)
//! expect vcd d09_vcd.vcd == 11_vcd_dumpvars.expected.vcd
`timescale 1ns/1ns
module d09_vcd;
  reg a;
  reg [3:0] v;
  initial begin
    $dumpfile("d09_vcd.vcd");
    $dumpvars(0, d09_vcd);
    a = 1'b0;
    v = 4'b0000;
    #1 a = 1'b1;
    #1 v = 4'b1010;
    #1 a = 1'bx;
       v = 4'bz01x;
       $finish(0);
  end
endmodule
