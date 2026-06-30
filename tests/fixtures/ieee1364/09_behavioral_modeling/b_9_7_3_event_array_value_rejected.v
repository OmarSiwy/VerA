// IEEE 1364-2005 §9.7.3: An event holds no data and cannot be read as an integer.
// Legal neighbor: b_9_7_3_event_arrays.v triggers/waits on selected elements.
// digital-runner: reject
//! inherited IEEE 1364-2005 9.7.3
//! reject E1100
//! reject holds no data; it can only be triggered and waited on
module event_array_value_rejected;
  event e[0:1]; integer n; initial n = e[0];
endmodule
