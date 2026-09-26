# Inherited IEEE 1364-2005 §17.2 file-I/O audit

Reviewed 2026-09-23 against supplied docs/1364-2005.pdf, SHA256
3bebc696d5a338dbfa6925c9ffdeccc6de745e703abae8af84dd8f5551fe0a9e.
Complete §17.2, **File input-output system tasks and functions**, including
§§17.2.1–17.2.10: printed286–298, physical316–328, text read in full.
Visual inspection: physical317–319 and326–328, including Syntax17-4–8,
Table17-7 file modes and Tables17-8/9 SDF selection/scaling. This is a source
review boundary, not an exhaustive passing-evidence claim or a percentage.

AMS §9.1 inherits these digital obligations; AMS §9.5 adds analog behavior.
Analog accepted/rejected-iteration file rollback, cross-context sharing and
multiple-analysis reopening are additional obligations and are not exercised
by the digital fixtures below. Conversely, digital character/binary reads,
packed-reg strings and memory loading are not certified by analog string tests.

## Source-backed corrections and measured evidence

All paths below are under tests/fixtures/digital. Targeted execution used the
current root vera executable with --run, from this directory. Expected files
contain independently derived normative output, not copies of observed errors.
Digital transcripts have no XFAIL inversion; failures remain failures.

| ID | Source and fixture | Observed result / disposition |
|---|---|---|
| IEEE-FILE-MEM-001 | §17.2.9 p296; audit_readmem_lowest_descending.v plus audit_readmem_four.hex | Both [7:4] and [4:7] declarations load indices4..7 with11,22,33,44. Exit0, both exact expected lines. Existing d09_08_readmemh.v header repaired from LEFT to LOWEST index; ascending declaration had masked its false general rule. |
| IEEE-FILE-MEM-002 | §17.2.9 p297; d09_91_readmem_overflow_rejected.v | Withdrawn erroneous refusal/error requirement. Source mandates warning for sequential count mismatch. Converted to positive digital transcript, explicit task range0..3, copied five-word data control into actual digital relative-path location. Exit0 and expected11 22 33 44; no warning observed. Warning obligation remains OPEN because successful stderr is not asserted by runner. Historical filename retained. |
| IEEE-FILE-SCAN-001 | §17.2.4.3 p293; audit_sscanf_unknown_input.v | Packed-reg input with x and format with z must return EOF(-1). Execution exits1 E1100 at sscanf, before either behavior. Expected two−1 results retained, not treated as rejection success. |
| IEEE-FILE-READ-001 | §§17.2.1/4.1/5/8; audit_file_read_position.v plus audit_file_ab.txt | fd marker, character read, pushback, rewind cancellation, signed seek and EOF checks. Execution exits1 E1100 at fopen before any observation. No credit for later operations. |

The d09_91 collection/name-list transition is intentional invalid-oracle
repair: it leaves the legacy rejection collection and enters actual digital
transcript execution. It does NOT make a compiler defect disappear. The
withdrawn claimed error becomes the distinct unasserted mandatory warning in
IEEE-FILE-MEM-002. The original data existed only as
ch09_system_tasks/d09_91_readmem_overflow_rejected.hex, not the source's named
ieee1364/17_system_tasks/91_readmem_overflow_rejected.hex; the new five-word control corrects
that runtime setup without deleting the historical control.

## Atomic obligation worklist

Every row is a group requiring finer independent cases, not one keyword test.

| Clause / group | Independent requirements and missing evidence |
|---|---|
| 17.2.1 / OPEN | Literal and packed-reg filename/mode; absent mode => MCD, explicit mode => fd; r/rb,w/wb,a/ab and all six update spellings; create/truncate/append; open failure0 and detailed error; platform binary/text mappings. |
| 17.2.1 / HANDLE | 32-bit MCD one-hot and bit31 clear; bit0 stdout; OR fanout; fd bit31 set and fixed stdin/out/err identifiers; no fd OR fanout; close one/multiple, no postclose access, channel reuse; close cancels active monitor/strobe. |
| 17.2.2 / OUTPUT | All16 file-output names, descriptor expressions, inherited formatting; simultaneous independent fmonitor registrations; no monitoron/off counterpart; canceled pending output after close. |
| 17.2.3 / STRING | swrite radix family and packed output string assignment per5.2.3; sformat interprets only second argument; dynamic format; excess/insufficient formatting arguments warning+continue or permitted static error. |
| 17.2.4.1 / CHAR | fgetc byte0xff versus EOF−1 with sufficiently wide destination; ungetc return0/errorEOF, unchanged file, next-byte restoration; host-dependent depth not arbitrary unlimited-stack requirement. |
| 17.2.4.2 / LINE | fgets newline transfer, EOF, destination full, non-byte-aligned capacity excluding partial top byte, character count/error0. |
| 17.2.4.3 / SCAN | Every conversion %,b,o,d,h/x,f/e/g,v,t,c,s,u,z,m; four-state decimal special values; whitespace and null handling, c exception; literal matching; suppression and width; truncation/real overflow; excess destinations ignored; unknown format/input EOF; matched-assigned count; conflicting/trailing input left unread. |
| 17.2.4.3 / RAW | %u two-state expansion and %z VPI vector representation use native host endian, unlike fread; external-byte controls needed, not merely formatter/scanner self-agreement. |
| 17.2.4.4 / BINARY | fread reg versus memory; ignored start/count for reg; memory start/default lowest, count/default fill, ascending addresses regardless declaration; big-endian byte transfer, 9-bit truncation, no x/z, byte count/error0. |
| 17.2.5 / POSITION | ftell next-byte offset/errorEOF; signed offsets and three origins; rewind equivalence; all positioning cancels pushback; seek beyond EOF does not itself extend; later write creates zero-readable gap; append ignores prior seek. |
| 17.2.6–8 / STATUS | Flush fd/MCD/all; ferror code and sufficiently wide text, clear reg/no-error0; feof reflects prior detection, not just cursor=end. |
| 17.2.9 / MEMORY | Both bases, comments/whitespace/xz/underscores; no width/base prefixes; @hex no intervening whitespace; lowest default, explicit start and both directions, direction persists after@; addresses constrained to task range require error and terminated load; count mismatch without@ requires warning. Only bounded cases measured above. |
| 17.2.10 / SDF | Literal/packed filename; optional/default instance scope including array index; config/log controls; MAXIMUM/MINIMUM/TYPICAL/TOOL_CONTROL default; scale triples/default1 and FROM_* selection/defaultMTM; arguments override configuration; actual annotated timing and logs need evidence, not accepted task name. |

Invalid conversion characters are implementation-dependent; insufficient scan
destinations undefined. Neither is a universal required-rejection oracle.
The §17.2.4 r/r+-only statement conflicts with Table17-7's w+/a+ update
descriptions, just as in AMS; preserve this source inconsistency rather than
invent a forbidden-mode test. Syntax17-4's quoted filename notation does not
erase the adjacent normative permission for packed-reg filenames.

Existing d09_09_readmemb_range.v remains a useful descending/xz candidate;
its body was read but not freshly run in this checkpoint. The broad §17.2
obligations above remain open where no measured case is recorded. No compiler
implementation was changed; full unit/benchmark gates belong to integration.

Root integration (2026-09-23): main read the full report and proposed fixtures,
independently checked load-memory, character and positioning semantics, and
reproduced both memory transcripts with the current CLI. The fixtures/data and
header correction are integrated. The former overflow rejection now requires
positive execution AND specific stderr warning evidence using the new bounded
digital observer (`conformance-digital-warning-evidence.md`). The worker table's
unasserted-warning boundary is therefore superseded for that fixture; actual
warning emission is still pending its separate compiler repair and root gates.
The historical file and withdrawn false error claim are retained in the audit
trail, not erased or counted as an implementation success.
