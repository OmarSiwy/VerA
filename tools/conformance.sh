#!/usr/bin/env bash
# The conformance number, measured — never typed.
#
#     tools/conformance.sh                      # print the markdown block
#     tools/conformance.sh --changelog v0.1.0   # prepend it to CHANGELOG.md
#     tools/conformance.sh --check v0.1.0       # re-measure and diff vs CHANGELOG.md
#
# Every number comes from a command in this file. There is no second place a
# percentage is written down, which is the point: ROADMAP.md §1 defines v1.0.0
# as four measures, and two of them are machine-readable today.
#
# ponytail: grep over the suite's own report, not a --json flag on bench.zig.
# Both lines parsed here are already machine-shaped — the `pass fail unasserted
# xfail` TSV row (bench.zig:828) and the coverage tally (harness.zig:564). If a
# third consumer ever wants this, add the JSON then.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 2

mode="${1:-}"
version="${2:-}"
case "$mode" in
  ""|--changelog|--check) ;;
  *) echo "usage: conformance.sh [--changelog|--check vX.Y.Z]" >&2; exit 2 ;;
esac
[ -n "$mode" ] && [ -z "$version" ] && {
  echo "usage: conformance.sh $mode vX.Y.Z" >&2; exit 2; }

die() { echo "conformance.sh: $1" >&2; exit 2; }

# CI has already run these suites and kept the logs; re-running them costs half
# an hour and cannot produce a different answer. Locally both are unset and this
# script runs them itself.
#   STRICT_LOG=… COVERAGE_LOG=… tools/conformance.sh
reuse="${STRICT_LOG:-}${COVERAGE_LOG:-}"
[ -n "$reuse" ] || zig build -Doptimize=ReleaseFast install >&2 || exit 2

# --- Measure A: the fixture suite -------------------------------------------
# bench.zig prints a TSV header `pass fail unasserted xfail` and one row under
# it. --strict decides the exit code on it; the counts print either way.
if [ -n "${STRICT_LOG:-}" ]; then
  strict="$(cat "$STRICT_LOG")"
  strict_rc="$(grep -oP '^(strict exit: |exit=)\K\d+' <<<"$strict" | tail -1)"; strict_rc="${strict_rc:-?}"
else
  strict="$(zig build benchmark -- --strict 2>&1)"; strict_rc=$?
fi
read -r pass fail unas xfail < <(grep -A1 -P '^pass\tfail\tunasserted\txfail$' <<<"$strict" | tail -1)
[[ "${pass:-}" =~ ^[0-9]+$ ]] || {
  printf '%s\n' "$strict" | tail -30 >&2
  die "could not parse the verdict row. bench.zig:828 changed?"
}
total=$((pass + fail + unas + xfail))

# --- Measure C: static clause citations, not verified rule coverage ----------
if [ -n "${COVERAGE_LOG:-}" ]; then
  cov="$(cat "$COVERAGE_LOG")" || die "could not read COVERAGE_LOG"
else
  cov="$(zig build benchmark -- --coverage 2>&1)" || die "coverage command failed"
fi
read -r both acc ref unc < <(grep -oP '\d+(?= (cited both ways|positive citations only|rejection citations only|uncited))' \
  <<<"$cov" | paste -sd' ')
clauses="$(grep -oP '^\d+ of \K\d+(?= LRM clauses cited)' <<<"$cov" | head -1)"
[[ "${clauses:-}" =~ ^[0-9]+$ ]] || die "could not parse the coverage tally. harness.zig:564 changed?"
for value in "${both:-}" "${acc:-}" "${ref:-}" "${unc:-}"; do
  [[ "$value" =~ ^[0-9]+$ ]] || die "incomplete coverage polarity tally"
done
(( both + acc + ref + unc == clauses )) || die "coverage tally does not sum to clause denominator"

# --- The two gates that are pass/fail, not a percentage ----------------------
zig build test         >/dev/null 2>&1 && unit=pass    || unit=FAIL
zig build test-devices >/dev/null 2>&1 && devices=pass || devices=FAIL

pct() { awk -v n="$1" -v d="$2" 'BEGIN{ printf (d==0 ? "n/a" : "%.1f%%"), 100*n/d }'; }

block="$(cat <<EOF
| Measure | Number | Remaining to v1.0.0 | Command |
|---|---|---|---|
| **A** — fixtures behaving as stated | **$pass / $total — $(pct "$pass" "$total")** | $((total - pass)) rows | \`zig build benchmark -- --strict\` |
| &nbsp;&nbsp;↳ FAIL · unasserted · XFAIL | $fail · $unas · $xfail | all three to 0 | same run |
| **C** — clauses with both citation polarities (static) | **$both / $clauses — $(pct "$both" "$clauses")** | $((clauses - both)) clauses | \`zig build benchmark -- --coverage\` |
| &nbsp;&nbsp;↳ positive-only · rejection-only · uncited | $acc · $ref · $unc | requires rule-level review | same run |
| **B** — IEEE 1364 §§17–18 obligations | hand-entered, see \`docs/CLAUSE-AUDIT.md\` §7.1 | not measured by this script | source and evidence review required |
| **D** — \`ARCHITECTURE.md\` §6 phases landed | hand-entered, see \`ARCHITECTURE.md\` §8 | not measured by this script | architecture review required |
| \`zig build test\` | **$unit** | pass | \`zig build test\` |
| \`zig build test-devices\` | **$devices** | pass | \`zig build test-devices\` |

\`--strict\` exit code **$strict_rc** — 0 only when FAIL, unasserted and XFAIL are all 0.
A and C are measured by this script and nothing else may write them. B and D are
hand-entered against their source documents; if you change one, say which
document you read.

C counts citations without executing fixtures. It is not a conformance score:
XFAILs and implementation-limit rejections can supply citations, and a clause
can contain multiple untested rules. See \`docs/CONFORMANCE.md\`.
EOF
)"

[ -z "$mode" ] && { printf '%s\n' "$block"; exit 0; }

# Only the rows this script computes are verifiable. B and D are hand-entered
# against documents no command reads, so `--check` must not hold them to the
# placeholder text `--changelog` wrote — it would force every release to either
# leave them blank or fail.
measured() { grep '^|' | grep -v 'hand-entered'; }
section() { sed -n "/^## ${version//./\\.} /,/^## .*—/p" CHANGELOG.md | measured; }

if [ "$mode" = "--check" ]; then
  grep -q "^## ${version//./\\.} " CHANGELOG.md || die "CHANGELOG.md has no $version entry. Run: tools/conformance.sh --changelog $version"
  if diff -u <(section) <(measured <<<"$block") >/tmp/conformance.diff; then
    echo "conformance.sh: $version matches the tree — $pass/$total fixtures, $both/$clauses clauses" >&2
    exit 0
  fi
  echo "conformance.sh: CHANGELOG.md's $version numbers are not what this tree measures." >&2
  echo "  Left is CHANGELOG.md, right is this run. Re-tag after re-measuring:" >&2
  echo "    tools/conformance.sh --changelog $version" >&2
  cat /tmp/conformance.diff >&2
  exit 1
fi

# --changelog: prepend. The preamble is preserved by splitting on the first
# `## ` line, so a re-run never duplicates it.
tmp="$(mktemp)"
{
  sed '/^## /,$d' CHANGELOG.md
  printf '## %s — %s\n\n' "$version" "$(date -u +%Y-%m-%d)"
  printf '%s\n\n' "$block"
  sed -n '/^## /,$p' CHANGELOG.md
} >"$tmp"
mv "$tmp" CHANGELOG.md
echo "CHANGELOG.md: $version written — $pass/$total fixtures, $both/$clauses clauses" >&2
