# Diagnostics

Every problem VerA reports has a **code**: a letter for the severity (`E`
error, `W` warning) and four digits. The first two digits name the stage
that found it:

| Class | Stage | Class | Stage |
|---|---|---|---|
| `01` | lexical and preprocessing | `06` | numerical safety (the finiteness proof) |
| `02` | syntax (LRM Annex A) | `07` | events and timing |
| `03` | types, disciplines, declarations | `08` | system tasks and functions |
| `04` | behavioural semantics | `09` | hierarchy and elaboration |
| `05` | analog operators and math | `10` | runtime and the device contract |

Codes are stable. A code is never renumbered or reused, so scripts,
fixtures (`//! reject E0314`) and this book can name one.

## Reading one

```verilog
{{#include ../examples/using/undeclared.va}}
```

```console
{{#include ../examples/using/undeclared.out}}
```

The first line is the code and its title, then the location, the source line
with the span underlined, and the LRM clause the rule comes from. `help:`
lines suggest a fix (here a near-miss name); the last one names the command
that prints the long form.

## `--explain`

`vera --explain CODE` prints the rule, why it exists, and how to satisfy it:

```console
{{#include ../examples/using/explain.out}}
```

`--explain` colours its output unless `--color=never` comes before it on the
command line; the transcript above asks for plain text.

## Warnings, and making them errors

A warning does not fail the compile. The one you will meet first is W0650.
Before emitting a device, VerA tries to prove that every contribution is a
finite IEEE double for every input. A contribution it can prove finite
compiles with Zig's optimized float mode (no NaN, no infinity, free to
reassociate and vectorise); one it cannot compiles in strict mode, which is
correct but slower:

```verilog
{{#include ../examples/using/expo.va}}
```

```console
{{#include ../examples/using/warn.out}}
```

`exp` of an unbounded voltage over an unranged parameter can overflow. LRM
§4.3.2 makes that legal, so VerA neither rejects the model nor inserts a
clamp behind your back. Ranges (LRM §3.4.2) give the prover something to
work with, and `--unknown-bound=X` tells it the solver keeps every node
within ±X volts (or amps for a flow unknown). Each note names the value that
broke the proof, so the fixes come one at a time:

```verilog
{{#include ../examples/using/expo_ranged.va}}
```

```console
{{#include ../examples/using/proof.out}}
```

With both parameters ranged and nodes bounded to ±3 V, `V(p,n)/vt` is at most
600 and `exp(600)` is finite, so the warning goes away.

Each code's level can be set from the command line, after rustc's lint
levels:

| Flag | Effect |
|---|---|
| `--allow=CODE` | do not report it |
| `--warn=CODE` | report it, do not fail |
| `--deny=CODE` | report it as an error |
| `--forbid=CODE` | like `--deny`, and refuse a later `--allow` or `--warn` of the same code |

An error code cannot be allowed or warned: it is a statement about the
program, not a preference.

```console
{{#include ../examples/using/deny.out}}
```

## JSON

`--diagnostics=json` prints one JSON object per line, for editors and
scripts. The fields are `code`, `level`, `stage`, `lrm`, `title`, `message`,
`span` (`file`, `line`, `col`, and byte offsets), `labels` and `notes`:

```console
{{#include ../examples/using/json.out}}
```

The byte offsets count from the start of the preprocessed text, which begins
with the LRM Annex D prelude; use `line` and `col` to find the source.
