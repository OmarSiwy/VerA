/* b7 vpiReset: VAMS-2023 12.36, over b7_digital.v.
 *
 * 12.36  "vpiReset — cause $reset informative built-in Verilog system task
 *        to be executed upon return of user VPI function. This operation
 *        shall be passed three integer value arguments: stop_value,
 *        reset_value, diagnostic_level that are the same values passed to the
 *        $reset system task (see F.7 of IEEE Std 1364 Verilog)." Returns
 *        "1 (true) if successful; 0 (false) on a failure".
 * vpiReset is IEEE 1364-2005 Annex G's 68; src/vpi/vpi_user.h does not define
 * it, so this file does.
 *
 * DERIVATION. At t=1, from a cbAfterDelay routine, vpi_sim_control(vpiReset,
 * 0, 0, 1): stop_value 0 (IEEE 1364-2005 F.7: the run restarts rather than
 * entering interactive mode), reset_value 0, diagnostic level 1. A listed
 * operation with its three arguments succeeds: 1, and no error. The routine
 * asks only once (a reset that re-runs time 0 does not re-run the startup
 * routine or a cbAfterDelay that already fired), so the run ends at its
 * $finish either way.
 *
 * KNOWN GAP: VerA refuses vpiReset ("needs an interactive mode VerA does not
 * have", src/vpi/run.zig). The failure is pinned as `.xfail` in build.zig's
 * vpi_runs. Only the ledger rows are cited, not the bare clause, because a
 * vpi_runs entry counts for --coverage whether or not it is an xfail.
 */

//! lrm 12.36:5
//! lrm 12.36:6

#include "../ch11_vpi/p02_check.h"

#ifndef vpiReset
#define vpiReset 68
#endif

static int calls;

static PLI_INT32 at1(p_cb_data d)
{
  (void)d;
  if (calls++ != 0) return 0;
  CHECK(vpi_sim_control(vpiReset, 0, 0, 1) == 1, "12.36: vpi_sim_control(vpiReset, 0, 0, 1) failed");
  expect_no_error("vpi_sim_control(vpiReset, 0, 0, 1)");
  return 0;
}

static PLI_INT32 eoc(p_cb_data d)
{
  static s_vpi_time t;
  static s_cb_data cb;
  (void)d;
  t.type = vpiSimTime;
  t.low = 1;
  cb.reason = cbAfterDelay;
  cb.cb_rtn = at1;
  cb.time = &t;
  CHECK(vpi_register_cb(&cb) != NULL, "cbAfterDelay(1) registration failed");
  return 0;
}

static PLI_INT32 eos(p_cb_data d)
{
  (void)d;
  CHECK(calls == 1, "the operation was requested once, got %d", calls);
  p02_done("b7_sim_control_reset");
  return 0;
}

static void setup(void)
{
  static s_cb_data c, e;
  c.reason = cbEndOfCompile;
  c.cb_rtn = eoc;
  CHECK(vpi_register_cb(&c) != NULL, "cbEndOfCompile registration failed");
  e.reason = cbEndOfSimulation;
  e.cb_rtn = eos;
  CHECK(vpi_register_cb(&e) != NULL, "cbEndOfSimulation registration failed");
}

void (*vlog_startup_routines[])(void) = { setup, 0 };
