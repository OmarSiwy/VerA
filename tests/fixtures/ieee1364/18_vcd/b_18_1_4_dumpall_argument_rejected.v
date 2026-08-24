// IEEE 1364-2005 §18.1.4, p. 328, Syntax 18-5:
//   dumpall_task ::= $dumpall ;
// A checkpoint is of "all selected variables" (the $dumpvars selection), so
// the task takes no argument naming one; `$dumpall(v)` is no dumpall_task.
// Legal neighbour: the bare $dumpall of b_18_2_4_example_value_changes.v.
// digital-runner: reject
//! inherited IEEE 1364-2005 18.1.4
//! reject E1100
//! reject $dumpoff, $dumpon, $dumpall and $dumpflush take no arguments
//! neighbour b_18_2_4_example_value_changes.v
`timescale 1ns/1ns
module b_18_1_4_dumpall_argument_rejected;
  reg a;
  reg [7:0] v;
  initial begin
    $dumpvars(0, b_18_1_4_dumpall_argument_rejected);
    $dumpall(v);
    a = 1'b0;
    v = 8'h00;
    #1 a = 1'b1;
  end
endmodule
