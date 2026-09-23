# IEEE Clause4 remaining data-type source/evidence audit

2026-09-23. Read complete extracted §§4.1–4.7, §4.9 including examples,
and §4.11. Printed21–32,34–35,39–40 / physical51–62,64–65,69–70.
Source docs/1364-2005.pdf SHA256
3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e.
Tables4-2/3/4 at physical57 and Tables4-5/6 plus unresolved-net rule at61
visually inspected. Syntax4-1/2 and capacitive Figures4-1/2/3 received text
review only; no visual-source-fidelity closure claimed for those artifacts.

§4.8 integer/real/time dependencies and §4.10 parameters remain with their
existing math/type/parameter source ledgers rather than duplicated here.
The source's §4.10.3 text was visible during boundary inspection but is not
claimed as a completed syntax/table audit by this report. See the Clause16
report for actual SDF annotation obligations, not parameter acceptance alone.

## Requirement groups and inherited/AMS distinctions

| ID | Source | Obligation / evidence limit |
|---|---|---|
| TYPE4-VALUE | 4.1 | Four values independently stored per bit; named events have no storage and real differs. z usually behaves like x in operators but MOS pass-through is an explicit exception. Do not collapse z universally. |
| TYPE4-INIT | 4.2.1/2 | Undriven ordinary nets initializez, trireg initializesx at declared charge; reg/integer/time initializex, real/realtime0. Variable declaration initialization behaves as blocking initial assignment, not an unconditional before-all-initial ordering. Existing analog zero defaults do not prove digital defaults. |
| TYPE4-DECL | Syntax4-1/2 | Net versus variable declaration forms, dimensions, signedness and initializers; net redeclarations forbidden subject to port namespace overlap. Strength/delay combinations require separate syntax negatives, not blanket refusal of valid declarations. |
| TYPE4-VECTOR | 4.3.1 | Left bound isMSB regardless numeric ordering; constant integer bounds may be negative/equal/ascending; modulo2^width arithmetic; vector maximum must allow at least65536bits. New negative-bound legal fixture fails. Boundary maximum not stress-tested here. |
| TYPE4-ACCESS | 4.3.2 | vectored/scalared are advisory. If implemented, vectored may restrict selects/strengths; scalared permits selects and PLI expanded representation. Do not require a single implementation choice for optional vectored restrictions. |
| TYPE4-STRENGTH | 4.4 | Charge only on trireg, defaultmedium; declaration drive strength accompanies net declaration assignment. Gate strength is a separate syntax. Existing primitive/trireg reports remain linked; unequal strengths not covered by new equal-strength table case. |
| TYPE4-IMPLICIT | 4.5 | Port declaration inference uses declared vector width; undeclared instance terminals and continuous LHS infer scalar default-nettype subject to visible prior declarations. Inferred name belongs to reference scope, including generate-local isolation. Arbitrary expression reads do not universally infer nets. |
| TYPE4-RESOLVE | 4.6.1/2 | wire andtri synonyms; wand/triand andwor/trior respective synonyms. Tables assume equal strengths. New packed-lane test observes every ordered value pair for all six names. No claim about unequal strengths or many-driver ordering. |
| TYPE4-CHARGE | 4.6.3 | trireg driven0/1/x versus capacitiveall-z; last driven value persists. Connected capacitors share charge by size; equal-size opposite values become x. Charge strength reverts after disconnection. Prior hold/decay tests do not establish these network behaviors. |
| TYPE4-PULL | 4.6.4 | tri0/tri1 include a permanent pull0/1 driver, not unconditional default overriding competing strengths. Tables4-5/6 assume strong explicit drivers. Existing d03_05 is a lead, not newly exhaustive evidence. |
| TYPE4-UWIRE | 4.6.5 | Each bit has at most one driver even if multiple values agree. Bidirectional switch terminal forbidden; hierarchy must enforce restriction or warn under12.3.9.3. New direct positive/negative pair executes as intended. Hierarchical and partial-bit cases remain open. |
| TYPE4-SUPPLY | 4.6.6 | supply0/1 have supply strength; ordinary value-only observation cannot prove strength. Prior strength review owns competing-driver tests. |
| TYPE4-REG | 4.7 | Procedural assignments update retained reg value; reg can model combinational logic, not necessarily hardware storage. No new syntactic restriction inferred from modeling motivation. |
| TYPE4-ARRAY | 4.9 | Every dimension has constant integer bounds, may be negative; element width independent of array size; all dimensions indexed for an element access. Complete/partial dimensions cannot be assigned or used as expression values. All variable types allow arrays; net arrays also legal. Minimum supported maximum is2^24elements; not exercised here. |
| TYPE4-NAMESPACE | 4.11 | Global module/primitive definitions share unique names; macro namespace separate and ordered redefinition overrides. Local block/module/generate/port/specify/attribute spaces have specific overlap. Attribute redefinition is legal; port names can be reintroduced with permitted net/variable declaration. Blanket duplicate-name tests must not reject these exceptions. |

IEEE's array restrictions are not a license to reject valid Verilog-AMS array
extensions. Conversely, acceptance under an AMS extension does not independently
prove a pure inherited IEEE negative. New positives use ordinary IEEE forms;
the new negative concerns uwire's explicit single-driver requirement. Existing
AMS nature/discipline, signal-flow and analog variable-initialization behavior
remains separately accounted in conformance-types.md and related ledgers.

## New fixtures and measured results

All paths under tests/fixtures/digital; direct runs use current root
zig-out/bin/vera --run from own worktree. No compiler edits/full builds.

- audit_type_net_resolution_tables: sixteen packed lanes enumerate driver
  pairs in MSB-first row order00,01,0x,0z,10,...,zz. Source table rows yield
  wire/tri0xx0x1x1xxxx01xz; wand/triand000001x10xxx01xz;
  wor/trior01x01111x1xx01xz. Exit0, all three exact transcript lines.
  Per-bit independence allows parallel lanes; this is not a timing test.
- audit_type_negative_vector_bounds: [-2:1] and[1:-2] each width4;
  assigning17 retains0001; [-3:-3] width1 retains1 from3. Exit1/E1100
  declaration bounds must be literal integers. Negative constants are legal
  constant expressions; no rejection marker substitutes for intended output.
- audit_type_multidimensional_array:4-bit words indexed[-1:0][2:1], dynamic
  index reads5 while unrelated word9 remains; assigning17 truncates to1
  without changing word14. Exit1/E1100 only one unpacked dimension implemented.
  Bounds and multidimensional access remain unobserved after this first blocker.
- audit_type_uwire_single_driver: one driver transitions0 then1, observations
  separated by1ns. Exit0, exact `zero=0`, `one=1`.
- audit_type_uwire_multiple_drivers_rejected: two constant1 drivers on samebit,
  required error despite agreeing values. Exit1/E1100 with distinctive
  `a uwire net accepts a single driver`. Explicit `// digital-runner: reject`
  and matching nonempty diagnostic marker ensure intended digital collection;
  the legal single-driver neighbor distinguishes broad unsupported refusal.

Prior Clause7 review freshly exercised d03_08/d03_09 single-trireg hold/decay
and found their historical unsupported comments stale. That remains bounded
evidence, not new proof of capacitive networks or complete Chapter4 behavior.
No syntax-only acceptance closes a table or value-transition obligation.

## Residual source and evidence boundaries

Syntax4-1's surrounding prose describes a count of declaration forms that
does not enumerate every grammar alternative shown; use the grammar and
individual conditions rather than that informal count as a denominator.
Figure-based charge propagation has not been reduced to an independent
multi-switch executable oracle in this work. Full syntax, all declaration
cross-products, namespace collisions/exceptions, huge-vector/array limits,
PLI access and implicit-net scoping remain open. Source-text traversal is
not evidence that all those cases pass.

No percentage, complete-Clause4 claim or full-gate result is asserted.
Main integration owns full tests and FAIL/XFAIL-name-list comparison.

Root integration, 2026-09-23: main read the complete report and all five
fixtures and independently reread the equal-strength resolution tables and
uwire single-driver rules. New fixtures are integrated. Fresh digital and
strict/coverage runs are pending; worker results above are not silently
promoted to fresh root results. Full declaration, strength and array-boundary
coverage remains open.

Root digital run exits one: exact failure-name comparison adds only the
legal negative-vector-bound and multidimensional-array cases. The complete
equal-strength table fixture and uwire legal/invalid pair pass. Every existing
failure name is preserved. Log: `/tmp/vera-types-ledger-devices.log`.
