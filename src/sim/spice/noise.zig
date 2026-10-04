//! Small-signal noise of the device generators, measured at an output node:
//! per frequency one adjoint solve of the stacked-real G + jwC system, then
//! each generator's PSD through its transfer to the output. Densities are
//! V^2/Hz; SPICE's `onoise_spectrum` is their square root.
//!
//! Copied from OmarSiwy/ESPice src/analysis/ac/noise.zig at
//! 12b5472f88b0ca9c7c8909297dc4fae6f176ea0d: `sweep`'s per-point density
//! (the adjoint row y, h = y[p] - y[n], dens = |h|^2 * psd) and `sourcePsd`.
//! Adapted: the frequency stream is a loop over `dense_lu`'s
//! `buildComplexAdmittance` + `factorize` + `solveFactoredT`, with the
//! device's `acDyn` terms added; the sources are read off VerA's contract
//! directly rather than through ESPice's `collectNoise`, which keeps three
//! things ESPice does not yet: a §4.6.4.3/.4 table generator's PSD
//! (`noise_tables`, or the card's `noiseTablePoints`), `PsdTerm.coeff`, and
//! §4.6.4.6 correlation (rows sharing a `source` add as phasors). A to-ground
//! generator is `row == col` in `noise_gens`. Not taken: the band integrals
//! (`nintegrate`), input-referred noise, per-source columns, sampled and
//! phase noise.
//!
//! ponytail: every generator is injected as a current, which is every
//! `I(...) <+` source; `noise_gens` does not say a row is a potential
//! contribution, so a `V(...) <+` generator would be mis-injected. A
//! `corr_with` term (BSIM4/PSP) is `error.CorrelatedTermUnsupported`.
const std = @import("std");
const contract = @import("contract");
const dense_lu = @import("dense_lu.zig");

/// The PSD of one parametric term at `f`: white plus flicker / f^ef. At
/// f <= 0 the flicker half has no value and only the white half counts.
pub inline fn sourcePsd(t: contract.PsdTerm, f: f64) f64 {
    if (t.flicker == 0 or f <= 0) return t.white;
    return t.white + t.flicker / std.math.pow(f64, f, t.ef);
}

/// §4.6.4.3/.4 a table generator's PSD at `f`, from the card's knots when
/// the device has `noiseTablePoints`; 0 for a parametric row.
fn tableAt(comptime D: type, model: *const D.Model, table: ?u16, f: f64) f64 {
    if (!@hasDecl(D, "noise_tables")) return 0;
    const ti = table orelse return 0;
    var tbl = D.noise_tables[ti];
    if (@hasDecl(D, "noiseTablePoints")) {
        const card = D.noiseTablePoints(model);
        var off: usize = 0;
        for (D.noise_tables[0..ti]) |t0| off += t0.points.len;
        var pts: [card.len][2]f64 = undefined;
        const mine = pts[0..tbl.points.len];
        @memcpy(mine, card[off..][0..tbl.points.len]);
        contract.sortNoiseTable(mine);
        tbl.points = mine;
    }
    return contract.noiseTableAt(tbl, f);
}

/// Fills `density[k]` with the output noise density at `freqs[k]`, V^2/Hz,
/// measured at unknown `out`, linearized at `x_op` (the converged operating
/// point; `ckt.sim` still describes it).
pub fn sweep(ckt: anytype, x_op: []const f64, out: usize, freqs: []const f64, density: []f64) !void {
    const C = @TypeOf(ckt.*);
    const D = C.Device;
    const n = C.unknowns;
    const nn = 2 * n;
    std.debug.assert(density.len == freqs.len);

    ckt.eval(x_op, 0);
    const c_mat: [n * n]f64 = if (C.has_charge) ckt.c_vals else @splat(0);
    const psd: [if (@hasDecl(D, "noise_gens")) D.noise_gens.len else 0]contract.PsdTerm =
        if (@hasDecl(D, "noise_gens")) D.noisePsd(C.Val, x_op[0..n].*, ckt.model, ckt.inst, ckt.sim) else .{};
    for (psd) |t| if (t.corr_with != null) return error.CorrelatedTermUnsupported;

    var a: [nn * nn]f64 = undefined;
    var piv: [nn]u32 = undefined;
    var e: [nn]f64 = @splat(0);
    e[out] = 1.0;
    var y: [nn]f64 = undefined;
    for (freqs, density) |f, *dens| {
        const omega = 2.0 * std.math.pi * f;
        dense_lu.buildComplexAdmittance(n, nn, &ckt.g_vals, &c_mat, omega, &a);
        if (@hasDecl(D, "acDyn")) {
            var dyn: [D.ac_dyn_slots.len]std.math.Complex(f64) = undefined;
            D.acDyn(f64, ckt.model, ckt.inst, x_op[0..n], ckt.sim, omega, &dyn);
            for (D.ac_dyn_slots, dyn) |s, v| {
                const r = s / n;
                const col = s % n;
                a[r * nn + col] += v.re;
                a[r * nn + n + col] -= v.im;
                a[(n + r) * nn + col] += v.im;
                a[(n + r) * nn + n + col] += v.re;
            }
        }
        // Adjoint: A^H y = e_out. The conjugate drops out of |H|^2 (and out
        // of a correlated sum, every term of which it conjugates alike), so
        // the stacked-real transpose solve is enough.
        try dense_lu.factorize(nn, &a, &piv);
        dense_lu.solveFactoredT(nn, &a, &piv, &e, &y);

        var total: f64 = 0;
        if (@hasDecl(D, "noise_gens")) for (D.noise_gens, psd, 0..) |gen, term, k| {
            // A shared generator is summed once, at its first row.
            if (gen.source) |s| if (for (D.noise_gens[0..k]) |g0| {
                if (g0.source == s) break true;
            } else false) continue;
            var h_re: f64 = 0;
            var h_im: f64 = 0;
            for (D.noise_gens, psd, 0..) |g, t, j| {
                if (j != k and (gen.source == null or g.source != gen.source)) continue;
                const row: usize = g.row;
                const col: usize = g.col;
                const yp_re = y[row];
                const yp_im = y[n + row];
                const yn_re: f64 = if (row == col) 0 else y[col];
                const yn_im: f64 = if (row == col) 0 else y[n + col];
                h_re += t.coeff * (yp_re - yn_re);
                h_im += t.coeff * (yp_im - yn_im);
            }
            total += (h_re * h_re + h_im * h_im) * (sourcePsd(term, f) + tableAt(D, ckt.model, gen.table, f));
        };
        dens.* = total;
    }
}
