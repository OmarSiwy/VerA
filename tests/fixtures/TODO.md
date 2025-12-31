# Where the conformance pass stopped

1102 fixtures. `814 pass / 287 XFAIL / 1 CANNOT RUN / 0 FAIL`.

The suite was reoriented from "describe what VerA does" to "state what the LRM
requires of ANY Verilog-AMS compiler". Those are different things, and the old
suite mixed them. This file records what changed, what is left, and where the
work list lives.

## What the XFAIL count means

287 is not a regression. It is the debt that was previously invisible.

An audit of all 20 chapters against `docs/VAMS-LRM/*.html` found ~52 fixtures
that were **inverted**: they `//! reject` source the LRM prints as a legal worked
example — §1.3.4.1 `shiftPlus5`, §2.9 Example 7 `add (* mode="cla" *) (b, c)`,
§5.5.3 `twocap`, §4.7.2.4 `arrayadd`, §2.6.1 `8'h Af`. A **conforming** compiler
fails those fixtures. Only VerA passed them, by having the same gap they encoded.

Each is now a run fixture stating the real requirement with real digits, plus
`//! xfail` naming what VerA does not do. The requirement is written down; the
day VerA implements it the XPASS fires and the marker must be deleted. Nothing
was weakened to make the suite green — the number went up on purpose.

Read the per-chapter `COVERAGE.md` for which rules those are. **Caveat: the
COVERAGE.md files are stale** — see below.

## Contract additions

Documented in [README.md](README.md); this is the summary.

| Directive | Meaning |
|---|---|
| `//! lrm <section>` | the clause the fixture pins. Prints on failure; feeds `--coverage`. **This is what makes the suite portable** — another compiler can never match VerA's `E0130` codes, but "must not compile, per §5.8" travels. 849 fixtures carry one. |
| `//! xfail <reason>` | the fixture is RIGHT and the compiler under test does not satisfy it yet. Works both directions: with `//! reject` (LRM says error, VerA accepts) or on a run fixture (LRM says legal, VerA rejects). Not a pass. `--strict` fails on it. XPASS is a hard FAIL. |

Runner flags: `-jN` (defaults to one per core), `--coverage`, `--fixture-opt=<mode>`.

`CANNOT RUN` outranks `xfail`: a host limitation is not a compiler
non-conformance, and conflating them loses information.

## Left to do

1. **`COVERAGE.md` in all 20 chapters is stale.** It predates this pass — fixtures
   were created, rewritten and deleted underneath it, and its prose was already
   overclaiming before that (it credited fixtures that never mention the construct
   they were credited for). Rewrite each from the directory as it now stands, and
   put every `//! xfail` in the table **with its reason** — that table is the honest
   debt ledger and it is the most useful thing the file can carry.

2. **The adversarial review never ran to completion.** The 287 xfails and the
   fresh `want` literals have not been independently verified. Three lenses were
   designed and are worth re-running:
   - **digits** — recompute every `want` from the spec (`python3 -c`, full double
     precision). Also flag values the LRM leaves *implementation-defined*:
     asserting one over-specifies, and a conforming compiler would fail it.
   - **laundering** — for each `//! xfail`, does the fixture still state the FULL
     requirement, so the XPASS fires when the gap closes? Or was it hollowed out
     and marked? A vague reason ("not supported") instead of a named defect is the
     tell.
   - **inversion** — re-read every `//! reject` in the chapter against the spec.
     52 were found by static reading; that is a floor, not a count.

3. **Work-order items not yet applied.** `tests/audit/*--WORKORDER.json` holds the
   full 550-item list, priority-ordered, one file per chapter. Each item was
   triaged and deduped but **not proven** — re-verify a claim before acting on it.
   Roughly two thirds are applied; the files do not record which.

4. **290 orphaned `.expected-error.txt` sidecars** remain, against the README's
   "No sidecar files". Every one has a `.va` carrying the same expectation on its
   `//! reject` line, so deleting them loses nothing — verified. 11 were removed
   from `annex_a_syntax/`; the rest were left pending a decision.

5. **Genuine VerA bugs surfaced by the pass**, worth triaging separately from the
   fixtures: `ch09_system_tasks/06_display_formats.va` fails to compile the
   generated testbench (engine bug, has a reference trace), and the §9.7 file-I/O
   family has no descriptor surface in compiled device code.

## Provenance

`docs/VAMS-LRM/*.html` was corrected against `VAMS-LRM-2-4.pdf` first, because the
audit reads the HTML as authoritative. 14 files were patched: two missing Annex A
productions (`constant_expression_or_null`, `string`) that were referenced but
undefined, `constant_expression_or_null` vs `analog_expression_or_null` in Syntax
7-2, the empty-port-list alternative in `list_of_port_declarations`, two missing
reserved keywords, and Symbol-font PUA codepoints in §5.6.4 that rendered blank.
Do not re-derive fixture expectations from an older copy of those files.
