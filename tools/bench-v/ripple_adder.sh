#!/usr/bin/env bash
# usage: ripple_adder.sh W VECTORS [gates] > ripple_adder.v
# A W-bit ripple-carry adder of W full-adder instances on scalar nets, so each
# vector ripples through W carry events, fed VECTORS LFSR operand pairs. One
# checksum line. Generated because VerA's digital path assigns whole nets only.
# `gates`: each full adder is five §7 gate primitives instead of two assigns,
# with the same checksum.
W=${1:-64} V=${2:-1000} G=${3:-}
awk -v W="$W" -v V="$V" -v G="$G" 'BEGIN {
  print "module fa(a, b, ci, s, co);\n  input a, b, ci;\n  output s, co;"
  if (G == "gates") print "  wire p, g, t;\n  xor x1(p, a, b), x2(s, p, ci);\n  and a1(g, a, b), a2(t, ci, p);\n  or o1(co, g, t);\nendmodule\n"
  else print "  assign s = a ^ b ^ ci;\n  assign co = (a & b) | (ci & (a ^ b));\nendmodule\n"
  print "module ripple_adder;\n  reg [" W-1 ":0] a, b;\n  reg [31:0] x, sum;\n  integer i, k;\n  wire c0 = 1'"'"'b0;"
  for (g = 0; g < W; g++) printf "  wire s%d, c%d;\n  fa f%d(a[%d], b[%d], c%d, s%d, c%d);\n", g, g+1, g, g, g, g, g, g+1
  printf "  wire [31:0] lo = {"; for (g = 31; g >= 0; g--) printf "s%d%s", g % W, g ? ", " : "};\n"
  print "  initial begin\n    x = 32'"'"'hACE1;\n    sum = 0;\n    for (i = 0; i < " V "; i = i + 1) begin"
  print "      for (k = 0; k < " W "; k = k + 1) begin\n        x = {x[30:0], x[31] ^ x[21] ^ x[1] ^ x[0]};\n        a[k] = x[0];\n        b[k] = x[7];\n      end"
  print "      #1 sum = {sum[30:0], sum[31]} ^ lo ^ c" W ";\n    end"
  print "    $display(\"ripple_adder W=" W " VECTORS=" V " checksum=%h\", sum);\n    $finish(0);\n  end\nendmodule"
}'
