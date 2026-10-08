// IEEE 1364-2005 §14.1: a specify block is "used to declare paths across a
// module and assign delays to those paths", and §15.1: "Timing checks can be
// placed in specify blocks to verify the timing performance of a design".
//
// VerA reads the block (A.7) and exposes it to VPI. A digital run evaluates
// its timing checks (§15) and applies none of its path delays (the §14
// clauses that describe simulation are not-supported in CLAUSES.tsv), so the
// block draws one W0251, for the path: a design that relies on a delay must
// be told. The checks are run, not named: W0251 lists them only in an analog
// compile, which evaluates none.
//
// The run stays inside both limits, so the checks report nothing (no W1199),
// and the transcript is the same as a simulator's that applies the path:
//   d = 1 at t = 0; clk rises at t = 5: setup 5 - 0 >= 2 is met;
//   d holds until t = 10: hold 10 - 5 >= 1 is met.
//   q takes d = 1 at t = 5, or at 5 + 3 = 8 under the (clk => q) path delay
//   VerA does not apply; either way t = 9 prints q=1.
// digital-runner: warning W0251
// digital-runner: warning path delays
//! inherited IEEE 1364-2005 14.1
//! expect stdout specify_timing_checks_named_by_w0251.expected.txt
module specify_timing_checks_named_by_w0251_ff(clk, d, q);
  input clk, d;
  output q;
  reg q;
  always @(posedge clk) q <= d;
  specify
    (clk => q) = 3;
    $setup(d, posedge clk, 2);
    $hold(posedge clk, d, 1);
  endspecify
endmodule

module specify_timing_checks_named_by_w0251;
  reg clk, d;
  wire q;
  specify_timing_checks_named_by_w0251_ff u(clk, d, q);
  initial begin
    clk = 1'b0;
    d = 1'b1;
    #5 clk = 1'b1;
    #4 $display("t=9 q=%b", q);
    #1 d = 1'b0;
  end
endmodule
