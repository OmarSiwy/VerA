// ---- §4.5 analog operator kernels ----

fn zIdt(comptime S: type, v: S, acc: f64, dt: f64, ic: f64) S { // §4.5.4
    if (dt <= 0.0) return S.con(ic); // §4.5.4 DC value is the initial condition
    return v.scale(dt).addC(acc);
}
fn zIdtHold(comptime S: type, v: S, off: f64, ic: f64, assert_: f64) S { // §4.5.4
    // "idt() returns the initial conditions ... whenever assert is nonzero."
    if (assert_ != 0.0) return S.con(ic);
    return v.addC(-off);
}
fn zIdtAcc(v: f64, acc: f64, dt: f64, ic: f64) f64 {
    if (dt <= 0.0) return ic;
    return acc + v * dt;
}
fn zIdtmod(comptime S: type, v: S, acc: f64, dt: f64, ic: f64, m: f64, o: f64) S { // §4.5.5
    const raw = zIdt(S, v, acc, dt, ic);
    if (!(m > 0.0)) return raw;
    // The wrap subtracts a piecewise-CONSTANT multiple of the modulus, so
    // the derivative of the wrapped integral is the derivative of the raw one.
    return raw.addC(-m * @floor((raw.val() - o) / m));
}
fn zWrap(x: f64, modulus: f64, offset: f64) f64 { // §4.5.5 idtmod
    if (!(modulus > 0.0)) return x;
    return x - modulus * @floor((x - offset) / modulus);
}
fn zSlew(comptime S: type, v: S, prev: f64, dt: f64, rise: f64, fall: f64) S { // §4.5.9
    if (dt <= 0.0) return v;
    return v.minC(prev + rise * dt).maxC(prev - fall * dt);
}
/// §5.10.3.1/§4.5.10 the crossing test for a direction that is a PARAMETER
/// (a constant_expression the model card owns, so codegen cannot pick the
/// comparison at emit time): +1 rising only, -1 falling only, anything
/// else either — the EXACT decode `Gen.crossTest` applies to a folded one,
/// so overriding the parameter to the value the default had changes nothing.
fn zCrossDir(dir: f64, prev: f64, in: f64) bool {
    if (dir == 1.0) return prev <= 0.0 and in > 0.0;
    if (dir == -1.0) return prev >= 0.0 and in < 0.0;
    if (dir != 0.0) return false; // §5.10.3.1 any other dir disables cross()
    return (prev <= 0.0 and in > 0.0) or (prev >= 0.0 and in < 0.0);
}
/// §4.5.8 the fraction of the current excursion the ramp has traversed.
/// "transition() forces all positive transitions of expr to occur over
/// rise_time and all negative transitions to occur in fall_time", and the
/// result "describes a piecewise linear function over time" — so the shape
/// is (t - t0)/tt clamped into [0, 1], with tt picked by the DIRECTION of
/// the excursion and t0 the time the excursion began.
///
/// A zero transition time is §4.5.8's own degenerate case ("If neither
/// rise_time nor fall_time are specified or are equal to zero (0.0) …"),
/// left to `default_transition and, with no directive, to the simulator:
/// here that is an instantaneous edge, fraction 1.
fn zTransFrac(target: f64, from: f64, t0: f64, t: f64, rise: f64, fall: f64) f64 {
    const tt = if (target >= from) rise else fall;
    if (!(tt > 0.0)) return 1.0;
    return @min(@max((t - t0) / tt, 0.0), 1.0);
}
fn zTransition(comptime S: type, v: S, from: f64, to: f64, t0: f64, t: f64, dt: f64, rise: f64, fall: f64) S { // §4.5.8
    // "In DC analysis, transition() passes the value of the expr directly
    // to its output." There is no elapsed time to ramp over.
    if (dt <= 0.0) return v;
    // In a transient the output is a function of the input's PAST alone:
    // the excursion in flight was armed by the accepted step that SAW the
    // input change, "after an initial delay of td". Taking the CURRENT
    // input as the ramp's target — which this did — armed every ramp at the
    // previous accepted timepoint, so the output was already part-way up it
    // at the corner itself and no td could have shifted that.
    return S.con(from + (to - from) * zTransFrac(to, from, t0, t, rise, fall));
}
/// §4.5.8 accepted-step bookkeeping. "A transition is created when the
/// input expression changes, and at this point it uses the value of td,
/// rise_time, fall_time and time_tol to determine the new pending
/// transition operator." `to` is the armed destination and so also the last
/// ACCEPTED input, which makes `in != to` that sentence's test.
///
/// LEAVING THE EXCURSION ALONE is the important half: while the input has
/// not changed the excursion is the one that started at `from`, and
/// re-arming the origin every step would shrink the remaining distance by
/// the same factor each time — an exponential decay wearing a ramp's
/// coefficients, which is the bug this operator used to have.
fn zTransStep(in: f64, from: *f64, to: *f64, t0: *f64, t: f64, dt: f64, td: f64, rise: f64, fall: f64) void {
    if (dt <= 0.0) { // the DC point: the output IS the input, so sit on it
        from.* = in;
        to.* = in;
        t0.* = t;
        return;
    }
    if (in == to.*) return;
    // "td models transport delay": the ramp begins td after the change and
    // the output stays on its old trajectory until then, so it leaves from
    // where that trajectory will be at t + td, not from where it is now.
    const te = t + td;
    const f = zTransFrac(to.*, from.*, t0.*, te, rise, fall);
    const vi = from.* + (to.* - from.*) * f;
    // §4.5.8's four interruption paragraphs (Figures 4-7 … 4-12): an input
    // that changes inside the active region is "not ... a new transition,
    // but rather a readjustment", whose slope uses "either the original
    // transition's origin or destination as the new origin". One rule, four
    // figures — the reference is the DESTINATION when the new direction
    // opposes the original and the ORIGIN when it agrees:
    //   rising,  v3 < vi -> opposes -> (v3-v2)/tf3    rising,  v3 > vi -> (v3-v1)/tr3
    //   falling, v3 > vi -> opposes -> (v3-v2)/tr3    falling, v3 < vi -> (v3-v1)/tf3
    // "applied from the point of interruption (ti,vi)", spelled here as the
    // shifted origin (t4,v4) those paragraphs also name: v4 is the reference
    // level, t4 where the slope line through (te,vi) reaches it. The arrival
    // t3 = ti + (v3-vi)/slope then falls out of zTransFrac.
    //
    // NOT active is a new transition from where the output is — the branch
    // this took unconditionally, which is the reading the four paragraphs
    // exist to rule out.
    if (f < 1.0 and in != vi) {
        const tt3 = if (in > vi) rise else fall;
        const vref = if ((in > vi) != (to.* > from.*)) to.* else from.*;
        const slope = if (tt3 > 0.0) (in - vref) / tt3 else 0.0;
        if (slope != 0.0) {
            from.* = vref;
            to.* = in;
            t0.* = te + (vref - vi) / slope;
            return;
        }
    }
    from.* = vi;
    to.* = in;
    t0.* = te;
}
