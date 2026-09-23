# Readmem validation edges: source review and controls

Reviewed2026-09-23. Source IEEE1364-2005 PDF SHA256
`3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e`.
Read complete §17.2.9 printed296–297, §3.5/3.5.1 printed9–12, and the
§1.2(a) mandatory-error dependency previously reviewed in
`conformance-readmem-diagnostic-refinement.md`. Syntax3-1 on printed9/physical39
and question-mark/underscore prose on printed11/physical41 were independently
visually checked. No compiler changes or full build in this handoff.

## Source conclusions, with scope limits

### Data underscores

§17.2.9 allows underscores as in source numbers. Syntax3-1 requires an initial
binary/hex digit and then permits repeated digits or underscores. §3.5.1 says
underscores are legal except as the first character and otherwise ignored.
Thus `_` and `_11` are invalid file numbers; `1__1_` is a legal hex spelling of
11, and `0__0010001_` is a legal binary spelling of17. This is not a requirement
to reject every underscore or every repeated/trailing underscore. Invalid input
requires an error via §1.2(a); message text and process termination remain
implementation-specific.

### Question mark

§17.2.9 admits binary and hexadecimal numbers while removing their source
length/base prefixes. Syntax3-1 defines `z_digit` as z, Z or ?, and §3.5.1 says
question mark is a z alternative, setting the corresponding digit's bits to
high impedance. The readmem paragraph's explicit x/z/underscore discussion
does not redefine the binary/hex digit grammar or make ? an x wildcard. The
new positive requires `0?` in an8-bit hex word to produce0000zzzz, and
`0000000?` in an8-bit binary word to produce0000000z. Both words fully specify
their width, so this does not depend on unresolved readmem left-padding rules.
Do not use casex/UDP wildcard semantics for the loaded simulation value.

### Tokens beyond the selected load range

§17.2.9 constrains the text file to permitted content and numbers of the
appropriate radix. Reaching the final destination limits assignments; it does
not turn punctuation into a valid number. The full-file count/address condition
also requires accounting for later words and address directives. Consequently
`11 ;` for a one-word range still violates the file-content constraint, requiring
an error through §1.2(a). An ordinary excess-data warning alone does not satisfy
that error requirement. This conclusion applies the file-wide shall constraint;
the source does not separately spell out an algorithm for validating discarded
tokens. It does not require writes past the finish address or prescribe whole-
simulation termination. The control `11 22` remains legal excess data with a
warning and retained first word11.

### File addresses

`@g` violates the hexadecimal address format. `@ 0` violates the explicit
no-whitespace-between-marker-and-number constraint. An address written as many
leading zeros followed by A still represents10; textual length alone is not
arithmetic overflow. The legal neighbor chooses explicit range10..10.

`@10000000000000000` represents2^64. With explicit task range0..0 it is outside
the requested interval, so §17.2.9 requires an error and termination of the load.
The standard does not require parsing into signed64bits, support for a declared
memory of that size, or a particular overflow/range error label. The current
malformed-address error is sufficient for the tested required-error observation;
it is not proof of arbitrary-precision address support. The fixture matches
E1100 without pinning that diagnostic's precise classification, with a separate
legal address control. It does not credit erroring on every large textual input.

Unresolved or out-of-scope address cases remain explicit: x/z/? addresses,
signed address spellings, underscore rules specifically within address tokens,
addresses outside the declaration when no task bounds are supplied, and valid
large declared ranges beyond host limits need their own authority and oracle
review. No rejection is invented for those here.

## Focused observed behavior

Executed with parent's current cachedCLI
`/home/omare/Documents/Projects/Zig/VerA/.zig-cache/o/2d2342b680affbb3c77bc2f9598d5927/vera`,
SHA256 `ea2c724c744b0d0c810128ed1a1013cfa18d07b78fccf9f3ab5483c2acaef3e8`.
This artifact contains the preceding full-token validation repair. Each command
uses `--run tests/fixtures/digital/NAME.v`, from the agent worktree, with exit
status and separate stdout/stderr capture. Positive output was compared with
the independent `.expected.txt` by `diff -u`.

| New fixture | Observed result | Evidence disposition |
|---|---|---|
|audit_readmem_question_z|Exit0; actual `hex=0000xxxx binary=0000000x`, expected z bits|READMEM-QUESTION-001 required positive fails|
|audit_readmem_underscore_legal|Exit0, exact `11,11`, empty stderr|Bounded legal repeated/trailing underscore pass|
|audit_readmem_address_zero_padding|Exit0, exact `11`, empty stderr|Bounded large textual but small numerical address pass|
|audit_readmem_excess_legal_neighbor|Exit0, exact `11`, W1150 found2/expected1|Legal excess-data neighbor pass|
|audit_readmem_edge_underscore_only_rejected|Exit0, no error|READMEM-UNDERSCORE-001 unmet required error|
|audit_readmem_edge_underscore_leading_rejected|Exit0, no error|READMEM-UNDERSCORE-001 unmet required error|
|audit_readmem_edge_after_range_rejected|Exit0, W1150 only|READMEM-DISCARDED-TOKEN-001 unmet required error|
|audit_readmem_edge_address_bad_digit_rejected|Exit1, E1100 malformed @ address|Bounded invalid address diagnostic pass|
|audit_readmem_edge_address_gap_rejected|Exit1, E1100 malformed @ address|Bounded invalid address diagnostic pass|
|audit_readmem_edge_address_overflow_rejected|Exit1, E1100 malformed @ address|Bounded out-of-task-range error pass; no overflow-precision claim|

All files are under `tests/fixtures/digital/`. Positive data files share their
fixture basename and `.hex`/`.bin` extension as applicable. Each negative has
`audit_readmem_edge_SUFFIX.txt` data, explicit `digital-runner: reject` opt-in,
and a distinctive diagnostic phrase or the scoped E1100 code. Nonzero process
exit is the current local runner contract, not an independently required global
simulation outcome. Required expectations remain unchanged despite observed
failures; no unsupported XFAIL mechanism is claimed.

## Read-only root-cause leads

- `memWord` classifies `'x', '?'` together as unknown, contrary to source-number
  z semantics for question mark. The input is accepted but its value is wrong.
- `memWord` skips every underscore without requiring an initial digit; an
  underscore-only token therefore leaves the zero-filled destination unchanged
  as zero instead of reporting invalid input.
- `readMemory` increments its word counter and skips tokens when `exhausted`,
  bypassing `memWord` validation entirely. The repaired full-token validator
  cannot help tokens that are never sent to it.
- Address parsing is currently signed64-bit; error handling is present, and
  explicit task-range checking is present. These are not automatically defects
  in the tested invalid-overflow case.

Any repair should preserve valid oversized-word truncation, ordinary excess-
word warnings, later-address relocation, comment handling and legal separators.
No repair is included until parent accepts these source conclusions. This is
bounded partial evidence, not complete readmem closure, a new verified ledger
status, or a conformance measure.
