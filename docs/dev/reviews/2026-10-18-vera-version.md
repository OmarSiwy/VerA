# Design review: a device carries the VerA release, not an ABI integer

- **Change**: `contract.abi_version: u32 = 6` and every device's
  `pub const contract_abi: u32 = 6;` are replaced by `contract.vera_version`
  (the release, semver, `build.zig.zon`'s `.version`) and a device's
  `pub const vera_version = "0.9.0";`. `validateHost` refuses a device whose
  string is not exactly the contract's, naming both. `vera --version` prints
  it, VPI's `vpi_get_vlog_info` reports it (`vera.version`), and a test in
  `zig build test` holds the contract's literal equal to the manifest's.
  User decision, 2026-10-18: a host (ESPice) checks which VerA release
  generated a device.
- **Domain skill(s)**: `api-design` (the device/host contract, a boundary).
- **Hot/cold**: cold. One comptime string compare per (host, device) pair at
  the host's compile time; nothing runs at run time.
- **Stages run**: R1, R6, R7, R9 (a boundary change, §10.1); R10 by reading.

## Boundary (R1)

The usage code first. A host that links a VerA device and supports one
release:

```zig
const std = @import("std");
const contract = @import("contract"); // share/vera/contract.zig of that release
const D = @import("device"); // vera --emit-zig model.va

comptime {
    contract.validate(D);
    contract.validateHost(@This(), D); // always refuses another release's D
}

// A host that pins a release independent of the contract file it was given:
const pinned = "0.9.0";
comptime {
    if (!std.mem.eql(u8, D.vera_version, pinned))
        @compileError("regenerate " ++ @typeName(D) ++ " with VerA " ++ pinned);
}

// A host that runs devices from several releases (through their own
// contracts) reports which one it loaded:
std.log.info("{s}: VerA {s}", .{ @typeName(D), D.vera_version });
```

What the device says, before and after (`.va` codegen, `lib/device/codegen/file.zig`
`emitTopology`; `.v` devices, `lib/digital/emit.zig` `deviceRoot`):

```zig
/// The contract ABI this device was generated for (`contract.abi_version`).
pub const contract_abi: u32 = 6;
```

```zig
/// The VerA release that generated this device (`contract.vera_version`).
pub const vera_version = "0.9.0";
```

The five characteristics:

- **Granularity**: one declaration, read at comptime. A host can check it
  through `validateHost` (all or nothing, with the regenerate message) or
  read `D.vera_version` itself and decide (pin, log, accept a range). The
  high tier has a path down.
- **Redundancy**: one spelling, `contract.vera_version`; the manifest's
  `.version` is the second literal only because `contract.zig` ships alone
  to hosts and imports nothing. The CLI test holds them equal and
  `tools/conformance.py --changelog` writes both.
- **Coupling**: the device's stamp is coupled to the release, which is the
  point: any contract change ships in a release. What is lost is the
  integer's promise that two releases with one ABI interoperate; no host
  used it (the integer moved with every observable change, and VerA always
  regenerated), so a device from another release is refused even when
  nothing a host sees changed. Optional declarations a release adds stay
  optional (`@hasDecl`), as before.
- **Retention**: none; a comptime constant.
- **Flow control**: the host's. `validateHost` refuses at compile time; no
  callback, no run-time check.

## Containment (R6)

| Module | Error set | Boundary validation | Check budget (Principle 17.10) | Bounds |
| ------ | --------- | ------------------- | ------------------------------ | ------ |
| `contract.validateHost` | compile errors only | `@hasDecl(D, "vera_version")`, then `std.mem.eql` against `vera_version`; each refusal names `@typeName(D)`, both versions and "regenerate" | always on (not gated by `validating`), comptime, zero run-time cost | one compare |
| `src/cli/args.zig` `--version` | `Io.Writer.Error` | none needed: no input | n.a. | n.a. |
| `tools/conformance.py` `release_version` | `die` (exit 2) | the tag must be `vX.Y.Z`; each literal must exist; `--check` refuses a tree whose literal is another version | n.a. | two files |

A device without the declaration (hand-written, or from before this change,
which declares `contract_abi`) is refused with its own message rather than a
raw "no member named" error.

## Test plan (R7)

| Bug class | Oracle | Layer | Tier | Harness / file |
| --------- | ------ | ----- | ---- | -------------- |
| the contract's literal drifts from `build.zig.zon` | the manifest, read as text by `build.zig` (`manifestVersion`) into `build_options.version` | unit | merge (`zig build test`, `cli`) | `src/cli/args.zig` "--version prints contract.vera_version, which is build.zig.zon's .version" |
| `--version` prints something else or reads on | the literal string `"vera " ++ vera_version ++ "\n"`, stops before `--no-such-flag` | unit | merge | same test |
| a `.v` device stamped with a literal instead of the contract (the 2026-10-02 ESPice bug) | `contract.vera_version` | host | merge (`test-devices`) | `tests/vdev_host.zig` "every .v device is stamped with the contract's vera_version" |
| a `.va` device without the stamp, or with another | `validateHost`, compiled by every `vera --check` and fixture testbench | integration | merge (fixture suite) | every fixture |
| `--changelog` sets one literal and not the other, or the zon's `minimum_zig_version` | hand-written before/after files | unit | `conformance.py selftest` | `ReleaseVersionTests` |
| byte counts of generated devices | the line is 1 byte shorter (110 → 109) | golden | merge | `tests/harness/sweep.zig` `expected`, every `.device` - 1 |

Seams under test: the ones above, all existing; none new. Exit criteria:
`zig build test` exit 0, `test-devices` all pass, goldens move only by the
stamp line of each device, `tools/doctest.py` clean after `--update`.

## Record (R9)

- No seam, no table, no new module edge (`vpi` reaches the version through
  `vera.version`, which `lib/root.zig` already imports `kernels` for).
- Terms: "the ABI version" retires; "the VerA release a device carries"
  (`vera_version`) replaces it. `docs/host/device.md` "Version stamp",
  `docs/host/linking.md`, `docs/host/why.md`, `docs/using/cli.md`,
  `AGENTS.md` §3 (the two literals move together), `ARCHITECTURE.md` B1.
- Hard-to-reverse: the device text changes for every host. ESPice must read
  `vera_version` instead of `contract_abi` (it is regenerated against the
  same contract file, so `validateHost` already does that for it).
- Semver: a minor (device text changes). Historical records that cite
  `abi_version` (`Vague_Decisions.md` "Device ABI 6", earlier reviews, an
  Unreleased bullet) stay as written.

## Checklist

| # | Check | Source | Verdict | Evidence |
| - | ----- | ------ | ------- | -------- |
| 1 | the usage code exists | R1 | pass | above |
| 2 | one owner of the version literal | §11.8 | pass | `tools/contract.zig` `vera_version`; codegen via `kernels.vera_version`, `.v` emit, CLI, VPI all read it |
| 3 | no second spelling of the stamp | §11.8 | pass | both emitters format the contract's constant |
| 4 | always-on refusal names both versions | user decision | pass | `validateHost` |
| 5 | R7 string compares | `tests/fitness.zig` | pass | `src/cli/args.zig` row 39 → 40 for `--version` |
| 6 | `doctest.py` transcripts | §9 | needs `--update` | `docs/examples/host/device.out`, `docs/examples/using/help.out` hand-edited |
