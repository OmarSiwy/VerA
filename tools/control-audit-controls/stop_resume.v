// IEEE17.4.2 suspension is not termination. Requires interactive host resume;
// not an ordinary transcript fixture. Invoke under a timeout for diagnosis.
module stop_resume;
  initial begin
    $display("before");
    $stop(0);
    $display("after resume");
    $finish(0);
  end
endmodule
