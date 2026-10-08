// IEEE 1364-2005 §19.9, p. 360: "The directive `unconnected_drive takes one
// of two arguments—pull1 or pull0."
//
// pull2 is neither. Legal neighbour: b_19_9_unconnected_drive.v uses pull1
// and pull0.
// digital-runner: reject
//! inherited IEEE 1364-2005 19.9
//! reject E0141
//! reject `unconnected_drive takes pull0 or pull1
//! neighbour b_19_9_unconnected_drive.v
`unconnected_drive pull2
module b_19_9_pull_value_rejected(input i);
  initial $display("accepted");
endmodule
`nounconnected_drive
