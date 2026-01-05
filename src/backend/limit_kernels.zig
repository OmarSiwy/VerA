// §4.5.15 SPICE voltage-limiting kernels — EMITTED VERBATIM into every device
// that honours a `$limit` call (`codegen.limit_txt` is `@embedFile` of this
// file) and `@import`ed by codegen.zig's tests, for the same reason
// `filter_kernels.zig` is: the numerics the tests check are the numerics the
// device runs. Until this file existed they were a string literal in
// `cg_limit.zig` and nothing could call them.
//
// Transcribed from ngspice `src/spicelib/devices/devsup.c` — which is what the
// `"pnjlim"`/`"fetlim"`/`"limvds"` identifiers in a `.va` name. §4.5.15 leaves
// the algorithm implementation-defined, so the LRM fixes nothing here except
// §9.17.3's "when the simulator has converged, the return value of the $limit()
// function is the value of the access function reference" — i.e. a converged
// bias must come back UNCHANGED. That transparency is the property the
// `annex_e_spice/limit_*.va` fixtures assert and the one the tests below pin.
//
// Nothing here allocates or reads the enclosing device: each is a pure f64
// function of the new iterate, the previous one, and the algorithm's own
// constants. `cg_limit.emitClamp` writes the correction back into `x`, and
// reads "the clamp fired" off the returned value differing from the one passed
// in — which is only a truthful convergence flag because `zPnjlim` returns its
// argument BIT-IDENTICALLY on every path that did not damp.

/// SPICE3 `DEVpnjlim`: damp a p-n junction's exponential. `vt` is the
/// junction's thermal voltage and `vcrit` the bias where its exponential
/// starts to outrun Newton, i.e. `vt*ln(vt/(sqrt(2)*is))`.
pub fn zPnjlim(vnew0: f64, vold: f64, vt: f64, vcrit: f64) f64 {
    var vnew = vnew0;
    if (vnew > vcrit and @abs(vnew - vold) > vt + vt) {
        if (vold > 0.0) {
            // The guard above makes |arg| > 2, so both logs take a
            // strictly positive argument.
            const arg = (vnew - vold) / vt;
            vnew = if (arg > 0.0)
                vold + vt * (2.0 + @log(arg - 2.0))
            else
                vold - vt * (2.0 + @log(2.0 - arg));
        } else {
            vnew = vt * @log(vnew / vt);
        }
    } else if (vnew < 0.0) {
        const arg = if (vold > 0.0) -vold - 1.0 else 2.0 * vold - 1.0;
        if (vnew < arg) vnew = arg;
    }
    return vnew;
}

/// SPICE3 `DEVfetlim`: keep a gate bias from stepping across threshold in
/// one Newton iteration. `vto` is the threshold voltage.
pub fn zFetlim(vnew0: f64, vold: f64, vto: f64) f64 {
    var vnew = vnew0;
    const vtsthi = @abs(2.0 * (vold - vto)) + 2.0;
    const vtstlo = vtsthi * 0.5 + 2.0;
    const vtox = vto + 3.5;
    const delv = vnew - vold;
    if (vold >= vto) {
        if (vold >= vtox) {
            if (delv <= 0.0) { // going off
                if (vnew >= vtox) {
                    if (-delv > vtstlo) vnew = vold - vtstlo;
                } else vnew = @max(vnew, vto + 2.0);
            } else { // staying on
                if (delv >= vtsthi) vnew = vold + vtsthi;
            }
        } else { // middle region
            vnew = if (delv <= 0.0) @max(vnew, vto - 0.5) else @min(vnew, vto + 4.0);
        }
    } else { // off
        if (delv <= 0.0) {
            if (-delv > vtsthi) vnew = vold - vtsthi;
        } else {
            const vtemp = vto + 0.5;
            if (vnew <= vtemp) {
                if (delv > vtstlo) vnew = vold + vtstlo;
            } else vnew = vtemp;
        }
    }
    return vnew;
}

/// SPICE3 `DEVlimvds`: bound a drain-source step. Takes no model data —
/// the numbers are the algorithm.
pub fn zLimvds(vnew0: f64, vold: f64) f64 {
    var vnew = vnew0;
    if (vold >= 3.5) {
        if (vnew > vold) {
            vnew = @min(vnew, 3.0 * vold + 2.0);
        } else if (vnew < 3.5) vnew = @max(vnew, 2.0);
    } else {
        vnew = if (vnew > vold) @min(vnew, 4.0) else @max(vnew, -0.5);
    }
    return vnew;
}

