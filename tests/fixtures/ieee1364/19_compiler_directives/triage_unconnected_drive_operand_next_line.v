//! inherited IEEE 1364-2005 19.9
// `unconnected_drive's pull1 operand may be on the next line; the unconnected
// input port of u is then pulled high (br_gh782c).
`unconnected_drive
pull1
module triage_unconnected_drive_operand_next_line;
  leaf u();
endmodule
`nounconnected_drive

module leaf(in);
  input in;

  initial #1 if (in === 1'b1) $display("PASSED"); else $display("FAILED %b", in);
endmodule
