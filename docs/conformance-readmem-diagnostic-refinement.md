# Readmem diagnostic authority and isolated warning witnesses

Reviewed 2026-09-23. Source: IEEE1364-2005 PDF SHA256
`3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e`.
This adds a normative dependency missing from the earlier bounded review in
`conformance-readmem-ledger-review.md`; that historical uncertainty is explicitly
superseded below, not silently erased. No compiler or existing fixture changed.

## Mandatory error authority

IEEE §1.2(a), printed2 / physical32, says tool implementations must enforce
mandatory requirements and issue an error when input does not meet them.
The full §1.2 text was read and physical32 visually inspected. This is normative
by §1.5, printed3 / physical33. §17.2.9, printed296 / physical326, specifies
mandatory file-content constraints, including:

- permitted content only;
- neither a length nor a base-format specification on data numbers;
- binary numbers for `$readmemb`, hexadecimal numbers for `$readmemh`.

Together these establish an error requirement for invalid punctuation, forbidden
length/base prefixes and digits outside the selected radix. A separate source
sentence requiring an error beside each prohibition is unnecessary. Update
ONLYCONTENT/NOWIDTH/NOBASE and malformed-digit cases to cite both §17.2.9 and
§1.2(a). Do not leave the existence of an error obligation unresolved solely
because §17.2.9 does not repeat the diagnostic requirement there.

This does **not** prescribe E1100, message wording, a process exit code, or
termination of the whole simulation. For file addresses outside the requested
range, §17.2.9 separately and expressly requires an error message and termination
of the load. A general malformed-file error must not be conflated with that
additional load-termination requirement. The local digital negative runner
currently requires nonzero process exit and a distinctive error-header phrase;
that is an implementation/harness convention, not a portable standard oracle.
Another conforming simulator could report the required error while continuing
other simulation work. The file-format rule forbidding whitespace after `@`
remains an explicit normative input constraint; this handoff's executable
malformed cases concentrate on the direct shall requirements above.

§17.2.7 describes file-I/O error status and `$ferror`, but does not replace this
authority with permission to silently accept malformed readmem data. Readmem is
a task without a returned file descriptor or status value in Syntax17-7. No new
readmem-specific ferror/status-return oracle is inferred here.

## Independently observable warnings

The earlier `audit_readmem_count_warning.v` contains multiple loads and remains
unchanged as a useful combined regression. The current digital warning observer
searches actual warning headers for each directive but does not attribute a
header to a particular call. Therefore one warning could satisfy that combined
fixture even if other required warnings were absent.

Each new positive below contains exactly one readmem call. Its directives
require W1150 plus the distinctive count-message with the derived found/expected
counts. A passing test additionally requires exit0 and exact loaded-memory
stdout. W1150 and its text are tool-specific observation contracts; the source
requirement is a warning, not this diagnostic identity. Direct focused runs also
asserted exactly one W1150 header per process.

| New fixture suffix after `audit_readmem_warn_` | Task/range | Source data words | Expected memory indices0,1,2,3 |
|---|---|---|---|
|hex_short_up|hex0..3|2|11,22,aa,aa|
|hex_short_down|hex3..0|2|aa,aa,22,11|
|hex_excess_up|hex0..3|5|11,22,33,44|
|hex_excess_down|hex3..0|5|44,33,22,11|
|binary_short_start|binary start2, implied finish3|1|aa,aa,01,aa|
|binary_excess_start|binary start2, implied finish3|3|aa,aa,01,02|
|empty|hex0..3|0|aa,aa,aa,aa|

Every suffix has `.v` and `.expected.txt` files under `tests/fixtures/digital/`.
The empty file is comment-only, including apparent numbers/addresses that must
not count or suppress the warning. Additional data files:
`audit_readmem_one.bin`, `audit_readmem_three.bin`,
`audit_readmem_empty_comments.hex`. Hex cases reuse existing short/excess data.
No claim is made about every range, width, radix or malformed-file interaction.

## Malformed-input witnesses and a discovered defect

Each `audit_readmem_malformed_*_rejected.v` explicitly opts into the digital
negative runner and expects `the memory file has a malformed data word`.
Each reads one isolated invalid token while still inside its selected range.

| Suffix | File token | Memory width | Current result |
|---|---|---|---|
|width|`8'h11`|8|Exit0, no diagnostic: unmet required error|
|base|`'h11`|8|Exit0, no diagnostic: unmet required error|
|width_wide|`8'h11`|16|Exit1, intended E1100 phrase|
|base_wide|`'h11`|16|Exit1, intended E1100 phrase|
|punctuation|`;`|8|Exit1, intended E1100 phrase|
|binary_digit|`2` with readmemb|8|Exit1, intended E1100 phrase|
|hex_digit|`g` with readmemh|8|Exit1, intended E1100 phrase|

Data files are `audit_readmem_invalid_{width,base,punctuation,binary_digit,hex_digit}.txt`.
The paired legal neighbor `audit_readmem_malformed_legal_neighbors.v` loads
unprefixed hex11 and binary10 and prints exactly `11,02`; it exits0 with empty
stderr. Its data files are `audit_readmem_legal_one.{hex,bin}`.

**READMEM-TOKEN-VALIDATE-001:** read-only inspection of root
`src/sim/digital.zig` finds `memWord` loops only while both input remains and
the destination width is unfilled. Reading right-to-left, an 8-bit destination
is filled by the trailing two hex digits, so the forbidden prefix is never
validated. A 16-bit destination reaches it and diagnoses the same illegal
input. Destination truncation must not legalize a forbidden source-file token.
The two unmet negatives deliberately retain required expectations; they are
not deleted, weakened or labeled as working XFAILs. No fix is included here.
All-character validation before/alongside truncation is a root-cause lead,
not authorization for a compiler change in this handoff.

## Execution provenance and stale-binary distinction

Initial runs used installed `zig-out/bin/vera`, SHA256
`0439a27f71562b347f5be260d01e378677ed102d46dee2fc0845df39acb73a51`.
That binary lacked the integrated warnings/start-only implementation: ordinary
warning cases printed correct values without warnings, and start-only calls
were rejected. These are stale-artifact observations, not regressions attributed
to the current source.

Parent supplied the current build artifact:
`/home/omare/Documents/Projects/Zig/VerA/.zig-cache/o/a10b1de8b23e4ac042c82f9415cfe87a/vera`,
SHA256 `6b6e9b28b46620533350a062c8a454330b5ff0ff4ab6fc14a01775c9df45e4ce`.
All new cases were rerun with that artifact, without building it in the agent.
Every isolated warning positive exits0, matches stdout exactly and emits one
W1150 header. The malformed-input results above are from this current artifact,
not just the stale binary. Captures were kept separately for stdout/stderr and
the actual exit code recorded; successful output alone was not treated as pass.

Command pattern from the agent worktree:

```sh
/home/omare/Documents/Projects/Zig/VerA/.zig-cache/o/a10b1de8b23e4ac042c82f9415cfe87a/vera --run tests/fixtures/digital/audit_readmem_warn_hex_short_up.v
```

No full build, compiler edits, ledger status promotion, mutation result or
conformance measure is claimed. Parent owns integration and complete failing
name-list comparison; the two newly exposed unmet error oracles must remain
visible in that comparison.
