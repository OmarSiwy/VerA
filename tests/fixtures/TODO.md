# Where the conformance pass stopped — HISTORICAL, and closed

This file recorded the state of the suite at the end of the wave-1 reorientation,
when it was `1102 fixtures · 814 pass · 287 XFAIL · 1 CANNOT RUN · 0 FAIL`. Every
number, every work list and every path in it is now dead, so the body is gone
rather than left to be read as current:

- the counts: measure them. `zig build torture` is the only register that cannot
  go stale, and `/TODO.md` carries the last measured figure plus the ceilings no
  fixture can state;
- the 287 xfails: two are left. Both are in `/TODO.md` with their blast radius;
- the `CANNOT RUN` verdict it explained: retired. See
  [README.md](README.md#the-retired-cannot-run-verdict);
- `tests/audit/*--WORKORDER.json`, the 550-item audit it pointed at: deleted once
  the epics it fed were worked off. `git log` is the history;
- the 290 orphaned `.expected-error.txt` sidecars: gone, all of them. The
  README's "no sidecar files" is now true rather than aspirational;
- the two VerA bugs it named (`ch09_system_tasks/06_display_formats.va` failing
  to build its testbench, the §9.7 file-I/O family) : both fixed, both green;
- the per-chapter `COVERAGE.md` staleness warning: those files were rewritten
  from the directories as they stand, chapter by chapter, across waves 2-7.

## The one thing here that is still load-bearing

`docs/*.html` was corrected against `VAMS-LRM-2-4.pdf` before any of this began,
because the fixtures were derived from the HTML. 14 files were patched: two Annex
A productions that were referenced but undefined (`constant_expression_or_null`,
`string`), `constant_expression_or_null` vs `analog_expression_or_null` in Syntax
7-2, the empty-port-list alternative in `list_of_port_declarations`, two missing
reserved keywords, and Symbol-font PUA codepoints in §5.6.4 that rendered blank.

**Do not re-derive a fixture's expectation from an older copy of those files.**
