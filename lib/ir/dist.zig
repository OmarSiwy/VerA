//! §9.13 Table 9-10's probabilistic distributions: one row per source
//! spelling. Read by lowering (`Lower.lowerRandom`) and by elaboration
//! (`rewriteParamsetDist`), which judge the same argument rules.

const std = @import("std");

/// One row of Table 9-10's probabilistic family: the source spelling, the
/// synthetic kernel `rng_kernels.zig` implements, and the argument rules
/// §9.13.1/§9.13.2 state for it.
pub const Dist = struct {
    /// Source spelling, `$` included.
    name: []const u8,
    /// `rng_kernels.zig` entry point.
    kernel: []const u8,
    /// Arguments AFTER the seed. §9.13.1's two take none and their seed is
    /// itself optional; every §9.13.2 distribution requires its seed.
    nparam: u8,
    /// §9.13.2: "$dist_ ... return integer values", "$rdist_ ... All functions
    /// return a real value."
    ty: enum { real, integer },
    /// Bit i set = parameter i "shall be greater than zero (0). Otherwise an
    /// error shall be reported." (§9.13.2 for the $rdist_ family; IEEE 1364
    /// §17.9.2 states the same domain for the integer twins.)
    positive: u8 = 0,
    /// First parameter is df/stages, whose reference algorithm uses a count.
    count: bool = false,
    /// §9.13.2 "The start value shall be smaller than the end value." Only the
    /// uniform pair, and it is a relation between two arguments rather than a
    /// domain on one, which is why it is a separate flag.
    ordered: bool = false,
};

/// Table 9-10, all 17 names. `$simprobe` is §9.16 and stays out.
const dists = [_]Dist{
    // §9.13.1. `kernel` is the same for both: "$arandom is upwardly compatible
    // with $random ... and has the same behavior."
    .{ .name = "$random", .kernel = "$rng$rand", .nparam = 0, .ty = .integer },
    .{ .name = "$arandom", .kernel = "$rng$rand", .nparam = 0, .ty = .integer },
    // §9.13.2, the integer family (IEEE 1364 §17.9.2).
    .{ .name = "$dist_uniform", .kernel = "$rng$i_uniform", .nparam = 2, .ty = .integer, .ordered = true },
    .{ .name = "$dist_normal", .kernel = "$rng$normal", .nparam = 2, .ty = .integer },
    .{ .name = "$dist_exponential", .kernel = "$rng$exponential", .nparam = 1, .ty = .integer, .positive = 0b01 },
    .{ .name = "$dist_poisson", .kernel = "$rng$poisson", .nparam = 1, .ty = .integer, .positive = 0b01 },
    .{ .name = "$dist_chi_square", .kernel = "$rng$chi_square", .nparam = 1, .ty = .integer, .positive = 0b01, .count = true },
    .{ .name = "$dist_t", .kernel = "$rng$t", .nparam = 1, .ty = .integer, .positive = 0b01, .count = true },
    .{ .name = "$dist_erlang", .kernel = "$rng$erlang", .nparam = 2, .ty = .integer, .positive = 0b11, .count = true },
    // §9.13.2, the real family.
    .{ .name = "$rdist_uniform", .kernel = "$rng$uniform", .nparam = 2, .ty = .real, .ordered = true },
    .{ .name = "$rdist_normal", .kernel = "$rng$normal", .nparam = 2, .ty = .real },
    .{ .name = "$rdist_exponential", .kernel = "$rng$exponential", .nparam = 1, .ty = .real, .positive = 0b01 },
    .{ .name = "$rdist_poisson", .kernel = "$rng$poisson", .nparam = 1, .ty = .real, .positive = 0b01 },
    .{ .name = "$rdist_chi_square", .kernel = "$rng$chi_square", .nparam = 1, .ty = .real, .positive = 0b01, .count = true },
    .{ .name = "$rdist_t", .kernel = "$rng$t", .nparam = 1, .ty = .real, .positive = 0b01, .count = true },
    .{ .name = "$rdist_erlang", .kernel = "$rng$erlang", .nparam = 2, .ty = .real, .positive = 0b11, .count = true },
};

/// The Table 9-10 row `name` spells, or null.
pub fn of(name: []const u8) ?*const Dist {
    for (&dists) |*d| if (std.mem.eql(u8, name, d.name)) return d;
    return null;
}

/// The name §9.13.2 gives parameter `i` of `d`, for the diagnostics.
pub fn paramName(d: *const Dist, i: usize) []const u8 {
    if (d.ordered) return if (i == 0) "start" else "end";
    if (std.mem.endsWith(u8, d.name, "chi_square") or std.mem.endsWith(u8, d.name, "_t"))
        return "degree_of_freedom";
    if (std.mem.endsWith(u8, d.name, "erlang")) return if (i == 0) "k_stage" else "mean";
    if (std.mem.endsWith(u8, d.name, "normal")) return if (i == 0) "mean" else "standard_deviation";
    return "mean";
}
