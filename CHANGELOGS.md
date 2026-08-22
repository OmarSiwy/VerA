# Changelog

Every change to VerA since v1.0.0, newest first. One short bullet per change.
A fix names the GitHub issue it closes, as `(#123)`.

Measured conformance per release is a separate record, `CHANGELOG.md`, which
only `tools/conformance.py` writes.

## Unreleased

- `` `include "discipline.h" `` and `"constants.h"`, the Verilog-A 1.0 names of the Annex D headers, now resolve to the built-ins (VD-093) (#4).
- `vera --emit-osdi FILE.va -o out.osdi`: an OSDI 0.4 library ngspice loads with `pre_osdi` (`tools/osdi_dyn.zig`), the same device `--emit-so` builds.
- `nix develop .#benchmarking` carries the reference tools for accuracy checks: iverilog, verilator, yosys, ngspice, Xyce, gnucap and OpenVAF-Reloaded.
- License: Apache 2.0 (was MIT). Third-party notices are in `NOTICE`.
- `CHANGELOGS.md` started: every change from now on gets a bullet here.
