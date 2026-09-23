# Lexical legal neighbors and literal-tab positions

Source-derived additions,2026-09-23, following independent lexical-ledger
review LEX-REVIEW-006/008. Source2.2–2.4 printed11/PDF24 and2.7
string-to-integer character representation govern these cases. The earlier
review records original visual boundaries and source hash. No source rule,
ledger, compiler, shared harness or existing fixture was changed.

## Added source cases

All paths below are under `tests/fixtures/ch02_lexical/`.

| Fixture | Independent oracle | Discriminated fault |
|---|---|---|
| `audit_comment_nonnest_legal_neighbor.va` | A second opener inside a block does not start nesting; first closer ends it. The immediately following assignment executes with value5. There is no stray second closer. | Rejecting every embedded opener, or maintaining a nesting depth that swallows the assignment. |
| `audit_comment_separator_legal_neighbor.va` | `real/*...*/value` remains a declaration with separate keyword and identifier. The assigned/read value is7. | Deleting the comment and welding the surrounding tokens into `realvalue`. |
| `audit_string_literal_tab_positions.va` | Literal tab beforeAB, betweenA/B, afterAB produces606530,4262210,4276745 respectively. | Stripping/collapsing tabs, confusing literal tab with an escape spelling, or reversing packed character order. |

Literal byte09 is present inside each string in the last fixture; no
backslash-t escape is substituted. AMS2.7 supplies the byte interpretation:
TAB9,A65,B66, so the three expressions are
`9*65536+65*256+66`, `65*65536+9*256+66`, and
`65*65536+66*256+9`. The fixture header states these derivations and
pins `checks3`; the comment neighbors each pin `checks1`.

## Actual execution provenance

The installed `zig-out/bin/vera` was stale and was NOT used. Requested
cached root CLI:

`/home/omare/Documents/Projects/Zig/VerA/.zig-cache/o/a10b1de8b23e4ac042c82f9415cfe87a/vera`

SHA256 verified before execution:
`6b6e9b28b46620533350a062c8a454330b5ff0ff4ab6fc14a01775c9df45e4ce`.

Working directory was `/tmp/vera-parallel-audit.w1HPwr/ch6`. For EACH
new fixture, the command was:

```sh
/home/omare/Documents/Projects/Zig/VerA/.zig-cache/o/a10b1de8b23e4ac042c82f9415cfe87a/vera \
  --emit-exe \
  --contract /home/omare/Documents/Projects/Zig/VerA/tools/contract.zig \
  -I /home/omare/Documents/Projects/Zig/VerA/tests/fixtures \
  -I tests/fixtures/ch02_lexical tests/fixtures/ch02_lexical/NAME.va
.zig-cache/vera-tb/NAME
```

Each emission exited0 and returned the path of the matching testbench. Each
returned executable was actually run and exited0. Complete check observations:

```text
first closer ends nonnested comment got=5 want=5 ok=1
comment separates keyword and identifier got=7 want=7 ok=1
literal leading tab got=606530 want=606530 ok=1
literal interior tab got=4262210 want=4262210 ok=1
literal trailing tab got=4276745 want=4276745 ok=1
```

The emitted runtime headers each showed point0 and zero node residual.
Observation multiplicities were1,1,3 respectively; zero process exit was
not used as a substitute for checking the verdicts.

| Artifact | SHA256 |
|---|---|
| nonnest source | `7ce45acecbeefb797edd019c66141c3684bbd8021bc1e98c2c04f2bef5c9ce19` |
| separator source | `81eb74c65eac79873ea2bd5843fa4193e16b30849cf8fe968dbd6d1f4332df34` |
| tab source | `e2a299cfc1d2d08cfb5b4aaea5adcce1275f2fa4c5b745b8e7ba778b9c84b7b8` |
| nonnest generated executable | `cbf04f4acbb750c1a66218799ec9efb67bb63008e31692866e08613228381070` |
| separator generated executable | `36437ffdf0f2ac833d3a0865dc07f5f26e6e826569b3f10b03942430bbde71c8` |
| tab generated executable | `02910f99f7cac42c62485c67ac3dd8348eb0c5f2f5b98745859b489de5a17018` |
| root contract.zig | `786f63775390328dfe812cc4300129da6649eadc8263f350aa798b80d4be05ad` |
| root check.vh | `bde308693e0b56b9b615f04554a040262a7fb5cbdbb0b1a9f55039fd4ebe4401` |

## Existing negative controls rerun

Used the SAME cached CLI with `--check --contract` and both root fixture
include paths, against the original unchanged root negatives:

- `13_nested_comment_rejected.va`: exit1,E0205 at line14 column27,
  `unsupported module item: found still_outer`. This diagnoses the invalid
  trailing tokens, not the second opener inside the comment.
- `39_block_comment_separates_tokens.va`: exit1,E0207 at line21 column28,
  unexpected token2 with `expected ')'`. The comment did not weld1 and2.

Both outcomes match the fixtures' existing relevant diagnostic pins.
The legal neighbors prevent blanket refusal from masquerading as enforcement.

## Limits

These are prescribed-point generated analog-testbench observations, not a
full mixed-signal or external-host claim. They close the specific missing
legal-neighbor/literal-position observations only, not every lexical matrix,
profile execution or malformed-input requirement. No controlled mutation was
executed, and no durable full transcript/artifact bundle is claimed from the
copied check observations alone. Existing ledger statuses remain unchanged
for root review. No compiler builds, full suites or A/C measurements were run.

## Root integration

Main reviewed all three fixtures and independent numeric derivations, then
integrated and reran them using the readmem-token patched CLI SHA256
`ea2c724c744b0d0c810128ed1a1013cfa18d07b78fccf9f3ab5483c2acaef3e8`.
Each emission and returned executable exits0. Root observes the same five
ok=1 lines above, with multiplicities1/1/3. Captures are
`/tmp/audit_{comment_nonnest_legal_neighbor,comment_separator_legal_neighbor,string_literal_tab_positions}.{out,err}`.
The corresponding ledger rows now include these bounded positive cases,
retaining partial status and all unexecuted boundaries. The earlier tab
fixture's represented boundary is narrowed to what it actually contains.
All23 ledger validation tests pass; this is not completeness certification.
