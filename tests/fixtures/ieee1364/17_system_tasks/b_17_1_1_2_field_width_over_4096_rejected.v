// An engine limit, not a language rule. IEEE 1364-2005 §17.1.1.2 bounds no
// field width or precision. VerA composes one field whole and takes a width
// or precision up to 4096 (specification/Vague_Decisions.md), refusing a larger one with
// E1011, the analog side's code for the same bound. A width of 99999999999
// used to saturate at 2^32 and write 4 GiB of spaces.
//
// Legal neighbour: b_17_1_1_2_real_precision_100.v.
// digital-runner: reject
//! reject E1011
//! reject a field width or precision here exceeds 4096
//! neighbour b_17_1_1_2_real_precision_100.v
module b_17_1_1_2_field_width_over_4096_rejected;
  integer x;
  initial begin
    x = 1;
    $display("%99999999999d", x);
  end
endmodule
