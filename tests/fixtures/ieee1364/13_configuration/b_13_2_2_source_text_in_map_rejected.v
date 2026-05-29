// IEEE 1364-2005 §13.2.2, p. 202: "The syntax of a lib.map file is limited to
// library specifications, include statements, and standard Verilog comment
// syntax."
//
// libmap/bad/source_text.map declares a library and then a module. Legal
// neighbour: b_13_2_2_include_map.v, a map of an include statement and a
// comment.
// digital-runner: reject
// digital-runner: --libmap libmap/bad/source_text.map
//! inherited IEEE 1364-2005 13.2.2
//! reject E0244
//! reject found `module`
module top;
endmodule
