//! lib/digital/'s plain loops, one `export fn` each, so a later edit that
//! makes one scalar again shows in the assembly. In: the loop's operands as
//! C-ABI pointers and a length; out: what the loop in `plan.zig` computes.
//! No LRM clause: these check VerA's own emitter.
//!
//! expect: meet_plain vector>=16 (37 on x86_64_v3, ymm vpandn/vpand/vpor;
//! the short-circuit `changed or` form it replaced: 0)

/// `plan.meet`'s word loop: `in &= set` over `n` words, returning the bits
/// it cleared (non-zero: `in` changed, so its pc is queued again).
export fn meet_plain(in: [*]u64, set: [*]const u64, n: usize) u64 {
    var lost: u64 = 0;
    for (in[0..n], set[0..n]) |*w, s| {
        lost |= w.* & ~s;
        w.* &= s;
    }
    return lost;
}
