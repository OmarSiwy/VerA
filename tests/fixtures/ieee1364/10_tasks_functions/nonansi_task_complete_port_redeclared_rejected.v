// A port with an explicit variable type is already completely declared.
// digital-runner: reject
// digital-runner: --std=1364-2005
//! inherited IEEE 1364-2005 10.2.1 12.3.3
//! reject-only duplicate
//! neighbour nonansi_task_port_completion.v
//! xfail A fully typed non-ANSI task port can incorrectly be redeclared with another type.
module nonansi_task_complete_port_redeclared_rejected;
  task t;
    input real x;
    integer x;
    $display("invalid task accepted");
  endtask
  initial t(1);
endmodule
