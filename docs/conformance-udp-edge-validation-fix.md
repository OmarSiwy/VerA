# UDP single-transition validation

2026-09-23. IEEE1364-2005 §§8.1.4 and8.4 explicitly prohibit more than one
input transition descriptor in a sequential table row. Main read the complete
Clause8 text and reproduced acceptance of the invalid two-edge definition
before the repair. The matching single-edge definition also passed.

The parser already recognized the UDP input alphabet and rejected edges in
combinational rows, but sequential rows accepted arbitrary numbers of edges.
The repair counts a parenthesized pair once, at its opening parenthesis, and
each shorthand r/R/f/F/p/P/n/N/* once. A second descriptor raises E0234 with
a rule-specific message. Level symbols and the closing parenthesis do not
increment the count. Combinational handling and runtime level/edge dominance
are unchanged; this is not complete UDP validation or execution support.

The new parser test covers fifteen legal forms and eight invalid combinations;
the worker's focused run passes, along with the existing header/row-preservation
test. Root reviewed and integrated only these parser hunks, preserving unrelated
formatting. New digital negative audit_udp_two_edges_rejected.v requires both
E0234 and the transition-count phrase; its source differs from the legal control
only in the second input descriptor. The previously accepted invalid control
remains available for comparison. Root build and suite results are pending.

Root focused parser test and CLI install exit zero. Running the new two-edge
fixture now exits one with E0234 and the exact required phrase; its one-edge
control exits zero and prints `definition accepted`. Full unit/strict/digital
gates are running for the integrated UDP, parameter and expression batch.

The integrated root unit gate now exits zero. Full digital execution passes
the new input-z and two-edge negatives; their positive definition controls
were also independently run. The three required UDP runtime witnesses remain
failures before behavior is reached, as reported in the source review. Exact
digital name comparison adds only new expression/hierarchy/UDP positives and
preserves all pre-existing failure names. Strict/measurement completion is
still pending.
