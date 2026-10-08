// IEEE 1364-2005 §13.1, p. 199: "From this module's source description, the
// instantiated modules (or children) are found, then the source descriptions
// for the module definitions of these subinstances shall be located, and so
// on until every instance in the design is mapped to a source description."
//
// top instantiates `absent`, and no module, primitive or config of that name
// is in the source, so the instance u cannot be mapped to a source
// description. Legal neighbour: b_13_1_every_instance_bound.v, whose every
// instance names a module the source declares.
// digital-runner: reject
//! inherited IEEE 1364-2005 13.1
//! reject E1100
//! reject undeclared module in instantiation
//! neighbour b_13_1_every_instance_bound.v
module top;
  absent u();
  initial $display("bound");
endmodule
