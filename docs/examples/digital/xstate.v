// Four-state values (IEEE 1364-2005 §4.1, §5.1). A reg nobody assigned
// holds x and an undriven wire holds z. Arithmetic on an x operand gives x
// in every bit, and comparing an x with == gives x, not 0 or 1.
module xstate;
  reg [3:0] r;
  wire [3:0] w;
  reg [3:0] s;
  initial begin
    s = r + 1;
    #1 $display("r = %b, w = %b, r + 1 = %b, r == 0 is %b", r, w, s, r == 0);
  end
endmodule
