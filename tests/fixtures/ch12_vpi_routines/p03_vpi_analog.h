/* p03_vpi_analog.h — the P03 half of the VPI, as a C application needs to see
 * it. NOT a fixture: the twelve `NN_*.c` plugins beside it are the fixtures,
 * and this is the header they will not compile without.
 *
 * WHY IT EXISTS AS A SEPARATE FILE. src/vpi/vpi_user.h says in its own banner
 * that "a constant VerA does not answer is ABSENT rather than
 * declared-and-unimplemented", and lists P03 — callbacks, analog values,
 * analog system task registration — as what is missing. So today none of the
 * names below exist anywhere in the tree (verified: src/vpi/root.zig exports
 * exactly eleven routines, none of them a value, callback or analog routine),
 * and a plugin that uses them cannot be compiled at all.
 *
 * WHEN P03 LANDS, this file is DELETED and every declaration in it moves into
 * src/vpi/vpi_user.h, where it belongs. The plugins then `#include
 * "vpi_user.h"` alone. Nothing here may be given a different layout or a
 * different meaning on the way: the structures are copied from Figures 12-3,
 * 12-17 and 12-18 and from §12.32.2, field for field and in order.
 *
 * MOVED ALREADY, and now src/vpi/vpi_user.h's: s_cb_data/p_cb_data (Figure
 * 12-17, unchanged), cbEndOfCompile/cbStartOfSimulation/cbEndOfSimulation,
 * vpi_register_cb, vpi_remove_cb, vpi_get_cb_info. Declaring them here as
 * well would be a C redefinition, not a harmless repeat.
 *
 * TWO INCONSISTENCIES IN THE LRM'S OWN TEXT, resolved here in favour of the
 * normative structure definitions rather than the illustrative code:
 *
 *   1. Figure 12-17 declares `p_vpi_time time;` — a POINTER. §12.32.3's own
 *      sampler listing writes `sampler->cb_data.time.real = 0.0;`, which only
 *      compiles against an embedded struct. Figure 12-17 is the definition of
 *      the structure and the example is prose; the pointer wins. Every plugin
 *      here therefore owns an s_vpi_time and points `time` at it, which is
 *      also what IEEE 1364 §27.2 requires of the same field.
 *   2. §12.32.2 defines the partials structure with a member named
 *      `derivative_wrt`; §12.22.2's resistor_derivtf() assigns
 *      `derivs.derivative_to`. The structure definition wins.
 *   3. Figure 12-18 declares every systf callback as `int (*f)()` — an
 *      unprototyped C89 spelling that says nothing. §12.22.2 then writes
 *      `resistor_compiletf(p_cb_data)` and `resistor_derivtf(p_cb_data)`, but
 *      `resistor_calltf(int data, int reason)`. Two of the three take a
 *      p_cb_data, one does not, and no clause explains the difference. All four
 *      take a `p_cb_data` here: it carries the user_data the bare `int data`
 *      was standing in for, and it is the only spelling under which §12.32.3's
 *      `vpi_handle(vpiSysTfCall, NULL)` has a documented context to read.
 *
 * NUMBERING. Verilog-AMS prints no header listing: §12.2 and §12.31 both defer
 * to "the vpi_user.h file listing in Annex G of the IEEE Std 1364 Verilog
 * specification". Annex G has numbers for the 1364 names below and NONE for the
 * AMS-only ones — there is no standard value for acbAcceptedPoint, vpiDerivative
 * or vpiExpStrVal anywhere. Those are allocated here, in one clearly fenced
 * block, and NO FIXTURE ASSERTS ANY OF THEIR VALUES: every assertion in this
 * directory is about behaviour. An implementation is free to renumber the
 * fenced block; it is not free to change what the constants mean.
 */

#ifndef VERA_P03_VPI_ANALOG_H
#define VERA_P03_VPI_ANALOG_H

#include "vpi_user.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ==========================================================================
 * IEEE 1364 Annex G numbering — names that already have a standard value.
 * ========================================================================== */

/* s_vpi_value.format — Annex G. vpiRealVal is the only one §12.10's Table 12-2
 * shares with 1364; the rest are here because vpi_get_value()/vpi_put_value()
 * on a systf argument (§12.22.2's resistor_calltf) needs them. */
#define vpiBinStrVal            1
#define vpiOctStrVal            2
#define vpiDecStrVal            3
#define vpiHexStrVal            4
#define vpiScalarVal            5
#define vpiIntVal               6
#define vpiRealVal              7
#define vpiStringVal            8
#define vpiVectorVal            9
#define vpiStrengthVal         10
#define vpiTimeVal             11
#define vpiObjTypeVal          12
#define vpiSuppressVal         13

/* vpi_put_value() delay modes — Annex G. §12.22.2 passes vpiNoDelay. */
#define vpiNoDelay              1
#define vpiInertialDelay        2
#define vpiTransportDelay       3
#define vpiPureTransportDelay   4
#define vpiForceFlag            5
#define vpiReleaseFlag          6
#define vpiCancelEvent          7

/* ==========================================================================
 * VerA ALLOCATION — names Verilog-AMS defines and gives no number to.
 *
 * Everything below this line is named by the LRM (§11.6.6, §11.6.7, §12.10,
 * §12.22.1, §12.31.3, §12.32) and numbered by VerA. 700+ is chosen to sit above
 * every 1364 Annex G object, property and reason so a full Annex G header can be
 * dropped in beside this one without a collision.
 * ========================================================================== */

/* §12.31.3 "Simulator analog and related callbacks", in the clause's order. */
#define acbInitialStep        701   /* "Upon acceptance of the first analog solution" */
#define acbFinalStep          702   /* "Upon acceptance of the last analog solution" */
#define acbAbsTime            703   /* "...for the given time (this callback shall force a solution at that time)" */
#define acbElapsedTime        704   /* "...advanced from the current solution by the given interval" */
#define acbConvergenceTest    705   /* "Prior acceptance ... allows rejection ... and backup to an earlier time" */
#define acbAcceptedPoint      706   /* "Upon acceptance of the solution at the given time" */

/* §12.10 Table 12-2's extra analog value format. The other three names in that
 * table (vpiDecStrVal, vpiRealVal, vpiStringVal) are 1364's and are above.
 * Table 12-2 spells this one "vpExpStrVal" in the Format column and
 * "vpiExpStrVal" in the body of §12.10; the `vpi` spelling is obviously the
 * intended one and the other is a typo in the standard. */
#define vpiExpStrVal          710

/* §11.6.6/§11.6.7 object and relationship tags a quantity is reached through. */
#define vpiQuantity           720   /* §11.6.7 the Quantity object */
#define vpiBranchObj          721   /* §11.6.6 the branch object (Annex G's vpiBranch is not defined) */
#define vpiPotential          722   /* §11.6.6 branch bit -> Quantity via vpiPotential */
#define vpiFlow               723   /* §11.6.6 branch bit -> Quantity via vpiFlow; also §11.6.20's bool property */
#define vpiPosNode            724   /* §11.6.6 */
#define vpiNegNode            725   /* §11.6.6 */

/* §12.22.1's first argument to vpi_handle_multi(). */
#define vpiDerivative         730

/* §12.32's s_vpi_analog_systf_data.type and .sysfunctype. §12.32.1: "The type
 * field value shall be an integer constant of vpiAnalogSysTask or
 * vpiAnalogSysFunction" — §12.22.2's own listing writes the task spelling as
 * `vpiSysAnalogTask`. Both spellings are given the same value here so either
 * listing compiles; new code should use the §12.32.1 spelling. */
#define vpiAnalogSysTask      740
#define vpiAnalogSysFunc      741
#define vpiAnalogSysFunction  741
#define vpiSysAnalogTask      740
#define vpiIntFunc            742
#define vpiRealFunc           743

/* §12.32.3 retrieves the call this callback is for. */
#define vpiSysTfCall          750
#define vpiCallbackObj        751   /* §11.6.25's callback object, as vpi_get(vpiType, cb) */

/* ==========================================================================
 * Structures.
 * ========================================================================== */

/* Figure 12-3. The two unions are separate storage: §12.10 says "the value for
 * real and imaginary unions", so a complex small-signal value arrives whole. */
typedef struct t_vpi_analog_value {
  PLI_INT32 format;             /* vpi[RealVal,ExpStrVal,DecStrVal,StringVal] */
  union { PLI_BYTE8 *str; double real; PLI_BYTE8 *misc; } real;
  union { PLI_BYTE8 *str; double real; PLI_BYTE8 *misc; } imaginary;
} s_vpi_analog_value, *p_vpi_analog_value;

/* §12.32.2. `derivative_of` uses 0 for the returned value and k for the k-th
 * argument; `derivative_wrt` uses k for the k-th argument and has no 0 case,
 * because nothing is differentiated with respect to a return value. */
typedef struct t_vpi_stf_partials {
  PLI_INT32  count;
  PLI_INT32 *derivative_of;
  PLI_INT32 *derivative_wrt;
} s_vpi_stf_partials, *p_vpi_stf_partials;

/* Figure 12-18, field for field. */
typedef struct t_vpi_analog_systf_data {
  PLI_INT32            type;        /* vpiAnalogSysTask, vpiAnalogSysFunc */
  PLI_INT32            sysfunctype; /* vpiIntFunc, vpiRealFunc */
  PLI_BYTE8           *tfname;      /* §12.32: "first character shall be `$`" */
  PLI_INT32          (*calltf)(struct t_cb_data *);
  PLI_INT32          (*compiletf)(struct t_cb_data *);
  PLI_INT32          (*sizetf)(struct t_cb_data *);
  p_vpi_stf_partials (*derivtf)(struct t_cb_data *);
  PLI_BYTE8           *user_data;
} s_vpi_analog_systf_data, *p_vpi_analog_systf_data;

/* ==========================================================================
 * Routines.
 * ========================================================================== */

/* §12.7/§12.8/§12.9. All three take no arguments and return a double; all three
 * are defined to return 0 outside the analysis they describe. */
extern double    vpi_get_analog_delta(void);
extern double    vpi_get_analog_freq(void);
extern double    vpi_get_analog_time(void);

/* §12.10. Fills value_p from a vpiPotential or vpiFlow quantity object. The
 * string buffer is the routine's, is overwritten by the next call, and §12.10
 * requires it to be a DIFFERENT buffer from vpi_get_str()'s. */
extern void      vpi_get_analog_value(vpiHandle obj, p_vpi_analog_value value_p);

/* §12.16/§12.30, on the digital/systf-argument side. */
extern void      vpi_get_value(vpiHandle obj, p_vpi_value value_p);
extern vpiHandle vpi_put_value(vpiHandle obj, p_vpi_value value_p,
                               p_vpi_time time_p, PLI_INT32 flags);

/* §12.32/§12.13. */
extern vpiHandle vpi_register_analog_systf(p_vpi_analog_systf_data systf_data_p);
extern void      vpi_get_analog_systf_info(vpiHandle obj, p_vpi_analog_systf_data systf_data_p);

/* §12.22/§12.22.1. The derivative form is
 * vpi_handle_multi(vpiDerivative, of_arg, wrt_arg). */
extern vpiHandle vpi_handle_multi(PLI_INT32 type, vpiHandle ref1, vpiHandle ref2);

/* §12.28. */
extern PLI_INT32 vpi_printf(const PLI_BYTE8 *format, ...);

#ifdef __cplusplus
}
#endif

/* ==========================================================================
 * The plugins' shared self-check, same contract as tests/vpi_app.c's: first
 * failure prints the check and exits 1, success prints one census line.
 * ========================================================================== */

#include <stdio.h>
#include <stdlib.h>
#include <math.h>

/* Not every plugin uses every helper, and a shared header full of statics
 * otherwise costs each of them a -Wunused-function. */
#if defined(__GNUC__) || defined(__clang__)
#  define P03_UNUSED __attribute__((unused))
#else
#  define P03_UNUSED
#endif

#define P03_FAIL(...)                                                         \
  do {                                                                        \
    fprintf(stderr, "p03: %s:%d: ", __FILE__, __LINE__);                      \
    fprintf(stderr, __VA_ARGS__);                                             \
    fprintf(stderr, "\n");                                                    \
    exit(1);                                                                  \
  } while (0)

#define P03_CHECK(cond, ...)                                                  \
  do { if (!(cond)) P03_FAIL(__VA_ARGS__); } while (0)

/* Every expected value in this directory is hand-derived and EXACT in exact
 * arithmetic; the tolerance is there for the solver's last bits only. */
#define P03_NEAR(got, want, tol, what)                                        \
  P03_CHECK(fabs((got) - (want)) <= (tol),                                    \
            "%s: got %.17g want %.17g (tol %g)", (what), (double)(got),       \
            (double)(want), (double)(tol))

/* §12.2, as tests/vpi_app.c uses it: a call that must fail has to SAY so. */
static P03_UNUSED int p03_saw_error(const char *what)
{
  s_vpi_error_info info;
  if (vpi_chk_error(&info) != vpiError)
    P03_FAIL("%s should have set vpiError", what);
  P03_CHECK(info.state == vpiPLI, "%s: error state should be vpiPLI", what);
  P03_CHECK(info.code && info.code[0], "%s: error carries no code", what);
  P03_CHECK(info.message && info.message[0], "%s: error carries no message", what);
  return 1;
}

static P03_UNUSED void p03_no_error(const char *what)
{
  if (vpi_chk_error(NULL) != 0) P03_FAIL("%s unexpectedly set an error", what);
}

/* §11.6.6/§11.6.7 in two lines: "the bit-level branch has tagged one-to-one
 * relationships ... to Quantity via vpiFlow, and to Quantity via vpiPotential",
 * and §11.6.7 gives Quantity its "real value"/"imaginary value" through
 * vpi_get_analog_value(). Every P03 fixture that reads a circuit value reaches
 * it this way — a NODE is not a quantity, and nothing in §11.6.5 gives a node a
 * value, so going through the branch of a known instance is the only route the
 * data model actually draws.
 *
 * `inst` is the full hierarchical name of a two-terminal instance; `tag` is
 * vpiPotential or vpiFlow. Not part of the interface: this is fixture code and
 * stays here when the declarations above move into src/vpi/vpi_user.h. */
static P03_UNUSED vpiHandle p03_quantity(const char *inst, PLI_INT32 tag)
{
  vpiHandle m, itr, br, q;
  /* Annex G's signature is mutable; the lookup does not modify this name. */
  m = vpi_handle_by_name((PLI_BYTE8 *)inst, NULL);
  P03_CHECK(m != NULL, "no instance named `%s`", inst);
  itr = vpi_iterate(vpiBranchObj, m);
  P03_CHECK(itr != NULL, "§11.6.6: `%s` has no branches", inst);
  br = vpi_scan(itr);
  P03_CHECK(br != NULL, "§11.6.6: `%s` has an empty branch iterator", inst);
  vpi_free_object(itr);
  q = vpi_handle(tag, br);
  P03_CHECK(q != NULL, "§11.6.6: branch of `%s` has no quantity for tag %d", inst, (int)tag);
  return q;
}

/* §12.10 with vpiRealVal: "Real and imaginary values of the object are returned
 * as doubles." Returns the real part and, when `im` is non-NULL, the imaginary
 * one. */
static P03_UNUSED double p03_real_of(vpiHandle q, double *im)
{
  s_vpi_analog_value v;
  v.format = vpiRealVal;
  vpi_get_analog_value(q, &v);
  p03_no_error("vpi_get_analog_value(vpiRealVal)");
  if (im) *im = v.imaginary.real;
  return v.real.real;
}

#endif /* VERA_P03_VPI_ANALOG_H */
