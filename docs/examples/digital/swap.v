// Blocking and nonblocking assignment (IEEE 1364-2005 §9.2.1, §9.2.2).
// a = b; b = a; runs in order: a takes 2, then b takes a's new value, 2.
// c <= d; d <= c; reads both right-hand sides first and updates later, so
// the two values swap: c = 2, d = 1.
module swap;
  reg [3:0] a, b, c, d;
  initial begin
    a = 1; b = 2;
    a = b;
    b = a;
    c = 1; d = 2;
    c <= d;
    d <= c;
    #1 $display("blocking: a = %0d, b = %0d    nonblocking: c = %0d, d = %0d", a, b, c, d);
  end
endmodule
