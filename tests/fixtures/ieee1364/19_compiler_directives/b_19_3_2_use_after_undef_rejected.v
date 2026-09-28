// IEEE 1364-2005 §19.3.2, p. 352: "The directive `undef shall undefine a
// previously defined text macro." ... "An undefined text macro has no value,
// just as if it had never been defined."
//
// `w is defined, undefined, then used: it names no macro, as a name never
// defined does (b_19_use_before_define_rejected.v). Legal neighbour:
// b_19_3_2_undef.v, which reads `width only while it is defined.
// digital-runner: reject
//! inherited IEEE 1364-2005 19.3.2
//! reject E0115
//! reject undefined macro
`define w 8
`undef w
module b_19_3_2_use_after_undef_rejected;
  initial $display("%0d", `w);
endmodule
