# Conformance plan

## STATUS: the plan is executed. This document is now the record of it.

All seven waves have run. Measured from the tree, not carried forward — every number
below is `zig build torture` output or a grep over `tests/fixtures`:

| | baseline (when this plan was written) | now |
|---|---|---|
| fixtures | 1150 | **1152** |
| behave as they say they do | 812 | **1144** |
| XFAIL | 337 | **7** |
| CANNOT RUN | 1 | **1** |
| FAIL | 0 | **0** |
| compile and assert nothing | 16 | **0** |

The seven remaining XFAILs, by folder, with what each is:

- `annex_e_spice/{spice_model,spice_subcircuit,spice_case_lookup}.va` — **not a debt.** E.1.1
  guards the whole SPICE-netlist family with "IF a simulator … is also able to read SPICE
  netlists", and E.1.2 hands the antecedent to the implementer ("solely determined by the
  authors of the simulator"). VerA reads one language and no netlist, so the antecedent is
  false and these state no requirement that binds it. The marker is kept because `//! xfail`
  is honoured only for VerA — they are ordinary requirements for a tool that DOES read
  netlists — and because XPASS guards against silently resolving an undeclared module.
  **Do not close these by implementing a SPICE netlist reader.**
- `annex_f_resolution/unknown_discipline_mixed_port.va` — F.2 step 4.b's multi-candidate arm:
  `resolveDiscipline` keeps the FIRST declared discipline of a signal's segments instead of
  collecting the SET. E0903 is reserved and unemitted for exactly this. `connectrules` is
  also still E0201. Needs neither hierarchy (it exists) nor a digital engine (this fixture
  demands an error, not an execution).
- `ch05_analog_behavior/two_named_branches.va` — branch identity is fixed; what is left is
  that VerA lowers a branch-flow READ at its statement position and this file's CHECKs
  precede its two `<+` lines. Closing it means evaluating a §9.4 task's operands after the
  block (§9.4.1 converged reporting) — a change to every display task, not to branches.
- `ch07_mixed_signal/discrete_bus_{narrow,31}_unsupported.va` — blocked by a **contradiction
  inside the suite**, not by a missing capability: `reg [7:0] r` and `initial r = 8'hff`
  parse and are recorded, but four green fixtures pin `reject E0205` on a constant assignment
  in an `initial` block, three of them arguing under C.7/C.9 that the refusal IS conformance.
  No implementation satisfies these two and those four at once. Re-verdicting is an owner
  decision, not work.

What the plan got wrong, recorded because the errors are more useful than the hits:

1. **Three "sites" were misdiagnosed and the Notes below already say so** — the modulo bug
   that was unary-minus folding, the casex/casez diagnostic that could never fire, and
   `transition()` mislabelled as a chapter-10 gap. All three notes were right and all three
   epics closed on the corrected diagnosis.
2. **Wave 7's "reclassify, do not implement" was wrong on five of its own fixtures.** They
   were not blocked on a digital scheduler; they were MASKED by E0205, and making that
   refusal *recover* instead of bail let the real rules fire (E0422/E0430/E0431/E0432).
3. **The driver-access family (9 fixtures) needed no connectmodule and no driver state.**
   Every one is a *reject* fixture: §9.22 paragraph 3 makes driver access legal only inside a
   connect module, so refusing every call site VerA can reach is the conforming behaviour
   (E0818). The plan's own risk field asked whether they were in scope; the answer was that
   the question did not arise.
4. **`connectmodule` needed only to PARSE.** A.1.2's `module_keyword ::= module | macromodule
   | connectmodule` is one parser arm. No digital event routing, no driver state, no second
   codegen path.
5. **Per-epic fixture counts were never accurate** and the Notes said so (+/-3). The drift was
   larger than that in both directions; several chapters' COVERAGE.md aggregates were off by
   more than a factor of two (ch06 claimed 40 xfails against 28 measured, ch03 36 against 14,
   ch09 78 against 65). Every COVERAGE.md has since been re-censused by grep.

The plan body below is unedited except where a sentence became factually false; those are
marked in place. Read it as history and as the site index, not as a work list.

---

Generated from the torture suite's own `//! xfail` reasons, one audit agent per LRM
chapter, each verifying the reason against the source rather than trusting it.
Baseline `zig build torture`: **812/1150 pass, 337 XFAIL, 1 CANNOT RUN, 0 FAIL**.

Counts are +/-3; see Notes.


## Waves


### Wave 1 — cumulative 96/337


Every epic here is a diagnostic that should already exist, at a site the auditors located and I spot-checked. 96 fixtures for what is mostly `return` becoming `emit`. CONTENTION: twelve of these touch src/ir/lower.zig, but in disjoint functions — checkAccessMatch:1683, collectDisciplines:724, checkNatureTable:780, lowerSysTask:2331/lowerSysCall:2510, lowerParamDecl:950, internNode:876, lowerContribution:1500, lowerCase:2003, lowerUnary:2686, flowUnknown:923, freshBranch:1722, lowerBranchAccess:2520. Land the analog-context flag FIRST (it adds a field to struct Lower that two others read) and the rest are non-overlapping hunks. The lexer/preprocessor/token/cg_display epics touch nothing lower.zig owns and can run fully parallel.


| epic | fixtures | effort |
|---|---:|---|
| Access-function / discipline-binding checks (checkAccessMatch early return) | 11 | small |
| Nature & discipline declaration validation (checkNatureTable / collectDisciplines) | 11 | small |
| Analog-context restrictions (Tables 9-1/2/3/5/6/7/8 'analog: No' cells) | 10 | small |
| Analog operator & event argument validation (filter and cross/above bounds) | 9 | small |
| Parameter declaration validation (type conformance and range ordering) | 5 | small |
| Declaration uniqueness and conflicting discipline redeclaration | 4 | small |
| Signal-flow port direction and contribution-target rules | 4 | small |
| Infinity and NaN contribution rejection | 3 | small |
| Discrete domain binding rejection (Verilog-A subset) | 2 | trivial |
| Analog-initial context restrictions ($stop, event control) | 2 | trivial |
| Probe-branch dual-quantity constraint | 2 | small |
| Misc lowering gates (self-branch, antisymmetry, case default, loop contributions, named branches, modulo, reduction ban) | 8 | small |
| expm1 / ln1p accuracy (use the C library forms) | 3 | trivial |
| Reserved-word table gaps (assert, net_resolution) | 2 | trivial |
| Preprocessor conformance bundle (__VAMS_ text, escaped names, driver_access.vams, begin_keywords) | 4 | small |
| Number and attribute lexing gaps | 3 | small |
| Display formatting correctness (%c, argument pairing) | 2 | trivial |
| Legacy-spelling and grammar-reject bundle | 11 | small |

### Wave 2 — cumulative 168/337


Parser and AST surface work. 72 fixtures. CONTENTION IS REAL HERE: generate blocks (parser.zig:324), vector nets (parseNetDecl ~980, parsePortList:244, parseNetNames:486), replication (parser.zig:1323-1349), module header (parser.zig:201-267), branch decls (parser.zig:494-513), generic access (parser.zig:1351-1370) and port-list extensions all live in src/frontend/parser.zig and three of them edit parsePortList. Serialise the port-list group (vector ranges, named ports, concatenated ports, module header) into one changeset; the rest are far enough apart. Ast.Port and Ast.BranchDecl both gain fields, so land the AST shape changes before the parser hunks. Do NOT start default_discipline until the Verilog-A-vs-AMS scope question is answered.


| epic | fixtures | effort |
|---|---:|---|
| Generate blocks parse module items (incl. implicit generate region) | 11 | medium |
| Vector nets, vector ports and genvar-indexed access | 6 | large |
| Replication {n{...}} in concatenations and assignment patterns | 5 | medium |
| Module header syntax extensions (parameter port list, macromodule, named/concatenated ports) | 6 | small |
| Branch declaration extensions (port branches, branch arrays) | 2 | small |
| Generic potential() / flow() access functions | 2 | small |
| Analog function declaration validation | 4 | small |
| ddt/idt nature identifier as tolerance argument | 3 | small |
| String literal to integer conversion (and the reject side) | 3 | medium |
| Discipline compatibility rules (§3.11) for two-net access and branch terminals | 3 | small |
| __FILE__ and __LINE__ predefined macros | 3 | medium |
| Vector net range rejection with the right diagnostic (discrete buses) | 3 | small |
| default_discipline directive — DISPUTED between two auditors | 4 | medium |
| $simparam completeness and parameter derive coverage | 4 | small |

### Wave 3 — cumulative 210/337


Behavioural correctness, mostly in the backend. 42 fixtures. CONTENTION: above(), transition() and the filter-completeness epic all edit src/backend/codegen.zig in the 2780-2850 band and share the filter/kernel emission framework — treat them as one owner, serialised. Contribution value retention rewrites accumulation in src/ir/lower.zig:1722-1750 and must not run alongside anything else touching contributions. Generate validation and case-generate depend on wave 2's parser restructuring. The short-circuit ternary changes CFG shape, so it must not overlap the value-retention work in the same file.


| epic | fixtures | effort |
|---|---:|---|
| Generate validation rules (nesting, constant schemes, block naming, parameter ban) | 6 | small |
| case-generate construct | 2 | medium |
| Node and port alias functions ($analog_node_alias / $analog_port_alias) | 8 | medium |
| String formatting and scanning ($swrite / $sformat / $sscanf) | 4 | medium |
| above() edge-triggered state machine | 2 | medium |
| transition() piecewise-linear ramp with independent rise/fall | 4 | large |
| Named events (declare, trigger, detect) within the analog block | 3 | medium |
| Contribution value retention and flow-source readback | 3 | medium |
| Filter and analysis-function completeness (last_crossing directions, z-filter tau, null zeros, ac_stim, ddx) | 4 | medium |
| Expression semantics gaps (short-circuit ternary, ternary analog-operator ban, access shadowing, integer width) | 4 | medium |
| Assorted single-site semantics (multidim arrays, $limit function limiter, paramset decl, nature attribute reference, whole-array assignment, macro-substituted based numbers, analog-initial re-execution, array formals, attribute validation) | 13 | medium |
| $table_model isoline interpolation | 2 | large |

### Wave 4 — cumulative 259/337


Contract- and harness-level work, 49 fixtures, each with an unresolved design question stated in its risk field. CONTENTION: the RNG and file-I/O epics both add state to the Instance struct in tools/contract.zig — that file is ABI-critical and must have one owner for the whole wave. The Newton solver is confined to src/backend/tb.zig and conflicts with nothing; start it first and independently. Signal-flow codegen touches codegen.zig:838-1129 and depends on wave 1's port-direction rules.


| epic | fixtures | effort |
|---|---:|---|
| Testbench Newton solver (indirect contributions and self-driven nodes) | 4 | large |
| Signal-flow contribution codegen | 3 | large |
| Probabilistic distributions ($random, $arandom, $dist_*, $rdist_*) | 19 | architectural |
| File descriptor I/O subsystem (§9.5) | 19 | architectural |

### Wave 5 — cumulative 306/337


Alone in its wave on purpose. 47 fixtures. It rewrites the assumption that src/ir/lower.zig, src/ir/mir.zig and src/backend/codegen.zig all rest on — one flat module, one set of unknowns. Nothing else can safely touch those three files while it is in flight. Everything cheap has already shipped by now, so the branch can run long without stalling the fixture count.


| epic | fixtures | effort |
|---|---:|---|
| Module instantiation and hierarchy elaboration | 47 | architectural |

### Wave 6 — cumulative 333/337


27 fixtures that were individually cheap all along and only ever blocked on elaboration. Once the hierarchy exists these fan out cleanly: defparam and paramset in the parser plus override resolution; hierarchical names in parsePrimary and parseNetNames; Annex F resolution as its own post-elaboration pass; driver access as a separate connectmodule codegen path. CONTENTION: Annex F resolution and $mfactor propagation both read the elaborated tree but write different tables. The driver-access family (9 of the 27) is a second codegen path and should be evaluated for scope before it is built. **[FALSE, corrected in wave 6: the driver-access family is nine REJECT fixtures. §9.22 paragraph 3 makes those functions legal only inside a connect module, so refusing every call site the compiler can reach is the conforming behaviour and needs no codegen path at all — the rule went into lowering as E0818 and the `driver_queries` constant 0 was deleted.]**


| epic | fixtures | effort |
|---|---:|---|
| Hierarchy dependents (defparam, paramset instantiation, OOMR names, $mfactor propagation, Annex F resolution, gate primitives, driver access) | 27 | architectural |
| $simprobe and unregistered VPI analog system functions | 2 | architectural |

### Wave 7 — cumulative 337/337


Not work — a bookkeeping decision. These 4 fixtures document LRM rules that are masked by the C.7 subset rejection and cannot be reached without a digital scheduler. Reclassify them out of XFAIL rather than implementing them, and the real remaining gap drops to 333.


| epic | fixtures | effort |
|---|---:|---|
| Out of Verilog-A scope (initial/always blocks, digital reg, both-contexts assignment) | 4 | architectural |

## Epics


### 1. Access-function / discipline-binding checks (checkAccessMatch early return)

- **LRM** §4.4 3.6.3 1.3.4 1.3.5 6.5.2.1 C.4
- **Fixtures** 11 (annex_d_standard_definitions, ch03_data_types, ch01_intro, ch06_hierarchy, annex_c_analog_subset)
- **Effort** small
- **Site** src/ir/lower.zig:1683-1703 checkAccessMatch(). VERIFIED: line 1686 `if (dname.len == 0) return;` and line 1692 `if (want.len == 0 or eql(want,name)) return;` are the two silent exits. Both need a diagnostic instead of a return: empty discipline (undeclared/natureless net used behaviourally) and missing nature binding for the requested half (V on a flow-only signal-flow discipline, I on a potential-only one, any access on ddiscrete/\logic).
- **Why here** Highest fixtures-per-line in the whole audit: two `return` statements become two `emit` calls and eleven fixtures across five chapters flip. The header comment at :1680 already admits the gap ('the missing binding is its own diagnostic') — that diagnostic was never written.
- **Risk** The early returns were deliberate; §3.6.5 implicit nets legitimately have an empty discipline until they are probed. The check must fire on the ACCESS, not the declaration, or every implicit net regresses. Needs a new class-3 code distinct from E0501 (which is name-mismatch, not absence).

### 2. Nature & discipline declaration validation (checkNatureTable / collectDisciplines)

- **LRM** §3.6.1.2 3.6.1.3 3.6.2.1 3.6.2.2 3.6.4 3.13.1
- **Fixtures** 11 (ch03_data_types)
- **Effort** small
- **Site** src/ir/lower.zig collectDisciplines (~724-730) and checkNatureTable (~780-890). Seven independent gates on one already-parsed table: conservative discipline binding the same nature twice (46), discrete domain carrying nature bindings (47), access attribute must be an identifier not a string / units must be a string / user attributes must be constant (65 x2, 68), idt_nature must name an existing and related nature (66 x2), nature-vs-nature and discipline-vs-discipline name collisions (67 x2), duplicate user attribute in one nature (68), ground net must be continuous (62).
- **Why here** Eleven fixtures, one function, no cross-file reach. The nature table is fully parsed and in memory; every rule is a field comparison or a hash-set insert. Nothing downstream consumes the result, so there is no regression surface.
- **Risk** Base-nature relatedness for idt_nature needs the natureOf walk (already exists). The uniqueness passes must not reject the Annex D prelude, which redefines nothing but is parsed alongside user natures — scope the maps per file.

### 3. Analog-context restrictions (Tables 9-1/2/3/5/6/7/8 'analog: No' cells)

- **LRM** §9.2 9.4.1 9.5 9.6 9.7 9.8 9.9 9.11
- **Fixtures** 10 (ch09_system_tasks, annex_g_change_history)
- **Effort** small
- **Site** src/ir/lower.zig lowerSysTask:2331 and lowerSysCall:2510. There is no analog-context flag anywhere in the codebase today. Add one field to Lower (analog / analog-initial / digital), set it where the analog block body is entered (~line 630), and gate the eight name-lists from the tables: radix-suffixed display/strobe/write/monitor variants, $monitoron/off, file-I/O radix variants plus $fgetc/$ungetc/$fread/$readmem*/$sdf_annotate, $printtimescale/$timeformat, the 16 PLA tasks, the 5 $q_* tasks, $time/$stime/$realtime, $itor/$rtoi/$signed/$unsigned.
- **Why here** One piece of state (the context flag) unlocks ten fixtures and is the prerequisite for every later 'this construct is digital-only' rule. Building it once beats bolting a bespoke check onto each task.
- **Risk** Nine tables, nine different name lists. Missing one table is a silent conformance hole rather than a visible failure. The flag must distinguish analog from analog-initial, because §9.7.2 ($stop) keys on the narrower one.

### 4. Analog operator & event argument validation (filter and cross/above bounds)

- **LRM** §4.5.5 4.5.6 4.5.7 4.5.8 4.5.9 4.5.10 5.10.3.1
- **Fixtures** 9 (ch04_expressions, ch05_analog_behavior)
- **Effort** small
- **Site** src/ir/lower.zig lowerFilter (~3040-3095) plus the event-function lowering that feeds src/backend/codegen.zig:2368-2380. Rules: idtmod modulus > 0; absdelay td > 0; transition td/rise/fall/time_tol >= 0; slew max_pos > 0 and max_neg < 0 (check BEFORE the negate-the-positive default is applied); last_crossing direction in {-1,0,+1}; ddx second argument must be a single-net probe (today the E0504 check at ~3040 only asserts 'is a call'); cross/above dir must be integer, tolerances non-negative, and tolerances require a non-null dir.
- **Why here** Nine fixtures, one lowering function, all constant-folded argument comparisons. The LRM states each bound in one sentence; the checks are one `if` each and they share the same argument-walk.
- **Risk** Arguments may be non-constant expressions. Fold what folds and stay silent otherwise rather than rejecting anything unprovable — a false reject on a parameterised rise time would break working models.

### 5. Parameter declaration validation (type conformance and range ordering)

- **LRM** §3.4.1 3.4.2 3.4.4 3.4.6
- **Fixtures** 5 (ch03_data_types)
- **Effort** small
- **Site** src/ir/lower.zig lowerParamDecl (~950-1010). Reject string initializer on a real parameter and numeric initializer on a string parameter (§3.4.1 forbids any string conversion); require an explicit type on array parameters (§3.4.4) and on string parameters (§3.4.6); reject `from [hi:lo]` where the first bound exceeds the second (§3.4.2).
- **Why here** Five fixtures in one function against compile-time constants. No IR or codegen reach.
- **Risk** Type inference for untyped parameters is current behaviour and some existing fixtures may lean on it. Only reject where the LRM names an explicit error; leave plain inference alone.

### 6. Declaration uniqueness and conflicting discipline redeclaration

- **LRM** §3.2 3.3 3.4 3.10 6.2 7.4.4 F.2.1 F.2.2
- **Fixtures** 4 (ch07_mixed_signal, annex_f_resolution, ch06_hierarchy)
- **Effort** small
- **Site** src/ir/lower.zig:876-893 internNode(). VERIFIED: on found_existing it overwrites `node_disciplines.items[...] = discipline` with no comparison. Emit E0902 when the existing discipline is non-empty and differs — §7.4.4 forbids ANY second declaration, compatible or not. Separately, scope registration must reject a duplicate identifier in one scope, and src/frontend/parser.zig:439-455 must reject a body redeclaration of a port already declared ANSI-style in the header.
- **Why here** Four fixtures, and the discipline half is a three-line guard at a site the audit confirmed by inspection. Also removes a silent-overwrite hazard that would poison hierarchy work later.
- **Risk** internNode is called for implicit nets with an empty discipline string; the guard must only fire when both sides are non-empty, or every implicit net that is later declared regresses.

### 7. Signal-flow port direction and contribution-target rules

- **LRM** §1.3.4.1 1.3.4.2
- **Fixtures** 4 (ch01_intro)
- **Effort** small
- **Site** src/ir/lower.zig port registration (~545-560, node_directional is populated at :554 but only read post-hoc by codegen) and lowerContribute (~1478-1510). Two rules: a single-nature discipline may not bind to an inout port (rule fires on the DECLARATION, not on any contribution); and a contribution to a single-nature directional port must target an output, never an input. src/backend/codegen.zig signalFlowNet:838-849 already has the single-nature predicate to mirror.
- **Why here** Four fixtures, information already present at the point of decision (direction in node_directional, natures in disciplines). Today the only refusal happens in codegen, too late and for the wrong reason.
- **Risk** Must fire on declaration for the inout rule; tying it to a contribution lets a violating port with no contribution through silently.

### 8. expm1 / ln1p accuracy (use the C library forms)

- **LRM** §4.3.1 9.14
- **Fixtures** 3 (ch09_system_tasks, ch04_expressions)
- **Effort** trivial
- **Site** src/backend/codegen.zig:3539-3545. VERIFIED: zExpm1 and zLn1p are emitted as helper bodies computing exp(x)-1 and log(1+x) naively. Replace with std.math.expm1 / std.math.log1p — src/ir/proof.zig:1791 already folds constants with exactly those two functions, so availability is proven.
- **Why here** Two helper bodies, three fixtures, and the correct implementation is already linked into the proof layer.
- **Risk** Values change (toward correct). Any fixture with a tight threshold that was tuned against the cancelling form will move.

### 9. Legacy-spelling and grammar-reject bundle

- **LRM** §G.1 G.2.2 C.7 E.3.1 E.3.4 3.4 4.2.14 5.10.2 9.17.3
- **Fixtures** 11 (annex_g_change_history, annex_c_analog_subset, annex_e_spice)
- **Effort** small
- **Site** Six unrelated one-site rejects: drop the '$limexp' alias at src/backend/codegen.zig:2420 and :3379; reject empty parens on @(final_step()) at src/frontend/parser.zig:1125-1131; refuse a bare `;` as an analog_seq_block statement at parser.zig:917-919 (context must be threaded, null is legal only in conditional/case/event bodies); reject a brace-only (non-apostrophe) array initializer in src/ir/lower.zig declaration lowering; dispatch .kw_casex/.kw_casez at parser.zig:937 into parseCase so the existing E0416 at lower.zig:2010 is actually reachable; name ccvs/cccs/mutual_inductor specifically per E.3.1 instead of letting them fall into the generic E0204; and promote the silent 'too few arguments' decline at src/backend/cg_limit.zig:100-104 into a real diagnostic.
- **Why here** Eleven fixtures for six independent small edits, none of which touch each other. The casex/casez one is pure wiring — the diagnostic text already exists and has never been reachable.
- **Risk** The null-statement fix needs statement context in the parser and must not break recoverStatement at parser.zig:1031, which relies on the semicolon being consumed.

### 10. Misc lowering gates (self-branch, antisymmetry, case default, loop contributions, named branches, modulo, reduction ban)

- **LRM** §4.2.4 4.2.10 4.4 5.4.1 5.4.2.2 5.8.3 5.9 1.3.1.2
- **Fixtures** 8 (ch04_expressions, ch05_analog_behavior, ch01_intro)
- **Effort** small
- **Site** Seven independent gates in src/ir/lower.zig: reject V(n,n)/I(n,n) at lowerBranchAccess (~2520, E0315 already defined and never raised); canonicalise flowUnknown (:923) so I(n,p) returns the negation of the flow(p,n) unknown instead of minting a second independent unknown; count default arms in lowerCase (:2003); forbid contributions inside non-genvar loops (§5.9) using the existing non-static lowerCondBody flag; key named branches by (name, hi, lo) instead of (hi, lo) at freshBranch (:1722) so two branches over one net pair stay distinct; fold unary minus on integer literals in src/ir/analysis.zig so `11 % -3` proves its divisor non-zero; gate unary reductions in lowerUnary (:2686) on analog context, and unblock the `^` reduction parser path at src/frontend/parser.zig:1259 so the already-defined E0320 can fire.
- **Why here** Eight fixtures for seven small guards, four of which just raise diagnostics that were already written and wired to nothing.
- **Risk** Flow antisymmetry is the only one with reach: the canonical-order rule must hold across every access site and stay consistent with codegen's `flow(...)` naming, or a sign flips somewhere silently.

### 11. Discrete domain binding rejection (Verilog-A subset)

- **LRM** §C.4 C.17 3.6.2.2 7.2.1
- **Fixtures** 2 (ch07_mixed_signal, annex_c_analog_subset)
- **Effort** trivial
- **Site** src/ir/lower.zig:551-554 (ports) and :569-570 (nets). DisciplineInfo.is_discrete is already computed at :726 and never read. Reject the BINDING; C.17 requires the DEFINITION to stay tolerated and silently ignored.
- **Why here** The predicate already exists and is dead. Two fixtures for one `if`.
- **Risk** Rejecting the definition instead of the binding breaks C.17 and any prelude that declares ddiscrete.

### 12. Analog-initial context restrictions ($stop, event control)

- **LRM** §5.2.1 9.7.2
- **Fixtures** 2 (ch05_analog_behavior, ch09_system_tasks)
- **Effort** trivial
- **Depends on** Analog-context restrictions (Tables 9-1/2/3/5/6/7/8 'analog: No' cells)
- **Site** src/ir/lower.zig — reuses the analog/analog-initial flag from the analog-context epic. §9.7.2 forbids $stop in analog initial; §5.2.1 forbids event control statements there.
- **Why here** Two fixtures once the context flag exists; on its own it would be duplicated state.
- **Risk** None beyond correctly distinguishing analog-initial from analog.

### 13. Probe-branch dual-quantity constraint

- **LRM** §1.3.1 5.4.2.1
- **Fixtures** 2 (ch01_intro, ch05_analog_behavior)
- **Effort** small
- **Site** src/ir/lower.zig — per-branch accessed-quantity set maintained during lowerBranchAccess, checked against the Contribution table (branches with no contribution are probes). Emit on the second distinct quantity read of a probe branch.
- **Why here** Two fixtures; needs a small map, not a new pass, if the set is built during lowering.
- **Risk** Classification depends on contributions that may be lowered after the read. A post-lowering sweep over the branch table is the safer shape.

### 14. Infinity and NaN contribution rejection

- **LRM** §7.3.2.1
- **Fixtures** 3 (ch07_mixed_signal)
- **Effort** small
- **Site** src/ir/lower.zig lowerContribution (~1500+) after splitContribution. Reject a resist/react value that constant-folds to +inf, -inf or NaN. Distinct from W0650, which is a finiteness-proof warning about runtime values, not the §7.3.2.1 rule.
- **Why here** Three fixtures, all folded at compile time (1.0/0.0, -1.0/0.0, 0.0/0.0).
- **Risk** Only the folded case is catchable; runtime infinities stay W0650's job. Do not try to make this a runtime check.

### 15. Preprocessor conformance bundle (__VAMS_ text, escaped names, driver_access.vams, begin_keywords)

- **LRM** §10.4 10.6 D.3
- **Fixtures** 4 (ch10_directives, annex_d_standard_definitions)
- **Effort** small
- **Site** src/frontend/preprocessor.zig handleDefine:543-584 — reject macro TEXT beginning with __VAMS_ (§10.4 constrains the body, not the name; fixture 15 proves a __VAMS_-prefixed NAME is legal), and accept escaped macro names via the lexer's escaped-identifier rule at src/frontend/lexer.zig:213-225. preprocessor.zig:868 builtin_includes — add driver_access.vams verbatim from Annex D.3 (the omission is explicit in the source comment). src/frontend/parser.zig:135-142 — downgrade or drop E0137: §10.6 says `begin_keywords crosses file boundaries and never requires a matching close within one file.
- **Why here** Four fixtures across two files, all mechanical, no semantic reach.
- **Risk** Dropping E0137 inverts a previous author's reading of §10.6; the fixture and the clause text both back the inversion. driver_access.vams was omitted on purpose as 'outside annex C' — Annex D is normative, so add it, but note the scope creep.

### 16. Number and attribute lexing gaps

- **LRM** §2.6.1 2.9 A.8.2
- **Fixtures** 3 (ch02_lexical)
- **Effort** small
- **Site** src/frontend/lexer.zig lexBasedTail:159-176 — skip whitespace between base format and digits (§2.6.1 explicitly permits it, all five LRM examples use it). lexer.zig parseInt:487-490 — reject an explicit size of zero (§2.6.1 size is a non_zero_unsigned_number; today 0 is the unsized sentinel, so `0'b1` silently means unsized). src/frontend/parser.zig:1361 — call the existing skipAttributes() between a function name and its argument list (§2.9 Example 7).
- **Why here** Three fixtures; the attribute one is a single call to a function used at fourteen other sites.
- **Risk** The zero-size fix needs a sentinel other than 0 for 'unsized', or an explicit 'size was present' flag.

### 17. Display formatting correctness (%c, argument pairing)

- **LRM** §9.4.3
- **Fixtures** 2 (ch09_system_tasks)
- **Effort** trivial
- **Site** src/backend/cg_display.zig:215/226/243 and renderPrintArg:261 — %c currently maps to Zig verb {c} while the value is rendered as i64, so the generated device does not compile ('expected u8, found i64'). Truncate to u8 for the %c case. Separately, count non-%m/%%/%l specifiers against supplied arguments and reject a mismatch.
- **Why here** The %c bug breaks compilation of the whole 06_display_formats fixture including its %h and %o round-trips; it is a one-line cast.
- **Risk** None.

### 18. Reserved-word table gaps (assert, net_resolution)

- **LRM** §B.1 C.16 2.8.2
- **Fixtures** 2 (annex_b_keywords, annex_c_analog_subset)
- **Effort** trivial
- **Site** src/frontend/token.zig:594-620 reserved_keywords. VERIFIED: neither spelling appears. Adding them routes both through .kw_reserved, and parser.zig identLike():1791-1799 already produces E0208 for reserved words in identifier position.
- **Why here** Two array entries, two fixtures.
- **Risk** Any model using either spelling as an identifier now fails — which is the point; both are named reserved in Annex B and C.16.

### 19. Generate blocks parse module items (incl. implicit generate region)

- **LRM** §6.6 6.6.1 A.4.2 A.1.4
- **Fixtures** 11 (ch06_hierarchy, annex_a_syntax)
- **Effort** medium
- **Site** src/frontend/parser.zig:324-329. Today for/if/begin inside a generate region are dispatched to parseStmt(), so the body is parsed as an analog STATEMENT and the `analog` keyword inside dies at E0209 (parser.zig:1412, expression context). Per Syntax 6-8 a generate_block is `module_or_generate_item | begin [:id] { module_or_generate_item } end`. Add parseGenerateBlock() that loops parseModuleItem. Also remove the `if (!in_generate) return unsupportedItem()` gate — §6.6 makes the generate region optional and the §6.6.1 rcline2 example uses a bare for at module scope. Inject the §6.6.1 implicit localparam (genvar name and value) into each unrolled iteration's scope in src/ir/lower.zig.
- **Why here** Eleven fixtures from one parser restructuring. It is also the gate for six more validation fixtures and two case-generate fixtures downstream.
- **Risk** Conflating generate-block scope with module scope in name binding. Lowering must keep elaboration-time loops (constant genvar, unrolled) distinct from runtime analog_for; both currently parse to the same Ast.Stmt.for_stmt. src/ir/lower.zig:1459 already distinguishes constant conditions, which covers the if-generate half.

### 20. Vector nets, vector ports and genvar-indexed access

- **LRM** §3.6.3 3.6.3.2 5.9.3 6.5.2.2 2.8
- **Fixtures** 6 (ch03_data_types, ch05_analog_behavior, ch06_hierarchy)
- **Effort** large
- **Site** src/frontend/parser.zig parseNetDecl (~980) and parseNetNames:486 must accept `[msb:lsb]` and net_decl_assignments (`electrical a = 5.0;` as a nodeset); parsePortList:244-267 must accept a range after the discipline. src/ir/lower.zig tryUnrollFor:2144 must unroll genvar-indexed loops, and the E0302/E0301 refusals must move out of the parser and into lowering. Scalarise at elaboration (dt[1..3] becomes dt__1..dt__3) rather than teaching the node table about ranges.
- **Why here** Six fixtures directly and it is the prerequisite for whole-array assignment checking. Scalarisation keeps the flat node list intact, which is the cheap path.
- **Risk** The flat node list is the core data structure. Scalarisation at parse/elaboration time is the low-risk shape; storing ranges in the node table is not. Interacts with the discrete-bus rejection epic, which must keep rejecting reg vectors while electrical vectors start working.

### 21. Replication {n{...}} in concatenations and assignment patterns

- **LRM** §4.2.13 4.2.14 3.3 A.8.1
- **Fixtures** 5 (ch03_data_types, ch04_expressions, annex_a_syntax)
- **Effort** medium
- **Site** src/frontend/parser.zig:1323-1336 (concat) and :1340-1349 (assign_pattern). Two-token lookahead on `{`: constant_expression followed by `{` means replication. Ast.ExprTag.multi_concat already exists and is never produced (see the comment at :1331). Lowering unrolls; the zero-replication case must still evaluate its operand once (§4.2.13) and must be legal inside an outer concatenation. src/ir/lower.zig must reject multi_concat on an assignment LHS (E0317).
- **Why here** Five fixtures across three chapters, one parser rule, and the AST tag is already reserved for it.
- **Risk** Ambiguity with plain concatenation needs two-token lookahead. Non-constant multipliers are legal for strings (§3.3 Table 3-3: `{i{b}}`), so the count cannot be assumed foldable in every context.

### 22. Analog function declaration validation

- **LRM** §4.7.1 4.7.2.2
- **Fixtures** 4 (ch04_expressions)
- **Effort** small
- **Site** src/frontend/parser.zig:779-787 (FuncDecl construction) — reject zero formals; the untyped-formal default to .real at :771-772 must not paper over a missing block-item declaration. src/ir/lower.zig ~3300 — reject named blocks in an analog function body (§4.7.1, the ban exists to dodge shadowing of the implicit return variable) and reject a bare `return;` (§4.7.2.2 requires an expression).
- **Why here** Four fixtures, two sites, all pure rejects on already-parsed structure.
- **Risk** The formal-typing rule needs the parser to record whether a type was declared or defaulted; that is a new bit on FuncArg.

### 23. ddt/idt nature identifier as tolerance argument

- **LRM** §4.5.3 4.5.4 5.5.3 A.8.3
- **Fixtures** 3 (ch04_expressions, annex_a_syntax, annex_d_standard_definitions)
- **Effort** small
- **Site** src/ir/lower.zig lowerIdent (~2450/2654) currently emits E0314 for `Voltage` because natures are not in the expression scope; lowerReactive (~1820-1825) acknowledges the second argument and drops it. Resolve a bare identifier in the abstol slot against self.file.natures plus the Annex D prelude before falling through to E0314, and take its abstol.
- **Why here** Three fixtures across three chapters, one lookup added at one site, and the value is only used for tolerance so DC results do not move.
- **Risk** Only the abstol slot may consult the nature scope; leaking nature names into general expression lookup would shadow variables.

### 24. String literal to integer conversion (and the reject side)

- **LRM** §2.7 2.3 3.3
- **Fixtures** 3 (ch02_lexical, ch03_data_types)
- **Effort** medium
- **Site** src/ir/lower.zig type coercion at :479/487/497/503/511 and lowerAssign (~1338-1357); src/backend/codegen.zig:1950 renders string constants as quoted text. A string literal used as an integer operand is an unsigned big-endian byte sequence (§2.7): "\n"=10, "AB"=16706. Assigning a string VARIABLE to an integral type stays an error (§3.3).
- **Why here** Three fixtures, and it removes a whole class of 'invalid format string' codegen failures.
- **Risk** The conversion must apply in every operand context or it silently produces wrong results on the paths it misses. Literal vs variable is the load-bearing distinction: literals convert, variables do not.

### 25. Discipline compatibility rules (§3.11) for two-net access and branch terminals

- **LRM** §3.11 3.11.1 3.12 7.4.3
- **Fixtures** 3 (ch03_data_types, ch07_mixed_signal)
- **Effort** small
- **Depends on** Access-function / discipline-binding checks (checkAccessMatch early return)
- **Site** src/ir/lower.zig branchOf:1647-1670 resolves hi and lo but only calls checkAccessMatch on hi (:1668) and never compares the two disciplines. Add a compatibility helper implementing §3.11.1 (Self, Natureless, Domainless, Domain/Potential/Flow incompatibility) and call it from branchOf and from branch declaration registration (~604-616).
- **Why here** Three fixtures, one helper, and the helper is reused later by hierarchy discipline resolution.
- **Risk** Getting §3.11.1 wrong in either direction is a conformance regression. The nature relationship graph (base-nature computation) must be complete first.

### 26. __FILE__ and __LINE__ predefined macros

- **LRM** §10.7
- **Fixtures** 3 (ch10_directives)
- **Effort** medium
- **Site** src/frontend/preprocessor.zig:635-636 explicitly denies both with E0114. Expand dynamically from the provenance already tracked in diag.SourceMap (pp.segs) and the physical line, and make the `__line__ directive (currently .ignored at :98) update a remap state on struct Pp.
- **Why here** Three fixtures inside one file, no reach past the preprocessor.
- **Risk** Line numbers must be PHYSICAL source lines, not post-expansion positions, and must restore correctly when an `include pops.

### 27. Vector net range rejection with the right diagnostic (discrete buses)

- **LRM** §3.6.3 7.3.1
- **Fixtures** 3 (ch07_mixed_signal)
- **Effort** small
- **Site** src/frontend/parser.zig net declaration — `reg [7:0] r` dies at E0208 ('expected an identifier') because there is no range alternative in the grammar. Accept the range, then reject it with E0302 (which exists and is used for vector ports), and add the §7.3.1 Table 7-1 width rule in lowering: >31 bits is illegal because bit 31 would land on the integer sign bit.
- **Why here** Three fixtures. VerA is right to refuse these; it refuses for the wrong reason and pins the wrong code.
- **Risk** Overlaps the vector-nets epic in the same parser production. Coordinate: electrical ranges start working, reg ranges keep failing but with E0302.

### 28. default_discipline directive — DISPUTED between two auditors

- **LRM** §10.2 C.4 3.8 7.4
- **Fixtures** 4 (ch10_directives, annex_c_analog_subset)
- **Effort** medium
- **Site** src/frontend/preprocessor.zig:89 (currently .ignored). Two incompatible required behaviours were reported: ch10 wants the directive parsed, its Syntax 10-1 qualifier validated against the closed 15-name list, and discipline resolution implemented so that withdrawing the default makes undeclared nets fail; annex_c cites C.4 ('the `default_discipline compiler directive is not supported in Verilog-A') and wants the directive itself to be an error.
- **Why here** Four fixtures, but the design question must be settled before any code is written. If VerA targets Verilog-A, C.4 is dispositive and the epic collapses to a one-line E0114 — at which point fixtures 35/36/45 need retargeting.
- **Risk** OPEN QUESTION, do not paper over it: is VerA Verilog-A only, or Verilog-AMS? C.4 says reject; ch10 says implement. Implementing it also drags in a real discipline-resolution pass (large), whereas rejecting it is trivial. Resolve scope first.

### 29. Module header syntax extensions (parameter port list, macromodule, named/concatenated ports)

- **LRM** §6.2 6.5.1 A.1.2 A.1.3
- **Fixtures** 6 (ch06_hierarchy, annex_a_syntax)
- **Effort** small
- **Site** src/frontend/parser.zig:201-209 parseModule — accept .kw_macromodule alongside .kw_module (A.1.2 makes them interchangeable), and accept `#( parameter_declaration ... )` before the port list (today `#` hits expect(.semicolon) and yields E0207). parsePortList:244-267 — accept `.ext(inner)` named ports and `{a,b}` concatenated ports (A.1.3 port_expression), which needs an external_name field and a multi-name variant on Ast.Port.
- **Why here** Six fixtures in one function pair. Header parameters reuse the existing ParamDecl lowering unchanged, and the //! param override machinery in src/backend/tb.zig applies to them for free.
- **Risk** Named and concatenated ports change Ast.Port's shape; every consumer and the testbench port-name mapping must handle both. Header parameters are only externally overridable once hierarchy exists, but the fixtures test them locally.

### 30. Branch declaration extensions (port branches, branch arrays)

- **LRM** §3.12.1 A.2.3 A.8.9 5.5.1
- **Fixtures** 2 (ch03_data_types, annex_a_syntax)
- **Effort** small
- **Site** src/frontend/parser.zig parseBranchDecl (~494-513, 1000, 1752) — accept `branch (<p>) name;` (port branch, Syntax 3-9) and `branch (p,n) pair[0:1];` (range on the identifier). Ast.BranchDecl needs an is_port_branch flag and a range; lowering expands the range into distinct branches over the same node pair.
- **Why here** Two fixtures, one parser function, and the range expansion reuses whatever the named-branch keying fix produces.
- **Risk** Branch arrays produce multiple distinct entities over one net pair — depends on the (name, hi, lo) branch keying from the misc-lowering epic landing first, or they collapse.

### 31. Generic potential() / flow() access functions

- **LRM** §4.4 5.5.1 A.8.9
- **Fixtures** 2 (ch04_expressions, ch05_analog_behavior)
- **Effort** small
- **Site** src/frontend/parser.zig:1351-1370 — kw_potential and kw_flow are reserved for discipline declarations and never reach expression parsing, so `potential(b)` dies at E0209. Demote them to context-sensitive names in expression position only and route to the same parseAccess path as V/I; lowering maps them to the discipline's own access opcodes.
- **Why here** Two fixtures; discipline declarations use separate parsing paths so the demotion is safe.
- **Risk** Interacts with the access-function shadowing rule (§3.13.2): if a module declares `real potential;`, the generic spelling must become unavailable, not silently rebind.

### 32. Node and port alias functions ($analog_node_alias / $analog_port_alias)

- **LRM** §9.20 9.20.1
- **Fixtures** 8 (ch09_system_tasks)
- **Effort** medium
- **Depends on** Analog-context restrictions (Tables 9-1/2/3/5/6/7/8 'analog: No' cells)
- **Site** src/backend/codegen.zig:2608-2609 returns constant 0.0 with no argument inspection. Six 'shall be error' rules must be checked at lowering (call site must be analog initial; first argument must be an electrical node declaration, not a port reference; no bit-select; second argument must be a constant string; no duplicate alias target; no conditional alias), plus the actual topology operation at init time and an integer status return.
- **Why here** Eight fixtures, six of which are pure rejects that need only AST shape plus the analog-initial flag. Only two need the real aliasing.
- **Risk** Aliasing mutates circuit matrix topology; a wrong alias corrupts the solution silently. Ship the six rejects first and the topology operation second — the reject fixtures are the majority of the value.

### 33. Generate validation rules (nesting, constant schemes, block naming, parameter ban)

- **LRM** §6.6 6.6.1 6.6.2
- **Fixtures** 6 (ch06_hierarchy)
- **Effort** small
- **Depends on** Generate blocks parse module items (incl. implicit generate region)
- **Site** src/frontend/parser.zig:399-402 — reject `generate` inside `generate` (§6.6: regions do not nest). parser.zig:331-334 — reject parameter declarations inside a generate block. src/ir/lower.zig / analysis.zig — require constant (elaboration-time) expressions in every generate scheme, and register named generate blocks in the parent scope so collisions with declarations, sibling blocks and instance arrays are caught.
- **Why here** Six fixtures once generate blocks parse correctly; four of the six are one-line gates.
- **Risk** Name registration needs generate blocks represented as distinct scope objects, which does not exist yet. Incomplete conflict detection is the likely failure mode.

### 34. case-generate construct

- **LRM** §6.6.2 A.4.2
- **Fixtures** 2 (ch06_hierarchy, annex_a_syntax)
- **Effort** medium
- **Depends on** Generate blocks parse module items (incl. implicit generate region)
- **Site** src/frontend/parser.zig:310-435 parseModuleItem — add .kw_case when in_generate, parsing `case (const_expr) item... endcase` where each arm is a generate_block. Lowering folds the selector and splices the selected arm's module items.
- **Why here** Two fixtures, and it completes the Syntax 6-8 generate trio.
- **Risk** §6.6.2 naming rules differ inside a case (blocks in different arms of one case may share a name; blocks across different generate constructs may not).

### 35. String formatting and scanning ($swrite / $sformat / $sscanf)

- **LRM** §9.5.3 9.5.4.2
- **Fixtures** 4 (ch09_system_tasks)
- **Effort** medium
- **Depends on** Display formatting correctness (%c, argument pairing)
- **Site** src/backend/codegen.zig:2678 lumps all three into void_tasks returning S.con(0.0). They need no file descriptor — the target is an in-memory string variable — so they are separable from the §9.5 file subsystem. Emit a formatter into the string variable and a C-sscanf-shaped parser for the read direction, reusing the cg_display.zig specifier table.
- **Why here** Four fixtures that do NOT need the architectural file-descriptor work, extracted from the §9.5 bundle so they can ship years earlier.
- **Risk** Full printf/scanf semantics are a swamp; scope to the specifier subset cg_display.zig already supports and reject the rest.

### 36. above() edge-triggered state machine

- **LRM** §5.10.3.2
- **Fixtures** 2 (ch05_analog_behavior, ch08_scheduling)
- **Effort** medium
- **Site** src/backend/codegen.zig:2824 emits a stateless level test `expr.val() > 0.0`, so the event re-fires at every solver iteration while the expression stays positive. Mirror the cross() implementation at :2374-2380 with a per-instance __prev field (allocation already exists for cross at :1023); the condition is previous <= 0.0 and current > 0.0, plus the §5.10.3.2 initialisation case.
- **Why here** Two fixtures and the pattern is already written for cross() twenty lines away.
- **Risk** Models that accidentally relied on level-triggered re-firing will change behaviour. The LRM is unambiguous, so this is a correctness fix, not a judgement call.

### 37. transition() piecewise-linear ramp with independent rise/fall

- **LRM** §4.5.8 10.3
- **Fixtures** 4 (ch10_directives, annex_g_change_history)
- **Effort** large
- **Depends on** default_transition operand is mandatory
- **Site** src/backend/codegen.zig:2838-2846 transitionTau() returns `(rise + fall) * 0.5 / 2.2` — a single first-order lag constant used for both directions, so transition(V,0,4n,8n) and transition(V,0,8n,4n) produce identical waveforms. §4.5.8 requires a piecewise-linear ramp with rise_time on positive transitions and fall_time on negative. Also needs the `default_transition operand (preprocessor.zig:90, currently .ignored) threaded into calls that omit rise/fall.
- **Why here** Four fixtures, and the ch10 auditor correctly identified that fixing the directive alone cannot pass 38-40 because the underlying filter is the wrong shape. This is a §4.5.8 bug wearing a chapter-10 costume.
- **Risk** The filter API passes one tau. Fixing it means either branching on edge direction in generated code or a two-constant kernel — either way it touches the shared filter framework, so it cannot run in parallel with other cg_filters work.

### 38. Named events (declare, trigger, detect) within the analog block

- **LRM** §5.10.4 A.2.1.3 A.6.5 C.2
- **Fixtures** 3 (ch05_analog_behavior, annex_a_syntax, annex_c_analog_subset)
- **Effort** medium
- **Site** src/frontend/parser.zig:365 rejects `event` with E0203; src/ir/lower.zig:2324 rejects @(named) with E0705. Needs: event declarations in the module item list, `->` trigger, @(ev) detection, an event table in lowering, and a flag variable per event in codegen (set on trigger, tested at the next accepted step per §5.8.1).
- **Why here** Three fixtures across three chapters. Analog-only named events do not require a digital scheduler — a per-instance boolean and the existing step model suffice.
- **Risk** C.7 excludes DIGITAL events; whether analog named events are inside the Verilog-A subset is an interpretation (C.2's 'a set of events' vs C.7's exclusion). If they are out of subset, the correct answer is a clean rejection, not an implementation — settle before building.

### 39. Contribution value retention and flow-source readback

- **LRM** §5.4.2.2 5.6.1.2 5.6.1.3
- **Fixtures** 3 (ch01_intro, ch05_analog_behavior)
- **Effort** medium
- **Site** src/ir/lower.zig lowerBranchAccess:2835-2853 mints a flowUnknown (:923) for every I() read, seeded to 0 at :1733, and never stamps accumulated flow contributions into it — so reading a flow SOURCE returns 0 instead of the retained value. Separately, the accumulator at :302/:1722-1750 sums all contributions to a branch; §5.6.1.3 requires a contribution of the opposite kind to REPLACE the retained value, not add to it.
- **Why here** Three fixtures and it removes a genuine wrong-answer class (the LRM's own worked example in §5.6.1.3 yields 7.0; VerA yields 8.0).
- **Risk** Flow probes (uncontributed branches) must still read 0 while flow sources read their accumulation — the distinction is whether a Contribution with .flow access exists. Changing accumulation from sum to replace-on-kind-mismatch touches every contribution path.

### 40. Filter and analysis-function completeness (last_crossing directions, z-filter tau, null zeros, ac_stim, ddx)

- **LRM** §4.5.10 4.5.11 4.5.12 4.6.3
- **Fixtures** 4 (ch04_expressions)
- **Effort** medium
- **Depends on** Analog operator & event argument validation (filter and cross/above bounds)
- **Site** src/backend/codegen.zig — last_crossing ignores direction, so only +1 works and -1/0 return 0.0; zi_* filters blanket-refuse the optional t/t0 tail, so the legal non-zero-tau form is rejected alongside the illegal zero-tau-to-branch form; E0505 rejects the `,,` null zeros argument that §4.5.11/4.5.12 explicitly permit (empty product = unity numerator); ac_stim emits @compileError and has no lowering at all (§4.6.3: return the phasor when the analysis name matches, zero otherwise).
- **Why here** Four fixtures in one subsystem; ac_stim in particular is small (stateless conditional on analysis type) and currently produces a compile error.
- **Risk** The zero-tau z-filter rule is context-dependent (illegal assigned directly to a branch, legal assigned to a variable), which needs statement type tracked in lowering.

### 41. Expression semantics gaps (short-circuit ternary, ternary analog-operator ban, access shadowing, integer width)

- **LRM** §3.2 3.13.2 4.2.3 4.2.12 4.5.15
- **Fixtures** 4 (ch04_expressions, ch03_data_types)
- **Effort** medium
- **Site** src/ir/lower.zig:2504-2511 evaluates BOTH ternary arms and selects, so side effects in the unselected arm still happen (§4.2.3 forbids this) and cond_depth never rises, so the §4.5.15 E0514 check at :3045-3049 never sees an analog operator in a ternary arm as conditional. Fixing short-circuiting means real CFG branching with a phi at the join (mirroring lowerCondBody ~1931). Separately: integer is lowered as i64 but §3.2 specifies 32-bit wrap; and §3.13.2 access-function shadowing needs the access name suppressed when a module declares an identifier of the same name.
- **Why here** Four fixtures. The ternary arm-depth fix (one fixture) is small and independent of the short-circuit rewrite (one fixture) — ship the cheap half first.
- **Risk** Short-circuiting moves the ternary from a straight-line select to a branching construct; proof and codegen both assume straight-line. Integer width is a change to every integer operation and will flip 72_integer_overflow_wrap's current asserted value.

### 42. $simparam completeness and parameter derive coverage

- **LRM** §9.15 6.3.4 3.4.7
- **Fixtures** 4 (ch09_system_tasks, ch03_data_types, ch06_hierarchy)
- **Effort** small
- **Site** src/backend/codegen.zig:2563-2572 answers an unknown $simparam with a silent default instead of the §9.15 error when no fallback is supplied, and its known list (gmin, tnom, scale, shrink, sourceScaleFactor) lacks timeUnit/timePrecision from the `timescale directive. Separately, src/backend/codegen.zig emitModelStruct (~800) emits no Model field for aliasparam names (testbench fails with 'no field named trise'), and src/backend/cg_filters.zig f64Const() covers only arithmetic/abs/sqrt/min/max/pow so a parameter defined by a transcendental stays folded at its initial value.
- **Why here** Four fixtures across three chapters, all lookup-table or emission-coverage gaps in codegen with no semantic design work.
- **Risk** Turning the silent $simparam default into an error may break models that quietly relied on 0.0 — which is exactly the corruption §9.15 is guarding against.

### 43. Assorted single-site semantics (multidim arrays, $limit function limiter, paramset decl, nature attribute reference, whole-array assignment, macro-substituted based numbers, analog-initial re-execution, array formals, attribute validation)

- **LRM** §2.6.1 2.9 3.2 4.7.2.3 5.2.1 5.5.3 5.7 6.4 9.17.3
- **Fixtures** 13 (ch03_data_types, ch04_expressions, ch05_analog_behavior, ch02_lexical, ch08_scheduling)
- **Effort** medium
- **Depends on** Vector nets, vector ports and genvar-indexed access; Number and attribute lexing gaps
- **Site** Nine unrelated items: parseArrayRange (~parser.zig:1900) must loop for additional dimensions (§3.2 allows `{dimension}`); $limit's second argument may be an analog_function_identifier (Syntax 9-12 third form) and must be looked up in the function table, not as a value; accept a paramset declaration at parser.zig:122-126 without instantiating it; accept `V(x).abstol` (Syntax 5-4 nature_attribute_reference) after an access call; validate array assignment shape (§5.7) once vectors exist; join macro-substituted based-number tokens (§2.6.1 explicitly permits macro substitution of all three tokens, but the preprocessor expands before the lexer assembles them); re-execute analog initial per parameter-sweep sub-task (src/ir/lower.zig:635-638 guards it on initial_step, which fires once per analysis, not per sub-task); array formals with assignment-pattern actuals in analog functions (parser.zig:716-735); and capture attributes into the AST so their values can be required constant (§2.9) and domain-checked (§2.9.2 desc/units/op/multiplicity).
- **Why here** Thirteen fixtures with no shared root cause and no shared file beyond the parser. Grouped only so they can be swept in one pass; each is independently shippable.
- **Risk** The macro-substituted based number is the odd one out and is genuinely large: macro expansion runs before lexing, so joining the three tokens means either provenance marking or deferring based-number assembly to the parser. Consider dropping that one fixture rather than restructuring the front end for it.

### 44. $table_model isoline interpolation

- **LRM** §9.21
- **Fixtures** 2 (ch09_system_tasks)
- **Effort** large
- **Depends on** Vector nets, vector ports and genvar-indexed access
- **Site** src/ir/lower.zig:2457 blocks $table_model with E0801; the comment at src/backend/codegen.zig:2699 states the honest reason ('no isoline interpolator'). Needs table declaration parsing, multi-dimensional array management, an interpolation formula and boundary handling.
- **Why here** Two fixtures for a complete numerical subsystem — the worst ratio among non-architectural epics. Deferred deliberately.
- **Risk** Table interpolation is a subsystem, not a feature. The current refusal is accurate and self-consistent; leaving it refused costs two fixtures.

### 45. Testbench Newton solver (indirect contributions and self-driven nodes)

- **LRM** §5.6.7 5.6.7.1 5.6.1 A.6.10
- **Fixtures** 4 (ch05_analog_behavior, annex_a_syntax, annex_g_change_history)
- **Effort** large
- **Site** src/backend/tb.zig:356-422 emitPoint writes //! bias values straight into x[] at :389-390, calls point() and step(), and never iterates. Indirect contributions parse and lower correctly (the `:` syntax and the constraint equation are both emitted) — the unknown simply never moves off its initial guess. Same root cause for 22_input_port_contribution_honoured, where the residual and Jacobian are stamped correctly but nothing solves them.
- **Why here** Four fixtures, zero compiler changes. This is a harness gap that three separate auditors independently diagnosed and were explicit about ('the gap is the harness and not the compiler').
- **Risk** Adding a nonlinear solver to the test harness changes how every fixture is validated. The alternative — declaring that the harness evaluates rather than solves, and retargeting these four fixtures — is legitimate and much cheaper. Decide which before writing a solver.

### 46. Signal-flow contribution codegen

- **LRM** §1.3.4 1.3.4.1 1.3.4.2 3.6.2.2
- **Fixtures** 3 (ch01_intro)
- **Effort** large
- **Depends on** Signal-flow port direction and contribution-target rules; Contribution value retention and flow-source readback
- **Site** src/backend/codegen.zig signalFlowNet:838-849 identifies single-nature directional ports and :1115-1129 pre_fatals the whole contribution. §1.3.4.1/2 require these contributions to WORK (as a source to a proxy node for potential, a current source for flow), not to be refused.
- **Why here** Three fixtures, but they also depend on flow-source readback landing first, so the marginal cost after those epics is lower than it looks.
- **Risk** OPEN DESIGN QUESTION: signal-flow ports are meaningful when instantiated and connected to a conservative node elsewhere. In a flat single module there is no such connection, so how a signal-flow source enters the nodal system is undefined by the LRM and unresolved here. The fixtures sidestep it with mixed flat modules; the general answer needs hierarchy.

### 47. Probabilistic distributions ($random, $arandom, $dist_*, $rdist_*)

- **LRM** §9.13 9.13.1 9.13.2
- **Fixtures** 19 (ch09_system_tasks)
- **Effort** architectural
- **Site** src/ir/lower.zig:2444-2463 isRejectedSysFunc blanket-rejects all 17 names with E0801 before any argument is examined. Unblocking requires: removing the rejection, adding per-distribution argument validation (integer seed, domain constraints such as exponential rate > 0, uniform start/end), a seeded RNG stream in the Kernel, and per-instance RNG state in the Instance struct (tools/contract.zig).
- **Why here** Nineteen fixtures — the second-largest single block — but the current refusal is principled, not lazy: the comment in lower.zig explains that a draw changing between Newton iterations makes the residual non-deterministic and the solve never converges.
- **Risk** OPEN QUESTION, unresolved: when is the RNG state allowed to advance? Per Newton iteration destroys convergence; per operating point needs a defined reset boundary in the Kernel contract that does not exist. Six of the nineteen fixtures are pure argument-validation rejects and could ship behind a still-refused RNG if the rejection is moved after argument checking — that is the cheap partial win worth taking.

### 48. File descriptor I/O subsystem (§9.5)

- **LRM** §9.5 9.5.1 9.5.2 9.5.4 9.5.5 9.5.6 9.5.7 9.5.8
- **Fixtures** 19 (ch09_system_tasks, combined)
- **Effort** architectural
- **Depends on** String formatting and scanning ($swrite / $sformat / $sscanf)
- **Site** src/backend/codegen.zig:2671-2685 lowers every §9.5 task to S.con(0.0) via void_tasks — including $fopen, whose 0 return is the LRM's failure code. src/ir/lower.zig:2365 keeps the f-tasks out of isDisplayTask, and the comment at :2362 states the reason: the descriptor is something 'the compiled device has no way to own'. Requires descriptor storage on the Instance struct in tools/contract.zig (ABI-critical) and a host-side handle table.
- **Why here** Nineteen fixtures, but every one needs a host file table that the device-kernel contract does not have. The four string-formatting fixtures were split out precisely because they need no descriptor.
- **Risk** File lifetime must track instance lifetime across operating points; the Instance struct is ABI-critical; and the multichannel-descriptor mode (§9.5.1, bit per file, OR'd for multi-file writes) is a second representation on top of the fd mode. This is a contract question, not a codegen bug.

### 49. $simprobe and unregistered VPI analog system functions

- **LRM** §9.16 12.32.3 2.8.3
- **Fixtures** 2 (ch09_system_tasks, ch12_vpi_routines)
- **Effort** architectural
- **Depends on** Module instantiation and hierarchy elaboration
- **Site** src/ir/lower.zig:2459 refuses $simprobe (no sibling instance to probe); src/backend/codegen.zig:2699-2700 aborts on any unrecognised system function because 'a substitute value would corrupt the model'. §12.32.3's own sampnhold example puts an unregistered $sampler in a contribution, so the grammar must accept it even though the value is host-supplied.
- **Why here** Two fixtures for a VPI host subsystem. A cheap partial exists: emit 0.0 with a loud warning for unregistered systfs rather than aborting codegen — that alone would flip the ch12 fixture.
- **Risk** The abort is defensible: silently substituting 0.0 turns 'whatever the host registers' into 'always zero' and hides real model bugs. The warning-plus-zero compromise needs a decision, not just code.

### 50. Module instantiation and hierarchy elaboration

- **LRM** §6.2.2 6.3 6.7 E.2 E.2.1 E.2.2 E.3 F.1 F.2 A.4.1
- **Fixtures** 47 (ch06_hierarchy, ch03_data_types, annex_e_spice, ch05_analog_behavior, annex_a_syntax)
- **Effort** architectural
- **Site** src/frontend/parser.zig:406-415 detects `identifier #` or `identifier identifier (` at module scope and emits E0204 unconditionally. Beyond the parser: an elaboration pass in src/ir/lower.zig (which today checks kind == .module at :2315 and assumes one flat body at :546-560) to bind ports, apply parameter overrides, flatten child equations and resolve hierarchical names; src/ir/analysis.zig for scope resolution; src/backend/codegen.zig and src/ir/mir.zig both assume a single flat body with one unknown set. Annex E adds a second lookup path for SPICE primitives, models and subcircuits with E.3.3 name shadowing and case-insensitive fallback.
- **Why here** Forty-seven fixtures directly and twenty-seven more downstream — 74 of 337, over a fifth of the whole gap, behind one feature. Ranked last among value-producing epics anyway because the effort is a pipeline redesign, not a feature: every stage after the parser assumes one flat module.
- **Risk** This breaks the founding assumption of the IR. Elaboration must produce something the existing flat MIR can still consume (inline-and-flatten) or the MIR gains a hierarchy concept and every consumer changes. Annex E additionally needs a resolver that can defer to built-in SPICE definitions. Do not start this in parallel with anything else that touches lower.zig or codegen.zig.

### 51. Hierarchy dependents (defparam, paramset instantiation, OOMR names, $mfactor propagation, Annex F resolution, gate primitives, driver access)

- **LRM** §6.3.1 6.3.6 6.4 6.4.2 6.7 9.19 9.22 9.23 A.4.1 F.2.1 F.2.2
- **Fixtures** 27 (ch06_hierarchy, annex_a_syntax, annex_e_spice, annex_f_resolution, ch09_system_tasks, ch08_scheduling)
- **Effort** architectural
- **Depends on** Module instantiation and hierarchy elaboration
- **Site** All blocked on elaboration existing. defparam at parser.zig:433 plus hierarchical parameter binding; paramset declaration and §6.4.2 range-based binning selection at instance elaboration; hierarchical identifiers (`u.gain`, `$root.top.x`) in parsePrimary (~1200) plus out-of-context dotted net declarations in parseNetNames:470-487; $mfactor propagation and double-scaling detection; the Annex F post-order depth-first discipline resolution with continuous-over-discrete precedence, conflicting out-of-context declarations, and the mixed-port unknown-discipline error; gate/switch primitives at parser.zig:426; and the whole connectmodule driver-access family (codegen.zig:2640-2644 stubs all seven to 0, @(driver_update) is unparsed). **[BOTH HALVES NOW FALSE. The stubs are deleted, not made unreachable: legality is decidable at the call SITE, so lowering refuses the eight names with E0818. `connectmodule`/`endmodule` and A.6.5's `driver_update expression` parse — one `module_keyword` arm and one `parseEventTerm` arm — and `elaborate.pickTop` skips connect modules per §7.6. No second codegen path was built or needed; a connect module is recorded and never lowered.]**
- **Why here** Twenty-seven fixtures that are all cheap-to-medium individually and all unreachable until elaboration lands. Listed as one epic because sequencing them separately before wave 5 would be fiction.
- **Risk** The Annex F traversal order is specified precisely but post-order DFS over a dynamically discovered signal graph fails silently when wrong. Connectmodules are a genuinely separate abstraction (digital event routing, driver state) and may deserve to stay out of scope even after hierarchy lands — that is 9 of the 27. **[The risk was real and the scoping was wrong. Nine of those fixtures ask VerA to REFUSE the call, not to perform it, so no abstraction was needed. The tenth (`38_driver_update_connectmodule.va`) needs the keyword to PARSE and says so at length in its own header: its only CHECK is on a branch potential in a separate ordinary module and the connect module is never instantiated. Real driver access, if it ever lands, is an optional-contract-decl (the `display`/`u_abstol`/§9.5 shape) with the HOST supplying the per-net driver list — not a scheduler inside VerA.]**

### 52. Out of Verilog-A scope (initial/always blocks, digital reg, both-contexts assignment)

- **LRM** §4.5.15 5.2.1 7.2.2 C.7 A.1.4
- **Fixtures** 4 (ch04_expressions, ch05_analog_behavior, ch07_mixed_signal)
- **Effort** architectural
- **Site** src/frontend/parser.zig:434 rejects `initial`, `always` and `reg` as unsupported module items. The rules these fixtures document (§4.5.15 forbids analog operators in initial/always; §5.2.1 forbids reading digital values from analog initial; §7.2.2 forbids assigning one variable in both contexts) are all MASKED by the earlier subset rejection, and every auditor said so explicitly.
- **Why here** Four fixtures that are conformance records, not actionable gaps. They require a digital scheduler and event kernel — a second simulation domain — which is outside the Verilog-A subset VerA targets.
- **Risk** None if left alone. These should arguably be reclassified from XFAIL to 'out of subset' so the XFAIL count reflects real work.
- **[WRONG, and this was the plan's biggest single error. None of these needed a digital scheduler. Each states a real rule that VerA never REACHED because `always`/`initial`/`reg` died at E0205 first. Making the E0205 report add to the diagnostic bag instead of setting `Parser.failed` lets the body parse through the ANALOG statement production and be judged: §4.5.15 fires as E0422, §4.7.3 as E0430, §5.2.1 as E0431 and §7.2.2 as E0432. Five fixtures closed with no execution model, no event queue and no delta cycles, and 24 green fixtures that pin E0205 together with the words `initial`/`always`/`reg` kept the exact diagnostic they pin. The two `discrete_bus_*` fixtures did NOT close, and not for want of capability — see STATUS above.]**

## Notes

ARITHMETIC. Summing the raw per-chapter fixture lists after merging duplicates gave 340, three over the 337 XFAIL baseline. I could not textually resolve the last three, so I trimmed three counts where cross-chapter double-claiming is most likely: file I/O 20->19 (combined/08_file_and_display_side_effects.va describes the identical §9.5 gap as ch09's 031-054 block and may be the same fixture counted twice), analog-context 11->10 (annex_g/13_realtime_analog_context_rejected.va and ch09/148_realtime_analog_rejected.va are the same rule reported by two auditors), and replication 6->5 (ch03/77_assignment_pattern_replication.va vs ch04/144_assignment_pattern_replication.va). If those are genuinely distinct files, three epics are undercounted by one each and the true total is 340 — meaning three fixtures elsewhere in the raw data are not actually XFAIL. Do not treat the per-epic numbers as exact to +/-3.

FIXTURES DOUBLE-CLAIMED AND WHERE I PUT THEM. 06_display_formats.va was claimed by both the %c fix and the string-formatting epic; assigned to %c (trivial, lands first, and it is what currently breaks compilation of the file). 044/045/046/048 (swrite/sformat/sscanf) were inside the 24-fixture §9.5 block; pulled out into their own epic because in-memory string formatting needs no file descriptor and should not wait on the contract redesign — that is 4 fixtures moved from architectural to medium. generate_implicit_localparam.va appeared in two ch06 features; counted once. annex_f's out_of_context_declaration.va and conflicting_ooc_declarations.va appeared in both its module-instantiation epic and its OOC epic; assigned to the hierarchy-dependents epic since hierarchy must land first. ch01's 12_flow_signal_flow.va was claimed by both the signal-flow codegen epic and the testbench port-flow bias epic; assigned to codegen, leaving the tb.zig unknownName:237-242 port-flow fix with zero net fixtures (still worth doing, it is what makes the signal-flow fixtures testable).

AUDITORS WHO CONTRADICTED EACH OTHER.
1. default_discipline. The ch10 auditor wants the directive parsed, its Syntax 10-1 qualifier validated, and a real discipline-resolution pass built (large). The annex_c auditor cites C.4 verbatim — 'the `default_discipline compiler directive is not supported in Verilog-A' — and wants it to be a hard error (trivial). These cannot both be satisfied: if the directive is an error, fixtures 35/36/45 need retargeting. This is the single biggest open scope question in the audit: is VerA Verilog-A only, or Verilog-AMS? Answer it before touching preprocessor.zig:89.
2. Named events. The ch05/annex_a auditors treat them as implementable analog features (§5.10.4). The annex_c auditor flagged the interpretation risk directly: C.2 lists 'a set of events' as in-subset while C.7 excludes digital events, and it is not settled which side analog named events fall on. If out of subset, the correct deliverable is a clean rejection, not an implementation.
3. transition(). The ch10 auditor discovered while investigating `default_transition that fixtures 38-40 cannot pass by fixing the directive alone, because codegen.zig:2838 implements transition() as a first-order lag rather than §4.5.8's piecewise-linear ramp. The annex_g auditor found the same bug independently from the opposite direction (rise/fall binding). They agree; I merged them, but note the fix was mislabelled as a chapter-10 gap in one report.
4. Verilog-A subset in general. Several 'architectural' labels are really 'out of subset' — always/always blocks, digital reg, connectmodules. Four fixtures (wave 7) are conformance records for rules that C.7 makes unreachable. Every auditor said so; none of them proposed reclassifying. I did.

SITES REPORTED AS NOT FOUND OR UNVERIFIED. The ch05 auditor could not confirm implicit_zero_contribution.va is actually in the XFAIL set ('may be a false positive or requires re-examination') and I excluded it from all counts. The annex_e auditor reported port_discipline_ignored_on_module.va as PASSING and the annex_c auditor reported 16_unused_ams_words_rejected.va as PASSING; both excluded. The ch07 auditor filed two zero-fixture entries (case equality, casex/casez 'already implemented') that are just confirmations — but the annex_c auditor then showed that the casex/casez path is unreachable: E0416 exists at lower.zig:2010 and never fires because parser.zig:937 has no .kw_casex/.kw_casez arm, so the construct dies as a failed expression parse instead. Two auditors looked at the same diagnostic and reached opposite conclusions; annex_c is right.

DISPUTED LRM CLAIMS. (a) 31_begin_keywords_unterminated.va: the ch10 auditor argues E0137 is wrong, that §10.6's 'even across source code file boundaries' means an unclosed `begin_keywords is legal at EOF, and that a previous author misread the clause. I agree with the fixture, but this inverts a deliberate check — worth a second reading before deleting it. (b) 40_access_name_shadow.va: the ch03 auditor concluded VerA's current E0209 behaviour is actually LRM-compliant once §3.13.2 shadowing is understood, and that the fixture may be testing that shadowing is permitted rather than that access succeeds. The fixture's intent is unclear; clarify it before writing code. (c) 118_modulo_negative_divisor.va: not a modulo bug at all — the range analysis in src/ir/analysis.zig does not fold unary minus on literals, so `-3` widens to full s64 and E0601 fires spuriously. The fix is in range analysis, not in modulo lowering. (d) driver_access.vams: the omission at preprocessor.zig:868 has an explicit source comment declaring it out of scope, but Annex D is normative. Adding it is trivial; it does drag digital driver-access macros into a compiler that refuses digital driver access.

GENUINELY OPEN DESIGN QUESTIONS, unresolved by this audit.
1. RNG and convergence (19 fixtures). When may a random draw advance? Per Newton iteration destroys the residual's determinism and the solve never converges; per operating point requires a reset boundary in the Kernel contract that does not exist. The blanket refusal at lower.zig:2444 is the only currently self-consistent rule. Cheap partial: move the rejection to AFTER argument checking and six of the nineteen (the pure reject fixtures 115/116/117/150/151/166) pass while the RNG stays refused. **[ANSWERED, all 19: the premise was right and the conclusion was wrong. §9.13.1/§9.13.2 make the seed a SOURCE VARIABLE — "a value is passed to the function and a different value is returned" — so a variate is a pure function of that variable's incoming value and is automatically fixed for the whole Newton loop at one operating point. Lowering splits one source call into two pure calls over the seed. The seedless forms have no such variable, so their "internal seed" is an `Instance` latch advanced by `updateState` on the ACCEPTED step and read only by `eval` — the boundary the contract already had. The four argument-rule negatives reject at E0816, per-argument, so they fire whether or not the family is supported.]**
2. Where does I/O live (19 fixtures)? A compiled device has no host file table. Threading descriptors through the Kernel changes the simulator-device contract in tools/contract.zig. The alternative — I/O happens in the generated testbench, not the evaluation kernel — is cheaper but does not match what the fixtures ask for. **[ANSWERED, all 19, and the "alternative" turned out to BE what the fixtures ask for. The descriptor table is a HOST facility (`src/backend/file_kernels.zig`) carried only by the printing artifact, and every §9.5 call is sequenced in that artifact's per-accepted-point phase — the same optional `display` decl §9.4's prints go through, which §9.5.2 ("$fdisplay … the same as $display") and §9.5.9 ("the file write operations shall not be performed unless the iteration is accepted") both point at. `eval` never opens, reads or writes, which is what keeps the residual a pure function of x. A device compiled for a solver has no such phase, so its `$fopen` answers 0 — and §9.5.1 reserves exactly that for a file that cannot be opened, so the degraded path is conformant and not a stub.]**
3. Signal-flow sources in a nodal system (3 fixtures). §1.3.4 guarantees mixed conservative/signal-flow modules work, but a signal-flow port is only meaningful when connected to a conservative node in a parent — which requires hierarchy. How a signal-flow source enters the matrix in a flat module is not specified by the LRM and not decided here. **[ANSWERED without needing the parent. §1.3.4.1's potential-only net needed no special case at all — the ordinary branch relation reduces to it, the KCL row at the net being `ib = 0`. §1.3.4.2's flow-only net gets `codegen.zig flowOnlySignalFlowNet`: the node's one unknown IS its flow, so the row is `x[n] − c` and not a KCL injection. `signalFlowNet`'s blanket refusal is gone.]**
4. Does the test harness solve or evaluate (4 fixtures)? src/backend/tb.zig:389 writes bias values into x[] and never iterates. Three auditors independently hit this. Either add a Newton loop (large, changes how every fixture validates) or declare the harness an evaluator and retarget the four constraint fixtures. This is a policy call, not an engineering one. **[ANSWERED: the Newton loop was added, and NO fixture was retargeted. `tb.zig` iterates on the residual the device stamps, and a new `//! solve` directive says which unknowns are the device's to determine — `//! bias` still pins what it names, `//! solve` frees only the rest, so a fixture needing one terminal grounded and another solved writes both lines. `unknownName` additionally takes `I(p,n)`, `I(a)` and `I(<a>)` onto §5.4.2/§5.4.3's own unknowns, so a port flow is expressible as a precondition. 17 fixtures still write the old mangled `flowZ28pZ2cnZ29` spelling; that is behaviour-neutral portability debt, not a gap.]**
5. Elaboration shape (74 fixtures downstream). Does elaboration inline-and-flatten child modules so the existing flat MIR survives unchanged, or does the MIR gain a hierarchy concept? Every consumer of src/ir/mir.zig depends on the answer. Inline-and-flatten is the lazy path and probably right for a device compiler, but it forecloses hierarchical name access at runtime (§6.7) and $simprobe. **[ANSWERED: inline-and-flatten, in `src/ir/elaborate.zig`, and the foreclosure did not happen. §6.7 out-of-module references resolve because flattening interns the dotted path as one name (`Lower.flatName`, which also strips `$root.` and the top module's own name and is where §6.2.1's local-scope-first rule lives), and a path that does not resolve is E0901. `$simprobe` is a name lookup in the flattened design, not a walk of a live netlist, and is green. The flat MIR survived unchanged.]**
6. Connectmodules (10 fixtures: driver access plus @(driver_update)). Even with hierarchy, these need digital event routing and driver state management — a second codegen path. Worth deciding explicitly whether they are in scope rather than inheriting them as hierarchy dependents. **[ANSWERED, and the premise was wrong: none of the ten needed either. Nine ask for a REFUSAL (E0818 at lowering, §9.22 paragraph 3) and the tenth needs the keyword to parse. Deciding explicitly was the right instinct; the deciding was done by reading the ten fixtures rather than the audit.]**

ONE CORRECTION TO A RANKING INPUT. Several auditors marked pure-validation epics 'blocked_by' a parent that only supplies shared state (e.g. every Table 9-x radix-variant reject 'blocked by' analog-context restrictions). Those are not real dependencies on separate work — they are the same epic reported at two granularities, which is why the ch09 chapter appears to have 40+ features when it has about 15. I merged rather than sequenced them; the ch09 raw output overstates its feature count by roughly 2x for this reason. **[The merge was right and the ch09 outcome confirms it: what looked like 40+ features and 65–78 xfails was four walls and a short tail, and closing a wall took eleven to twenty-five fixtures green at once. ch09 now carries zero xfails.]**
