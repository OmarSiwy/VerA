// IEEE 1364-2005 §9.7.3: An event-array dimension takes an expression index, not a range.
// Legal neighbor: b_9_7_3_event_arrays.v triggers/waits on selected elements.
// digital-runner: reject
//! inherited IEEE 1364-2005 9.7.3
//! reject E1100
//! reject an index, not a part-select
//! neighbour b_9_7_3_event_arrays.v
module event_array_part_select_rejected;
  event e[0:1]; initial -> e[1:0];
endmodule
