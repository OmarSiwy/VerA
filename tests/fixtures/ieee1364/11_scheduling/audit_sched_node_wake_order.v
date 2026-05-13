// IEEE1364-2005 §11.4.2: "active events can be taken off the queue and
// processed in any order", so the LRM would also accept an empty
// transcript here. VerA pins one order: the static schedule runs an
// `always @*` as a levelized node, yet it still wakes it after an event
// control that suspended before it, as `vera --run` does.
// Time 0: the first initial suspends at @(posedge a). a = 0 is no posedge;
// it wakes the always block, which sets y = 0 and suspends again, after
// the first initial. Time 1: a rises. The first initial resumes first and
// suspends at @(y); the always block then sets y = 1, which wakes it:
// "saw y=1 at 1".
//! inherited IEEE 1364-2005 11.4.2
module audit_sched_node_wake_order;
  reg a, y;
  initial @(posedge a) @(y) $display("saw y=%b at %0d", y, $time);
  always @* y = a;
  initial begin
    a = 0;
    #1 a = 1;
    #1 $finish(0);
  end
endmodule
