# Readmem start-only arguments and formfeed separators

Source: IEEE1364-2005 §17.2.9, printed296–297 / physical326–327,
SHA256 `3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e`.
Reviewed 2026-09-23. Follow-up to `conformance-readmem-warning-fix.md`;
that report's start-only and formfeed residuals are addressed here, not silently
deleted from their historical checkpoint.

The source explicitly permits whitespace including formfeeds. A task with a
start address and no finish address loads upward to the highest memory address;
this direction persists after file address specifications. File addresses must
remain in the requested range when the task supplies addressing information.
Thus start2 on a memory with highest index3 requests2..3, not2..0 even when the
declaration is `[3:0]`. Address1 is outside that requested range, while address3
followed by address2 legally restarts an upward walk.

## Scoped implementation

Only production file changed: `src/sim/digital.zig`.

- Preflight accepts two, three or four arguments, preserving existing filename,
  memory and constant-bound checks.
- Start is evaluated whenever present; finish is evaluated only when present,
  otherwise it remains the declaration's highest index.
- Descending traversal requires an explicitly supplied finish below start.
- File-address range checking also applies to the start-only form.
- Both whitespace skipping and word termination recognize byte0c. No broad
  locale-dependent whitespace predicate was introduced.
- Existing W1150 warning and loaded-value preservation semantics remain.

Current root baseline was reproduced exactly before changes:
`3fd621462db74523ca662f3e536ce25411ef4ecdb670cc2438e27908d4136176`.
Handoff SHA256:
`3a46db92587cc6fd1079d295384da4ef9b420a5f6bd8ef9088c4d1d3e21ef3c0`.
Previous vector/disable/clog2/wait and W1150 changes are preserved. Unrelated
baseline formatting is unchanged; no diagnostic catalog or harness edits.

## Executed evidence

```sh
zig test --dep diag --dep frontend -Mroot=src/sim/root.zig -Mdiag=lib/diag.zig --dep diag -Mfrontend=lib/frontend/root.zig --test-filter readmem
```

Exit0: five discovered tests, including the module import test. These actually
run Verilog through the executor using temporary memory files, not just parse
source. Exact output and warning counts cover existing count/address cases plus
start-only short/excess/exact input, start at highest address, restart upward
after `@`, addresses below/above requested range, and leading/interior/trailing
formfeeds in hexadecimal and binary files. Comments containing apparent words
or addresses are not counted. Invalid address tests assert DigitalFailed,
distinctive E1100 text and no subsequent display.

`git diff --check -- src/sim/digital.zig` exits0. No CLI rebuild or full gate
was run for this handoff; standalone fixtures await the parent's rebuilt CLI.

## New fixtures

Under `tests/fixtures/digital/`:

- `audit_readmem_start_formfeed.v` plus exact expected transcript checks both
  declaration directions, both radices, untouched lower elements and restart
  direction. Three data files are `audit_readmem_formfeed.hex`,
  `audit_readmem_formfeed.bin`, and `audit_readmem_formfeed_address.bin`.
- `audit_readmem_start_address_rejected.v` explicitly opts into the digital
  negative runner and requires `memory file address is outside the requested
  load range`, not any generic failure. Its start3 request excludes later `@2`
  even though address2 belongs to the declared memory.

Data files deliberately contain literal formfeed bytes, not the characters
backslash-f. `od -An -tx1 audit_readmem_formfeed.hex` reads
`0c 31 31 0c 32 32 0c 0a`. Preserve those bytes during integration.

No conformance measure is hand-entered and no complete §17.2.9 closure claimed.
Dynamic filename/address expressions, unknown/outside-declaration task bounds,
other malformed file inputs, and further value-width/radix boundaries remain
outside this patch. Parent owns full gates and FAIL/XFAIL name-list comparison.

Root integration, 2026-09-23: applied the scoped compiler diff and retained
the fixture data's literal formfeed bytes (hex file independently inspected
with `od`). Reread fixture derivations and expected transcript. Root focused
readmem command passes all five discovered tests. Full unit gate exits zero;
digital gate exits one with all pre-existing failures unchanged and both new
cases passing. Exact failure-name comparison against the primitive/grammar
checkpoint is identical. Logs: `/tmp/vera-readmem-start-{unit,devices}.log`.
No new A/C measurement or whole-clause closure is claimed.
