/* IEEE 1364-2005 §26.6.42 (attributes), over b_26_6_42_attributes.v.
 *
 * §26.6.42, p. 415: module, net, ... ->> attribute; attribute -> vpiParent,
 *   "-> name str: vpiName", "-> On definition bool: vpiDefAttribute", "->
 *   value: vpi_get_value()". Details: "The property vpiDefAttribute shall
 *   return true if the attribute was defined on a module as part of the
 *   module definition. The property shall return false for attributes
 *   defined on a module as part of a module instantiation or for any object
 *   other than a module."
 *
 * ------------------------------------------------------------------ DERIVATION
 *
 * `(* mod_attr = 1 *) module b26_attributes;` puts one attribute on the
 * module definition: the module ->> attribute yields mod_attr, vpiDefAttribute
 * TRUE, value 1, vpiParent the module. `(* net_attr = "on" *) wire w;` puts
 * one on the net: net_attr, vpiDefAttribute FALSE (not a module), value the
 * string "on", vpiParent w.
 *
 * REFUSAL: vpi_get(vpiSize, attribute) - the diagram draws no size -
 * vpiUndefined with vpi_chk_error() nonzero.
 *
 * VerA runs the design but has no attribute object (vpi_iterate(vpiAttribute)
 * is refused), so build.zig runs this as an xfail.
 */

//! inherited IEEE 1364-2005 26.6.42
//! inherited-reject IEEE 1364-2005 26.6.42

#include "b_check.h"

/* Annex G numbers that src/vpi/vpi_user.h does not define. */
#ifndef vpiDefAttribute
#define vpiDefAttribute 55
#endif
#ifndef vpiAttribute
#define vpiAttribute 105
#endif

static vpiHandle only_attr(vpiHandle ref)
{
  vpiHandle itr = vpi_iterate(vpiAttribute, ref), h;
  CHECK(itr != NULL, "26.6.42: ->> attribute");
  h = vpi_scan(itr);
  CHECK(h != NULL && vpi_scan(itr) == NULL, "26.6.42: exactly one attribute");
  return h;
}

static PLI_INT32 walk(p_cb_data cb_data)
{
  vpiHandle top = p02_by_name("b26_attributes");
  vpiHandle w = p02_by_name("b26_attributes.w");
  vpiHandle ma = only_attr(top), na = only_attr(w);
  s_vpi_value v;

  (void)cb_data;
  CHECK_STR(vpi_get_str(vpiName, ma), "mod_attr", "26.6.42 name");
  CHECK(vpi_get(vpiDefAttribute, ma) == 1, "26.6.42: defined on the module definition");
  CHECK(vpi_compare_objects(vpi_handle(vpiParent, ma), top), "26.6.42: -> vpiParent");
  v.format = vpiIntVal;
  vpi_get_value(ma, &v);
  CHECK(v.value.integer == 1, "26.6.42: mod_attr = 1");
  CHECK_STR(vpi_get_str(vpiName, na), "net_attr", "26.6.42 name");
  CHECK(vpi_get(vpiDefAttribute, na) == 0, "26.6.42: FALSE for an object other than a module");
  CHECK(vpi_compare_objects(vpi_handle(vpiParent, na), w), "26.6.42: -> vpiParent");
  v.format = vpiStringVal;
  vpi_get_value(na, &v);
  CHECK_STR(v.value.str, "on", "26.6.42: net_attr = \"on\"");
  expect_no_error("the attribute walk");
  CHECK(vpi_get(vpiSize, ma) == vpiUndefined, "26.6.42: an attribute has no size");
  expect_refusal("vpi_get(vpiSize, attribute)");
  p02_done("b_26_6_42_attributes");
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
