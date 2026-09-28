// An engine limit, not a language rule. IEEE 1364-2005 §12.4.1 unrolls a loop
// generate at elaboration and bounds nothing about the count. The digital
// runner gives up after 65536 iterations (docs/IMPLEMENTATION.md) with E1100,
// which is also what a loop that never ends meets. This one never ends.
// digital-runner: reject
//! reject E1100
//! reject does not terminate within 65536 iterations
module b_12_generate_past_65536_iterations_rejected;
  genvar i;
  generate for (i = 0; i >= 0; i = i + 1) begin : g end endgenerate
  initial $display("accepted");
endmodule
