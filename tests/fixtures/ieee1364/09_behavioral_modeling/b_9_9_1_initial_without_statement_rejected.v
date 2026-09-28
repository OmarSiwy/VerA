// IEEE 1364-2005 §9.9.1, p. 143 (Syntax 9-15): "initial_construct ::= initial
// statement". A.6.4 (p. 498) keeps the null statement out of `statement`:
// "statement_or_null ::= statement | { attribute_instance } ;".
//
// `initial ;` gives the construct a null statement, which only
// statement_or_null derives. Legal neighbour: b_9_9_initial_and_always.v,
// whose initial constructs each carry a statement.
// digital-runner: reject
//! inherited IEEE 1364-2005 9.9.1
//! reject E0209
//! reject statement
//! xfail `initial ;` is accepted
module b_9_9_1_initial_without_statement_rejected;
  initial ;
endmodule
