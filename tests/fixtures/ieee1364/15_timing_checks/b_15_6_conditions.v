// IEEE 1364-2005 §15.6 (pp. 265-266): "Reference events and data events
// shall only be detected by timing checks when their associated conditions
// are true" (§15.1). "The comparisons used in the condition can be
// deterministic, as in ===, !==, ~, or no operation, or nondeterministic, as
// in == or !=. When comparisons are deterministic, an x value on the
// conditioning signal shall not enable the timing check. For
// nondeterministic comparisons, an x on the conditioning signal shall enable
// the timing check." "The conditioning signal shall be a scalar net; if a
// vector net or an expression resulting in a multibit value is used, then
// the least significant bit of the vector net or the expression value is
// used." Syntax 15-16: `&&& expression`, `&&& ~ expression`, and expression
// `==`, `===`, `!=`, `!==` a scalar_constant.
//
// The cell: seven copies of $setup(d, posedge clk &&& <cond>, 5, <n>), each
// notifier 0 from t=1, the conditions:
//   plain: en        inv: ~en          ceq: en === 1'b1   eq: en == 1'b1
//   neq: en != 1'b0  cneq: en !== 1'b0  vec: bus (2 bits)
// Three times a data event at T-2 is followed by clk rising at T, which
// violates (T-5, T) wherever the condition lets the reference event be seen:
//   T=12, en = x (never assigned yet), bus = 2'b10:
//     deterministic forms see x and do not detect it: plain, inv, ceq, cneq
//     stay 0; nondeterministic forms do: eq and neq toggle to 1. vec reads
//     bus's least significant bit, 0: stays 0.
//   T=22, en = 1, bus = 2'b10: plain (1), ceq (1 === 1), eq (1 == 1), neq
//     (1 != 0), cneq (1 !== 0) toggle; inv (~1 = 0) does not; vec's bit 0 is
//     still 0, so it does not, though bus as a whole is nonzero.
//   T=32, en = 0, bus = 2'b01: inv (~0 = 1) toggles; plain, ceq, eq, neq and
//     cneq see a false condition; vec's bit 0 is 1: it toggles.
// So at t=14, 24 and 34:
//   plain 0 1 1, inv 0 0 1, ceq 0 1 1, eq 1 0 0, neq 1 0 0, cneq 0 1 1,
//   vec 0 0 1.
//! inherited IEEE 1364-2005 15.6
`timescale 1ns/1ns
module b_15_6_conditions_ff(clk, d, en, bus);
  input clk, d, en;
  input [1:0] bus;
  reg n_plain, n_inv, n_ceq, n_eq, n_neq, n_cneq, n_vec;
  initial #1 begin
    n_plain = 0; n_inv = 0; n_ceq = 0; n_eq = 0;
    n_neq = 0; n_cneq = 0; n_vec = 0;
  end
  specify
    $setup(d, posedge clk &&& en, 5, n_plain);
    $setup(d, posedge clk &&& ~en, 5, n_inv);
    $setup(d, posedge clk &&& (en === 1'b1), 5, n_ceq);
    $setup(d, posedge clk &&& (en == 1'b1), 5, n_eq);
    $setup(d, posedge clk &&& (en != 1'b0), 5, n_neq);
    $setup(d, posedge clk &&& (en !== 1'b0), 5, n_cneq);
    $setup(d, posedge clk &&& bus, 5, n_vec);
  endspecify
endmodule

module b_15_6_conditions;
  reg clk, d, en;
  reg [1:0] bus;
  b_15_6_conditions_ff u(clk, d, en, bus);
  task show;
    $display("t=%0d plain=%b inv=%b ceq=%b eq=%b neq=%b cneq=%b vec=%b", $time,
             u.n_plain, u.n_inv, u.n_ceq, u.n_eq, u.n_neq, u.n_cneq, u.n_vec);
  endtask
  initial begin
    clk = 0; d = 0; bus = 2'b10;
    #10 d = 1;
    #2 clk = 1;
    #2 show;
    #1 clk = 0;
    #3 en = 1;
    #2 d = 0;
    #2 clk = 1;
    #2 show;
    #1 clk = 0;
    #3 en = 0; bus = 2'b01;
    #2 d = 1;
    #2 clk = 1;
    #2 show;
    $finish(0);
  end
endmodule
