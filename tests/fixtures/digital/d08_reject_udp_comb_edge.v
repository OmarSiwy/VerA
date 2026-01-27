// D08 — REJECT: an edge descriptor in a COMBINATIONAL UDP table.
//
// Verilog-AMS 2.4 Annex A.5.3 splits the two bodies at the top and never lets
// them mix:
//
//     udp_body ::= combinational_body | sequential_body
//     combinational_body ::= table combinational_entry { combinational_entry }
//         endtable
//     combinational_entry ::= level_input_list : output_symbol ;
//     level_input_list ::= level_symbol { level_symbol }
//     level_symbol ::= 0 | 1 | x | X | ? | b | B
//
// A combinational entry's inputs are a `level_input_list`, and `level_symbol`
// contains no edge alternative; `edge_indicator` and `edge_symbol` appear only
// under `edge_input_list`, which only a `sequential_entry` can reach. `(01)`
// below therefore derives from no production of `combinational_body`.
//
// The grammar is stating a semantic impossibility, which is why this is worth a
// fixture rather than a parser footnote: an edge is a statement about the
// PREVIOUS value of an input, and a combinational UDP has no previous value to
// compare against. This primitive also has no `output reg` and no
// `current_state` column, so there is nowhere for that history to live even if
// the entry were read. A compiler that accepts the edge here has either
// silently promoted the primitive to sequential — inventing state the source
// never declared — or is matching `(01)` as if it were a level, which would
// make the first entry fire on a steady a=0 and change the function.
//
// Every other part is well formed: A.5.2's port order (output first, inputs
// after), a two-input table, legal `output_symbol`s. The edge descriptor is the
// only defect.
//
// WHAT THE DIRECTIVES DEMAND, AND WHY THEY ARE NOT `DiagnosticsReported`.
// This file carried `//! reject DiagnosticsReported` until review. That label
// matches ANY diagnostic (`tests/torture.zig:223`), so once `primitive` parses,
// a UDP parser that tripped over the port list or over `?` would satisfy it
// without ever having looked at `(01)`. Worse for this fixture specifically: an
// implementation that landed SEQUENTIAL UDPs first and refused combinational
// bodies wholesale would have passed too — the exact opposite of the rule being
// tested, since the rule presupposes that a combinational body is legal.
//
// The two lines below are a CONJUNCTION — `verifyRejected`
// (torture.zig:142-150) fails the fixture unless every `//! reject` line
// matches — and a non-code pattern is matched against each diagnostic's
// message, caret label, notes and catalogue title (torture.zig:235-243). The
// refusal must therefore name BOTH halves of A.5.3's split: that the body is
// `combinational`, and that the offending construct is an `edge`. "Combinational
// UDPs are not supported" satisfies the first and not the second; a generic
// parse error satisfies neither.
//
// No `E0xxx` is written, and that is deliberate rather than lazy:
// `lib/diag_code.zig` has no code for a UDP table shape violation today, and a
// fixtures-only row may not mint one in `src/`. Prose is the weaker of the two
// forms the runner accepts — it pins wording, where a code pins the rule
// (torture.zig:248-252). Whoever implements UDPs should allocate the code for
// "edge indicator in a combinational UDP body" and replace these two lines with
// it. Replace, not delete: a bare `DiagnosticsReported` must not come back.
//
//! lrm A.5.3
//! reject combinational
//! reject edge
`timescale 1ns/1ns

primitive udp_bad_edge (o, a, b);
  output o;
  input  a, b;
  table
  //  a     b  :  o
     (01)   0  :  1  ;
      ?     ?  :  0  ;
  endtable
endprimitive

module d08_reject_udp_comb_edge;
  reg  a, b;
  wire o;

  udp_bad_edge u1 (o, a, b);

  initial begin
    a = 1'b0; b = 1'b0; #1
    a = 1'b1; #1
      $display("unreachable got o=%b", o);
  end
endmodule
