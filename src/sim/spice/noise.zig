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
//! (`noise_tables`, or the card's knots through `contract.noiseTable`),
//! `PsdTerm.coeff`, and §4.6.4.6 correlation: rows sharing a `source` are one
//! generator whose transfers add as phasors, and a `PsdTerm.corr_with` link
//! between two generators a and b adds 2·rho·sqrt(S_a·S_b)·Re(H_a·conj(H_b)),
//! once per pair. A to-ground generator is `row == col` in `noise_gens`. Not
//! taken: the band integrals (`nintegrate`), input-referred noise, per-source
//! columns, sampled and phase noise.
//!
//! In: a converged operating point and a frequency list; out: one output
//! density per frequency. LRM: §4.6.4 (generators), §4.6.4.3/.4 (tables),
//! §4.6.4.6 (correlation), §4.6.1 (the analysis kind).
//!
//! ponytail: every generator is injected as a current, which is every
//! `I(...) <+` source; `noise_gens` does not say a row is a potential
//! contribution, so a `V(...) <+` generator would be mis-injected.
const std = @import("std");
const contract = @import("contract");
const dense_lu = @import("dense_lu.zig");

/// Returns the PSD of one parametric term at `f`: white plus flicker / f^ef.
/// At f <= 0 the flicker half has no value and only the white half counts.
pub inline fn sourcePsd(t: contract.PsdTerm, f: f64) f64 {
    if (t.flicker == 0 or f <= 0) return t.white;
    return t.white + t.flicker / std.math.pow(f64, f, t.ef);
}

/// §4.6.4.3/.4 a table generator's PSD at `f`, from the card's knots
/// (`contract.noiseTable`); 0 for a parametric row.
fn tableAt(comptime D: type, model: *const D.Model, table: ?u16, f: f64) f64 {
    if (!@hasDecl(D, "noise_tables")) return 0;
    const ti = table orelse return 0;
    return contract.noiseTableAt(contract.noiseTable(D, model, ti), f);
}

/// Fills `density[k]` with the output noise density at `freqs[k]`, V^2/Hz,
/// measured at unknown `out`, linearized at `x_op` (the converged operating
/// point; `ckt.sim` still describes it). Errors: `error.BadCorrelation`, a
/// `corr_with` that names no other generator, or a |rho| over 1 (checked
/// before any frequency); `error.Singular`, a frequency whose admittance
/// does not factor, with `density` partial. Asserts that
/// `density.len == freqs.len`, `out` < n_u and `x_op` holds n_u values.
pub fn sweep(ckt: anytype, x_op: []const f64, out: usize, freqs: []const f64, density: []f64) !void {
    const C = @TypeOf(ckt.*);
    const D = C.Device;
    const n = C.unknowns;
    const nn = 2 * n;
    std.debug.assert(density.len == freqs.len);
    if (!@hasDecl(D, "noise_gens")) {
        @memset(density, 0);
        return;
    }
    const ng = D.noise_gens.len;
    // Each row's generator, named by its first row: rows sharing a `source`
    // are one generator (§4.6.4.6).
    const lead = comptime blk: {
        var l: [ng]usize = undefined;
        for (D.noise_gens, 0..) |g, k| {
            l[k] = k;
            if (g.source) |s| for (D.noise_gens[0..k], 0..) |g0, i| {
                if (g0.source == s) {
                    l[k] = i;
                    break;
                }
            };
        }
        break :blk l;
    };

    // §4.6.1 Table 4-22: the sweep is the noise analysis proper, where only
    // analysis("noise") holds, and under `.noise` `eval` leaves every
    // `ac_dyn_slots` partial to `acDyn` (`contract.acDynSlots`); in the
    // operating point's kind the slot would be counted twice.
    const op_sim = ckt.sim;
    defer ckt.setSimState(op_sim);
    ckt.setSimState(.{ .t = op_sim.t, .kind = .noise, .analog_initial = false });
    ckt.eval(x_op, 0);
    const c_mat: [n * n]f64 = if (C.has_charge) ckt.c_vals else @splat(0);
    const psd = D.noisePsd(C.Val, x_op[0..n].*, ckt.model, ckt.inst, ckt.sim);
    for (psd, 0..) |t, k| if (t.corr_with) |j| {
        if (j >= ng or lead[j] == lead[k] or !(@abs(t.corr) <= 1)) return error.BadCorrelation;
    };

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
        // Adjoint: A^H y = e_out, so y is the conjugate of each transfer.
        // The conjugate drops out of |H|^2 and of Re(H_a·conj(H_b)), both
        // conjugated alike, so the stacked-real transpose solve is enough.
        try dense_lu.factorize(nn, &a, &piv);
        dense_lu.solveFactoredT(nn, &a, &piv, &e, &y);

        // Each generator's transfer, at its first row: its rows' coeff·(y[row]
        // - y[col]) summed.
        var h_re: [ng]f64 = @splat(0);
        var h_im: [ng]f64 = @splat(0);
        for (D.noise_gens, psd, lead) |g, t, l| {
            const row: usize = g.row;
            const col: usize = g.col;
            const yn_re: f64 = if (row == col) 0 else y[col];
            const yn_im: f64 = if (row == col) 0 else y[n + col];
            h_re[l] += t.coeff * (y[row] - yn_re);
            h_im[l] += t.coeff * (y[n + row] - yn_im);
        }
        var s: [ng]f64 = undefined;
        var total: f64 = 0;
        for (D.noise_gens, psd, lead, 0..) |g, t, l, k| if (l == k) {
            s[k] = sourcePsd(t, f) + tableAt(D, ckt.model, g.table, f);
            total += (h_re[k] * h_re[k] + h_im[k] * h_im[k]) * s[k];
        };
        for (psd, 0..) |t, k| if (t.corr_with) |j| if (firstLink(&psd, &lead, k)) {
            const ga = lead[k];
            const gb = lead[j];
            total += 2.0 * t.corr * @sqrt(s[ga] * s[gb]) * (h_re[ga] * h_re[gb] + h_im[ga] * h_im[gb]);
        };
        dens.* = total;
    }
}

/// Whether row `k`'s `corr_with` is the first row, in either direction, to
/// link its pair of generators: a pair is one cross term however many of
/// their rows state it, and the first statement's rho is the one used.
fn firstLink(psd: []const contract.PsdTerm, lead: []const usize, k: usize) bool {
    const a = lead[k];
    const b = lead[psd[k].corr_with.?];
    for (psd[0..k], lead[0..k]) |t, l| if (t.corr_with) |j| {
        const lj = lead[j];
        if ((l == a and lj == b) or (l == b and lj == a)) return false;
    };
    return true;
}

// ---------------------------------------------------------------------------
// Tests. Oracles: transfer impedances solved by hand on two small networks
// (Z = Y^-1 of a 2x2 conductance matrix; 1/(G + jwC) for an RC), and the
// §4.6.4.3/.4 and §4.6.4.6 combination rules applied to them.
// ---------------------------------------------------------------------------

const Circuit = @import("circuit.zig").Circuit;

/// Runs `sweep` on `D` at the origin, measured at unknown 0.
fn densityAt(comptime D: type, model: D.Model, comptime freqs: []const f64) ![freqs.len]f64 {
    var m = model;
    var inst: D.Instance = .{};
    var ckt: Circuit(D) = .init(&m, &inst);
    const x: [contract.nU(D)]f64 = @splat(0);
    var dens: [freqs.len]f64 = undefined;
    try sweep(&ckt, &x, 0, freqs, &dens);
    return dens;
}

/// MockNoise's network: Y = [[2e-3, -1e-3], [-1e-3, 3e-3]], so the
/// transfers to node a are Z_aa = 600 and Z_ab = 200 ohm.
fn twoNode(comptime D: type, comptime S: type, x: *const [2]S.V) contract.Rows(D, S) {
    const p = contract.probes(D, S, x);
    const ab = p[0].sub(p[1]).scale(1e-3);
    return contract.rows(D, S, .{ p[0].scale(1e-3).add(ab), p[1].scale(2e-3).sub(ab) });
}

/// Two nodes, a and b: 1 mS from a to ground, 2 mS from b to ground, 1 mS
/// between them, and a to-ground noise current at each, 4e-24 A^2/Hz at a
/// and 1e-24 at b, b's linked to a's with `corr` = `rho`. No VerA source
/// publishes `corr_with` (§4.6.4.6 builds partial correlation from shared
/// generators), so the link is a hand-written device's, as a native host
/// model (BSIM4 tnoiMod, PSP) publishes it.
const MockNoise = struct {
    pub const U = enum(u8) { a, b };
    pub const num_ports: usize = 2;
    pub const contract_abi = contract.abi_version;
    pub const Model = struct { rho: f64 = 0 };
    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: *const [2]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        const ab = p[0].sub(p[1]).scale(1e-3);
        return contract.rows(@This(), S, .{ p[0].scale(1e-3).add(ab), p[1].scale(2e-3).sub(ab) });
    }

    pub const noise_gens = [_]contract.NoiseGen(@This()){
        .{ .row = 0, .col = 0, .kind = .thermal },
        .{ .row = 1, .col = 1, .kind = .thermal },
    };

    pub fn noisePsd(comptime _: type, _: [2]f64, m: *const Model, _: *const Instance, _: contract.SimState) [2]contract.PsdTerm {
        return .{ .{ .white = 4e-24 }, .{ .white = 1e-24, .corr_with = 0, .corr = m.rho } };
    }
};

test "§4.6.4.6 a corr_with link adds 2·rho·sqrt(S_a·S_b)·Re(H_a·conj(H_b)), and a bad one is refused" {
    // By hand: Y = [[2e-3, -1e-3], [-1e-3, 3e-3]], det 5e-6, so the
    // transfers to a are Z_aa = 3e-3/5e-6 = 600 and Z_ab = 1e-3/5e-6 = 200
    // ohm, real (no charge) and of one sign. Output density at a:
    //   600^2·4e-24 + 200^2·1e-24 + 2·rho·sqrt(4e-24·1e-24)·600·200
    //   = 1.48e-18 + rho·4.8e-19:  rho 0.5 -> 1.72e-18, 0 -> 1.48e-18,
    //   -0.5 -> 1.24e-18.
    const freqs = [_]f64{1e3};
    const x = [2]f64{ 0, 0 };
    for ([_]f64{ 0.5, 0, -0.5 }, [_]f64{ 1.72e-18, 1.48e-18, 1.24e-18 }) |rho, want| {
        var model: MockNoise.Model = .{ .rho = rho };
        var inst: MockNoise.Instance = .{};
        var ckt: Circuit(MockNoise) = .init(&model, &inst);
        var dens: [1]f64 = undefined;
        try sweep(&ckt, &x, 0, &freqs, &dens);
        try std.testing.expectApproxEqRel(want, dens[0], 1e-12);
    }
    var model: MockNoise.Model = .{ .rho = 1.5 };
    var inst: MockNoise.Instance = .{};
    var ckt: Circuit(MockNoise) = .init(&model, &inst);
    var dens: [1]f64 = undefined;
    try std.testing.expectError(error.BadCorrelation, sweep(&ckt, &x, 0, &freqs, &dens));
}

test sourcePsd {
    try std.testing.expectEqual(1e-24, sourcePsd(.{ .white = 1e-24 }, 1e3));
    // white + flicker / f^ef: 1 + 100/100 = 2, and 1 + 100/100^2 = 1.01.
    try std.testing.expectEqual(2, sourcePsd(.{ .white = 1, .flicker = 100, .ef = 1 }, 100));
    try std.testing.expectApproxEqRel(@as(f64, 1.01), sourcePsd(.{ .white = 1, .flicker = 100, .ef = 2 }, 100), 1e-15);
    // At f <= 0 only the white half has a value.
    try std.testing.expectEqual(1, sourcePsd(.{ .white = 1, .flicker = 100, .ef = 1 }, 0));
    try std.testing.expectEqual(1, sourcePsd(.{ .white = 1, .flicker = 100, .ef = 1 }, -5));
}

/// A 1 mS conductance on one node and no `noise_gens`.
const MockQuiet = struct {
    pub const U = enum(u8) { a };
    pub const num_ports: usize = 1;
    pub const contract_abi = contract.abi_version;
    pub const Model = struct {};
    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: *const [1]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        return contract.rows(@This(), S, .{p[0].scale(1e-3)});
    }
};

test "a device without generators has zero output noise" {
    try std.testing.expectEqual([2]f64{ 0, 0 }, try densityAt(MockQuiet, .{}, &.{ 1, 1e6 }));
}

/// MockNoise's network with one generator contributed at both nodes (one
/// `source`), the second use scaled by `coeff_b`.
const MockShared = struct {
    pub const U = enum(u8) { a, b };
    pub const num_ports: usize = 2;
    pub const contract_abi = contract.abi_version;
    pub const Model = struct { coeff_b: f64 = 1 };
    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: *const [2]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        return twoNode(@This(), S, x);
    }

    pub const noise_gens = [_]contract.NoiseGen(@This()){
        .{ .row = 0, .col = 0, .kind = .thermal, .source = 0 },
        .{ .row = 1, .col = 1, .kind = .thermal, .source = 0 },
    };

    pub fn noisePsd(comptime _: type, _: [2]f64, m: *const Model, _: *const Instance, _: contract.SimState) [2]contract.PsdTerm {
        return .{ .{ .white = 1e-24 }, .{ .white = 1e-24, .coeff = m.coeff_b } };
    }
};

test "§4.6.4.6 rows sharing a source add as phasors, signed by coeff" {
    // One generator S = 1e-24 at a and, times coeff_b, at b: the transfer
    // is 600 + coeff_b·200, so 800^2·S, 400^2·S and 700^2·S, where two
    // independent generators would give (600^2 + 200^2)·S = 4e-19.
    for ([_]f64{ 1, -1, 0.5 }, [_]f64{ 6.4e-19, 1.6e-19, 4.9e-19 }) |coeff, want| {
        const d = try densityAt(MockShared, .{ .coeff_b = coeff }, &.{1e3});
        try std.testing.expectApproxEqRel(want, d[0], 1e-12);
    }
}

/// MockShared plus an independent generator, with row 1 linked to the
/// generator row `link` names.
const MockBadLink = struct {
    pub const U = enum(u8) { a, b };
    pub const num_ports: usize = 2;
    pub const contract_abi = contract.abi_version;
    pub const Model = struct { link: u8 = 2 };
    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: *const [2]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        return twoNode(@This(), S, x);
    }

    pub const noise_gens = [_]contract.NoiseGen(@This()){
        .{ .row = 0, .col = 0, .kind = .thermal, .source = 0 },
        .{ .row = 1, .col = 1, .kind = .thermal, .source = 0 },
        .{ .row = 1, .col = 0, .kind = .thermal },
    };

    pub fn noisePsd(comptime _: type, _: [2]f64, m: *const Model, _: *const Instance, _: contract.SimState) [3]contract.PsdTerm {
        return .{ .{ .white = 1e-24 }, .{ .white = 1e-24, .corr_with = m.link, .corr = 0.5 }, .{ .white = 1e-24 } };
    }
};

test "a corr_with inside its own generator, or past the last row, is refused" {
    // Row 1 is generator 0's second use: linking it to row 0 links the
    // generator to itself.
    try std.testing.expectError(error.BadCorrelation, densityAt(MockBadLink, .{ .link = 0 }, &.{1e3}));
    try std.testing.expectError(error.BadCorrelation, densityAt(MockBadLink, .{ .link = 3 }, &.{1e3}));
    _ = try densityAt(MockBadLink, .{ .link = 2 }, &.{1e3});
}

/// MockNoise with the link stated from both ends, with different rho.
const MockTwiceLinked = struct {
    pub const U = enum(u8) { a, b };
    pub const num_ports: usize = 2;
    pub const contract_abi = contract.abi_version;
    pub const Model = struct {};
    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: *const [2]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        return twoNode(@This(), S, x);
    }

    pub const noise_gens = [_]contract.NoiseGen(@This()){
        .{ .row = 0, .col = 0, .kind = .thermal },
        .{ .row = 1, .col = 1, .kind = .thermal },
    };

    pub fn noisePsd(comptime _: type, _: [2]f64, _: *const Model, _: *const Instance, _: contract.SimState) [2]contract.PsdTerm {
        return .{ .{ .white = 4e-24, .corr_with = 1, .corr = 0.5 }, .{ .white = 1e-24, .corr_with = 0, .corr = -0.5 } };
    }
};

test "a pair linked from both ends is one cross term, at the first statement's rho" {
    // As MockNoise at rho = 0.5: 1.48e-18 + 0.5·4.8e-19. Counting both
    // statements would give 1.48e-18.
    const d = try densityAt(MockTwiceLinked, .{}, &.{1e3});
    try std.testing.expectApproxEqRel(@as(f64, 1.72e-18), d[0], 1e-12);
}

/// 1 mS in parallel with 1 nF on one node, and a to-ground noise current.
const MockRcNoise = struct {
    pub const U = enum(u8) { a };
    pub const num_ports: usize = 1;
    pub const contract_abi = contract.abi_version;
    pub const Model = struct {};
    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: *const [1]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        return contract.rows(@This(), S, .{p[0].scale(1e-3)});
    }

    pub fn q(comptime S: type, x: *const [1]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Sites(@This(), S) {
        const p = contract.probes(@This(), S, x);
        return contract.sites(@This(), S, .{p[0].scale(1e-9)});
    }

    pub const noise_gens = [_]contract.NoiseGen(@This()){.{ .row = 0, .col = 0, .kind = .thermal }};

    pub fn noisePsd(comptime _: type, _: [1]f64, _: *const Model, _: *const Instance, _: contract.SimState) [1]contract.PsdTerm {
        return .{.{ .white = 1e-24 }};
    }
};

test "the charge plane enters as jwC: an RC's density halves at its corner" {
    // |Z|^2 = 1/(G^2 + (wC)^2): 1e6 at DC, 5e5 at w = G/C = 1e6 rad/s.
    const d = try densityAt(MockRcNoise, .{}, &.{ 0, 1e6 / (2.0 * std.math.pi) });
    try std.testing.expectApproxEqRel(@as(f64, 1e-18), d[0], 1e-12);
    try std.testing.expectApproxEqRel(@as(f64, 5e-19), d[1], 1e-12);
}

/// A 1 mS node whose noise current is a §4.6.4.3 linear table over
/// (10 Hz, 1e-24), (20 Hz, 3e-24).
const MockTable = struct {
    pub const U = enum(u8) { a };
    pub const num_ports: usize = 1;
    pub const contract_abi = contract.abi_version;
    pub const Model = struct {};
    pub const Instance = struct {};

    pub fn eval(comptime S: type, x: *const [1]S.V, _: *const Model, _: *const Instance, _: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        return contract.rows(@This(), S, .{p[0].scale(1e-3)});
    }

    pub const noise_tables = [_]contract.NoiseTable{
        .{ .interp = .linear, .points = &.{ .{ 10, 1e-24 }, .{ 20, 3e-24 } } },
    };
    pub const noise_gens = [_]contract.NoiseGen(@This()){.{ .row = 0, .col = 0, .kind = .table, .table = 0 }};

    pub fn noisePsd(comptime _: type, _: [1]f64, _: *const Model, _: *const Instance, _: contract.SimState) [1]contract.PsdTerm {
        return .{.{ .white = 0 }};
    }
};

test "§4.6.4.3 a table generator's PSD is its table, clamped at both ends" {
    // |Z|^2 = 1e6: 1e-24 below the table, 2e-24 halfway, 3e-24 above.
    const d = try densityAt(MockTable, .{}, &.{ 5, 15, 40 });
    for ([_]f64{ 1e-18, 2e-18, 3e-18 }, d) |want, got| try std.testing.expectApproxEqRel(want, got, 1e-12);
}

/// A 1 mS node whose conductance is frequency dependent (an `absdelay` of
/// zero, say): under `.ac`/`.noise`, `eval` omits the partial
/// (`ac_dyn_slots`) and `acDyn` supplies it, as `contract.acDynSlots`
/// requires.
const MockAcDyn = struct {
    pub const U = enum(u8) { a };
    pub const num_ports: usize = 1;
    pub const contract_abi = contract.abi_version;
    pub const Model = struct { g: f64 = 1e-3 };
    pub const Instance = struct {};
    pub const ac_dyn_slots = [_]u32{0};

    pub fn eval(comptime S: type, x: *const [1]S.V, m: *const Model, _: *const Instance, sim: contract.SimState) contract.Rows(@This(), S) {
        const p = contract.probes(@This(), S, x);
        const small_signal = sim.kind == .ac or sim.kind == .noise;
        const i = if (small_signal) p[0].scale(0).addC(m.g * x[0]) else p[0].scale(m.g);
        return contract.rows(@This(), S, .{i});
    }

    pub fn acDyn(comptime F: type, m: *const Model, _: *const Instance, _: *const [1]f64, _: contract.SimState, _: F, out: *[ac_dyn_slots.len]std.math.Complex(F)) void {
        out[0] = .{ .re = m.g, .im = 0 };
    }

    pub const noise_gens = [_]contract.NoiseGen(@This()){.{ .row = 0, .col = 0, .kind = .thermal }};

    pub fn noisePsd(comptime _: type, _: [1]f64, _: *const Model, _: *const Instance, _: contract.SimState) [1]contract.PsdTerm {
        return .{.{ .white = 4e-24 }};
    }
};

test "§4.6.1 the sweep linearizes as a .noise analysis, so ac_dyn_slots count once" {
    // A(w) = G + acDyn = 0 + 1e-3: 4e-24 / 1e-6 = 4e-18. Evaluated in the
    // operating point's kind, G would carry the partial too and the slot
    // would count twice: 4e-24 / 4e-6 = 1e-18.
    var model: MockAcDyn.Model = .{};
    var inst: MockAcDyn.Instance = .{};
    var ckt: Circuit(MockAcDyn) = .init(&model, &inst);
    ckt.setSimState(.{ .kind = .static, .analog_initial = false });
    var dens: [1]f64 = undefined;
    try sweep(&ckt, &.{0}, 0, &.{1e3}, &dens);
    try std.testing.expectApproxEqRel(@as(f64, 4e-18), dens[0], 1e-12);
    // The operating point's analysis is left as it was.
    try std.testing.expectEqual(contract.AnalysisKind.static, ckt.sim.kind);
}
