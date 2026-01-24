# Digital time conversion

`src/sim/time.zig` supplies allocation-free timescale conversion to the scheduler's
unsigned 64-bit ticks. The [source runner](digital-source-execution.md) uses it
for integral delays in one module with an explicit timescale. Multiple scopes,
design-wide precision selection and mixed-signal timing remain open.

## Standard rules

The target is [Verilog-AMS 2023](https://www.accellera.org/images/downloads/standards/v-ams/VAMS-LRM-2023.pdf)
with inherited [IEEE 1364-2005](https://ieeexplore.ieee.org/document/1620780):

- §19.8 permits magnitudes 1, 10 and 100 with s, ms, us, ns, ps and fs.
  Local precision cannot be coarser than the unit; the finest precision in the
  design determines global ticks. Local delay rounding precedes global scaling.
- §§4.8 and 4.8.2 require at least 64-bit unsigned time values and nearest-integer
  real conversion, with exact halves rounded away from zero.
- §9.7.1 interprets negative procedural delays as unsigned two's-complement time
  values and X/Z delays as zero. §14.3.1 instead clamps negative specify-path
  delays to zero. These are separate contexts, not a universal negative clamp.

`Quantum.fromParts` validates a directive operand. `Quantum.fromSeconds` accepts
only the existing preprocessor's canonical 18 floating constants; it does not
estimate decimal exponents from a floating ratio. `Scale.init` validates local
and global precision and stores two exact decimal integer factors.
`unsignedDelay` and `signedDelay` never convert integer counts through a real.
`pathSignedDelay` applies the separate specify-path rule. Callers handle X/Z
before invoking these known-value utilities.

## Real rounding interpretation

`realDelay` multiplies the evaluated IEEE binary64 value by the exact decimal
local factor using binary64 arithmetic, rounds the result to the nearest integer
with halves away from zero, then converts to global ticks using checked integer
multiplication. No timestamp or scheduler key is floating point. Integral inputs
never enter this path and retain all 64 bits.

This is an explicit interpretation, not a claim that §19.8 uniquely specifies
all intermediate arithmetic. It follows established binary64 delay conversion:
the standard's 1.55 example gives 16 local ticks, and 0.15 and 1.45 at a factor
of 10 give 2 and 15. Although their represented binary64 values lie just below
decimal halves, the multiplication rounds to 1.5 and 14.5 before conversion.
[Icarus Verilog's real conversion](https://github.com/steveicarus/iverilog/blob/master/verireal.cc)
and [runtime delay elaboration](https://github.com/steveicarus/iverilog/blob/master/elaborate.cc)
use this sequence. This is a source comparison, not a completed differential
simulation suite or proof that all intermediate choices are mandated.

Real inputs retain binary64 precision, not all 64 integer bits. For example, the
binary64 value immediately above 1, multiplied by 10^17, produces the tick count
100000000000000016; rounding the exact rational product instead would produce
100000000000000022. The implementation follows binary64 scaling and does not
substitute that different numeric model. Boundary overflow is diagnosed before
integer conversion. The interpretation still needs language-level qualification.

Negative procedural real delays currently return `NegativeRealDelay`. Their
conversion order relative to local precision and unsigned-time conversion still
needs qualification; they are not silently changed to zero. `pathRealDelay`
implements the separate negative-to-zero path rule. Nonfinite real inputs return
`NonFiniteDelay`; a count or scaled result beyond u64 returns `DelayOverflow`.
These are explicit implementation limits, not language rules allowing rejection
of all such source expressions. The scheduler separately checks timestamp addition.

## Evidence and remaining integration

`zig build test-sim` includes operand validation, decimal factors, integer counts
above 2^53, local-before-global rounding, adjacent half-tick values, subnormals,
maximum timestamp counts, overflow and negative-context tests. A dyadic-rational
oracle checks all valid local scale pairs with exactly representable scaled
inputs; separate tests pin the binary64 rounding boundary behavior.
The time tests run in Debug and ReleaseFast.

The source runner tests integral delay expressions, X/Z-to-zero conversion,
zero-delay scheduling and exact integer tick reporting. Remaining work includes
multiple-module directive state, unspecified/mixed timescale rules and `resetall`,
design-wide precision selection, general delay expressions, real procedural
conversion, qualification of the rounding interpretation above, and standard
time queries/format conversion. Analog/digital boundary quantization is a separate AMS §8.4
operation; these utilities do not implement it.
