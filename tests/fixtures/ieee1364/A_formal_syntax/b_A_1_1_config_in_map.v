// IEEE 1364-2005 A.1.1, p. 487:
//   library_text ::= { library_description }
//   library_description ::=
//       library_declaration
//     | include_statement
//     | config_declaration
//   library_declaration ::=
//       library library_identifier file_path_spec [ { , file_path_spec } ]
//       [ -incdir file_path_spec { , file_path_spec } ] ;
//   include_statement ::= include file_path_spec ;
//
// a11/config.map holds the library_declaration `library liba cells/a.v;`
// and a config_declaration (A.1.5) that names this file's top as its design
// and liba as its default liblist. Whether or not a tool binds through cfg,
// u1's cell a is found in liba (the map's only library, §13.5.1; the
// liblist's only library, §13.3.1.5) and top matches no file_path_spec, so
// is work's (§13.2.1):
//   t=0 top work.top; t=1 top.u1 liba.a.
// digital-runner: --libmap a11/config.map
// digital-runner: files a11/cells/a.v
//! inherited IEEE 1364-2005 A.1.1
//! xfail VerA's library map reader refuses a config_declaration (E0244 "a library map holds `library` and `include` statements only")
`timescale 1ns/1ns
module top;
  a #(1) u1();
  initial $display("%m %l");
endmodule
