// IEEE 1364-2005 §5.2.1 permits a variable base but requires a constant
// width. A variable with value four is still not a constant expression.
// native_indexed_selects.v supplies the legal runtime-base neighbour.
//! inherited IEEE 1364-2005 5.2.1
//! reject constant expression
module native_select_variable_width_rejected;
  reg [7:0] v;
  integer w;
  initial begin w = 4; $display("%b", v[0 +: w]); end
endmodule
