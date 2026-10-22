// Completing an untyped port once is legal; declaring the variable twice is not.
// digital-runner: reject
// digital-runner: --std=1364-2005
//! inherited IEEE 1364-2005 10.2.1 12.3.3
//! reject-only duplicate
//! neighbour nonansi_task_port_completion.v
//! xfail Duplicate non-ANSI task-port variables are accepted and executed.
module nonansi_task_duplicate_port_variable_rejected;
  task t;
    input x;
    reg x;
    reg x;
    $display("invalid task accepted");
  endtask
  initial t(1);
endmodule
