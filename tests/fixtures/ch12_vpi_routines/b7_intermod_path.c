/* b7 inter-module path: VAMS-2023 12.22, with 12.11's and 12.29's counts for
 * the object it returns.
 *
 * 12.22  "The VPI routine vpi_handle_multi() shall return a handle to objects
 *        of type vpiInterModPath associated with a list of output port and
 *        input port reference objects. The ports shall be of the same size
 *        and can be at different levels of the hierarchy."
 * 12.11  "For inter-module path objects, the no_of_delays value shall be 2 or
 *        3."  12.29: the same sentence for vpi_put_delays(), which "shall set
 *        the delays or timing limits of an object as indicated in the delay_p
 *        structure".
 * IEEE 1364-2005 §26.6.16 draws the object with vpi_get_delays() and
 * vpi_put_delays() and says "To get to an intermodule path,
 * vpi_handle_multi(vpiInterModPath, port1, port2) can be used."
 *
 * DERIVATION. b7_specify.v: u1's port y is an output, u2's port a an input,
 * both one bit, joined by net n. That is the list 12.22 names, so the call
 * returns a handle, of type vpiInterModPath. No annotation is needed first:
 * vpi_put_delays() on this very handle is how an interconnect delay is
 * written, so the handle exists before any delay does. Then, in the 1 ns
 * unit of both cells (integers, compared with ==):
 *     put 2 (1, 2)       -> get 2: 1, 2
 *     put 3 (1, 2, 3)    -> get 3: 1, 2, 3
 *
 * KNOWN GAP: src/vpi/vpi_user.h says "vpi_handle_multi(vpiInterModPath,
 * port, port) is always NULL": VerA reads no SDF and makes no inter-module
 * path. build.zig's vpi_runs pins that failure as `.xfail`. Only the ledger
 * rows are cited, not the bare clauses, because a vpi_runs entry counts for
 * --coverage whether or not it is an xfail.
 */

//! lrm 12.22:1
//! lrm 12.11:11
//! lrm 12.29:11

#include "../ch11_vpi/p02_check.h"

static vpiHandle port_named(vpiHandle inst, const char *name)
{
  vpiHandle itr = vpi_iterate(vpiPort, inst), p, found = NULL;
  while (itr != NULL && (p = vpi_scan(itr)) != NULL)
    if (found == NULL && strcmp(vpi_get_str(vpiName, p), name) == 0) found = p;
  return found;
}

static s_vpi_time da[3];
static s_vpi_delay dl;

static void delays(int n)
{
  dl.da = da;
  dl.no_of_delays = n;
  dl.time_type = vpiScaledRealTime;
  dl.mtm_flag = 0;
  dl.append_flag = 0;
  dl.pulsere_flag = 0;
}

static void round_trip(vpiHandle path, int n)
{
  int k;
  for (k = 0; k < 3; k++) {
    da[k].type = vpiScaledRealTime;
    da[k].real = k + 1;
  }
  delays(n);
  vpi_put_delays(path, &dl);
  expect_no_error("vpi_put_delays(inter-module path)");
  for (k = 0; k < 3; k++) da[k].real = -1.0;
  vpi_get_delays(path, &dl);
  expect_no_error("vpi_get_delays(inter-module path)");
  for (k = 0; k < n; k++)
    CHECK(da[k].real == k + 1, "12.29: inter-module path put %d delays: da[%d] is %.17g, want %d", n, k, da[k].real, k + 1);
}

static PLI_INT32 walk(p_cb_data cb)
{
  vpiHandle y1, a2, path;
  (void)cb;

  y1 = port_named(p02_by_name("b7_specify.u1"), "y");
  a2 = port_named(p02_by_name("b7_specify.u2"), "a");
  CHECK(y1 != NULL && vpi_get(vpiDirection, y1) == vpiOutput && vpi_get(vpiSize, y1) == 1, "u1.y is a one-bit output port");
  CHECK(a2 != NULL && vpi_get(vpiDirection, a2) == vpiInput && vpi_get(vpiSize, a2) == 1, "u2.a is a one-bit input port");

  path = vpi_handle_multi(vpiInterModPath, y1, a2);
  CHECK(path != NULL, "12.22: vpi_handle_multi(vpiInterModPath, output port u1.y, input port u2.a) returned no inter-module path");
  expect_no_error("vpi_handle_multi(vpiInterModPath, u1.y, u2.a)");
  CHECK(vpi_get(vpiType, path) == vpiInterModPath, "12.22: the handle is a vpiInterModPath");

  round_trip(path, 2);
  round_trip(path, 3);

  p02_done("b7_intermod_path");
  return 0;
}

static void setup(void)
{
  static s_cb_data cb;
  cb.reason = cbEndOfCompile;
  cb.cb_rtn = walk;
  CHECK(vpi_register_cb(&cb) != NULL, "cbEndOfCompile registration failed");
}

void (*vlog_startup_routines[])(void) = { setup, 0 };
