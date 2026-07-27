//! Timer controls and observation times -> absolute event deadlines, VAMS
//! §5.10.3.3. Embedded into devices and imported by the mixed coordinator, so
//! both paths count from start_time rather than accumulating periods.

const ztm = @import("std");

/// Shared infinity avoids repeating comptime work at every emitted timer site.
pub const z_inf: f64 = ztm.math.inf(f64);

/// The first representable event time strictly after t. The latest controls
/// describe start + k*period; a non-positive period has only its start event.
pub fn zNextTimer(start: f64, period: f64, t: f64) ?f64 {
    if (!ztm.math.isFinite(start) or !ztm.math.isFinite(t)) return null;
    if (start > t) return start;
    if (!(period > 0.0) or !ztm.math.isFinite(period)) return null;
    var n = @floor((t - start) / period) + 1.0;
    // Repair a division rounded to either side of a firing count.
    if (n > 1.0 and start + (n - 1.0) * period > t) n -= 1.0;
    if (start + n * period <= t) n += 1.0;
    const next = start + n * period;
    if (ztm.math.isFinite(next) and next > t) return next;
    // A tiny period can disappear in the addition or overflow the count.
    // Consecutive f64 times then span an event: use the first time beyond t.
    // A finite count with an infinite event is genuine finite-time exhaustion.
    if (next <= t or !ztm.math.isFinite(n)) {
        const future = ztm.math.nextAfter(f64, t, z_inf);
        if (ztm.math.isFinite(future)) return future;
    }
    return null;
}

/// A changed control replaces the pending event before the event condition is
/// evaluated. The replacement can be now if now is on the new absolute grid,
/// but a past one-shot is spent. Otherwise preserve the scheduled event: a
/// host that steps just beyond it still observes that event (§5.10.3.3).
pub fn zTimerPending(start: f64, period: f64, t: f64, old_start: f64, old_period: f64, pending: f64) f64 {
    if (start == old_start and period == old_period) return pending;
    if (start >= t) return start;
    if (!(period > 0)) return z_inf;
    return zNextTimer(start, period, ztm.math.nextAfter(f64, t, -z_inf)) orelse z_inf;
}

/// Enable gates delivery, never the absolute schedule's progress.
pub fn zTimerDue(start: f64, period: f64, t: f64, old_start: f64, old_period: f64, pending: f64) bool {
    return t >= zTimerPending(start, period, t, old_start, old_period, pending);
}
