//! Annex E Table E.1: the SPICE primitives, as ordinary Verilog-A modules.
//!
//! Data only. One module per Table E.1 primitive, so a SPICE-named instance elaborates like
//! any other module.
//!
//! LRM clauses this file's code cites: §3.4.4, §4.5.5, §4.6.1, §4.6.3, §6.2.2, §6.3, §6.4, §6.5.5, §6.7.1, §7, §9.10.

const std = @import("std");

// ---------------------------------------------------------------------------
// Annex E — the Table E.1 SPICE primitives, as ordinary modules
// ---------------------------------------------------------------------------

/// Annex E Table E.1 — the "basic set of SPICE primitives" E.2 requires a
/// SPICE-compatible tool to provide, written as ordinary Verilog-AMS module
/// declarations and prepended like the annex D files.
///
/// WHY A PRELUDE OF MODULES, and not a table of names in the parser or codegen.
/// E.2 is explicit that "SPICE primitives built into the simulator shall be
/// treated in the same manner in Verilog-AMS HDL as built-in primitives" — the
/// same MANNER, which is instantiation. A primitive that is a real module gets
/// §6.3 parameter overrides, §6.5.5 named connection, §6.2.2 elaboration, §6.7.1
/// hierarchical access and every diagnostic in those clauses for free, from the
/// code that already implements them; a hard-coded name gets none of it and has
/// to reimplement each one. It is also readable: a user can see what `resistor`
/// does, which is the only defence against E.1.2's fourth axis of
/// incompatibility ("the mathematical description of the built-in primitives can
/// differ").
///
/// WHAT IS NORMATIVE HERE AND WHAT IS NOT. Table E.1 fixes three things and
/// nothing else: the primitive NAME, the port names IN ORDER, and the parameter
/// names IN ORDER (E.3: "for connection by order instead of by name, the ports
/// and parameters shall be given in the order listed"), plus "the default
/// discipline of the ports for these primitives shall be electrical and their
/// descriptions shall be inout". So the headers below are transcription and must
/// not drift. Everything else is implementation-dependent BY THE ANNEX'S OWN
/// WORDS — E.2: "while the Verilog-AMS HDL built-in primitives are standardized,
/// the SPICE primitives are not. All aspects of SPICE primitives are
/// implementation dependent" — which covers every parameter DEFAULT (Table E.1
/// lists none), every value range, and the five rows whose Behavior column is
/// EMPTY (tline, diode, bjt, mosfet, jfet, mesfet: interface only, no equations,
/// and a comment at each site saying so).
///
/// THE BEHAVIOR COLUMN IS CONTRIBUTED AS A FLOW WHEREVER THE TABLE'S EQUATION
/// ALLOWS IT. Table E.1 writes the resistor as `V = I*r*(...)`, which as a
/// potential contribution makes the branch a source and its current an unknown
/// the equation system carries; written as the algebraically identical
/// `I <+ V/(r*(...))` the current is the contributed value, which is what a
/// §6.7.1 flow probe of the primitive's branch reads back. Same equation, and
/// the observable the annex describes is observable.
///
/// `dc`, `mag` and `phase` lead the parameter list of every independent source
/// row and appear in NONE of their Behavior expressions: they are the §4.6.1
/// analysis-dependent values (DC operating point, AC magnitude and phase) rather
/// than terms of the transient waveform. E.3 makes those names REQUIRED, and a
/// required parameter no equation reads is a parameter that does nothing — so
/// the Behavior column is guarded by `analysis("static") && !analysis("tran")`
/// on every source row, which is §4.6.1's ".OP or .DC analysis" and not a
/// transient's own initial operating point, and `dc` is what the source holds
/// there. E.2.2.3 is the annex using it: `VA VCC GND 5`, a plain 5 V supply, is
/// translated `vsine #(.dc(5)) Vcc (vcc, gnd);` with every waveform parameter
/// left at its default.
///
/// ponytail: `mag` and `phase` are still declared and unused. §4.6.3's
/// `ac_stim(analysis_name, mag, phase)` is the shape they want, and the reason
/// they do not have it is that a source contributing an AC stimulus on top of
/// its large-signal value needs the complex side §4.6.3's own ceiling in
/// `codegen.analysisMatch` does not have yet.
///
/// E.3.1's ccvs, cccs and mutual inductor are ABSENT on purpose: they take a
/// controlling INSTANCE name as a parameter, "Verilog-AMS HDL does not support
/// the concept of passing an instance name as a parameter", and so E.3.1 says in
/// terms that they "are not supported". A missing module is the right answer and
/// E0904 is its diagnostic.
pub const spice_primitives =
    \\// Annex E Table E.1 — names, ports and parameters transcribed; see
    \\// `Preprocessor.spice_primitives` for what of this is normative.
    \\
    \\// resistor | p, n | r, tc1, tc2 | V = I*r*(1 + tc1*T + tc2*T^2)
    \\//
    \\// `T` is a bare T in the published table: it fixes neither a reference
    \\// temperature nor whether the polynomial is in absolute temperature or in
    \\// the rise above nominal, so it is read here as §9.10 `$temperature` in
    \\// kelvin. tc1 = tc2 = 0 collapses the factor to exactly 1 at every T,
    \\// which is the only reading the table pins.
    \\module resistor(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real r = 1.0 from (0:inf);
    \\   parameter real tc1 = 0.0;
    \\   parameter real tc2 = 0.0;
    \\   analog
    \\      I(p, n) <+ V(p, n) / (r * (1.0 + tc1 * $temperature
    \\                                     + tc2 * $temperature * $temperature));
    \\endmodule
    \\
    \\// capacitor | p, n | c, ic | V = (1/c)*integral(I) + ic
    \\//
    \\// Written as the table's integral form rather than as `I <+ c*ddt(V)`,
    \\// because §4.5.5's second argument to `idt` IS the initial condition the
    \\// `ic` parameter names and `ddt` has nowhere to put it.
    \\module capacitor(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real c = 1.0 from (0:inf);
    \\   parameter real ic = 0.0;
    \\   analog
    \\      V(p, n) <+ idt(I(p, n) / c, ic);
    \\endmodule
    \\
    \\// inductor | p, n | l, ic | I = l*integral(V) + ic
    \\//
    \\// The published row multiplies by `l` where the physics divides by it; the
    \\// dimensionally correct 1/l is used here. An inductor whose current grew
    \\// with its inductance would be a transcription bug shipped as a device.
    \\module inductor(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real l = 1.0 from (0:inf);
    \\   parameter real ic = 0.0;
    \\   analog
    \\      I(p, n) <+ idt(V(p, n) / l, ic);
    \\endmodule
    \\
    \\// iexp | p, n | dc, mag, phase, val0, val1, td0, tau0, td1, tau1
    \\//
    \\// `Itd1`, "the value of I at time t = td1", is the second branch evaluated
    \\// at td1 — a closed form, not a recurrence. The first branch is `val0` in
    \\// the iexp row and `dc` in the vexp row; both are transcribed as printed.
    \\module iexp(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real dc = 0.0;
    \\   parameter real mag = 1.0;
    \\   parameter real phase = 0.0;
    \\   parameter real val0 = 0.0;
    \\   parameter real val1 = 1.0;
    \\   parameter real td0 = 0.0;
    \\   parameter real tau0 = 1.0 from (0:inf);
    \\   parameter real td1 = 1.0;
    \\   parameter real tau1 = 1.0 from (0:inf);
    \\   analog begin
    \\      // §4.6.1: `dc` at an operating point that is not a transient's own.
    \\      if (analysis("static") && !analysis("tran"))
    \\         I(p, n) <+ dc;
    \\      else if ($abstime <= td0)
    \\         I(p, n) <+ val0;
    \\      else if ($abstime <= td1)
    \\         I(p, n) <+ val1 - (val1 - dc) * exp((td0 - $abstime) / tau0);
    \\      else
    \\         I(p, n) <+ val0 - (val0 - (val1 - (val1 - dc)
    \\                                   * exp((td0 - td1) / tau0)))
    \\                          * exp((td1 - $abstime) / tau1);
    \\   end
    \\endmodule
    \\
    \\// ipulse | p, n | dc, mag, phase, val0, val1, td, rise, fall, width, period
    \\//
    \\// The table's t0..t4 are one period offset by `n*period` for non-negative
    \\// integer n, so the five branches are the ONE period the time reduced into
    \\// it falls in. period = 0 is a single pulse (nothing to reduce).
    \\module ipulse(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real dc = 0.0;
    \\   parameter real mag = 1.0;
    \\   parameter real phase = 0.0;
    \\   parameter real val0 = 0.0;
    \\   parameter real val1 = 1.0;
    \\   parameter real td = 0.0;
    \\   parameter real rise = 1e-12 from (0:inf);
    \\   parameter real fall = 1e-12 from (0:inf);
    \\   parameter real width = 1e-9 from (0:inf);
    \\   parameter real period = 0.0 from [0:inf);
    \\   analog begin : pulse
    \\      real tp;
    \\      tp = $abstime - td;
    \\      if (period > 0.0 && tp > 0.0)
    \\         tp = tp - period * floor(tp / period);
    \\      // §4.6.1: `dc` at an operating point that is not a transient's own.
    \\      if (analysis("static") && !analysis("tran"))
    \\         I(p, n) <+ dc;
    \\      else if (tp <= 0.0)
    \\         I(p, n) <+ val0;
    \\      else if (tp <= rise)
    \\         I(p, n) <+ val0 + (val1 - val0) * tp / rise;
    \\      else if (tp <= rise + width)
    \\         I(p, n) <+ val1;
    \\      else if (tp <= rise + width + fall)
    \\         I(p, n) <+ val1 + (val0 - val1) * (tp - rise - width) / fall;
    \\      else
    \\         I(p, n) <+ val0;
    \\   end
    \\endmodule
    \\
    \\// ipwl | p, n | dc, mag, phase, wave
    \\//
    \\// `wave` is (time, value) pairs and the table's `n = len(wave)`. §3.4.4
    \\// sizes an array parameter with a range, and there is no unsized array
    \\// parameter to declare, so the length is its own parameter and an instance
    \\// with more than four entries overrides `nwave` alongside `wave`. That is
    \\// the one place this row's interface is wider than Table E.1's.
    \\module ipwl(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real dc = 0.0;
    \\   parameter real mag = 1.0;
    \\   parameter real phase = 0.0;
    \\   parameter integer nwave = 4 from [4:inf);
    \\   parameter real wave[0:nwave-1] = '{0.0, 0.0, 1.0, 0.0};
    \\   analog begin : pwl
    \\      integer i;
    \\      real iw;
    \\      iw = wave[nwave-1];
    \\      for (i = 0; i + 3 <= nwave - 1; i = i + 2) begin
    \\         if ($abstime >= wave[i] && $abstime < wave[i+2])
    \\            iw = wave[i+1] + (wave[i+3] - wave[i+1])
    \\                             * ($abstime - wave[i]) / (wave[i+2] - wave[i]);
    \\      end
    \\      // §4.6.1: `dc` at an operating point that is not a transient's own.
    \\      if (analysis("static") && !analysis("tran"))
    \\         I(p, n) <+ dc;
    \\      else
    \\         I(p, n) <+ iw;
    \\   end
    \\endmodule
    \\
    \\// isine | p, n | dc, mag, phase, offset, ampl, freq, td, damp, sinephase,
    \\//               ammodindex, ammodfreq, ammodphase, fmmodindex, fmmodfreq
    \\//
    \\// I = offset + ampl * (1 - Fam*cos(2*pi*Fam_f*(t-td) - Pam))
    \\//                   * (1 - damp*(t-td))
    \\//                   * cos(2*pi*freq*(1 - Ffm*cos(2*pi*Ffm_f*(t-td)))*(t-td)
    \\//                         - Psin)
    \\// The published row labels the FM frequency f_AM in both source rows; it is
    \\// fmmodfreq, as the parameter name says.
    \\module isine(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real dc = 0.0;
    \\   parameter real mag = 1.0;
    \\   parameter real phase = 0.0;
    \\   parameter real offset = 0.0;
    \\   parameter real ampl = 1.0;
    \\   parameter real freq = 1.0 from (0:inf);
    \\   parameter real td = 0.0;
    \\   parameter real damp = 0.0;
    \\   parameter real sinephase = 0.0;
    \\   parameter real ammodindex = 0.0;
    \\   parameter real ammodfreq = 0.0;
    \\   parameter real ammodphase = 0.0;
    \\   parameter real fmmodindex = 0.0;
    \\   parameter real fmmodfreq = 0.0;
    \\   analog
    \\      // §4.6.1: `dc` at an operating point that is not a transient's own.
    \\      if (analysis("static") && !analysis("tran"))
    \\         I(p, n) <+ dc;
    \\      else
    \\         I(p, n) <+ offset + ampl
    \\         * (1.0 - ammodindex * cos(`M_TWO_PI * ammodfreq * ($abstime - td)
    \\                                   - ammodphase))
    \\         * (1.0 - damp * ($abstime - td))
    \\         * cos(`M_TWO_PI * freq
    \\               * (1.0 - fmmodindex * cos(`M_TWO_PI * fmmodfreq
    \\                                         * ($abstime - td)))
    \\               * ($abstime - td) - sinephase);
    \\endmodule
    \\
    \\// vexp | p, n | dc, mag, phase, val0, val1, td0, tau0, td1, tau1
    \\// The iexp row with V for I, and `dc` rather than `val0` before td0.
    \\module vexp(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real dc = 0.0;
    \\   parameter real mag = 1.0;
    \\   parameter real phase = 0.0;
    \\   parameter real val0 = 0.0;
    \\   parameter real val1 = 1.0;
    \\   parameter real td0 = 0.0;
    \\   parameter real tau0 = 1.0 from (0:inf);
    \\   parameter real td1 = 1.0;
    \\   parameter real tau1 = 1.0 from (0:inf);
    \\   analog begin
    \\      // §4.6.1: `dc` at an operating point that is not a transient's own.
    \\      if (analysis("static") && !analysis("tran"))
    \\         V(p, n) <+ dc;
    \\      else if ($abstime <= td0)
    \\         V(p, n) <+ dc;
    \\      else if ($abstime <= td1)
    \\         V(p, n) <+ val1 - (val1 - dc) * exp((td0 - $abstime) / tau0);
    \\      else
    \\         V(p, n) <+ val0 - (val0 - (val1 - (val1 - dc)
    \\                                   * exp((td0 - td1) / tau0)))
    \\                          * exp((td1 - $abstime) / tau1);
    \\   end
    \\endmodule
    \\
    \\// vpulse | p, n | dc, mag, phase, val0, val1, td, rise, fall, width, period
    \\module vpulse(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real dc = 0.0;
    \\   parameter real mag = 1.0;
    \\   parameter real phase = 0.0;
    \\   parameter real val0 = 0.0;
    \\   parameter real val1 = 1.0;
    \\   parameter real td = 0.0;
    \\   parameter real rise = 1e-12 from (0:inf);
    \\   parameter real fall = 1e-12 from (0:inf);
    \\   parameter real width = 1e-9 from (0:inf);
    \\   parameter real period = 0.0 from [0:inf);
    \\   analog begin : pulse
    \\      real tp;
    \\      tp = $abstime - td;
    \\      if (period > 0.0 && tp > 0.0)
    \\         tp = tp - period * floor(tp / period);
    \\      // §4.6.1: `dc` at an operating point that is not a transient's own.
    \\      if (analysis("static") && !analysis("tran"))
    \\         V(p, n) <+ dc;
    \\      else if (tp <= 0.0)
    \\         V(p, n) <+ val0;
    \\      else if (tp <= rise)
    \\         V(p, n) <+ val0 + (val1 - val0) * tp / rise;
    \\      else if (tp <= rise + width)
    \\         V(p, n) <+ val1;
    \\      else if (tp <= rise + width + fall)
    \\         V(p, n) <+ val1 + (val0 - val1) * (tp - rise - width) / fall;
    \\      else
    \\         V(p, n) <+ val0;
    \\   end
    \\endmodule
    \\
    \\// vpwl | p, n | dc, mag, phase, wave
    \\// See ipwl for `nwave`. The published row's last line reads `I = wave[n-1]`
    \\// where every other line of it reads V; it is V.
    \\module vpwl(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real dc = 0.0;
    \\   parameter real mag = 1.0;
    \\   parameter real phase = 0.0;
    \\   parameter integer nwave = 4 from [4:inf);
    \\   parameter real wave[0:nwave-1] = '{0.0, 0.0, 1.0, 0.0};
    \\   analog begin : pwl
    \\      integer i;
    \\      real vw;
    \\      vw = wave[nwave-1];
    \\      for (i = 0; i + 3 <= nwave - 1; i = i + 2) begin
    \\         if ($abstime >= wave[i] && $abstime < wave[i+2])
    \\            vw = wave[i+1] + (wave[i+3] - wave[i+1])
    \\                             * ($abstime - wave[i]) / (wave[i+2] - wave[i]);
    \\      end
    \\      // §4.6.1: `dc` at an operating point that is not a transient's own.
    \\      if (analysis("static") && !analysis("tran"))
    \\         V(p, n) <+ dc;
    \\      else
    \\         V(p, n) <+ vw;
    \\   end
    \\endmodule
    \\
    \\// vsine | p, n | dc, mag, phase, offset, ampl, freq, td, damp, sinephase,
    \\//               ammodindex, ammodfreq, ammodphase, fmmodindex, fmmodfreq
    \\// The isine row with V for I.
    \\module vsine(p, n);
    \\   inout p, n;
    \\   electrical p, n;
    \\   parameter real dc = 0.0;
    \\   parameter real mag = 1.0;
    \\   parameter real phase = 0.0;
    \\   parameter real offset = 0.0;
    \\   parameter real ampl = 1.0;
    \\   parameter real freq = 1.0 from (0:inf);
    \\   parameter real td = 0.0;
    \\   parameter real damp = 0.0;
    \\   parameter real sinephase = 0.0;
    \\   parameter real ammodindex = 0.0;
    \\   parameter real ammodfreq = 0.0;
    \\   parameter real ammodphase = 0.0;
    \\   parameter real fmmodindex = 0.0;
    \\   parameter real fmmodfreq = 0.0;
    \\   analog
    \\      // §4.6.1: `dc` at an operating point that is not a transient's own.
    \\      if (analysis("static") && !analysis("tran"))
    \\         V(p, n) <+ dc;
    \\      else
    \\         V(p, n) <+ offset + ampl
    \\         * (1.0 - ammodindex * cos(`M_TWO_PI * ammodfreq * ($abstime - td)
    \\                                   - ammodphase))
    \\         * (1.0 - damp * ($abstime - td))
    \\         * cos(`M_TWO_PI * freq
    \\               * (1.0 - fmmodindex * cos(`M_TWO_PI * fmmodfreq
    \\                                         * ($abstime - td)))
    \\               * ($abstime - td) - sinephase);
    \\endmodule
    \\
    \\// tline | t1, b1, t2, b2 | z0, td, f, nl | (Behavior column EMPTY)
    \\//
    \\// Interface only. The table gives no equations for this row, and a
    \\// transmission line is the one passive whose behaviour is not derivable
    \\// from its parameter names: z0 with td is a delay line, z0 with f and nl is
    \\// the same line specified by electrical length at a frequency, and the
    \\// table says which of the two a given instance means nowhere. E.2 makes
    \\// that choice implementation-dependent; guessing it here would put a
    \\// specific simulator's convention in a shipped standard file.
    \\module tline(t1, b1, t2, b2);
    \\   inout t1, b1, t2, b2;
    \\   electrical t1, b1, t2, b2;
    \\   parameter real z0 = 50.0;
    \\   parameter real td = 0.0;
    \\   parameter real f = 0.0;
    \\   parameter real nl = 0.0;
    \\endmodule
    \\
    \\// vccs | sink, src, ps, ns | gm | I(sink, src) = gm*V(ps, ns)
    \\module vccs(sink, src, ps, ns);
    \\   inout sink, src, ps, ns;
    \\   electrical sink, src, ps, ns;
    \\   parameter real gm = 1.0;
    \\   analog
    \\      I(sink, src) <+ gm * V(ps, ns);
    \\endmodule
    \\
    \\// vcvs | p, n, ps, ns | gain | V(p, n) = gain*V(ps, ns)
    \\module vcvs(p, n, ps, ns);
    \\   inout p, n, ps, ns;
    \\   electrical p, n, ps, ns;
    \\   parameter real gain = 1.0;
    \\   analog
    \\      V(p, n) <+ gain * V(ps, ns);
    \\endmodule
    \\
    \\// The five semiconductor rows. Behavior column EMPTY for every one of them,
    \\// and E.2: "all aspects of SPICE primitives are implementation dependent".
    \\// A SPICE netlist gives these their equations through a .MODEL card whose
    \\// parameters Table E.1 does not list and E.1.2's fourth axis says differ
    \\// between simulators; E.3's last paragraph is how Verilog-AMS supplies them
    \\// instead — "in Verilog-AMS they may be used directly in a paramset
    \\// statement" (§6.4), which is a paramset over the interface below.
    \\
    \\// diode | a, c | area
    \\module diode(a, c);
    \\   inout a, c;
    \\   electrical a, c;
    \\   parameter real area = 1.0;
    \\endmodule
    \\
    \\// bjt | c, b, e, s | area
    \\module bjt(c, b, e, s);
    \\   inout c, b, e, s;
    \\   electrical c, b, e, s;
    \\   parameter real area = 1.0;
    \\endmodule
    \\
    \\// mosfet | d, g, s, b | w, l, ad, as, pd, ps, nrd, nrs
    \\module mosfet(d, g, s, b);
    \\   inout d, g, s, b;
    \\   electrical d, g, s, b;
    \\   parameter real w = 1.0;
    \\   parameter real l = 1.0;
    \\   parameter real ad = 0.0;
    \\   parameter real as = 0.0;
    \\   parameter real pd = 0.0;
    \\   parameter real ps = 0.0;
    \\   parameter real nrd = 0.0;
    \\   parameter real nrs = 0.0;
    \\endmodule
    \\
    \\// jfet | d, g, s | area
    \\module jfet(d, g, s);
    \\   inout d, g, s;
    \\   electrical d, g, s;
    \\   parameter real area = 1.0;
    \\endmodule
    \\
    \\// mesfet | d, g, s | area
    \\module mesfet(d, g, s);
    \\   inout d, g, s;
    \\   electrical d, g, s;
    \\   parameter real area = 1.0;
    \\endmodule
    \\
;

/// How many module declarations `spice_primitives` holds, COUNTED FROM THE TEXT
/// so the number cannot drift from the prelude it describes.
///
/// This is how a consumer tells a shipped primitive from a user's module without
/// a byte offset threaded through four stages: the prelude is prepended verbatim
/// whenever `Options.std_defs` is set, its modules therefore occupy exactly the
/// first `spice_module_count` entries of `Ast.SourceFile.modules` (the parser
/// appends in source order), and `Ast.SourceFile.builtin_modules` is set to this.
/// E.3.3's "a module defined in the Verilog-AMS will always be selected in
/// favor of a SPICE primitive using exactly the same name" is then a search
/// order, and §6.2.2's top can never be a primitive.
pub const spice_module_count = blk: {
    @setEvalBranchQuota(200_000);
    // ponytail: count the fixed, non-overlapping header spelling with stdlib;
    // use tokens if the embedded source ever needs a general declaration count.
    break :blk @as(u32, @intCast(std.mem.count(u8, spice_primitives, "\nmodule ")));
};

/// annex D.3 — driver_access.vams, verbatim. Twelve masks naming the bit each
/// §7 driver flag occupies. Self-guarded, and NOT preloaded: nothing in the
/// analog subset reads a driver, so a design has to `include it.
pub const driver_access_vams =
    \\// Copyright(c) 2009-2014 Accellera Systems Initiative Inc.
    \\// Verbatim copies of the material in annex D may be used and distributed
    \\// without restriction. VAMS-2023.
    \\`ifdef DRIVER_ACCESS_VAMS
    \\`else
    \\`define DRIVER_ACCESS_VAMS  1
    \\`define DRIVER_UNKNOWN      32'b00000000000    // No information
    \\`define DRIVER_DELAYED      32'b00000000001    // driver has fixed delay
    \\`define DRIVER_GATE         32'b00000000010    // driver is a primitive
    \\`define DRIVER_UDP          32'b00000000100    // driver is a user defined primitive
    \\`define DRIVER_ASSIGN       32'b00000001000    // driver is a continuous assignment
    \\`define DRIVER_BEHAVIORAL   32'b00000010000    // driver is a reg
    \\`define DRIVER_SDF          32'b00000100000    // driver is from backannotated code
    \\`define DRIVER_NODELETE     32'b00001000000    // events won't be deleted
    \\`define DRIVER_NOPREEMPT    32'b00010000000    // events won't be preempted
    \\`define DRIVER_KERNEL       32'b00100000000    // added by kernel (wor/wand)
    \\`define DRIVER_WOR          32'b01000000000    // driver is on a wor net
    \\`define DRIVER_WAND         32'b10000000000    // driver is on a wand net
    \\`endif
;
