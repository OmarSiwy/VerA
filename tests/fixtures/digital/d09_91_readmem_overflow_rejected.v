// REJECT. Inherited IEEE 1364-2005 §17.2.9: when the data file holds more
// numbers than there are addresses in the range being loaded, the task shall
// report an error. Silently dropping the surplus is the dangerous answer —
// a memory image that is one word too long is almost always a build mistake,
// and the loaded contents are then wrong in a way no later assertion sees.
//
// 91_readmem_overflow_rejected.hex holds FIVE words:
//     11 22 33 44 55
// and the memory is `reg [7:0] m [0:3]` — four addresses, 0 through 3, and no
// start/finish arguments, so the range is the whole declared range. The first
// four words fill m[0..3]; the fifth word has nowhere to go. 5 − 4 = 1, i.e.
// exactly one word past the end, the smallest overflow there is, so an
// implementation that checks the count only coarsely still has to catch it.
// (The file held SIX words while the header claimed "one word past the end";
// the count and the prose disagreed. Corrected by trimming the file to five
// words, which is the stronger of the two readings.)
//
// The memory is otherwise ordinary and the file is otherwise well formed:
// plain hexadecimal, no comments, no `@` address, no x or z digits. The only
// thing wrong with this program is the count, which is the rule cited.
//
// This is a REFUSAL fixture and therefore does not count as positive coverage
// of the 17.2.9 row; 08_readmemh.v and 09_readmemb_range.v carry that.
//
// WHAT IS AND IS NOT VERIFIABLE FROM THE CORPUS ON DISK. docs/ holds the
// Verilog-AMS LRM only; §9.5 Table 9-2 names $readmemh and marks it digital-
// context, and that is every word the shipped text spends on it. IEEE 1364-2005
// §17.2.9 itself is NOT on disk, so the SEVERITY of the excess-data rule cannot
// be opened and checked here. What can: docs/CLAUSE-AUDIT.md:313 records the
// obligation as "17.2.9 $readmemb/$readmemh: comments, addresses, ranges,
// direction, x/z, malformed and excess data", i.e. excess data is part of the
// row. This fixture takes the position that excess data is DIAGNOSED and the
// load does not silently succeed. Its falsifier is explicit: if a reader with
// the 1364 text finds only a warning is required, then a conforming tool may
// warn and continue, this file must stop being a refusal, and it should become
// a stdout fixture asserting `11 22 33 44` plus the diagnostic — do that rather
// than leave a refusal the standard does not license.
//
// WHY THE DIRECTIVE NAMES A SUBSTRING. This file carried a bare `//! reject`
// until the review, which `tests/torture.zig:223` satisfies with ANY diagnostic
// — and one exists today, verified at 45b505d:
//   error[E1100]: digital source execution failed: digital system task
//   `$readmemh` is not implemented
// so the bare form passed on the feature being ABSENT. The substring below is
// chosen not to appear in that message (`$readmemh`, `E1100` and
// `DiagnosticsReported` all do appear, and all would be toothless). The
// implementation owes a diagnostic containing "more data than the load range";
// swap it for the catalogue code once the 17.2.9 row assigns one.
//
//! reject more data than the load range
//! rule inherited IEEE 1364-2005 17.2.9 — more data words than addresses in the load range is an error
//! data 91_readmem_overflow_rejected.hex
`timescale 1ns/1ns
module d09_readmem_overflow;
  reg [7:0] m [0:3];
  initial begin
    $readmemh("91_readmem_overflow_rejected.hex", m);
    $display("%h %h %h %h", m[0], m[1], m[2], m[3]);
    $finish(0);
  end
endmodule
