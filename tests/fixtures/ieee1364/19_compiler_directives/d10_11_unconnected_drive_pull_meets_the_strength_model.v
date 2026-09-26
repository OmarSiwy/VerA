// D10 x D03. The one part of IEEE Std 1364 §19.10 that the analog kernel
// CANNOT express, written for the digital source-execution path instead.
//
// §10.1 Table 10-1 carries `unconnected_drive over from IEEE Std 1364, where it
// pulls an unconnected input port to a logic level THROUGH A PULL-STRENGTH
// DRIVER. ch10_directives/58, 59 and 60 pin the level and say in their own
// headers why that is the weak half — 58, quoted exactly: "WHAT A PULL IS IN
// THE ANALOG KERNEL, since §19.10 describes a logic level and a drive
// STRENGTH, and this engine has neither." So those three fixtures approximate
// the pull as a potential source at 1 V or 0 V, and `lib/ir/lower.zig`
// (`applyUnconnectedDrive`) records the same approximation as its stated
// ceiling.
//
// The approximation is invisible as long as the pull is the ONLY driver of the
// port's net. It stops being invisible the moment the net has a second opinion,
// and that is the entire content of this file: on a four-state net the pull
// competes, and IEEE 1364 §7.10's eight drive strengths decide who wins.
//
// STRENGTH LEVELS, which are what the three answers below are computed from:
//
//     supply 7 > strong 6 > PULL 5 > large 4 > weak 3 > medium 2 > small 1 > highz 0
//
// One child, three unconnected input ports, one `unconnected_drive pull1 region
// over the module definition. Each port declares a different net type, so each
// meets the Pu1 driver with a different opponent:
//
//   w   wire     — no second driver at all. The net's own undriven value is Z,
//                  which is the identity of IEEE 1364 §7.9's resolution table,
//                  so the only driver decides: Pu1 -> the net reads 1.
//   t   tri0     — IEEE 1364 §3.7: a `tri0` net pulls itself to 0 AT PULL
//                  STRENGTH when nothing else drives it. So the net has Pu0
//                  against Pu1: equal strength, opposite values, and IEEE 1364
//                  §7.11 resolves that to X. This is the case no approximation
//                  can reach — a potential source cannot produce an X.
//   s   supply0  — IEEE 1364 §3.7: a supply net drives at SUPPLY strength,
//                  level 7, which is two levels above the pull. Su0 beats Pu1
//                  and the net reads 0 — the directive is honoured and still
//                  loses.
//
// EXPECTED OUTPUT, one line, `11_..._expected.txt`:
//
//     w=1 t=x s=0
//
// The three answers come from one directive and differ only by net type, which
// is what makes any of them discriminating: a tool with no strength model at
// all prints `w=1 t=x s=x` if it resolves every disagreement to X, or
// `w=1 t=0 s=0` if the declared net type simply wins, and neither matches.
//
// WHY THIS IS NOT A .va FIXTURE. The values above are logic values on discrete
// nets. `Lower.applyUnconnectedDrive` skips any net whose discipline binds no
// potential — "there is nothing to hold it at" — so the analog harness has no
// way to observe them, and `V()` on a discrete net is E0501, not a number.
//
// WHAT BLOCKS IT TODAY, all three of which are named in the source:
//   1. `src/sim/digital.zig` `wired()`: "every driver here is at the SAME
//      strength, so §7.10's eight drive strengths and §7.11's strength
//      resolution are not implemented" — quoted verbatim, and its §7.x are
//      IEEE 1364's, not this LRM's. That is the D03 carry-over, and the
//      comment's own upgrade path (a (strength0, strength1) pair per driver
//      bit) is exactly what the `t` and `s` columns need;
//   2. the same file refuses a module with instances (`m.instances.len != 0`),
//      so `--run` cannot elaborate the child at all;
//   3. nothing on the `--run` path reads the `DriveRegion` list the
//      preprocessor publishes — `applyUnconnectedDrive` is the only consumer
//      and it is analog-only.
//
// So this file fails for three independent reasons and will keep failing until
// D03's strength model exists. It is here to state the target, not to pass.

`unconnected_drive pull1
module d10_pulled(w, t, s);
  input w;
  input t;
  input s;
  wire    w;   // Z vs Pu1        -> 1
  tri0    t;   // Pu0 vs Pu1      -> x   (equal strength, opposite value)
  supply0 s;   // Su0 vs Pu1      -> 0   (supply outranks pull)
endmodule
`nounconnected_drive

module d10_unconnected_drive_pull_meets_the_strength_model;
  d10_pulled u( , , );
  initial $display("w=%b t=%b s=%b", u.w, u.t, u.s);
endmodule
