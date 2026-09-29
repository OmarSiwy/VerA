// IEEE 1364-2005 A.1.1, p. 487:
//   include_statement ::= include file_path_spec ;
//
// a11/bad/include_no_spec.map writes `include ;`: the file_path_spec is
// missing, so no include_statement derives it. The refusal says so.
// Legal neighbour: b_A_1_1_library_text.v, whose a11/lib.map writes
// `include more.map;`.
// digital-runner: reject
// digital-runner: --libmap a11/bad/include_no_spec.map
//! inherited IEEE 1364-2005 A.1.1
//! reject E0244
//! reject `include` names no file_path_spec
module top;
endmodule
