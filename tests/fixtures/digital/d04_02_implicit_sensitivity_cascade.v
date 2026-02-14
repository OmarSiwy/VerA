// A.6.5 `event_control ::= ... | @* | @ (*)`, the companion to fixture 01.
//
// 01 exercises RHS membership. This one pins propagation: the write is an
// ordinary variable update, so it triggers the OTHER block whose inferred
// list does contain that name. Two `@*` blocks therefore chain, and the chain
// settles inside one timestep, with no delay between the stages.
//
// This does not isolate write-only LHS exclusion. A running process is not
// waiting on its own event control, and an unchanged write is not a change
// event. That stronger former claim moves to ISENS-003 and the independent
// destination-poke witness audit_sched_implicit_write_only.v.
//
// HAND DERIVATION — q = x and r = q.
//   t=0   x<-0011 (leaves x, both blocks' names change)   q = 0011, r = 0011
//   t=1   display                                         "stage 0011 0011"
//         x<-1100                                         q = 1100, r = 1100
//   t=2   display                                         "moved 1100 1100"
//         x<-0101                                         q = 0101, r = 0101
//   t=3   display                                         "again 0101 0101"
//
// A cascade that needs a second timestep per stage prints "moved 1100 0011".
// A cascade that never propagates past the first stage prints "moved 1100 xxxx".
//
//! lrm A.6.5
//! lrm 1.2
//! timescale 1ns/1ps
`timescale 1ns/1ps
module d04_implicit_sensitivity_cascade;
  reg [3:0] x, q, r;

  always @* q = x;
  always @* r = q;

  initial begin
    x = 4'b0011;
    #1 $display("stage %b %b", q, r);
    x = 4'b1100;
    #1 $display("moved %b %b", q, r);
    x = 4'b0101;
    #1 $display("again %b %b", q, r);
    $finish(0);
  end
endmodule
