// Exercise: swap with blocking assignments, through a temporary.
module swap_tmp;
  reg [3:0] a, b, t;
  initial begin
    a = 1; b = 2;
    t = a;
    a = b;
    b = t;
    $display("a = %0d, b = %0d", a, b);
  end
endmodule
