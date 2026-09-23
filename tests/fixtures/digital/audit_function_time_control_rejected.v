// IEEE1364-2005 10.4.4, printed155: Function time controls are forbidden even when the result could be computed.
// Legal-context control: audit_function_return_variable.v.
// The reject phrase below is an INTENDED rule-specific diagnostic, not an
// observed current diagnostic. Generic unsupported-declaration rejection
// cannot establish this rule; the paired legal control must execute too.
// digital-runner: reject
//! lrm 1.1
//! inherited IEEE 1364-2005 10.4.4
//! reject function body cannot contain a time control
module audit_function_time_control_rejected;
  function f(input a); begin #1; f=a; end endfunction
  reg r;
  initial r=f(1'b1);
endmodule
