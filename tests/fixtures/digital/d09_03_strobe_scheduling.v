// §9.4.1, first rule: "$strobe provides the ability to display simulation data
// when the simulator has converged on a solution for all nodes." In the
// digital context the inherited IEEE 1364-2005 §17.1 wording for the same task
// is that the arguments are sampled and printed at the END of the current time
// step, after every other event in that step has been processed — which in the
// §5.4 region ordering means AFTER the nonblocking assign update region. That
// is what makes $strobe different from $display, whose §9.4.1 description
// ("The $display task provides the same capabilities as $strobe") is about
// FORMATTING, not about when it runs; $display prints where it stands.
//
// The existing runner already implements the region ordering this file leans
// on — tests/digital/scheduling.v pins that a nonblocking assignment made at
// t=0 is not visible to a $display in the same active region, and only becomes
// visible after a `#0`. So the ONLY new claim here is the scheduling of the
// sampling point of $strobe itself, which is the 17.1 row's "strobe/monitor
// scheduling, argument sampling" clause.
//
// HAND DERIVATION, time step t=0:
//   active region, in source order
//     a = 4'b0001            -> a is 0001
//     a <= 4'b0010           -> queues an NBA update of a to 0010
//     $display("display %b") -> prints the CURRENT a: "display 0001"
//     $strobe ("strobe %b")  -> queues a strobe; samples NOTHING yet
//     a = 4'b0100            -> a is 0100
//     $display("after %b")   -> prints the CURRENT a: "after 0100"
//   NBA update region
//     a <- 0010              (the blocking 0100 written after the <= is
//                             overwritten; §5.4 applies the queued update
//                             unconditionally)
//   postponed region
//     the queued strobe samples a NOW = 0010 -> "strobe 0010"
//
//   so the transcript order for t=0 is
//     display 0001 / after 0100 / strobe 0010
//   and the strobe line is printed LAST even though it was called SECOND.
//   A printer that evaluates $strobe eagerly prints "strobe 0001" in second
//   place; a printer that merely defers the OUTPUT without deferring the
//   SAMPLING prints "strobe 0001" in third place. Both fail here, and the two
//   failures are distinguishable, which is why the value 0001/0100/0010 are
//   three different patterns.
//
// HAND DERIVATION, time step t=1:
//   a = 4'b1000            -> a is 1000
//   $strobe("s1 %b", a)    -> queues strobe #1
//   $strobe("s2 %b", a)    -> queues strobe #2
//   a = 4'b1001            -> a is 1001
//   end of step: both queued strobes sample a = 1001 and print in CALL order
//     s1 1001
//     s2 1001
//   This is the "two $strobe calls in one time step" case: neither is dropped
//   (a single-slot strobe register would print only "s2 1001"), both see the
//   final settled value, and the order is the order of the calls and not the
//   reverse.
//
// t=2 runs only $finish(0), which per docs/digital-source-execution.md is
// silent, so it contributes no line.
//
//! lrm 9.4.1
//! inherited IEEE 1364-2005 17.1 ($strobe end-of-time-step sampling)
//! expect stdout 03_strobe_scheduling.expected.txt
`timescale 1ns/1ns
module d09_strobe_scheduling;
  reg [3:0] a;
  initial begin
    a = 4'b0001;
    a <= 4'b0010;
    $display("display %b", a);
    $strobe("strobe %b", a);
    a = 4'b0100;
    $display("after %b", a);
    #1;
    a = 4'b1000;
    $strobe("s1 %b", a);
    $strobe("s2 %b", a);
    a = 4'b1001;
    #1 $finish(0);
  end
endmodule
