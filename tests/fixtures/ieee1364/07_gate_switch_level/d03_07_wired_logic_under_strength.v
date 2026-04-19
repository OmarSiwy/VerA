// Verilog-AMS LRM 2.4 annex A.2.2.1 gives `wand`/`wor` as net types and annex
// A.2.2.2 gives the drive strengths; §1.1 makes the combination IEEE Std 1364
// Verilog's clause 7 wired-logic resolution. The wired-logic tables are tables
// over the four-state VALUES of the drivers — a wand is 0 when any driver is 0,
// a wor is 1 when any driver is 1 — so adding strengths must NOT change which
// value comes out of them.
//
// Wired resolution already works (src/sim/digital.zig `wired`), so most of this
// fixture is a regression pin: the answer stays the same when the drivers stop
// being equals. The one line that must change is the `highz0` driver's 0. A
// (strong1, highz0) driver asserting 0 asserts NOTHING — it is z, and z is the
// identity of all three wired tables — so it cannot pull a wand down.
//
// Only the resolved VALUE is asserted here. The strength of a wired-logic
// result is not observable from this runner: `%v` is not implemented (see
// docs/CLAUSE-AUDIT.md row 17.1-07) and there are no switch primitives to
// propagate it into (D08).
//
//! lrm annex A.2.2.1
//! lrm annex A.2.2.2
//! lrm 1.1
//! timescale 1ns/1ns
//
// HAND DERIVATION
//   wa : wand, drivers (strong1, highz0) a  and (weak1, weak0) b
//   wo : wor,  drivers (strong1, strong0) a and (weak1, weak0) b
//
//   t=1  a=1, b=0:  wa = 1 AND 0 = 0            wo = 1 OR 0 = 1
//   t=2  a=0, b=1:  a is z through highz0, and z is the wand identity,
//                   so wa = 1                   wo = 0 OR 1 = 1
//   t=3  a=0, b=0:  wa = z AND 0 = 0            wo = 0 OR 0 = 0
//   t=4  a=z, b=1:  wa = z AND 1 = 1            wo = z OR 1 = 1
//
// Today: line 2's wand reads 0, because a 0 with a highz0 strength spec is
// still a 0. The other three lines already pass on values and are here so a
// strength implementation cannot regress them.

`timescale 1ns/1ns
module d03_wired_logic_under_strength;
  reg a, b;
  wand wa;
  wor wo;

  assign (strong1, highz0) wa = a;
  assign (weak1, weak0) wa = b;
  assign (strong1, strong0) wo = a;
  assign (weak1, weak0) wo = b;

  initial begin
    a = 1'b1; b = 1'b0;
    #1 $display("one_zero %b %b", wa, wo);
    a = 1'b0; b = 1'b1;
    #1 $display("suppressed_zero %b %b", wa, wo);
    a = 1'b0; b = 1'b0;
    #1 $display("zero_zero %b %b", wa, wo);
    a = 1'bz; b = 1'b1;
    #1 $display("float_one %b %b", wa, wo);
    $finish(0);
  end
endmodule
