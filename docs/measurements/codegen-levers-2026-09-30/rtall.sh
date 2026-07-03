#!/bin/bash
# All runtime comparisons into results/runtime.jsonl (first .so of each group = baseline).
cd /tmp/claude-1000/-home-omare-Documents-Projects-Zig-VerA/8e3fb2cc-fae4-4ce7-b84a-3ddbec9744d1/scratchpad/cl
O=res/runtime.jsonl; : > $O
r() { python3 rbcmp.py 3 "$@" >> $O; }
for m in psp103 bsim4va; do
  r bench_loop so/$m.base.so so/$m.strip.so so/$m.grp.so so/$m.arrgrp_strip.so so/$m.noinl.so so/$m.s3strip.so so/$m.s3smallstrip.so
  for e in bench_loop bench_loop_eval bench_loop_q; do r $e so/$m.arp.so so/$m.arp_noinl.so so/$m.arp_evaldel.so; done
done
r bench_loop so/mos1.base.so so/mos1.strip.so so/mos1.grp.so so/mos1.noinl.so so/mos1.s3strip.so
for e in bench_loop bench_loop_eval bench_loop_q; do r $e so/mos1.arp.so so/mos1.arp_noinl.so so/mos1.arp_evaldel.so; done
r bench_loop so/diode.base.so so/diode.strip.so so/diode.grp.so so/diode.noinl.so
r bench_loop so/coupled_ltra.base.so so/coupled_ltra.strip.so so/coupled_ltra.grp.so so/coupled_ltra.s3strip.so
r bench_loop so/txl.base.so so/txl.strip.so so/txl.grp.so
r bench_loop so/resistor.base.so so/resistor.strip.so
echo done
