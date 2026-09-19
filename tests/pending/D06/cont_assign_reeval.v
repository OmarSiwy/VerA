// Verilog-AMS LRM 2.4 §8.5.3.1 Continuous assignment:
//   "A continuous assignment statement (6.1 of IEEE Std 1364 Verilog)
//    corresponds to a process, sensitive to the source elements in the
//    expression. When the value of the expression changes, it causes an ACTIVE
//    UPDATE EVENT to be added to the event queue, using current values to
//    determine the target."
//
// Two separable claims are pinned here.
//   (a) SENSITIVITY IS TO EVERY SOURCE ELEMENT of the expression, not just to
//       the one that happens to be selected. `sel`, `a` and `b` are all source
//       elements of `sel ? a : b`.
//   (b) The update is an ACTIVE UPDATE EVENT, i.e. it is QUEUED, not applied
//       in place. A read of the target taken in the same active region, after
//       the blocking assignment that changed the source, still observes the
//       OLD value; §8.5.3.3 then puts the `#0` read in the inactive region of
//       the same time, by which point the active region has been drained and
//       the new value is visible.
//
//! lrm 8.5.3.1
//! lrm 8.5.3.3 (the `#0` inactive-region sampling idiom used to read settled values)
//! timescale 1ns/1ns
//
// Hand derivation (y = sel ? a : b):
//   t=0  a=0, b=1, sel=0            -> expression = b = 1, update queued
//   t=1  active   : drained         -> y = 1
//   t=1  sel:=1   (blocking)        -> expression becomes a = 0, update QUEUED
//   t=1  same active region         -> y still 1   (claim (b))
//   t=1  inactive (#0)              -> y = 0
//   t=2  b:=0                       -> expression = a = 0, unchanged -> y = 0
//   t=3  a:=1                       -> expression = a = 1            -> y = 1 (claim (a))
//
// This fixture is the one member of the D06 set that the compiler is expected
// to PASS today; it exists so the already-shipped behaviour has evidence.

`timescale 1ns/1ns
module cont_assign_reeval;
  reg a, b, sel;
  wire y;

  assign y = sel ? a : b;

  initial begin
    a = 1'b0; b = 1'b1; sel = 1'b0;
    #1 $display("t1 y=%b", y);
    sel = 1'b1;
    $display("t1-stale y=%b", y);
    #0 $display("t1-settled y=%b", y);
    #1 b = 1'b0;
    #0 $display("t2 y=%b", y);
    #1 a = 1'b1;
    #0 $display("t3 y=%b", y);
    $finish(0);
  end
endmodule
