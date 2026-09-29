// AMS §2.6.2 forbids scaled digital delays even without a # token: A.7.4's
// path_delay_expression supplies a module path's delay. Legal neighbours:
// ieee1364/14_specify_blocks/b_14_3_path_delay_values.v and
// b_14_3_1_mintypmax_path_delays.v run with legal path values and pin W0251,
// which explicitly names the current absence of module-path execution.
// digital-runner: reject
//! lrm 2.6.2
//! reject E0247
module scaled_delay_path_rejected(input a, output y);
  buf g(y, a);
  specify
    (a => y) = 1u;
  endspecify
endmodule
