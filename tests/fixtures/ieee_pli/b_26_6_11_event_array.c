/* IEEE 1364-2005 §26.6.11 (named event array), over
 * b_26_6_11_event_array.v.
 *
 * §26.6.11, p. 397: named event array "-> access by index
 *   vpi_handle_by_index() vpi_handle_by_multi_index()", "-> name str: vpiName
 *   str: vpiFullName"; named event -> vpiParent named event array, vpiIndex
 *   expr (drawn with a single arrowhead; the Details below are what license
 *   vpi_iterate on it), "-> array member bool: vpiArray". Details: "vpi_iterate(
 *   vpiIndex, named_event_handle) shall return the set of indices for a named
 *   event within an array, starting with the index for the named event and
 *   working outward."
 *
 * ------------------------------------------------------------------ DERIVATION
 *
 * `event eva [0:1];`: eva is a vpiNamedEventArray named "eva"; access by
 * index 1 gives the named event eva[1], full name "b26_event_array.eva[1]",
 * an array member (vpiArray TRUE) whose vpiParent is eva and whose one index
 * reads 1.
 *
 * REFUSAL: vpi_get(vpiDirection, eva) - the diagram draws no direction -
 * vpiUndefined with vpi_chk_error() nonzero.
 *
 * VerA does not parse an event array (E0207), so build.zig runs this as an
 * xfail.
 */

//! inherited IEEE 1364-2005 26.6.11
//! inherited-reject IEEE 1364-2005 26.6.11

#include "b_check.h"

/* Annex G numbers that src/vpi/vpi_user.h does not define. */
#ifndef vpiNamedEventArray
#define vpiNamedEventArray 129
#endif

static PLI_INT32 walk(p_cb_data cb_data)
{
  vpiHandle eva = p02_by_name("b26_event_array.eva");
  vpiHandle e1, itr, ix;
  s_vpi_value v;

  (void)cb_data;
  CHECK(vpi_get(vpiType, eva) == vpiNamedEventArray, "26.6.11: a named event array");
  CHECK_STR(vpi_get_str(vpiName, eva), "eva", "26.6.11 name");
  e1 = vpi_handle_by_index(eva, 1);
  CHECK(e1 != NULL && vpi_get(vpiType, e1) == vpiNamedEvent, "26.6.11: access by index");
  CHECK_STR(vpi_get_str(vpiFullName, e1), "b26_event_array.eva[1]", "26.6.11 full name");
  CHECK(vpi_get(vpiArray, e1) == 1, "26.6.11: an array member");
  CHECK(vpi_compare_objects(vpi_handle(vpiParent, e1), eva), "26.6.11: -> vpiParent");
  itr = vpi_iterate(vpiIndex, e1);
  CHECK(itr != NULL, "26.6.11: its indices");
  ix = vpi_scan(itr);
  CHECK(ix != NULL && vpi_scan(itr) == NULL, "26.6.11: one index");
  v.format = vpiIntVal;
  vpi_get_value(ix, &v);
  CHECK(v.value.integer == 1, "26.6.11: index 1");
  expect_no_error("the event array walk");
  CHECK(vpi_get(vpiDirection, eva) == vpiUndefined, "26.6.11: an event array has no direction");
  expect_refusal("vpi_get(vpiDirection, named event array)");
  p02_done("b_26_6_11_event_array");
  return 0;
}

static PLI_INT32 start(p_cb_data cb_data)
{
  static s_vpi_time t = { vpiSimTime, 0, 0, 0.0 };
  static s_cb_data cb;
  (void)cb_data;
  cb.reason = cbReadOnlySynch;
  cb.cb_rtn = walk;
  cb.time = &t;
  CHECK(vpi_register_cb(&cb) != NULL, "cbReadOnlySynch(0) registration failed");
  return 0;
}

/* §26.2.4: from the startup routine only the action callbacks may be
 * registered, so the time callback is registered once simulation starts. */
static void setup(void)
{
  static s_cb_data ss;
  ss.reason = cbStartOfSimulation;
  ss.cb_rtn = start;
  CHECK(vpi_register_cb(&ss) != NULL, "cbStartOfSimulation registration failed");
}

void (*vlog_startup_routines[])(void) = { setup, 0 };
