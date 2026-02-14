# Independent readmem ledger review

Reviewed 2026-09-23. Root candidate `docs/rules/ieee-readmem.json` baseline
SHA256 `04d2e638bf7d62fe2aac35f89333061e7d85488dbba1e3a27bc8d0572a29618f`.
All candidate obligations, cases, profile metadata and evidence references were
read. Complete IEEE1364-2005 §17.2.9 printed296–297 / physical326–327 was reread;
its source SHA256 is
`3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e`.
The existing source audit and implementation reports remain historical records.
This independent review does not certify the denominator or promote partial
rows to verified.

## Applicability resolved from source

AMS2023 source SHA256:
`e93b5b6a767fe10e0e4a3ef312ffdc67907ffcc3c7553d16e04e03383a99c134`.

- §9.1, printed218 / physical231: the full language inherits IEEE system tasks,
  while allowing only some inherited tasks in analog context.
- §9.2 Table9-2, printed219 / physical232: the exact shared row for
  `$readmemb, $readmemh` says digital **Yes**, analog **No**. Text and original
  page image checked; not an inference from the digital runner.
- AnnexC.11, printed391 / physical404: analog-applicable Clause9 tasks apply
  to Verilog-A. Text and original page image checked.
- AnnexC.7, printed390 / physical403: Verilog-A has no digital behavior/events.

Therefore these memory-load execution obligations apply to the full Verilog-AMS
profile but are outside the Verilog-A subset. The initial ledger's unresolved
Verilog-A checkpoint was appropriately cautious before this review, but its
sentence that the rules are not inherently digital-only is no longer the right
applicability rationale after checking Table9-2. An implementation may expose
an extension; execution outside the standard profile is not positive normative
coverage. This decision does **not** establish a particular mandatory rejection,
severity or diagnostic for every analog-context call. Keep any analog-context
restriction/oracle review separate from these inherited execution rows.

Own-worktree ledger proposal changes only the two profile objects on every row.
Schema spelling is `outside`, not `excluded`. All status, obligation, cases,
evidence and denominator fields remain unchanged. Proposed ledger SHA256:
`1a8dcac11d00ce19698d7c045917a03d3fbba72ef1729110d221957eab30701e`.

## Decomposition corrections proposed for a later ledger revision

The candidate covers the direct §17.2.9 sentences broadly, but its rows are not
uniformly atomic and case descriptions sometimes combine distinct obligations.
Do not obtain a denominator by treating every current row as an equally complete
atom or every lexical variation as another independent rule.

| Existing group | Recommended refinement |
|---|---|
|SYNTAX-B/H|Keep task-specific entries, but explicitly enumerate each legal arity as separate cases. The present single primary case names all three without witnessing each. Filename and valid memory target are preconditions/dependencies, not proven by ordinary successful parsing.|
|TIME|Separate binary and hexadecimal nonzero-time execution and repeated invocation cases; require observable unchanged memory before the invocation and changed memory afterward. New witness below supplies those boundaries.|
|SPACE/NEWLINE/TAB/FORMFEED; LINECOMMENT/BLOCKCOMMENT; SEPARATE|A reasonable canonical rule grouping is whitespace alphabet, comment forms, and token separation, with named character/form cases. If the current fine-grained rows are retained, explicitly record their parent source sentence to prevent double-counting. Cover comments abutting numbers, comments containing apparent addresses/numbers, and leading/trailing separators.|
|ONLYCONTENT/NOWIDTH/NOBASE/ATSPACE|These define invalid file forms. §17.2.9 does not supply a specific mandatory fatal diagnostic for each malformed token; unlike ATRANGE it does not expressly require a message and terminated load. Separate input admissibility from implementation-specific diagnostic checks and mark exact response authority unresolved until independently established. Do not turn rejection of an invalid file into positive loading coverage.|
|BINARY/HEX|The BINARY primary case includes invalid digit2 while invalid_input says not-applicable. Split valid radix behavior and malformed-digit response cases, or cross-link a dedicated input-alphabet prohibition. HEX should independently witness alphabetic digits and radix10→16.|
|XLOWER/XUPPER/ZLOWER/ZUPPER/UNDERSCORE|Separate allowed spelling from resulting bit representation; source points to source-number rules. Cross-reference IEEE3.5/3.5.1 before claiming width padding/truncation, all-X/all-Z extension or underscore edge cases. Case equivalence is a case family, not necessarily an additional rule atom.|
|ATHEX|Separate address radix independent of data radix, and upper/lowercase acceptance as named cases. The revised candidate already names @a/@A paired binary files plus hex controls; the new fixture directly realizes it. A decimal-looking @10 boundary is still useful to distinguish hexadecimal16 from decimal10 independently of alphabetic-digit parsing.|
|ATREPEAT|One fixture with multiple relocations is bounded evidence, not an arbitrary finite-address-count guarantee. Distinguish relocation before range completion and after it, with same-address overwrite cases.|
|DEFAULTLOW/DEFAULTEND/STARTONLY/BOTHASC/BOTHDESC/BOTHONE|Keep initial-index selection, direction selection, stopping boundary and unchanged unfilled memory separately identifiable. Apply both declaration directions, nonzero bases and both radices as cases; inclusive equal endpoints is a boundary of the range rule rather than necessarily a separate normative sentence.|
|UPAFTERAT/DIRAFTERAT|UPAFTERAT combines default and start-only calls; the current linked start-only fixture does not witness default invocation. DIRAFTERAT should distinguish upward and downward explicit bounds.|
|ATRANGE|Decompose required address-domain constraint, required error message, and required termination of the load. Include start-only and both-bound requests, below/above boundaries, plus legal boundary neighbors. Termination of this load is not the same as mandatory termination of the entire simulation. A CLI exit alone cannot establish internal partial-load state.|
|WARNSHORT/WARNEXCESS|Separate shorter/longer files and actual warning observation, preserving loaded values. The linked count-warning fixture combines four calls; an observer that merely requires at least one W1150 header could pass while one case fails to warn. Focused unit tests assert individual warning counts; record those separately or isolate each CLI warning case.|
|COUNTMATCH/WITHAT|These are derived boundaries where this mandatory warning condition is false, not independent new shall-statements. Do not forbid every other warning. Attribute only an inappropriate address-free count warning; use a negative-warning observer or focused diagnostic-count test, not stdout alone.|

The term address is explicitly the memory's array index, not a packed bit offset.
SUCCESSIVE captures part of this; keep an explicit dependency on IEEE4.9.3's
memory/word distinction. The source's worked examples corroborate, rather than
add to, the default/start-only/descending rules. Invalid memory declarations,
array kinds, source-number width conversion, malformed-file behavior, address
expression syntax and task bounds outside the declaration require bounded
dependency reviews. No inference about those is made from current executor
restrictions. The candidate remains an uncertified decomposition.

## New runtime witnesses

`tests/fixtures/digital/audit_readmem_address_hex_case.v` initializes four
memories with cc sentinels. Four paired files differ only in @a/@A address
spelling within each radix. Both addresses mean index10; binary data10 means2,
hex data10 means16. Index11 receives3 and neighboring indices9/12 stay cc.
This detects case-sensitive address parsing, using binary radix for an address,
ignoring relocation, wrong data radix and unintended neighboring writes.

`audit_readmem_delayed_invocation.v` uses one sequential process:

- tick0 loads hexadecimal data, setting index10 to16;
- tick2 explicitly overwrites index10 with85;
- tick4 observes85, ruling out an early deferred load;
- tick5 loads binary data, setting index10 to2;
- tick7 reloads hexadecimal data, setting index10 back to16.

No simultaneous independent observer creates an active-region race. Untouched
neighboring sentinels are displayed at every observation. These are bounded
production-execution witnesses, not proofs for every time or input file.

Four data files: `audit_readmem_address_{lower,upper}.{bin,hex}`. Each positive
has an independently derived `.expected.txt` transcript. Both were run using
the current root CLI, with stdout and stderr captured separately, actual exit
codes checked and stdout compared by `diff -u`; both exit0, exact transcripts,
empty stderr. CLI SHA256 at execution:
`0439a27f71562b347f5be260d01e378677ed102d46dee2fc0845df39acb73a51`.

Source witness hashes:

- address-case `.v`: `836a86eaade00b40b5b24c6d4f60472d01d4ed8a5f4505936bbded961e71a111`
- delayed `.v`: `a2bda325ed1ae5e9105e0594d14a8e9a804dcbfd15bf53e50060b3f077df68b5`

Reproduce from the agent worktree with root's CLI:

```sh
/home/omare/Documents/Projects/Zig/VerA/zig-out/bin/vera --run tests/fixtures/digital/audit_readmem_address_hex_case.v
/home/omare/Documents/Projects/Zig/VerA/zig-out/bin/vera --run tests/fixtures/digital/audit_readmem_delayed_invocation.v
```

No mutation was executed. Wrong-implementation descriptions remain proposed
discriminators. Existing linked evidence is historical, partial, and not rerun
by ledger validation. No compiler edits, full builds, status promotion or
conformance percentage is included in this handoff.

During handoff the parent added required `html_trace` metadata to the root
schema/seed. Running that newer validator against this baseline-derived proposal
returns `IEEE-READMEM-SYNTAX-B: missing path`. This is an integration-schema
mismatch, not a successful validation. Merge only the reviewed profile objects
into the current seed, preserving the parent's new HTML trace fields, then
revalidate; do not replace the root ledger wholesale.

Root integration: main read this full review and independently checked the
Table9-2 and C.11 text. Merged only profile metadata by stable rule ID,
preserving root HTML trace fields and all partial/open statuses. Root schema
validation passes. The decomposition corrections above remain outstanding;
the new runtime witnesses await integration after the current strict run.
