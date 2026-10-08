// IEEE 1364-2005 §13.7.1, p. 209: "This mechanism shall include specification
// of library names only, with the definitions of these libraries to be taken
// from the library map file."
//
// `-L nosuch` names a library the §13.5 map (ex13_5/lib.map) does not
// declare, so there is no definition to take. Legal neighbour:
// b_13_7_1_command_line_search_order.v, `-L gateLib -L rtlLib`.
// digital-runner: reject
// digital-runner: --libmap ex13_5/lib.map
// digital-runner: files ex13_5/top.v ex13_5/adder.v ex13_5/adder.vg
// digital-runner: -L nosuch
//! inherited IEEE 1364-2005 13.7.1
//! reject E0244
//! reject no library map declares library `nosuch`
//! neighbour b_13_7_1_command_line_search_order.v
