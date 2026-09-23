// IEEE1364-2005 9.7.6 Syntax9-11 requires an expression inside wait(...).
// Only the missing expression is invalid; a matching flag expression control
// runs and prints ready. Diagnostic must identify the expression syntax error.
// digital-runner: reject
//! lrm A.6.5
//! inherited IEEE 1364-2005 9.7.6
//! reject E0209
//! reject expected an expression
module audit_sched_wait_empty_rejected;
  reg flag;
  initial begin
    flag = 1;
    wait () $display("ready");
    $finish(0);
  end
endmodule
