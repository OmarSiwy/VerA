// IEEE 1364-2005 §9.7.3: A named event has no value on which to detect a rising edge.
// Legal neighbor: b_9_7_3_event_arrays.v triggers/waits on selected elements.
// digital-runner: reject
//! inherited IEEE 1364-2005 9.7.3
//! reject E1100
//! reject has no value for a posedge or negedge
module event_array_posedge_rejected;
  event e[0:1]; initial @(posedge e[0]) $finish(0);
endmodule
