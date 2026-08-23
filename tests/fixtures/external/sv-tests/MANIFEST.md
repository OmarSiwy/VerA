# sv-tests: the Verilog-2005 subset

- upstream: https://github.com/chipsalliance/sv-tests
- commit: c4229f3bd5220e6d3ba8f390e5d09c87e462e9c7
- license: ISC (`LICENSE` upstream)

ISC would allow storing the tests here; they are fetched instead, like
ivtest, into `.zig-cache/external/sv-tests/` at test time, because a stored
`.v` under `tests/fixtures/` would be read by `zig build golden` as a VerA
fixture. Nothing of the suite is committed.

## Files used

`tests/chapter-*/**/*.sv` and `*.v`: each file with a `:name:` metadata
block. Generated tests (`make generate`), `tests/generic`, `tests/testbenches`
and the UVM tree are not used.

## Selection rule

sv-tests is written for IEEE 1800-2017, whose chapters do not map onto
1364-2005's, so the rule is the source text, not the `:tags:` chapter. A test
is selected when all of these hold:

1. It has metadata and needs no runner flags (`:defines:`, `:files:`,
   `:incdirs:`, `:top_module:`) and no `uvm` tag.
2. Outside comments and strings, it uses no IEEE 1800-2017 keyword that
   IEEE 1364-2005 does not reserve (`SV_KEYWORDS` in the script; this also
   drops a 1364 source that uses one as an identifier, which errs toward
   leaving a test out) and no SystemVerilog-only token: `'{`, an unbased
   `'0`/`'1`/`'x`/`'z`, a `type'(...)` cast, `++`, `--`, a compound
   assignment, `::`, `##`, `.*`, or `$` as a range bound (`SV_TOKENS`).
3. Every `$name` it calls is a normative IEEE 1364-2005 system task or
   function, the ivtest rule 4 list.

## Verdict

`vera --run --std=1364-2005 <file>` (a `.sv` file copied to a `.v` name in
the cache: VerA reads `.sv` as IEEE 1800 and refuses it), as sv-tests' `tools/runner` judges a
tool: a test without `:should_fail_because:` must exit 0 (or still be running
at the 20 s timeout), and when its `:type:` includes `simulation` every
`:assert: <expr>` line it prints must hold (`tools/logparser.py`). A
`:should_fail_because:` test must exit nonzero.
