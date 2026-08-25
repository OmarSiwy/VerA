# ivtest: the Icarus Verilog regression suite

- upstream: https://github.com/steveicarus/iverilog
- commit: dfeee909ed9f20b4870dd93423156c0170c0e1ff
- license: GPL-2.0-or-later (`ivtest/COPYING` upstream)
- tag: `v13_0`, the iverilog the `.#benchmarking` shell carries (13.0)

ivtest lives in the iverilog repository's `ivtest/` directory since the
standalone github.com/steveicarus/ivtest was archived. It is GPL: nothing of
it is committed here. `tools/external_digital.py` shallow-fetches the pinned
commit into `.zig-cache/external/ivtest/` (git-ignored) at test time. This
folder holds only VerA's manifest and triage.

## Files used

`ivtest/regress-ivl1.list`, `ivtest/regress-vlg.list`,
`ivtest/regress-vvp.list` and the `ivtest/vvp_tests/*.json` it names, the
sources under `ivtest/ivltests/`, and the gold files under `ivtest/gold/`.

## Selection rule

A test is selected when all of these hold:

1. Its winning list entry is in `regress-vlg.list` ("tests that should work
   using any simulator that supports standard Verilog (1364-2005)"), or it is
   a `regress-vvp.list` JSON test. Precedence is upstream's
   (`perl-lib/RegressionList.pm`): `regress-ivl1.list` ("Icarus specific
   language extensions ... known Icarus limitations and deviations") is read
   first and the first entry for a name wins, so a name in both is out.
   Version-prefixed overrides (`v12:name`) are ignored.
2. Its type is `normal`, `CE`, `CO`, `CN` or `RE`. `NI`, `EF` and `TE` are
   Icarus-version bookkeeping, not a statement about the language.
3. Every iverilog option it carries is `-gspecify`, a `-W` warning flag, or
   a language generation VerA has a `--std` for (`-g1995`, `-g2001`,
   `-g2001-noconfig`, `-g2005`). Anything else (`-g2005-sv`, `-g2009`,
   `-g2012`, `-gverilog-ams`, `-gxtypes`, `-Ttyp`, `-S`, `-f`, `-y`,
   `-gno-io-range-error`, `-gstrict-ca-eval`, plusargs, a top module) selects
   a non-1364 language or an Icarus behaviour, and is out.
4. Every `$name` the source calls, outside comments and strings, is a
   normative IEEE 1364-2005 system task or function (clauses 15, 17, 18; the
   list is `SYSTF_1364` in the script). Annex C's informative tasks and
   Icarus's own (`$simtime`, `$sformatf`, ...) are out.

## Verdict

`vera --run --std=1364-2005 -I ivltests ./ivltests/<name>.v`, run from
`ivtest/` as upstream runs iverilog (relative `$readmem`/`$fopen` paths):

- `normal`: exit 0, and the stdout equals the gold file after normalisation
  when the entry names one (`gold=` or JSON `gold`, whose
  `<gold>-vvp-stdout.gold` is compared), else a line that is `PASSED` alone
  (upstream's `perl-lib/Diff.pm`, case-insensitive).
- `CE`, `RE`: a nonzero exit (VerA's `--run` compiles and runs in one
  process, so the two are judged the same).
- `CO`, `CN`: exit 0 or still running at the 20 s timeout.

Normalisation drops what IEEE 1364-2005 leaves to the tool: the simulator's
own `$finish`/`$stop` report (17.4.1: "a diagnostic message"), iverilog's
compile warnings recorded in a gold file, and vvp's VCD banners. The rule is
`TOOL_LINE` in the script.

`--native` repeats every `normal` test VerA's interpreter accepts through
`vera --emit-exe` and judges the executable's stdout the same way
(`ivtest-native` in the report; its triage is this folder's
`TRIAGE-native.md`).
