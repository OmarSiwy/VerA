// IEEE17.4.1 legal verbosity2 requires time/location and resource statistics.
// Observation control only: host-dependent diagnostic bytes have no golden.
module finish_statistics;
  initial begin
    $display("before");
    $finish(2);
    $display("after");
  end
endmodule
