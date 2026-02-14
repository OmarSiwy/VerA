# IEEE 1364-2005 Annex G: public VPI header audit

Reviewed 2026-09-23. This is the **normative IEEE Annex G `vpi_user.h`**,
not the informative AMS Annex G change history. Complete extracted source
read: printed522–536 / physical552–566, from the annex heading through the
final header guard. Initial visual pass covered physical561–566; follow-up
visually inspected all remaining physical552–560 at 1800px. Thus every AnnexG
page has now been text-read and visually reviewed, including portability,
constant/alias lists, structures, prototypes and cleanup. PDF SHA256:
`3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e`.
No replacement header was copied from the licensed standard.

Compared complete current `src/vpi/vpi_user.h`, SHA256
`816f82a0293b630b05eff749a65451add981e2ca27fdc0b55bfe5cdac31bca94`,
and production export inventory in `src/vpi/root.zig`. Existing Chapter12
review and C application are complementary host evidence, not a complete
inherited header certification. Clause27 is being independently reviewed in
parallel; header declarations cannot establish routine semantics.

## Obligation register

These are coherent groups, not an exhaustive per-symbol executable matrix.
All missing members remain open requirements, not exclusions justified by the
header's intentional-P01-subset comments.

| ID | Printed pages | Source obligation / observed boundary |
|---|---|---|
|G-PORTABILITY|522–524,536|Six PLI scalar typedefs, opaque handle, shared guards, C++ linkage, prototype/export wrappers and cleanup. Scalar typedefs and handle match by inspection. Root uses a different outer guard, lacks portability macros, and lacks VPI_VECVAL interoperability guard; Windows/legacy-C/C++ integration untested. Do not equate every textual wrapper difference with a demonstrated ABI failure.|
|G-OBJECTS|524–525|Complete object-kind identifiers, including arrays, generated scopes and indexed part selects. Root exposes only a small object subset; macro absence and runtime object absence are separate.|
|G-RELATIONS|525–526|One-to-one, one-to-many and mixed relationships with exact identifiers. Root's Scope/InternalScope subset is not complete. Each relationship needs object applicability and empty-vs-invalid host tests.|
|G-PROPERTIES|526–530|Property identifiers and value categories, operation/timing-check kinds, delay modes, indexed part-select direction, signed/localparam flags and backward-compatible aliases. Most missing. vpiSigned65 and vpiLocalParam70 match. Alias spellings such as vpiBitXnorOp/vpiBitXNorOp must not be dropped as duplicates.|
|G-TIME|530|Time format constants and signed type/unsigned high-low/double real structure. Present fields match; baseline compile probe passes selected types. No time conversion/runtime closure.|
|G-DELAY|530–531|Application-owned delay array pointer, count, time type and mtm/append/pulsere flags. Root omits delay structure. Delay algorithms and validation belong to Clause27.|
|G-VECTOR|531|aval and bval are PLI_INT32, protected by VPI_VECVAL. Root uses PLI_UINT32 and omits guard. Both compile probes fail. Same ordinary binary layout would not repair incompatible C types or duplicate-definition interoperability.|
|G-STRENGTH|531|Strength record (logic,s0,s1), strength pointer in generic union, exact strength masks. Root omits all. Compile probe fails. Strength masks are not consecutive ordinal levels.|
|G-VALUE|531–532|Complete generic value union, format constants, force/release/cancel/return-event and scalar constants. Root union lacks strength; get/put routines undeclared. Correct declarations alone would not test four-state encoding or event scheduling.|
|G-SYSTF|532–533|System task/function registration record, callback function signatures, name and user data, task/function kinds. Missing public structure/routines; no registered-user-function runtime test supplied here.|
|G-VLOG-ERROR|533|Execution information and error records, states and severities. Error record present; vlog-info missing. Existing host error checks cover selected behavior only.|
|G-CALLBACK|533–534|Callback record includes index and typed callback pointer, all simulation/time/action reasons including later additions. Public record/reasons/register routine missing; compile probe fails. Timing, lifecycle, removal and invalid handles require actual host.|
|G-HANDLES|534–535|Exact handle acquisition/traversal/property signatures. Root by-name parameter is const PLI_BYTE8* instead of PLI_BYTE8*: incompatible function-pointer type, probe fails. Ordinary mutable-string calls may still compile; do not misdescribe as universal call failure. Multi-handle acquisition missing.|
|G-ROUTINES|535–536|Delay/value/time, output channels/varargs, compare/error/free/vlog-info, data/userdata, flush/control/multi-index declarations. Root exposes selected hierarchy/property/error/free routines only; production export search agrees absent value/callback implementations. Runtime unsupported requests are not conformance-negative evidence.|
|G-STARTUP|536|Extern startup pointer array terminated by null; macro cleanup and linkage. Root declares array with (void) prototype rather than old-style (), compatible for normal no-argument startup use; C/C++ and lifecycle tests still needed. Extra vpi_release_handle is not an IEEE AnnexG declaration and is not evidence for an inherited routine.|

## Reproducible compile-only evidence

Run from repository root:

```sh
python3 tools/audit_vpi_annex_g_header.py --include src/vpi
```

The independently written C11 clients select isolated assertions. `_Generic`
checks compatible C types, not platform-specific sizeof assumptions. All
clients are **legal required-positive** source; none is an invalid-input test.
The runner reports each actual compiler exit and returns failure if any client
fails. No fake implementation, local replacement declarations, linking or VPI
simulation is used. These probes are not yet wired into ordinary torture
coverage or a build gate.

Actual command used own-worktree runner and absolute root include path. Overall
exit1; BASELINE exit0, VECTOR_SIGNED/VECTOR_GUARD/STRENGTH/NAME_SIGNATURE/
CALLBACK/VALUE_ROUTINES each exit1, with assertion failures or missing members/
declarations matching the stated requirements. The Nix C wrapper also emitted
irrelevant unused-linker-argument warnings; these were not treated as errors.
No full build or full suite was run.

## Cross-source reconciliation and remaining evidence

Clause27 worker independently visually confirmed signed vector fields in
Figure27-8, strength member in Figure27-7 and mutable by-name argument in27.19.
Their routine audit owns runtime semantics. In particular IEEE27.19 name
resolution and AMS12.21 upward search must be compared as different profiles;
this header audit does not claim the AMS implementation's upward search is an
inherited defect.

Preserve source inconsistencies elsewhere: Clause27 prose/table spellings
vpiScalar/vpiStrength, vpiObjectVal and vpiStringVal do not silently replace
the actual AnnexG value identifiers. AMS analog extensions require additional
structures and routines, not deletion of inherited members. Existing Chapter12
draft fixture headers are not substitutes for the production public header.

Follow-up: [symbol inventory](conformance-ieee-annex-g-symbols.md) now enumerates
each uncommented macro definition (including conditional alternatives), scalar
typedef, structure tag/typedef/pointer alias/member, function and startup global.
Reproduce with `tools/inventory_vpi_annex_g.py PDF HEADER`; the source hash is
checked before extraction. This is a bounded extractor for the visually reviewed
AnnexG layout, not a general C parser. Macro comparisons compare replacement
tokens, not evaluated values; symbol/member rows explicitly require subsequent
type review. A complete declaration enumeration does not enumerate every
semantic obligation in Clause26/27. Commented repeated constants are excluded,
whereas actual aliases remain distinct rows. Header-only extra symbols and
platform preprocessor paths still need independent compatibility disposition.

The visual pass confirms the probe expectations exactly: vector fields use
PLI_INT32, the shared guard is VPI_VECVAL, strength has its own structure and
union pointer, callback index is signed, registration returns vpiHandle,
get-value returns void and put-value returns vpiHandle. Function-type probes
use the expanded declaration type, not the PROTO_PARAMS/XXTERN wrapper spelling.
No typo or extraction correction changes the earlier six failures.

Manual follow-up type comparison of all present declarations: six scalar
typedefs and vpiHandle agree; time and error structures agree in member types
and order; vector differs as above; generic value's existing members agree but
strength is omitted. All present inherited routine prototypes agree after
ignoring parameter-name spelling except the by-name const qualification.
The startup old-style/void difference remains as documented. The generated
inventory deliberately does not infer this manual type disposition itself.

Definite documentation correction needed in the production header: the comment
calling `vpi_release_handle` IEEE1364-2005's later spelling of `vpi_free_object`
has no support in this edition's complete AnnexG routine list. Preserve the
extension if desired, but label its actual provenance separately; do not remove
existing behavior or cite it as inherited coverage. No header edits made here.

Follow-up extractor validation command used explicit IEEE_PDF/VPI_HEADER
environment paths with `python3 -m unittest discover -s tools -p
test_inventory_vpi_annex_g.py -v`: exit0, all three tests passed. Tests cover
comment removal, empty/conditional definitions, aliases, union members,
comma-separated members, callback pointers and final multi-index/global rows.
They do not certify arbitrary C parsing. The original compile probes remain
unchanged; their recorded failures still describe the unchanged header hash.

Next steps: expand per-member type and
C++/guard interaction probes, then link real plugins to an operational host.
Host tests must cover successful values/relationships, legal empty results,
invalid requests, callback region/lifetime and scheduling—not merely presence
of a C declaration. No AnnexG obligation is declared closed by this report,
and no A/B/C/D measure is computed.

## Root integration evidence

Main read this complete report and all probe/extractor sources on 2026-09-23,
and independently checked the vector, strength, callback and name-signature
source declarations. Integrated the report, C clients and Python tools without
changing the production header. Regenerated the symbol inventory from the local
PDF and current header: byte-identical to the worker handoff. All three focused
extractor tests pass with explicit IEEE_PDF/VPI_HEADER paths. Root compile-only
runner exits one: baseline passes and the six required-positive compatibility
probes fail, reproducing the worker result. Separate logs are
`/tmp/vera-annex-g-header.out` and `/tmp/vera-annex-g-header.err`.
These failures are not counted as successful rejection tests or runtime evidence.

## Existing-interface repair handoff

Own-worktree patch prepared after the audit; the source comparison and symbol
inventory above deliberately retain their pre-change header hash as baseline.
Production header baseline `816f82a0293b630b05eff749a65451add981e2ca27fdc0b55bfe5cdac31bca94`
was cmp-identical before edits. Patched SHA256:
`71b6085ea558eadcc81497a269bb71d95041e27fa9a2936794dc24393c594ce6`.

Changes are limited to signed vector fields, VPI_VECVAL definition guard,
mutable-name C declaration and corrected alias provenance comment. No new API,
strength member, callback implementation or runtime stub is supplied.

Production C ABI review: root.zig baseline
`05717daa48fa6bc9701330222e4fdffd7c9a9bb72ba6e75d06fbc5375ddb85d5`
is unchanged. Its exported name pointer is internally const and never written;
that qualifier has no pointer calling-convention representation. Keeping its
read-only Zig implementation and direct Zig string-literal callers is consistent
with accepting mutable C pointers through the corrected public declaration.
There are no production vector consumers. Signed/unsigned C int words retain
size/alignment/member offsets on the tested host, independently asserted against
the old unsigned layout. This does not claim tested ABI equivalence for every
target or unchanged source semantics for third-party clients doing signed
arithmetic: the corrected signed field type is intentionally observable.

Three authorized draft P03 paths had explicit const casts adapted to the
required public signature, with no change to names or behavior. The lookup
implementation is read-only; casting a literal does **not** authorize writing
that literal. Baselines:

| Path under tests/fixtures/ch12_vpi_routines | Baseline SHA256 |
|---|---|
|p03_vpi_analog.h|15fdf81feca397c58ad14363e980356dd0ba1a7b95c127d0ed1385c118b88cac|
|p03_91_reject_stale_callback_handle.c|d68fc141653439b8d647874fc2b975774985695f5e8f9b18dd2a1e1b70372954|
|p03_08_analog_value_formats.c|a1de9a7942dd88560fd7318d5866b7d51a69dffdd8c0049a295970c9db0f4de5|

Focused verification against patched header:

- Six C11 probes BASELINE, VECTOR_SIGNED, VECTOR_GUARD, VECTOR_PREDEFINED,
  VECTOR_LAYOUT and NAME_SIGNATURE each exit0 with Wall/Wextra/Werror.
  Predefined probe simulates another header defining the shared vector type;
  repeated public-header inclusion is also checked.
- C++11 `tests/vpi_annex_g_compatibility.cpp` exits0 with those strict warnings,
  checking signed fields, function type and a writable-name caller.
- Current root `tests/vpi_app.c` (SHA256
  `e48debd01a4caec31812872e13d41491bf19ee7df33c7b4334753e2a1fa7a337`)
  and the two patched P03 C clients each pass strict C99 syntax checks, exit0.
- Full standalone header probe command remains exit1: STRENGTH, CALLBACK and
  VALUE_ROUTINES still fail as missing required-positive declarations. These
  failures are retained, not converted into passing rejection tests.

Commands use `-fsyntax-only -I src/vpi`, selected `-DPROBE_NAME` for the C probe,
and `-Wno-unused-command-line-argument` only for irrelevant Nix wrapper linker
flags. No link/host execution or full gate was performed for this patch; parent
must integrate and run those gates. Declaration repairs move source compatibility
evidence, not an automatically measured A/C or a closed runtime obligation.

Root repair integration, 2026-09-23: the scoped header/probe/client changes
are applied. All six selected C11 probes, the C++11 compatibility client,
and the existing C host plus both P03 clients pass strict syntax checks in
the root tree. The full header probe exits one only for STRENGTH, CALLBACK
and VALUE_ROUTINES. Runtime code is unchanged. The linked symbol inventory
has now been regenerated against the repaired header; the earlier hash and
six-failure result above remain historical baseline evidence. Full unit and
strict gates are running, not yet credited here.
