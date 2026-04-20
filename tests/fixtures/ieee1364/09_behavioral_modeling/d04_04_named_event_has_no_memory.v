// §5.10, the list of what an event IS:
//
//     — events have no time duration
//     — events can be triggered and detected in different parts of the model
//     — events do not block the execution of an analog block
//     — events can be detected using the @ operator
//     — events do not hold any data
//
// "No time duration" and "do not hold any data" together say a named event is
// not a flag. A `-> e` that happens when no process is waiting on `e` is gone;
// a `@(e)` reached afterwards waits for the NEXT trigger, not for the one that
// already passed. This is the rule a "set a bit, test the bit" implementation
// gets wrong, and it is worth its own fixture because that implementation is
// exactly what the analog side of VerA does today (lower.zig writes the event's
// flag slot at `->` and reads it at `@`) — correct for a single-pass analog
// block, wrong for two suspendable digital processes.
//
// HAND DERIVATION — the trigger is deliberately EARLY.
//   t=0   arm:    r<-0011, then delays to t=2
//         late:   delays to t=5
//   t=1   fire:   -> e      nobody is waiting; the event is discarded
//   t=2   arm:    prints "armed 0011", then blocks at @(e) forever
//   t=5   late:   prints "end 0011" and finishes; `arm` never resumes
//
// So the transcript has exactly two lines and does NOT contain "resumed". A
// latched event prints a third line, "resumed 0011", between them.
//
// r is printed only to keep both lines value-bearing; the assertion is the
// PRESENCE and ORDER of the lines.
//
//! lrm 5.10
//! lrm 5.10.4
//! lrm A.6.5
//! timescale 1ns/1ps
`timescale 1ns/1ps
module d04_named_event_has_no_memory;
  event e;
  reg [3:0] r;

  initial begin
    #1 -> e;
  end

  initial begin
    r = 4'b0011;
    #2 $display("armed %b", r);
    @(e) $display("resumed %b", r);
  end

  initial begin
    #5 $display("end %b", r);
    $finish(0);
  end
endmodule
