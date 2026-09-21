# D04 — Procedural execution

Row D04 of `ARPice/docs/verilog-ams-conformance-plan.md`. Fourteen positive `.v`
programs for the `vera --run` digital source-execution path, each with a golden
transcript, plus one `.va` refusal.

## Status, 2026-09-20

`zig build test-devices` runs the fourteen `.v` files and diffs their
transcripts; `zig build benchmark -- --strict` measures the `.va` one. Nine of
the fifteen pass:

| fixtures | state |
| --- | --- |
| 01–08 | pass — implicit sensitivity, named events, the two intra-assignment controls, and level-sensitive `wait` all landed |
| 14 | pass — `disable` of a named block, `src/sim/digital.zig`'s `disableRange` |
| 09, 10 | FAIL — `task`/`endtask` are not TOKENS (`lib/frontend/token.zig`'s reserved-but-unimplemented table), so no AST, so nothing for `digital.zig` to execute |
| 11, 12 | FAIL — `function` is parsed only after `analog` (`parser.zig`'s `parseAnalog` -> `parseFuncDecl`); a bare `function` module item is `E0205`, and there is no digital function-call expression |
| 13 | FAIL — `fork`/`join` are not tokens either |
| 15 | FAIL — `lib/ir/lower.zig`'s `lowerEventTrigger` still accepts `-> ev;` on the analog spine; its own comment says the `!in_event_stmt` gate is missing only because no fixture pinned it, and this is that fixture |

So the five open `.v` rows are blocked in the FRONTEND, not in the executor.
The call stack that 09–12 need cannot be written or tested until `task`,
`endtask`, `automatic`, `fork` and `join` have tags and a digital
`function_declaration`/`task_declaration`/`task_enable`/`function_call` reach
the AST. Whoever takes them needs `lib/frontend/token.zig`,
`lib/frontend/parser.zig` and `lib/frontend/ast.zig` as well as
`src/sim/digital.zig`.

## Ground truth established before writing

The plan's D04 paragraph and `docs/digital-source-execution.md` both say
implicit sensitivity, named events, intra-assignment controls, `wait`,
tasks/functions, `disable` and `fork`/`join` "remain open". That is accurate,
and it understates how open: most of these do not reach the executor at all.
Verified by running `zig-out/bin/vera --run` on a probe of each form:

| form | current diagnostic |
| --- | --- |
| `always @* ...` | `E0208: expected an identifier: found `*`` (lexer/parser) |
| `event e;` in a digital module | `E1100 ... requires a portless module with only variables and initial processes` (`digital.zig:1024`, `m.events.len != 0`) |
| `b = #5 a;` | `E0209: expected an expression: found `#`` |
| `q = @(posedge c) d;` | `E0209: expected an expression: found `@`` |
| `wait (g) ...` | `E0209: expected an expression: found wait` |
| `task ... endtask` | `E0205: unsupported module item: found task` |
| `function ... endfunction` | `E0205: unsupported module item: found `function`` |
| `fork ... join` | `E0209: expected an expression: found fork` |
| `begin : blk ... end` | `E1100 ... block declarations/named scopes are not implemented` |
| `forever` | `E0209: expected an expression: found `forever`` |

`fork`, `join`, `task`, `endtask`, `wait`, `automatic`, `force`, `release` and
`deassign` are in `lib/frontend/token.zig`'s reserved-but-unimplemented table
(the block at lines 774–792), so they are not even tokens with tags. The row is
greenfield from the lexer up.

**One thing IS implemented and is called out here because the row would
otherwise claim it as new work:** named events on the ANALOG path. The parser
accepts `event e;` as a module item (`parser.zig:924`) and `-> e;` as a
statement (`parser.zig:2363`), `ir/elaborate.zig:2309` carries it through, and
`ir/lower.zig:1519`/`3769` implement it as a per-timepoint flag slot that `->`
writes and `@(e)` reads. It already has two fixtures under `tests/fixtures/`
(`ch05_analog_behavior/named_event_unsupported.va` and
`annex_a_syntax/17_named_event_trigger.va`), so it is not re-pinned here.
Fixtures 03, 04 and 15 are the parts of §5.10.4 that implementation does *not*
reach: the digital domain, the no-memory rule, and the spine/event-statement
position rule. In particular fixture 04 is aimed squarely at the flag-slot
model, which is correct for a single-pass analog block and wrong for two
suspendable digital processes.

## LRM clauses covered

Semantics for the digital procedural language come into Verilog-AMS by
incorporation, and the two sentences that do it are quoted in the fixtures:

- **§1.1** — "Verilog-AMS HDL consists of the complete IEEE Std 1364 Verilog
  specification".
- **§1.2** — "the semantics of the initial and always blocks remain the same as
  in IEEE Std 1364 Verilog".

Clause text and grammar actually read (offline HTML in `VerA/docs/`):

- **A.2.6** function declarations — `function [ automatic ]
  [ function_range_or_type ] function_identifier ( function_port_list ) ;`,
  `function_port_list ::= tf_input_declaration { , tf_input_declaration }`
  (inputs only), `function_range_or_type ::= [ signed ] [ range ] | integer |
  real | realtime | time`.
- **A.2.7** task declarations — `task [ automatic ] ...`, `task_port_item ::=
  tf_input_declaration | tf_output_declaration | tf_inout_declaration`.
- **A.2.1.3** `event_declaration ::= event list_of_event_identifiers ;`.
- **A.6.2** `blocking_assignment ::= variable_lvalue = [ delay_or_event_control ]
  expression`, `nonblocking_assignment ::= variable_lvalue <=
  [ delay_or_event_control ] expression`.
- **A.6.3** `par_block ::= fork [ : block_identifier
  { block_item_declaration } ] { statement } join`, `seq_block ::= begin
  [ : block_identifier ... ] { statement } end`.
- **A.6.4** the `statement` list (which contains `disable_statement`,
  `event_trigger`, `par_block`, `seq_block`, `task_enable`, `wait_statement`)
  versus the `analog_statement` and `analog_event_statement` lists (which do
  not contain the same things) — the basis of fixture 15.
- **A.6.5** `event_control ::= @ hierarchical_event_identifier |
  @ ( event_expression ) | @* | @ (*)`, `delay_or_event_control ::=
  delay_control | event_control | repeat ( expression ) event_control`,
  `disable_statement`, `event_trigger`, `wait_statement ::= wait ( expression )
  statement_or_null`.
- **A.8.2** `function_call ::= hierarchical_function_identifier
  { attribute_instance } ( expression { , expression } )`.
- **§5.10** the five properties of an event ("no time duration", "do not hold
  any data", …).
- **§5.10.4** named events, including the sentence that defines the
  synchronization semantics — "An event-controlled statement (for example,
  `@trig rega = regb;`) shall cause simulation of its containing procedure to
  wait until some other procedure executes the appropriate event-triggering
  statement (for example, `-> trig`)" — and the clause's own mixed-domain
  example.
- **§8.5.1** the stratified event queue (seven regions).
- **§8.5.3.3** blocking assignment with a delay: "computes the right-hand side
  value using the current values, then causes the executing process to be
  suspended".
- **§8.5.3.4** nonblocking assignment: "always computes the updated value and
  schedules the update … The values in effect when the update is placed on the
  event queue are used".

Where a fixture's rule lives in IEEE Std 1364-2005 rather than in the VAMS text,
it is cited as "IEEE Std 1364 Verilog Clause 9/Clause 10" via §1.1 rather than
by a subsection number that cannot be checked against the offline corpus.

## One line per fixture

Positive (14):

1. `01_implicit_sensitivity_star.v` — `@*` infers EVERY name the statement
   reads. `c = a | b` observed one full ns after each write: `0000`, then
   `0011` after `a<-0011`, then `0111` after `b<-0100`, then `0000`. Sensitivity
   to only one operand gives `b_set 0011` or `a_set 0000`.
2. `02_implicit_sensitivity_cascade.v` — the LHS is written, not read, so it is
   not in its own block's inferred list but does wake the next block. `x -> q ->
   r` settles inside one timestep: `0011 0011`, `1100 1100`, `0101 0101`. A
   one-stage-per-timestep cascade gives `moved 1100 0011`.
3. `03_named_event_digital.v` — §5.10.4 synchronization between digital
   processes. Waiter blocks at `@(tick)` at t=0, `mark<-0001` at t=3, `-> tick`
   at t=5; the waiter then writes `r<-1010` and prints `resumed 1010 0001`. A
   `@(event)` treated as a no-op prints `resumed 1010 0000`.
4. `04_named_event_has_no_memory.v` — a trigger with nobody waiting is
   discarded. `-> e` at t=1, `@(e)` first reached at t=2; the transcript is
   exactly `armed 0011` then `end 0011`, with no `resumed` line. A latched
   (flag-slot) event adds a third line.
5. `05_intra_assignment_delay_blocking.v` — §8.5.3.3. `b = #5 a` with `a<-0001`
   at t=0 and `a<-1111` at t=2 gives `b = 0001` (sampled at t=0) and the next
   statement's `c = a` gives `1111` (read at t=5): `intra 0001 1111`. The prefix
   form `#5 b = a;` would give `1111 1111`.
6. `06_intra_assignment_event_blocking.v` — same rule, `event_control` branch.
   `q = @(posedge clk) d` samples `d = 0101` at t=0, `d<-1110` at t=5, posedge at
   t=10: `intra_event 0101 1110`. The prefix form gives `1110 1110`.
7. `07_intra_assignment_delay_nonblocking.v` — §8.5.3.4, the process does NOT
   suspend. `b <= #5 a` captures `0001`, `a<-1111` runs immediately, so t=0
   prints `t0 1111 xxxx` and t=6 prints `t6 1111 0001`.
8. `08_wait_is_level_sensitive.v` — `wait` on an already-true expression does not
   consume time. First `wait (g)` with `g = 1` runs its statement at t=0
   (`nowait 0001`); second with `g = 0` suspends until `g<-1` at t=4, by which
   time `stamp` (written at t=2) is `0001`: `waited 0010 0001`. Implemented as an
   edge wait, the first one hangs and nothing prints.
9. `09_task_argument_passing.v` — input/output/inout copy-in/copy-out. `p = 3`,
   `r = 10`; `o = i + 1 = 4`, `io = io + i = 13`; `p` unchanged. `task 0011 0100
   1101`. Missing copy-out leaves `q` at `xxxx` and `r` at `1010`.
10. `10_task_static_lifetime.v` — a task without `automatic` has one copy of its
    locals for the run. `n` cleared on call 1 → `a = 0001`; call 2 finds `n = 1`
    → `b = 0010`. `static 0001 0010`. Per-call storage gives `0001 xxxx`.
11. `11_function_automatic_recursion.v` — `function automatic` gives each
    invocation its own arguments, so `fact(5)` terminates: 5·4·3·2·1 = 120 =
    `0000000001111000` in sixteen bits. `fact 0000000001111000`.
12. `12_function_return_width_is_the_boundary.v` — the declared range truncates
    before the caller's context extends. `tw` is 4 bits: `tw(3) = 6`, `tw(10) =
    20 mod 16 = 4`; `r = 6 + 4 = 10` in 8 bits = `00001010`. A caller-width leak
    computes `6 + 20 = 26 = 00011010`.
13. `13_fork_join_is_concurrent.v` — fork arms start at the fork's entry time and
    `join` waits for the longest. Arms `#3 a` and `#1 b`: an observer at t=2 sees
    `at2 0000 0010`, and the statement after `join` runs at t=3 giving
    `fork 0001 0010 0100`. Sequential semantics give `at2 0000 xxxx`.
14. `14_disable_named_block.v` — `disable work` at t=2 cancels the block's
    pending t=4 resumption and its trailing statement: `disabled 0001 0000` at
    t=6 instead of `0010 1111`.

Refusal (1, against 14 positives):

15. `15_bare_event_trigger_in_analog_rejected.va` — `-> ev;` directly on the
    analog spine has no derivation: A.6.4 lists `event_trigger` under
    `analog_event_statement`, never under `analog_statement`. `vera --lint`
    accepts it today and `ir/lower.zig`'s `lowerEventTrigger` says in its own
    comment that the gate is missing only because "no fixture pins it". Expected
    `DiagnosticsReported`; the natural code is a new class-4 diagnostic beside
    E0401 with lrm `A.6.4`.

## Deliberately NOT covered

- **`forever`** — also unparsed (`E0209`), and D04's plan bullet says "all
  inherited loops", but `repeat`/`while`/`for` are already implemented and
  tested, so `forever` is one keyword of parser work with no new semantics to
  pin. It belongs to whoever adds `wait`.
- **Procedural continuous assignment** — `assign`/`deassign`/`force`/`release`
  (A.6.2 `procedural_continuous_assignments`, §8.5.3.2). It is a separate plan
  bullet, it needs the driver model that D03 owns, and `force`/`release`/
  `deassign` are reserved-but-untagged words today. No fixture here touches it.
- **`fork ... join_any` / `join_none`** — SystemVerilog; A.6.3 has only `join`.
- **`repeat (n) @(posedge clk)` as an intra-assignment control** — the third
  alternative of A.6.5's `delay_or_event_control`. Fixtures 05–07 cover the
  `delay_control` and `event_control` alternatives; the repeat form adds a
  counter over the same machinery.
- **Named `fork` blocks, block-item declarations inside `fork`/`begin`, and
  `disable` of a TASK** (A.6.5's first alternative, `disable
  hierarchical_task_identifier`). Fixture 14 pins the block form only.
- **Hierarchical event/block names** — every `hierarchical_event_identifier` and
  `hierarchical_block_identifier` here is a single flat identifier; the digital
  executor has no hierarchy yet (D03/D06).
- **`@*` over nets, memory elements and index expressions** — fixtures 01 and 02
  use scalar/packed `reg` only. What an implicit list does with `mem[i]` needs
  the memory-element sensitivity rule and deserves its own row's attention.
- **Mixed-domain named events** (§5.10.4's `analog begin @(dig_event) ... end`,
  §5.10.5) — that is M01/M02 territory and needs a working analog+digital run,
  not the digital-only `--run` path.
- **`$time`/`$monitor`** — the timing claims here are all made by writing a
  sentinel variable at a known time and printing it with `%b`, because `%0d` and
  `$time` are not implemented by the executor and are not part of this row.

## How to run these

Both suites walk this directory now; neither needs a per-fixture build-step
edit, which is what the `tests/pending/D04` staging area this file used to
describe was for.

```sh
cd /home/omare/Documents/Projects/Zig/VerA
zig build test-devices           # the fourteen .v, transcript-diffed
zig build benchmark -- --strict  # the .va refusal, with every other fixture
```

One at a time, to read a diagnostic rather than a verdict:

```sh
zig build
zig-out/bin/vera --run  tests/fixtures/digital/d04_09_task_argument_passing.v
zig-out/bin/vera --lint tests/fixtures/digital/d04_15_bare_event_trigger_in_analog_rejected.va
```

`test-devices` is deliberately NOT a dependency of `zig build test`: most of
what it measures is approved behaviour this compiler does not have yet, and
`build.zig` says so where the step is declared.
