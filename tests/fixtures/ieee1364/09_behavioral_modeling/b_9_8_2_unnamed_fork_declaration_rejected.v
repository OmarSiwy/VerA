// IEEE 1364-2005 §9.8.2, p. 141 (Syntax 9-14): "par_block ::= fork [ :
// block_identifier { block_item_declaration } ] { statement } join".
// §9.8.3, pp. 141-142: "Both sequential and parallel blocks can be named by adding
// : name_of_block after the keywords begin or fork. The naming of blocks serves
// several purposes: — It allows local variables, parameters, and named events
// to be declared for the block."
//
// A block_item_declaration can follow only `: block_identifier`; here `reg r;`
// opens an unnamed fork-join block. Legal neighbour:
// b_9_8_3_named_fork_declarations.v declares reg v in `fork : par` (an xfail:
// VerA refuses that legal form with the same parse error, so this refusal is
// not evidence that VerA distinguishes the two).
// digital-runner: reject
//! inherited IEEE 1364-2005 9.8.2 9.8.3
//! reject E0209
//! reject found `reg`
module b_9_8_2_unnamed_fork_declaration_rejected;
  initial fork
    reg r;
    r = 1'b1;
  join
endmodule
