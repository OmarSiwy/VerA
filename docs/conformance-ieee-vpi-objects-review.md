# IEEE26.6 object models — bounded installments

Read complete26.6 introduction and26.6.1–26.6.6, including every diagram,
property and note: printed386–392 / physical416–422. Visually inspected all
six object-content pages417–422 at1550-pixel rendering on2026-09-23. This
includes the continuation notes for module and net diagrams. The second
installment below extends review through26.6.12; no full Clause26 object-model
closure is claimed.

The original diagrams are authoritative. Arrows below were read from those
images, not inferred from extracted text order. No copyrighted source images
were added to the repository. Generic type/file/line/protection rules from
26.3 remain additional obligations even when absent from a diagram.

## Relationship and rule groups

| ID | Source | Required distinction and remaining evidence |
|---|---|---|
| OBJ-001 | 26.6.1 p387 | NULL-origin **double** arrow to modules requires top-module iteration, not a one-object handle. Module-to-child collections are one-to-many, with one-to-one containing-module reverse edges. Current declaration walker supplies bounded traversal regression, subject to the startup-phase qualification below. |
| OBJ-002 | 26.6.1 pp387–388 | Module array membership: module→array is one-to-one, array→members is one-to-many; module→index expression is one-to-one. Nonarray module index must be NULL, a valid absence rather than unsupported-relation error. New required-positive plugin covers this distinction. |
| OBJ-003 | 26.6.1 pp387–388 | Module properties include array/cell flags, decay/default-net/delay mode, definition location/name, protected flag, time unit/precision, top flag, unconnected drive, configuration/library/cell. NULL time-unit AND time-precision query returns global smallest precision here; reconcile routine-level wording explicitly. Definition locations respond to line remapping. Most properties are absent from current production header/implementation. |
| OBJ-004 | 26.6.1 p387 | Module collections also include net/reg arrays, variables, named-event arrays, processes, continuous assignments, primitive arrays, module paths, timing checks, parameters/specparams/defparams/parameter assignments and IO declarations. An object-kind macro or flat declaration is not graph execution evidence for these edges. |
| OBJ-005 | 26.6.2 p388 | Instance-array class includes primitive arrays and module arrays. Arrays have name/fullname/size, single left/right-range expression edges, an expression connection-list edge, indexed/multi-index access. Connection list is vpiOperation with vpiListOp. Member and parameter-assignment edges are plural. New plugin covers only module membership/index/size, not every property or connection list. |
| OBJ-006 | 26.6.2 p388 | Primitive arrays include gate/switch/UDP arrays, iterate primitive members and provide a single vpiDelay expression edge. Not interchangeable with module-array objects. Requires executable digital primitive hierarchy. |
| OBJ-007 | 26.6.3 p389 | Scope class includes module, task/function, generate scope, named begin/fork. Internal-scope collections and reverse containing scope/module edges are distinct; statement edges attach to named blocks/task-function group, not every scope indiscriminately. Existing module-only internal-scope iteration does not cover these classes. |
| OBJ-008 | 26.6.4 p389 | IO declarations are distinct objects reached from module/UDP definition/task-function; reverse owner relationship is singular. vpiExpr points to net/reg/variable declaration, while left/right-range tags point to expressions. Direction/name/scalar/vector/sign/size describe IO declaration, not port connection. |
| OBJ-009 | 26.6.5 p390 | Port belongs to module; port→bits is plural(vpiBit), bit→parent singular(vpiParent). Ports-class high/low connections each point to an expression: higher means closer to top, lower farther from top. Do not reverse these with net→port iteration. |
| OBJ-010 | 26.6.5 p390 | Port scalar/vector describe own width, not connected expression width; explicit name wins, absent name yields NULL; port order zero-based. Connection-by-name and explicit-name flags are different properties. Null low connection and disconnected high connection are valid NULL; null-port size0. Source anomaly in bit/index wording below. |
| OBJ-011 | 26.6.6 pp391–392(a–h) | Net bits exist independent of expansion; continuous assignments/primitive terms cross hierarchy but are accessed only from scalar/bit references. Low-side port and high-side port-instance iteration differ. Scalar/bit references return corresponding bits except undeterminable complex high connections may return whole port; size-mismatch nonconnections are excluded. Implicit-net line0/file-of-first-reference required. |
| OBJ-012 | 26.6.6 p392(h,t,u) | Net-bit index handle gives bit expression; index iteration gives multidimensional indices from innermost/bit outward. Nonarray net index iteration returns NULL. Array range iteration follows declaration left-to-right. New module-array probe does not close these net-array rules. |
| OBJ-013 | 26.6.6 p392(i–n) | Load/driver iterators filter active forces/assigns, include specified port cases and distinguish local from cross-hierarchy relationships. Local output/inout ports are loads; local input/inout ports drivers. Vector iteration deduplicates each loading/driving object; bit-by-bit connectivity requires bit handles. Variable-select iteration snapshots the selected bit at iteration start. Requires a live executor, not static header tests. |
| OBJ-014 | 26.6.6 p392(o–r) | vpiSimNet identifies a unique simulated net under collapsing; net-bit expanded property inherits parent; global load/driver sets may vary with legal collapse while local sets must not. Constant-select boolean distinguishes constant versus variable indices. Do not assert one simulator's legal global collapsed graph as universal. |
| OBJ-015 | 26.6.6 pp391–392(s) | Net size counts bits; net-array size counts total member nets. Net/array/bit identities and parent/member edges differ; ranges, declared/resolved net type, signedness, expansion, implicitness, strengths, charge strength, value and declaration-assignment flags require separate object/property evidence. |

## Source subtleties preserved

26.6.5(d) calls vpiIndex a property not applying to port bits, while its
diagram lists vpiPortIndex. This does not authorize silently substituting one
name for the other or demanding an invented bit-index property. Its example
of a null port is `module M();`, which also invites care when distinguishing
an empty port list from an explicit null entry. No null-port count oracle was
derived from that example in this installment.

26.6.6(d) says `vpiPorts` while the diagram's ports class maps to objects port
and port bit; neighboring notes use vpiPortInst explicitly. The graph also
prints `tchck term`, and note(q) omits a routine name before `(vpiLoad,...)`.
These source defects remain visible in the ledger; do not add misspelled C
API constants solely to make literal prose compile.

The source module graph explicitly has vpiProtected, unlike26.3.5's generic
vpiIsProtected spelling. This reinforces the unresolved property-name/scope
issue in the prior interface report; it does not resolve it by fiat.

## Concrete new host specification

`tests/fixtures/ieee_pli/audit_module_array.c` with its paired `.v` describes
two module instances in u[1:0]. At cbEndOfCompile the plugin checks:

- Nonarray top index is a successful NULL.
- Named array is vpiModuleArray of size2, not an ordinary member module.
- Member iteration visits both indices exactly once, in any order.
- Each member has vpiModule type and array flag1, points back to the array,
  and has an expression index whose value is0 or1.
- Direct indexed access refers to the same object as iteration, using
  vpi_compare_objects rather than C pointer equality.

The mandatory stderr marker records completion; empty HDL stdout and exit0
alone are insufficient. Startup only registers the legal callback. Syntax-only
probe with production `src/vpi/vpi_user.h` exits1 for missing callback, index,
array, value-format and get-value API declarations. No linked/runtime graph
result is claimed. No shims or fake graphs were introduced to manufacture
passing evidence. README marks this as an open required-positive host case,
outside any claimed executed conformance denominator.

Historical `tests/vpi_app.c` remains unchanged as implementation-specific
late-startup linkage/traversal regression. IEEE26.2.4 forbids its direct
startup object queries; phase-correct execution is still required. Existing
VPI-INDEX-VALID-BIT and VPI-PORT-EMPTY-RELATION XFAILs remain useful bounded
missing-capability probes, not complete net/port graph coverage.

No compiler/header edits, full builds, A/C measurements or conformance closure
claims were made. Remaining26.6.13–26.6.43 diagrams/notes are explicitly open.

## Second installment:26.6.7–26.6.12

Read complete text, diagrams and notes for regs/reg arrays, variables, memory,
object ranges, named events, and parameters/specparams: printed393–398 /
physical423–428. Visually inspected every one of those six pages, including
the full reg-note continuation on424, at1500-pixel rendering on2026-09-23.
Text from26.6.13–26.6.14 was incidentally read in the extraction batch, but
those graphs have not been visually audited and are not claimed complete.

| ID | Source | Additional requirement and evidence boundary |
|---|---|---|
| OBJ-016 | 26.6.7 p393 | Reg and reg-bit belong to a class with properties and connection edges; reg→bits is plural, bit→parent singular. Scope/module ownership, index expressions, declared ranges, initializer expression and reg-array membership are distinct relationships. Existing scalar-reg properties do not prove these graph edges. |
| OBJ-017 | 26.6.7 p394(a–e) | Cross-hierarchy primitive/continuous-assignment connectivity only from scalar/bit objects; low-side port versus high-side PortInst rules mirror but do not collapse into net rules. Complex high connections can return whole ports; width-disconnected references are excluded. Require paired scalar/bit/vector expressions and actual object graph. |
| OBJ-018 | 26.6.7 p394(f–j) | Reg-bit index handle versus multidimensional index iterator; active force/assign filtering for BOTH reg loads and drivers; deduplication at whole-vector level; selected-bit snapshot at iterator start. Legal collapse may change global sets. Static declarations cannot establish these lifecycle effects. |
| OBJ-019 | 26.6.7 p394(k–n) | Initializer expression accessible from reg/reg-bit; reg size counts bits, reg-array size counts member regs; member indices iterate inward-to-outward, array ranges left-to-right, nonarray index iteration is successful NULL. New probe covers simple memory array size and word width, not multidimensional order or initializers. |
| OBJ-020 | 26.6.8 p395(a–d) | Variables include integer/time/real; array elements are var-select words. Variable bit selections instead are vpiBitSelect expression objects, not reg bits; vpiParent reaches variable. Array flag distinguishes array from scalar, vpiVarSelect iteration gives members; singular index for1D and ordered iterator for multidimensional indices. New probe exercises real-array word identity and parent/index links. |
| OBJ-021 | 26.6.8 p395(e–i) | Variable-array ranges iterate left-to-right; left/right shortcuts describe rightmost dimension only. Array size counts variables; scalar/word size counts bits. Whole variable arrays do not have value property, though individual words do. No blanket whole-array read/write success oracle is justified by declared get/put routines. |
| OBJ-022 | 26.6.9 p396 | Legacy vpiMemory and vpiMemoryWord are access methods returning vpiRegArray and vpiReg, respectively, not obsolete object types. Memory flag, parent, index and word/array ranges remain distinct. New probe checks method-versus-returned-type and bit-count-versus-member-count. |
| OBJ-023 | 26.6.10 p396 | Range is an object with size and single tagged left/right expression edges. It is not merely the two integer bounds stored on an array. Full shape/order/ascending-descending/symbolic-bound cases remain. |
| OBJ-024 | 26.6.11 p397 | Named event has module/scope ownership, name and array membership; value interface here is put only. Event-array member iteration, reverse parent, index set and ranges differ from scalar event; nonarray index iteration returns NULL. Requires scheduling observation to prove event triggering, not just obtaining a handle. |
| OBJ-025 | 26.6.12 p398 | Parameters expose final post-instantiation/defparam value, constant kind, local flag, signedness, size and name; declared expression/range edges are distinct. Absent explicit range requires NULL left/right handles, even if value has a width. Existing HDL dependency checks do not prove VPI readback or range identity. |
| OBJ-026 | 26.6.12 p398 | Specparam, defparam and parameter-assignment are separate objects. Defparam/assignment have singular lhs(parameter) and rhs(expression); assignment records named-vs-ordered association. Target parameter must be the overridden instance object, not an unrelated same-named declaration. No such object family is presently exported by the production header. |

### Cross-standard discrepancy

The IEEE26.6.8 diagram visibly includes **real var** within the entire variables
class connected by a plural edge to var select; its notes apply array rules
to variables generally. This is additional source evidence against treating
AMS11.6.10's statement denying real arrays as a universal legal-source
rejection rule. The AMS contradiction was already logged against AMS3.2;
it is not silently edited here. The new pure digital real-array host probe
uses the unambiguous IEEE object model and does not claim the AMS diagram's
missing edge has been repaired in the original source.

Reg note26.6.7(c) again says vpiPorts; preserve the same spelling caveat as
OBJ-011 rather than introducing a new C constant. Source callback/argument
APIs are inherited from the earlier routine review; these graphs alone do
not define their complete ABI or storage lifetime contracts.

### Added required-positive host case

`ieee_pli/audit_array_object_kinds.c` and paired HDL declare reg memory[1:0]
with8-bit words plus a real samples[1:0] variable array. At cbEndOfCompile:
legacy memory iteration returns one reg-array; word iteration returns two
regs of width8; real-array iteration returns two var-selects. Both array sizes
are2. Each selected word has the expected parent and a distinct index0/1;
iteration order is unrestricted. Only declaration shape and constant index
expressions are read, so no uninitialized variable-value assumption is made.
The mandatory stderr marker and empty HDL stdout/exit0 form the documented
future host oracle.

The production-header C99 syntax probe exits1 for missing array/memory/select,
value and callback API names. This is blocked required support, not successful
negative coverage. It has not linked or executed; macro availability alone
would still not close any graph rule. Historical late-startup traversal remains
unchanged and qualified as implementation regression. No compiler/header/full
build or measurement changes were made in this installment.

## Final diagram installment: 26.6.13–26.6.43

Complete text and every diagram/note reviewed on 2026-09-23: printed
399–416, physical 429–446 of the licensed IEEE source. Every physical page
in that inclusive interval was visually inspected at 1450-pixel rendering;
arrows, class membership, relationship tags and notes were checked together.
This supersedes earlier pending-source statements for these subdivisions,
not their pending implementation or executable-evidence status. Together
the installments cover all of 26.6; the obligation groups below are not an
exhaustive enumeration of every property/edge permutation or a closure count.

| ID | Source / printed page | Required distinctions and open evidence |
|---|---|---|
| OBJ-027 | 26.6.13 / 399 | Primitive class includes gate/switch/UDP; module and array ownership, UDP definition and plural terminals are distinct. Size counts inputs, terminal indices start at zero; nonarray primitive index is successful NULL. Primitive put-value is permitted only for sequential UDPs. Need property/relationship cases and actual legal/illegal writes. |
| OBJ-028 | 26.6.14 / 400 | NULL-origin UDP-definition iteration; plural IO/table entries and singular initial statement. Table-entry values support string decompilation or vector ASCII only; primitive kind separates sequential/combinational. Neither generic integer readback nor gate-only traversal closes this group. |
| OBJ-029 | 26.6.15–16 / 401 | Module-path input/output are plural tagged path terminals, data-path input singular; terminals expose edge/direction/expressions. Path polarity, data polarity, condition, ifnone and delays differ. Intermodule paths require two-port handle_multi access and port iteration. Need real timing paths and delay read/write observations. |
| OBJ-030 | 26.6.17 / 402 | Timing-check reference/data/notifier relationships are distinct. Generic expression iteration returns event arguments as timing-check terminals, other arguments as their expression types; terminal condition differs from terminal expression. No timing-check execution or graph evidence is supplied by ordinary module handles. |
| OBJ-031 | 26.6.18 / 402 | Task/function IO declarations and calls link to declarations; functions have signedness, size, type and range expressions. An HDL function contains a same-name, same-size, same-type result object. HDL function execution alone does not verify this object. |
| OBJ-032 | 26.6.19 / 403–404 | Current system call uses NULL-origin handle; argument iteration admits expressions AND scope/primitive/arrays/events. User-defined registrations have separate objects and NULL-origin iteration. Function current value, registration info, equivalent decompilation, and protected-call argument access require separate probes. Null argument is Operation with NullOp, not a NULL handle. |
| OBJ-033 | 26.6.19(e) / 403 | PLI argument value evaluation is lazy: unread HDL/system function argument never executes; value request evaluates at request time. New host probe distinguishes unread versus requested side effects. Later-time requests and nested/system functions remain open. |
| OBJ-034 | 26.6.20 / 404 | Frames expose parent/scope/current statement, validity, active state and automatic objects. At most one active frame; NULL-origin handle returns it. Frame handles persist after execution unless explicitly freed. Automatic variables forbid value-change callbacks and delayed put-value. Requires lifecycle tests with legal static-variable controls; no rejection is inferred from absent APIs. |
| OBJ-035 | 26.6.21 / 405 | Delay device has separate singular input/output terminals, plural driver/load relationships. Input value changes before device delay, output only after it; declaration shape cannot prove timing. |
| OBJ-036 | 26.6.22–23 / 405–406 | Net and reg driver/load classes differ: reg drivers are force/assign, net drivers also include ports/delay/continuous assignments/primitive terminals. Complex nonconcatenation input connection is a port load; HighConn returns its expression. Require membership, active-force/assign lifecycle and reverse-connection tests, not raw counts only. |
| OBJ-037 | 26.6.24 / 406 | Continuous assignment has plural bits with singular parent; bit offset zero is LSB and each bit scalar. Whole and bit value-change callbacks are legal; lhs/rhs/delay expression links, strengths, declaration flag and values/delays require separate checks. |
| OBJ-038 | 26.6.25 / 407 | Use(vector) includes uses of vector and its selects; Use(bit) includes that bit, whole vector and containing parts. Variable bit-select object has parent and index-expression edges, not merely a reg-bit handle. Need exact use sets with unrelated-bit controls. |
| OBJ-039 | 26.6.26 / 408 | Indexed select has parent/base/width/type; ordinary part-select has left/right expressions. Operation operands are plural; replication first operand is multiplier, followed by concatenands. Decompilation preserves equivalence/precedence with prescribed spacing; protected expression size remains accessible. |
| OBJ-040 | 26.6.27 / 409 | Module→process is plural; process↔statement singular; blocks contain plural statements with scope ownership. Initial/always, begin/fork and named variants, atomic/null statements, and event-statement→named-event are separate graph kinds. Parser acceptance is not graph evidence. |
| OBJ-041 | 26.6.28–31 / 410–411 | Assignment exposes lhs/rhs, blocking flag and delay/event/repeat control. Delay/event controls attached to assignments have NULL statement, unlike standalone controls. Repeat control has count expression and event-control links. Need paired syntactic forms with handle/null/error distinctions. |
| OBJ-042 | 26.6.32–35 / 411–412 | While/repeat/wait have condition and body; for separately exposes initialization, condition, increment and body; forever body; if/if-else condition, then body and tagged else. Default untagged body relationships must not be replaced by arbitrary first-child traversal. |
| OBJ-043 | 26.6.36 / 412 | Case kind/condition plus plural items; a case item groups multiple expressions sharing one statement. Default item's expression iterator returns successful NULL. Need shared-label/default/empty-body controls. |
| OBJ-044 | 26.6.37–38 / 413 | Procedural assign/force expose lhs and rhs; deassign/release only lhs. Disable's Expr relationship targets function/task/named fork/named begin objects, not ordinary expression objects. Existing disable behavioral fixtures do not establish these VPI edges. |
| OBJ-045 | 26.6.39 / 414 | Expressions, primitive terminals, statements and time queues have plural callback relationships; unrelated callbacks use NULL-origin iteration. Callback-info routine reads registration data. Registration alone does not establish traversal or invocation. |
| OBJ-046 | 26.6.40 / 414 | Time queues iterate in increasing simulation-time order, empty queue gives NULL. Current queue inclusion requires events preceding read-only synchronization in IEEE text; conflicting AMS wording is recorded below. |
| OBJ-047 | 26.6.41 / 414 | ActiveTimeFormat from NULL returns the active task/function-call object; before any timeformat call it returns NULL. Need before/after/replacement cases, not just formatted output. |
| OBJ-048 | 26.6.42 / 415 | Listed object classes have plural attributes with singular parent and name/value. DefAttribute is true only for attributes on module definitions, false for instance attributes and every nonmodule object. Parsing attributes does not prove host provenance. |
| OBJ-049 | 26.6.43 / 416 | Iterator has IteratorType property and singular Use relationship to its creation reference. NULL-origin iterator's Use returns valid NULL. Need origin identity, mixed methods/types and lifecycle checks alongside routine-level scan/free rules. |

### Source conflict retained: current time queue

IEEE 26.6.40(c), printed414, permits the current queue in iteration only
when events precede read-only synchronization. AMS11.6.25 note5 uses the
opposite temporal direction (after). Neither wording has been silently
normalized, and no unified current-queue runtime oracle is asserted here.
Order and empty-queue obligations are independently testable. Resolve source
precedence/errata before claiming this particular cross-standard rule closed.

### New lazy-argument host oracle and actual result

`tests/fixtures/ieee_pli/audit_lazy_arguments.{c,v}` registers one task before
elaboration using only startup-legal registration APIs. At execution it
obtains both argument handles on each call, but requests the HDL function
argument's value only on the second call. The function increments an explicit
initialized counter. The HDL stdout oracle is `unread=0` then `read=1`;
the C callback also requires the returned value1. A mandatory final callback
stderr marker proves both task invocations occurred. `$finish(0)` avoids
simulator-dependent finish statistics. This tests no repeated-read caching
assumption, automatic-frame lifetime, or unspecified scheduling order.

Command executed in the isolated worktree:

```sh
cc -std=c99 -Wall -Wextra -Werror -Wno-unused-command-line-argument \
  -fsyntax-only -I /home/omare/Documents/Projects/Zig/VerA/src/vpi \
  tests/fixtures/ieee_pli/audit_lazy_arguments.c
```

Exit1: production header lacks current-call/argument/value constants and
get-value, registration/callback types and routines. This required-positive
probe has NOT linked or executed; the failure is missing host capability,
not a normative invalid-input success. Do not shim declarations or manually
invoke callbacks to turn it green. All remaining object graph groups above
remain open for phase-correct production-host execution. The historical
startup walker remains unchanged and qualified as implementation regression.
No compiler/header changes, full builds or A/C measurements were performed.

## Root handoff boundary

Main read this complete report on 2026-09-23 and retained it at root.
The source traversals and visual inspections above are attributed to the
worker, not claimed as a new independent main-agent full-source pass.
Named host probes remain pending root integration and cannot be credited
as executed conformance evidence. Later object-model installments complete
the source traversal formerly listed as pending, not the behavioral rules.
Public-header type/guard repairs are recorded separately in the AnnexG report;
runtime registration, callbacks and value APIs remain missing.
