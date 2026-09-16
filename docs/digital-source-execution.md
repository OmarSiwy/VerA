# Digital source execution

`zig-out/bin/vera --run tests/digital/scheduling.v` executes a bounded digital
Verilog source program. The existing preprocessor, lexer, parser and AST feed the
four-state value helpers and event scheduler directly. This is the first source
execution path; it is not full digital or mixed-signal conformance.

## Supported source

One ordinary portless module can declare scalar or packed `reg` variables,
`reg signed` variables and signed 32-bit `integer` variables. Packed bounds must
be nonnegative integer literals. State begins at X. Multiple `initial` and
`always` processes start at time zero. Sequential `begin`/`end` blocks, empty statements,
whole-variable blocking and nonblocking assignments, statement `#delay` and
`@` event controls, `if`/`else`, `case`/`casez`/`casex`, and `while`/`repeat`/`for` execute.
A transparent `generate`/`endgenerate` wrapper introduces no scope and is
accepted; conditional/loop/case generate constructs are rejected.

Expressions can nest the supported integral arithmetic, bitwise/logical,
equality/case equality, ordering and logical/arithmetic shift operators, unary
`+`, `-`, `~`, `!`, all six reductions, and conditional `?:`. A first pass infers
natural widths and signedness; evaluation then propagates the enclosing context
before computing operands. Assignment contributes width, never the destination's
signedness. An unsigned peer can therefore make a nested signed arithmetic-right
shift operate as unsigned before its value is produced.

Comparison operands form their own common type independently of the enclosing
expression. Shift counts, logical/reduction operands and the conditional test
are self-determined. Conditional arms share their inferred type and enclosing
context; a known test selects one arm, while an ambiguous test combines both
using IEEE 1364-2005 Table 5-21. In that inherited edition, even Z/Z arm bits merge
to X. Sized four-state values retain X/Z, and division by zero produces X.

Sized constants preserve their declared width. Known unsized constants use the
32-bit integer width. Larger unsized values and unsized four-state constants are
explicitly rejected pending their complete sizing/context rules; an explicit
size permits wide values. Selects and general function calls remain unsupported. Expressions exceeding 256 AST levels are diagnosed before execution;
an explicit evaluation stack is needed to remove that implementation ceiling.

Integral power uses the context-sized base and a self-determined exponent.
Repeated squaring wraps at the result width, without floating-point conversion.
Negative exponents produce zero except for bases 1 and -1; zero to a negative
power produces X. Any X/Z operand produces X, including an unknown base raised
to zero. The packed helper has exhaustive small-value, multiword mathematical
identity and allocation-failure tests, plus independent modular-oracle review.

`$signed` and `$unsigned` accept one integral expression, evaluate it at its own
width, and change its signedness without changing its bits. Enclosing context
then extends or truncates that result normally; assignment width does not flow
through the cast into its argument.

Integral concatenations join self-determined operands with the leftmost operand
at the most significant end. Both concatenation and replication produce unsigned
results and preserve all declared X/Z bits. Replication counts must be known,
nonnegative constant expressions; the currently supported pure casts/operators
can appear in a count, but module parameters and constant functions are still
outside this executor's supported declarations. Count and total-width overflow
are checked without floating-point conversion or truncation. Counts and result
widths are limited to u32; allocation failure is reported normally.

A zero replication is legal only directly inside a concatenation having a
positive-width operand. Thus `{{0{1'b1}},1'b1}` is accepted, while
`{{{0{1'b1}}},1'b1}` is rejected because its inner ordinary concat has no bits.
The repeated operand is evaluated once even when the count is zero. Digital
parsing preserves every concat/replication boundary instead of unrolling or
flattening it, so unsupported zero-count operands still fail preflight.

Direct unsized numeric operands in concatenations are prohibited by §5.1.14.
Compound arithmetic involving unsized constants is currently an explicit
unsupported boundary, pending the disputed interpretation of that wording
(see the [Icarus interpretation notes](https://github.com/steveicarus/iverilog/blob/master/Documentation/usage/icarus_verilog_quirks.rst#unsized-expressions-as-arguments-to-concatenation)).
This is not a claim that every such compound expression is normatively illegal.
The restriction stops at self-determined results such as comparisons, reductions,
logical operations and casts, and does not include shift counts or replication
multipliers. Sized operands can be used to state the intended width directly.

`$display` accepts literal formats with `%b` and `%%`. Binary output includes
every declared bit and preserves X/Z; escaped NUL bytes are retained. `$finish`
and `$finish(1)` report the current integer tick and mapped source location;
`$finish(0)` is silent. The argument controls verbosity, not the process exit
status. Statistics verbosity (`$finish(2)`) remains unsupported.

## Procedural control

`if`, `while`, and `for` execute their guarded body only when the condition's
four-state truth is one. Zero or ambiguous X/Z truth takes the false path; a
known one bit establishes true even beside unknown bits. `for` performs its
initial assignment once, tests before each iteration, and performs its step
after the body. Headers use the shared Verilog assignment grammar, not
SystemVerilog declaration/increment extensions.

A case selector is evaluated once. All labels and the selector contribute to
one common width and signedness, including labels that never match. Items are
then compared in source order; the first match executes, and `default` executes
only if none matches, regardless of its position. Normal case compares all four
states exactly. `casez` treats Z/? in either operand as a wildcard; `casex` also
treats X as a wildcard. Duplicate defaults and empty case lists are diagnosed.

`repeat` samples its integral count once at loop entry; changes to variables used
in that count do not change remaining iterations. X/Z counts execute zero times.
Each lexical repeat has a separate counter, including nested loops and different
initial processes. This relies on the current absence of recursive/reentrant
process invocation. Counts through 64 bits are supported without an iteration
clamp; wider counts are rejected before execution. Negative signed counts are
explicitly unsupported because IEEE 1364-2005 §9.6 does not define that case
unambiguously (also documented by the
[Icarus Verilog implementation](https://github.com/steveicarus/iverilog/blob/master/Documentation/usage/icarus_verilog_quirks.rst#repeat-statement-is-sign-aware)).

Loop bodies may suspend at delays and resume at the encoded continuation,
including a `for` step or `repeat` decrement. Untimed loops run until their
condition fails or `$finish` terminates simulation; no automatic iteration cap
changes program behavior. Statement trees deeper than 256 AST levels receive an
explicit implementation-limit diagnostic before execution. Expression/statement
scratch is reset after each instruction, once all captures and copies finish.
Queued callback records and NBA snapshot allocations currently remain in the run
arena; very long simulations can exhaust memory, which is reported as failure.

## Timing and scheduling

Delays require an explicit valid `timescale` before the module. The last valid
pre-module directive sets the module unit and precision; a single module makes
that precision the global tick. Malformed directives, `resetall`, and directives
after module start are rejected. Untimed programs need no directive. No guessed
time unit is supplied.

The current source slice supports integral delay expressions up to 64 bits.
X/Z delay values become zero. Negative signed integral delays are interpreted as
unsigned 64-bit values, as required for procedural delays; conversion to global
ticks and time addition diagnose overflow. Real delays remain unsupported even
though the separate time conversion utility provides a real conversion API.

## Event control and `always`

`@(v)`, `@(posedge v)`, `@(negedge v)` and `or`/`,` lists of those terms suspend
the process until a write gives the named variable a matching transition. Terms
resolve to their variables when the process is compiled, so a resumption cannot
fail mid-dispatch. Both the active and NBA regions publish through one write
path, so either can resume a waiting process.

A plain term watches the whole value and fires on any change; the edge forms
read the least significant bit and follow the §5.10.1 table, where x and z are
the intermediate value on both sides of a transition. A write that leaves the
value unchanged resumes nothing. The terms of one event expression share a
single resumption, so a process woken through one of them resumes exactly once
and retires the rest.

An `always` process returns to its own first statement instead of stopping.
A body that completes an iteration without reaching a delay or event control
would spin the scheduler forever at one timestamp; that is diagnosed rather than
left to hang. Sensitivity is explicit only — `always @*` and implicit
sensitivity lists are not yet inferred.

A blocking assignment updates state before the next statement. A nonblocking
assignment captures the RHS immediately into run-owned planes and publishes it
in the NBA region. Writes from one process keep lexical order. `#0` suspends the
process and resumes it in the inactive region, before pending NBA writes. A
nonzero delay resumes at the converted future tick. `$finish` ends execution and
discards pending events. Simultaneously active processes currently enter in
source order, one ordering permitted by the standard; programs with races must
not depend on that implementation choice.

The full program is validated before execution. Unsupported syntax and expression
forms fail before any process output, including forms inside unreachable control
bodies. Runtime-dependent timing overflow, unsupported negative repeat counts and
allocation/output failures can still occur after earlier valid output.

## Open conformance work

Ports, hierarchy, net driving/resolution, primitives, continuous assignments,
implicit sensitivity lists (`@*`), named events, intra-assignment event
controls, `forever`, `wait`, disable/jump
statements, procedural fork/join, named blocks, block declarations, declaration
initializers, parameters, time/real/string variables, arrays, remaining expression
forms and unsized rules,
other system tasks/formats, module-specific/global timing across hierarchy, and
analog/digital synchronization remain open. Analog compilation retains its
existing parser behavior; this executor does not reinterpret analog device
execution as digital simulation. `.sv` and VHDL have no enabled frontend here.

## Layout and lifetime rationale

The six design questions were answered before introducing executor state:

1. The transformation takes the shared frontend AST and produces four-state
   updates plus a display transcript, reusing existing Literal planes and queues.
2. Module variables and initial processes use flat tables; flattened statements,
   resumes and queued writes refer to u32 indices rather than linked pointers.
3. Source, instruction, variable and pending-event indices have checked u32
   capacity. Packed widths stay u32 and scheduler time stays u64. Task dispatch
   uses a closed u1 enum and a static string map for its two names.
4. Names are separate from mutable values. Each pending write consumes its target
   and captured planes together, so this small event record uses an AoS layout.
5. The caller's run arena owns source, instructions, state and NBA snapshots.
   Expression scratch resets between instructions; captured writes are copied into
   the run arena before scheduling and never borrow mutable variable planes.
6. Scheduler dispatch and shared-variable writes are causally ordered, so they
   are not independent SIMD lanes. This adds no SIMD kernel or performance claim.

Natural expression types add one run-owned cache row per existing ExprId. Width
is u32 and signedness is bool. Width zero denotes an uninferred row unless the
replication map marks a validated zero-count node. Both fields
are consumed together during evaluation, so these rows use AoS; AST structure
and values remain separate. The inference traversal uses a bounded u16 depth.
No new ownership lifetime, graph, or parallel execution axis is introduced.

Control flow adds a flat tagged instruction tape, a separate u32 case-target
pool, and u64 repeat counters. PCs and pool/counter handles are checked u32
indices; each instruction consumes all its variant's fields together (AoS).
Existing AST indices supply expressions and labels without a duplicate graph.
Tape/targets/counters share the run arena; case exit-patch indices are temporary
construction data in that arena. Compile nesting uses bounded u16 depth. These
changes preserve the same causal execution axis and NBA ownership contract.

Replication counts add a sparse run-owned map keyed by existing ExprId handles,
with checked u32 values. It also distinguishes validated zero-width replication
metadata from uninferred type rows. Positive-width Literal planes remain the
only runtime value representation. Constant count evaluation uses a temporary
arena; runtime concat operands/results use instruction scratch. The two cast
names use a static enum map. Packed copies mask source padding and keep value
and unknown planes separate; no new expression graph or SIMD claim is added.

## Verification and source rules

`zig build test-digital` runs the actual CLI on `tests/digital/scheduling.v`,
`tests/digital/expressions.v`, `tests/digital/control.v`, and
`tests/digital/concatenation.v`, checking exact transcripts. Scheduling distinguishes inactive from NBA execution,
snapshot evaluation from later reevaluation, multiple NBA ordering, assignment
context sizing, process resumption and finish cancellation. The expression fixture
checks the carry-loss example from §5.4.2, widened multiplication, nested mixed
signedness, comparison/logical/reduction boundaries, self-determined shift counts
and X/Z conditionals against explicitly stated expected values. The control
fixture checks case priority/global typing, wildcard symmetry, delay continuation
and NBA capture in loops, and fixed repeat counts despite variable changes.
The concat fixture covers cast/context barriers, nested and zero replication,
constant counts wider than 64 bits, and exact 129-bit X/Z outputs. Packed helper
tests compare word copies to an independent scalar-bit oracle, including dirty
padding and spare plane words; helper and source-run tests inject allocation
failures.
`zig build test-sim` also tests parser-to-executor semantics, initial X state, signed extension,
four-state display, exact escapes, unsupported-source rejection, statement depth,
64-bit repeat counts, an untimed 70,001-iteration loop and timing provenance. Both are dependencies of `zig build test`.

The relevant rules are IEEE 1364-2005 §5.1.14 (concatenation), §§5.4–5.5 (size and signedness), 9.2.1–9.2.2
(assignments), 9.4–9.6 (procedural control), 9.7.1 (procedural delays),
9.8–9.9 (sequential/initial processes),
11 (scheduling), 17.1.1.1 (display escapes), 17.4.1 (`$finish`) and
19.8 (`timescale`); and
[Verilog-AMS 2023](https://www.accellera.org/images/downloads/standards/v-ams/VAMS-LRM-2023.pdf)
§§8.5 (discrete scheduling) and 9.4.2 (display escapes).
The inherited digital rules are implemented within the stated subset; passing
these tests does not establish 100% Verilog-AMS conformance.
