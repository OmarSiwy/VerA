/* Independent oracle for IEEE 1364-2005 §17.9.3, pp. 317–320.
 * The listed arithmetic and draw order are retained. Historical 32-bit long
 * seed wrapping is expressed as uint32_t; AMS §9.13.3 real scale arguments
 * are double. Count arguments stay integral. Compile with -ffp-contract=off.
 * This is an algorithm oracle, not a statistical distribution replacement.
 */
#include <stdint.h>
#include <math.h>

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
double rng_reference(uint32_t *seed, uint8_t op, double a, double b) {
    switch (op) {
    case 0: return uniform(seed, a, b);
    case 1: return normal(seed, a, b);
    case 2: return exponential(seed, a);
    case 3: return poisson(seed, a);
    case 4: return chi_square(seed, (uint32_t)a);
    case 5: return student_t(seed, (uint32_t)a);
    case 6: return erlangian(seed, (uint32_t)a, b);
    default: return NAN;
    }
}
