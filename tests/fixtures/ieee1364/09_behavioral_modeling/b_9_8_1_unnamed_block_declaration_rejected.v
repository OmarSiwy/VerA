// IEEE 1364-2005 §9.8.1, p. 140 (Syntax 9-13): "seq_block ::= begin [ :
// block_identifier { block_item_declaration } ] { statement } end".
// §9.8.3, pp. 141-142: "Both sequential and parallel blocks can be named by adding
// : name_of_block after the keywords begin or fork. The naming of blocks serves
// several purposes: — It allows local variables, parameters, and named events
// to be declared for the block."
//
// A block_item_declaration can follow only `: block_identifier`; here `reg r;`
// opens an unnamed begin-end block. Legal neighbour:
// b_9_8_3_named_block_variables.v declares integer count in `begin : acc`.
// digital-runner: reject
//! inherited IEEE 1364-2005 9.8.1 9.8.3
//! reject E0209
//! reject found `reg`
//! neighbour b_9_8_3_named_block_variables.v
module b_9_8_1_unnamed_block_declaration_rejected;
  initial begin
    reg r;
    r = 1'b1;
  end
endmodule
