// Legal one-expression neighbor of audit_sched_wait_empty_rejected.v.
module audit_sched_wait_empty_rejected;
  reg flag;
  initial begin
    flag = 1;
    wait (flag) $display("ready");
    $finish(0);
  end
endmodule
