// IEEE 1364-2005 §13.2.2, p. 202: "The syntax of a lib.map file is limited to
// library specifications, include statements, and standard Verilog comment
// syntax." Against it, A.1.1 / Syntax 13-2 derive `library_description ::=
// ... | config_declaration`. The prose is the specific statement about map
// files; the grammar box also serves library_text in general, and §13.3
// places configs in source text (Vague_Decisions VD-039).
//
// libmap/bad/config_in_map.map declares a library and then a config. Legal
// neighbours: b_13_2_2_include_map.v (a map of an include statement and a
// comment) and audit_config_design_select.v (the same config in source text).
// digital-runner: reject
// digital-runner: --libmap libmap/bad/config_in_map.map
//! inherited IEEE 1364-2005 13.2.2
//! reject E0244
//! reject found `config`
module top;
endmodule
