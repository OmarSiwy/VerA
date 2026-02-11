#!/usr/bin/env bash
# Measure B — inherited IEEE 1364 §§17-18 obligations closed.
#
# B is the one measure of the four with no suite behind it: §§17-18 are outside
# `--coverage`'s denominator by construction (CLAUSE-AUDIT.md §1.1 c), so the
# rows are hand-read. What CAN be checked is the arithmetic, and that is this
# script's whole job: it re-adds CLAUSE-AUDIT.md §7.1's table and fails if the
# per-section rows stop summing to the total, or if closed + open stops summing
# to the row count.
#
# This is NOT a conformance measurement and must never be reported as one.
# It answers "is the hand-read tally self-consistent?", not "is it right?".
# Re-deriving the rows themselves is reading, and AGENTS.md §2 says so.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
doc="$root/docs/CLAUSE-AUDIT.md"
[ -r "$doc" ] || { echo "measure-b: $doc is missing (it was deleted once: 2cc1c08)" >&2; exit 2; }

# ponytail: awk over the one table, not a markdown parser. The table is pinned
# by its header row, so a reshuffle of §7 cannot silently match the wrong one.
awk -F'|' '
  /^\| Section \| Rows \| missing \|/ { intable = 1; next }
  intable && /^\| \*\*Total\*\*/ {
    for (i = 3; i <= 9; i++) { gsub(/[^0-9]/, "", $i) }
    trows = $3; tsum = $4 + $5 + $6 + $7 + $8 + $9
    intable = 0; next
  }
  intable && /^\| §4/ {
    for (i = 3; i <= 9; i++) { gsub(/[^0-9]/, "", $i); if ($i == "") $i = 0 }
    rows += $3; sum += $4 + $5 + $6 + $7 + $8 + $9
    per[++n] = $2 "  rows=" $3 "  verdicts=" ($4 + $5 + $6 + $7 + $8 + $9)
    if ($3 != $4 + $5 + $6 + $7 + $8 + $9) bad[++nbad] = per[n]
  }
  /^\| \*\*closed\*\* \|/ { c = $3; gsub(/[^0-9]/, "", c); closed = c }
  /^\| \*\*open\*\* \|/   { o = $3; gsub(/[^0-9]/, "", o); open = o }
  END {
    rc = 0
    for (i = 1; i <= n; i++) print "  " per[i]
    printf "\n  section rows       %d\n  section verdicts   %d\n  stated total       %d / %d\n", rows, sum, trows, tsum
    printf "  closed + open      %d + %d = %d\n\n", closed, open, closed + open
    for (i = 1; i <= nbad; i++) { printf "FAIL: section does not sum: %s\n", bad[i]; rc = 1 }
    if (rows != sum)        { printf "FAIL: rows %d != verdicts %d\n", rows, sum; rc = 1 }
    if (trows != rows)      { printf "FAIL: stated total %d != summed rows %d\n", trows, rows; rc = 1 }
    if (tsum != sum)        { printf "FAIL: stated verdict total %d != summed %d\n", tsum, sum; rc = 1 }
    if (closed + open != rows) { printf "FAIL: closed+open %d != rows %d\n", closed + open, rows; rc = 1 }
    if (rc == 0) printf "measure B: %d / %d closed, %d open — tally is self-consistent\n", closed, rows, open
    exit rc
  }
' "$doc"
