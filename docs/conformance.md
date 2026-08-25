# Conformance and performance

How much of Verilog-AMS does VerA implement, and how do you know? "The
tests pass" does not answer it: a test suite can pass while missing half
the standard. VerA measures four things instead, and none of them reduces
to another:

| | Measure | What it counts |
|---|---|---|
| **A** | fixtures behaving as stated | every fixture under `tests/fixtures/` does what its header says: compiles and prints `ok=1`, or is refused with the named diagnostic |
| **B** | IEEE 1364-2005 clauses with two-way evidence | clauses of the digital standard cited both by a passing fixture that uses the rule and by one that breaks it and is refused; chapters out of scope are marked `not-supported` |
| **C** | LRM clauses with two-way evidence | the same, for the Verilog-AMS LRM |
| **D** | architecture phases landed | read by hand against the project's architecture plan; no script measures it |

"Two-way" matters. A fixture that compiles a construct shows the rule is
implemented; a fixture that breaks the rule and is refused shows it is
*enforced*. A clause with only one of the two is counted apart.

## The numbers

The table below is printed by `tools/conformance.py`, from the suites run
on this commit, when the site is built. Nothing on this page is typed by
hand, and no other program may write measures A, B or C:

{{#include measured.md}}

Each release records the same table at the top of its entry in
[`CHANGELOG.md`](https://github.com/OmarSiwy/VerA/blob/main/CHANGELOG.md)
and on its [GitHub release](https://github.com/OmarSiwy/VerA/releases). The
release workflow measures the tree again on a clean machine and refuses to
publish a tag whose recorded numbers disagree with it.

To print the table yourself, from a checkout (it runs the suites, which
takes a while):

```sh
python3 tools/conformance.py
```

## What the numbers do not say

B and C count *citations*: they show that a clause has a fixture on each
side, not that every rule in the clause is tested. A clause can hold several
rules. The [requirement
ledger](https://github.com/OmarSiwy/VerA/blob/main/specification/TESTING.md)
breaks the LRM into its individual normative sentences, and tracks the
evidence for each.

The places VerA knowingly falls short are listed by name in
[`specification/known-gaps.txt`](https://github.com/OmarSiwy/VerA/blob/main/specification/known-gaps.txt):
every fixture marked as a known failure, and every clause with evidence on
only one side. CI fails if that list changes in either direction, so a new
gap cannot slip in and a fixed one has to be crossed off.
[Implementation-defined choices](using/implementation.md) lists the open
defects in prose.

## Charts

Each chart is drawn from suite output by `tools/report.py`; the commit and
date it measured are in its subtitle.

<div class="vera-chart">
{{#include ../specification/img/conformance.svg}}
</div>

<div class="vera-chart">
{{#include ../specification/img/lrm-chapters.svg}}
</div>

<div class="vera-chart">
{{#include ../specification/img/ieee-chapters.svg}}
</div>

How long VerA takes to compile, per fixture and against the size of the
design:

<div class="vera-chart">
{{#include ../specification/img/compile-time.svg}}
</div>

<div class="vera-chart">
{{#include ../specification/img/scaling.svg}}
</div>

How long it takes to build a set of production compact models (BSIM4,
PSP and others) into shared libraries:

<div class="vera-chart">
{{#include ../specification/img/model-build.svg}}
</div>

## The live report

The [conformance and speed report](https://omarsiwy.github.io/VerA/report/)
is rebuilt from scratch on every push to `main`. It adds what a chart
cannot hold: the clause-by-clause map of which fixture covers which rule,
the open gaps and defects, the compile-time distribution, and the speed of
the generated devices' `eval`.
