/* The independent oracle for IEEE 1364-2005 §17.9.3,
 * pp. 313-320, restored from `git show 4250899d^:tests/rng_reference.c`.
 * The listed arithmetic and draw order are kept. The listing's `long` is a
 * 32-bit word: the seed wraps as uint32_t, and rtl_dist_uniform's bounds are
 * int32_t. Its one undefined step, `(long) r` when the top sliver of the full
 * range makes r exactly 2^31, is a wide cast then a 32-bit store, which is
 * what a 32-bit long did. AMS §9.13.3's real scale arguments are double;
 * count arguments stay integral. Compile with -ffp-contract=off. This is an
 * algorithm oracle, not a statistical one.
 */
#include <math.h>
#include <stdint.h>

static double uniform(uint32_t *seed, double start, double end) {
    union { float s; uint32_t stemp; } u;
    double d = 0.00000011920928955078125, a, b, c;
    if (*seed == 0) *seed = 259341593;
    if (start >= end) { a = 0.0; b = 2147483647.0; }
    else { a = start; b = end; }
    *seed = 69069u * *seed + 1u;
    u.stemp = (*seed >> 9) | 0x3f800000u;
    c = (double)u.s;
    c = c + c * d;
    c = ((b - a) * (c - 1.0)) + a;
    return c;
}
static double normal(uint32_t *seed, double mean, double deviation) {
    double v1 = 0, v2, s = 1.0;
    while (s >= 1.0 || s == 0.0) {
        v1 = uniform(seed, -1, 1);
        v2 = uniform(seed, -1, 1);
        s = v1 * v1 + v2 * v2;
    }
    s = v1 * sqrt(-2.0 * log(s) / s);
    return s * deviation + mean;
}
static double exponential(uint32_t *seed, double mean) {
    double n = uniform(seed, 0, 1);
    if (n != 0) n = -log(n) * mean;
    return n;
}
static double poisson(uint32_t *seed, double mean) {
    uint32_t n = 0;
    double p = exp(-mean), q = uniform(seed, 0, 1);
    while (p < q) { ++n; q = uniform(seed, 0, 1) * q; }
    return n;
}
static double chi_square(uint32_t *seed, uint32_t df) {
    double x = 0;
    if (df % 2) { x = normal(seed, 0, 1); x *= x; }
    for (uint32_t k = 2; k <= df; k += 2)
        x = x + 2 * exponential(seed, 1);
    return x;
}
static double student_t(uint32_t *seed, uint32_t df) {
    double chi2 = chi_square(seed, df);
    double div = chi2 / (double)df;
    double root = sqrt(div);
    return normal(seed, 0, 1) / root;
}
static double erlangian(uint32_t *seed, uint32_t k, double mean) {
    double x = 1.0;
    for (uint32_t i = 1; i <= k; ++i) x *= uniform(seed, 0, 1);
    return -mean * log(x) / (double)k;
}
/* rtl_dist_uniform, and $random as rtl_dist_uniform(seed, LONG_MIN, LONG_MAX). */
static int32_t rtl_dist_uniform(uint32_t *seed, int32_t start, int32_t end) {
    double r;
    int64_t i;
    if (start >= end) return start;
    if (end != INT32_MAX) {
        int64_t e = (int64_t)end + 1;
        r = uniform(seed, start, (double)e);
        i = r >= 0 ? (int64_t)r : (int64_t)(r - 1);
        if (i < start) i = start;
        if (i >= e) i = e - 1;
    } else if (start != INT32_MIN) {
        int64_t s = (int64_t)start - 1;
        r = uniform(seed, (double)s, end) + 1.0;
        i = r >= 0 ? (int64_t)r : (int64_t)(r - 1);
        if (i <= s) i = s + 1;
        if (i > end) i = end;
    } else {
        r = (uniform(seed, start, end) + 2147483648.0) / 4294967295.0;
        r = r * 4294967296.0 - 2147483648.0;
        i = r >= 0 ? (int64_t)r : (int64_t)(r - 1);
    }
    return (int32_t)(uint32_t)(uint64_t)i;
}
double rng_reference(uint32_t *seed, uint8_t op, double a, double b) {
    switch (op) {
    case 0: return uniform(seed, a, b);
    case 1: return normal(seed, a, b);
    case 2: return exponential(seed, a);
    case 3: return poisson(seed, a);
    case 4: return chi_square(seed, (uint32_t)a);
    case 5: return student_t(seed, (uint32_t)a);
    case 6: return erlangian(seed, (uint32_t)a, b);
    case 7: return rtl_dist_uniform(seed, (int32_t)a, (int32_t)b);
    default: return NAN;
    }
}
