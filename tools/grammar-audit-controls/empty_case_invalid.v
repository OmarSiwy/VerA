// IEEE/AMS A.6.7 require at least one case_item, unlike empty begin/end.
module empty_case_invalid;
  initial begin
    case (1) endcase
    $display("accepted empty case");
    $finish(0);
  end
endmodule
