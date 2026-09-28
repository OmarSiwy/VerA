// b_26_6_11_event_array.c's design: a named event array (IEEE 1364-2005
// §4.9, A.2.3 `event_identifier { dimension }`).
module b26_event_array;
  event eva [0:1];
  initial begin
    -> eva[1];
    #1 $finish(0);
  end
endmodule
