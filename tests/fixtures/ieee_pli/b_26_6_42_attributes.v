// b_26_6_42_attributes.c's design: one attribute on the module definition,
// one on a net declaration (IEEE 1364-2005 §3.8).
(* mod_attr = 1 *)
module b26_attributes;
  (* net_attr = "on" *) wire w;
  reg r;
  assign w = r;
  initial begin
    r = 0;
    #1 $finish(0);
  end
endmodule
