// IEEE 1364-2005 §8.1.2: "Implementations may limit the maximum number of
// inputs to a UDP, but they shall allow at least 9 inputs for sequential UDPs
// and 10 inputs for combinational UDPs." VerA's limit is 64 inputs
// (docs/Vague_Decisions.md), sequential or combinational. This one has 65, and
// the limit is refused at the declaration with the code that names it (E1017),
// not as a symbol outside the column's alphabet (E0233).
// b_8_1_2_input_minimums.v pins the minimums the clause requires, and
// b_8_1_2_sequential_64_inputs.v the limit itself.
// digital-runner: reject
//! inherited IEEE 1364-2005 8.1.2
//! reject E1017
primitive wide_and(q, i0, i1, i2, i3, i4, i5, i6, i7, i8, i9, i10, i11, i12, i13, i14, i15, i16, i17, i18, i19, i20, i21, i22, i23, i24, i25, i26, i27, i28, i29, i30, i31, i32, i33, i34, i35, i36, i37, i38, i39, i40, i41, i42, i43, i44, i45, i46, i47, i48, i49, i50, i51, i52, i53, i54, i55, i56, i57, i58, i59, i60, i61, i62, i63, i64);
  output q;
  input i0, i1, i2, i3, i4, i5, i6, i7, i8, i9, i10, i11, i12, i13, i14, i15, i16, i17, i18, i19, i20, i21, i22, i23, i24, i25, i26, i27, i28, i29, i30, i31, i32, i33, i34, i35, i36, i37, i38, i39, i40, i41, i42, i43, i44, i45, i46, i47, i48, i49, i50, i51, i52, i53, i54, i55, i56, i57, i58, i59, i60, i61, i62, i63, i64;
  table
    1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 : 1;
  endtable
endprimitive
module audit_definition;
  initial begin $display("definition accepted"); $finish(0); end
endmodule
