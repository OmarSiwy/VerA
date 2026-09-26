// N 32-bit Fibonacci LFSRs in a chain, each stage XORing in its predecessor's
// previous value, clocked for CYCLES rising edges. One checksum line.
module lfsr_chain;
  parameter N = 64;
  parameter CYCLES = 1000;
  reg clk;
  reg [31:0] r [0:N-1];
  reg [31:0] prev, t, sum;
  integer i;
  always @(posedge clk) begin
    prev = 32'hACE1;
    for (i = 0; i < N; i = i + 1) begin
      t = r[i];
      r[i] <= {t[30:0], t[31] ^ t[21] ^ t[1] ^ t[0]} ^ prev;
      prev = t;
    end
  end
  initial begin
    for (i = 0; i < N; i = i + 1) r[i] = i + 1;
    clk = 0;
    repeat (2 * CYCLES) #1 clk = ~clk;
    #1 sum = 0;
    for (i = 0; i < N; i = i + 1) sum = sum ^ r[i];
    $display("lfsr_chain N=%0d CYCLES=%0d checksum=%h", N, CYCLES, sum);
    $finish(0);
  end
endmodule
