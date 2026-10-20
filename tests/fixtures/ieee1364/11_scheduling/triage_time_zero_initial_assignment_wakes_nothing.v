//! inherited IEEE 1364-2005 11.4
// VerA's documented time-0 order (VD): initial values are settled before
// always/@* processes wait, so an initial block's time-0 assignment wakes no
// always process (br948).
module triage_time_zero_initial_assignment_wakes_nothing;
  reg r;
  reg woke;

  always @(r) woke = 1'b1;

  initial begin
    woke = 1'b0;
    r = 1'b1;
    #1 if (woke === 1'b0) $display("PASSED"); else $display("FAILED");
  end
endmodule
