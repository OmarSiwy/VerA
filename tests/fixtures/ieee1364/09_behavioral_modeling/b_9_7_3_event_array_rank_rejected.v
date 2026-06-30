// IEEE 1364-2005 §9.7.3: An event-array trigger must select one index per dimension.
// Legal neighbor: b_9_7_3_event_arrays.v triggers/waits on selected elements.
// digital-runner: reject
//! inherited IEEE 1364-2005 9.7.3
//! reject E1100
//! reject one index per dimension
module event_array_rank_rejected;
  event e[0:1][2:3]; initial -> e[0];
endmodule
