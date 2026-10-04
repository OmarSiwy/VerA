#!/usr/bin/env bash
# Print VerA's known gaps, one per line, sorted: every FAIL/XFAIL fixture of
# the strict suite and every one-way or uncited clause of the two coverage
# inventories. CI diffs this against docs/known-gaps.txt (AGENTS.md §0 rule
# 3: names, not counts), so a new gap fails and a fixed one fails until its
# line is deleted.
#
#   tools/known_gaps.sh STRICT_STDERR LRM_COVERAGE_LOG IEEE_COVERAGE_LOG
set -euo pipefail
strict_err=$1 lrm=$2 ieee=$3

oneway() { # $1 tag, $2 log
	awk -v tag="$1" '
		/^(POSITIVE CITATIONS ONLY|REJECTION CITATIONS ONLY|UNCITED) —/ { f = 1; next }
		/^[A-Z][A-Z ]+ —/ { f = 0 }
		f && /^§/ { print tag, $1 }' "$2"
}

{
	grep -E '^(FAIL|XFAIL) ' "$strict_err" | sed 's|^\(X\?FAIL\) .*/tests/fixtures/|\1 |; s|:.*||' || true
	oneway ONEWAY-LRM "$lrm"
	oneway ONEWAY-IEEE "$ieee"
} | LC_ALL=C sort -u
