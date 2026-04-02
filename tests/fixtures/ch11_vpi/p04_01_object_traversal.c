/* p04 01 — the 11.6 diagrams for module, ports, nets, variables and
 * parameters, walked edge by edge over p04_objects.v.
 *
 * LRM 11.3.1: "One-to-one relationships are traversed with routine
 * vpi_handle()" and "One-to-many relationships are traversed with an
 * iteration mechanism" — the §11.5.3 key: a single arrow is vpi_handle(), a
 * double arrow vpi_iterate()/vpi_scan(), and a property listed under an
 * object is read with vpi_get()/vpi_get_str() (§11.5.2).
 *
 * ------------------------------------------------------------------ DERIVATION
 *
 * Every expected value below is read off p04_objects.v, not off a run.
 *
 * 11.3.1's own example, transplanted: vpi_handle_by_name("p04_objects.bus",
 * NULL) is the net, and vpi_handle(vpiModule, net) "shall return a handle to
 * module" p04_objects, whose vpiFullName is "p04_objects".
 *
 * 11.6.1 (module): the circled arrow into `module` is NOTE 1's
 * vpi_iterate(vpiModule, NULL), and the design has exactly one root. The
 * module -> module double arrow from the root yields exactly `u`, whose
 * vpiDefName is "p04_leaf" and whose vpiTopModule is FALSE; the root's is
 * TRUE.
 *
 * 11.6.4 (ports): module ->> port on `u` yields the header's two ports in
 * order. NOTE 6: vpiPortIndex gives the order, so a is 0 and y is 1. `a` is
 * `input [7:0]`: vpiDirection vpiInput, vpiSize 8, and by NOTE 3 vpiVector
 * TRUE, vpiScalar FALSE. `y` is `output`: vpiOutput, 1 bit, scalar. The
 * port -> module arrow leads back to `u` (vpi_compare_objects, 12.3, since a
 * C `==` does not answer that).
 *
 * 11.6.8 (nets): module ->> net on the root yields the two nets it declares,
 * in declaration order: `bus` (wire [7:0]: vpiSize 8, vector) and `lsb`
 * (scalar). net -> module leads back to the root. The value is read at t=0's
 * read-only region (12.31.2), after every t=0 event: r = 9, so bus =
 * {4'b0000, r} = 8'h09 ("09" in vpiHexStrVal, Table 12-4), and lsb =
 * bus[0] through u.y = 1 (vpi1 in vpiScalarVal).
 *
 * 11.6.10 (variables): module ->> integer var yields `i`, module ->> real var
 * yields `x`. `i` is 5 and `x` is 2.5, both written at t=0; 2.5 is exact in
 * binary64, so it is compared with ==. vpiSize of an integer is 32 (IEEE
 * 1364 §4.3.2's integer is 32 bits, which the variables diagram's vpiSize
 * reports). The scope <->> variables arrow leads back to the root.
 *
 * 11.6.12 (parameter): scope <->> parameter on the root yields `W` then `M`
 * in declaration order. NOTE 1: "Obtaining the value from the object
 * parameter shall return the final value of the parameter", which is 8 for
 * W and W - 1 = 7 for M. The arrow back to the scope is the root.
 */

//! lrm 11.3.1
//! lrm 11.6.1
//! lrm 11.6.4
//! lrm 11.6.8
//! lrm 11.6.10
//! lrm 11.6.12
//! lrm 12.3
//! lrm 12.5
//! lrm 12.12
//! lrm 12.16
//! lrm 12.19
//! lrm 12.23
//! lrm 12.35

#include "p02_check.h"

static vpiHandle top;

/* Scan `itr` to the end, storing at most `max` handles, and return how many
 * the iterator produced. The NULL that ends the loop frees the iterator
 * (12.4, 12.35). */
static int scan_all(vpiHandle itr, vpiHandle *out, int max)
{
  int n = 0;
  vpiHandle h;
  CHECK(itr != NULL, "vpi_iterate returned NULL for a non-empty set");
  CHECK(vpi_get(vpiType, itr) == vpiIterator, "12.23: the iterator's type is vpiIterator");
  while ((h = vpi_scan(itr)) != NULL) {
    if (n < max) out[n] = h;
    n++;
  }
  return n;
}

static void check_name(vpiHandle h, const char *name, const char *full)
{
  CHECK(strcmp(vpi_get_str(vpiName, h), name) == 0, "vpiName should be `%s`", name);
  CHECK(strcmp(vpi_get_str(vpiFullName, h), full) == 0, "vpiFullName should be `%s`", full);
}

static void module_and_11_3_1(void)
{
  vpiHandle got[4], net, mod, u;
  int n;

  /* 11.6.1 NOTE 1. */
  n = scan_all(vpi_iterate(vpiModule, NULL), got, 4);
  CHECK(n == 1, "one top-level module, got %d", n);
  top = got[0];
  check_name(top, "p04_objects", "p04_objects");
  CHECK(vpi_get(vpiTopModule, top) == 1, "the root is a top module");

  /* 11.3.1's example. */
  net = vpi_handle_by_name((PLI_BYTE8 *)"p04_objects.bus", NULL);
  CHECK(net != NULL, "11.3.1: vpi_handle_by_name(\"p04_objects.bus\", NULL)");
  mod = vpi_handle(vpiModule, net);
  CHECK(vpi_compare_objects(mod, top), "11.3.1: vpi_handle(vpiModule, net) is the module");
  CHECK(strcmp(vpi_get_str(vpiFullName, mod), "p04_objects") == 0, "11.3.1: its full name");

  /* module ->> module */
  n = scan_all(vpi_iterate(vpiModule, top), got, 4);
  CHECK(n == 1, "the root instantiates one module, got %d", n);
  u = got[0];
  check_name(u, "u", "p04_objects.u");
  CHECK(strcmp(vpi_get_str(vpiDefName, u), "p04_leaf") == 0, "u is an instance of p04_leaf");
  CHECK(vpi_get(vpiTopModule, u) == 0, "u is not a top module");
  CHECK(vpi_compare_objects(vpi_handle(vpiScope, u), top), "u's containing scope is the root");
  expect_no_error("the module walk");
}

static void ports(void)
{
  vpiHandle got[4];
  vpiHandle u = p02_by_name("p04_objects.u");
  int n = scan_all(vpi_iterate(vpiPort, u), got, 4);
  CHECK(n == 2, "u has two ports, got %d", n);

  check_name(got[0], "a", "p04_objects.u.a");
  CHECK(vpi_get(vpiType, got[0]) == vpiPort, "a is a vpiPort");
  CHECK(vpi_get(vpiPortIndex, got[0]) == 0, "NOTE 6: a is port 0");
  CHECK(vpi_get(vpiDirection, got[0]) == vpiInput, "a is an input");
  CHECK(vpi_get(vpiSize, got[0]) == 8, "a is 8 bits");
  CHECK(vpi_get(vpiVector, got[0]) == 1, "NOTE 3: a is a vector");
  CHECK(vpi_get(vpiScalar, got[0]) == 0, "NOTE 3: a is not a scalar");

  check_name(got[1], "y", "p04_objects.u.y");
  CHECK(vpi_get(vpiPortIndex, got[1]) == 1, "NOTE 6: y is port 1");
  CHECK(vpi_get(vpiDirection, got[1]) == vpiOutput, "y is an output");
  CHECK(vpi_get(vpiSize, got[1]) == 1, "y is 1 bit");
  CHECK(vpi_get(vpiScalar, got[1]) == 1, "NOTE 3: y is a scalar");
  CHECK(vpi_get(vpiVector, got[1]) == 0, "NOTE 3: y is not a vector");

  CHECK(vpi_compare_objects(vpi_handle(vpiModule, got[0]), u), "port -> module is u");
  CHECK(vpi_compare_objects(vpi_handle(vpiModule, got[1]), u), "port -> module is u");
  expect_no_error("the port walk");
}

static void nets(void)
{
  vpiHandle got[4];
  s_vpi_value v;
  int n = scan_all(vpi_iterate(vpiNet, top), got, 4);
  CHECK(n == 2, "the root declares two nets, got %d", n);

  check_name(got[0], "bus", "p04_objects.bus");
  CHECK(vpi_get(vpiType, got[0]) == vpiNet, "bus is a vpiNet");
  CHECK(vpi_get(vpiSize, got[0]) == 8, "bus is 8 bits");
  CHECK(vpi_get(vpiVector, got[0]) == 1 && vpi_get(vpiScalar, got[0]) == 0, "bus is a vector");
  check_name(got[1], "lsb", "p04_objects.lsb");
  CHECK(vpi_get(vpiSize, got[1]) == 1, "lsb is 1 bit");
  CHECK(vpi_get(vpiScalar, got[1]) == 1 && vpi_get(vpiVector, got[1]) == 0, "lsb is a scalar");
  CHECK(vpi_compare_objects(vpi_handle(vpiModule, got[0]), top), "net -> module is the root");

  v.format = vpiHexStrVal;
  vpi_get_value(got[0], &v);
  CHECK_STR(v.value.str, "09", "bus = {4'b0000, r} with r = 9");
  v.format = vpiScalarVal;
  vpi_get_value(got[1], &v);
  CHECK(v.value.scalar == vpi1, "lsb = bus[0] = 1");
  expect_no_error("the net walk");
}

static void variables(void)
{
  vpiHandle got[4];
  s_vpi_value v;
  int n = scan_all(vpi_iterate(vpiIntegerVar, top), got, 4);
  CHECK(n == 1, "one integer variable, got %d", n);
  check_name(got[0], "i", "p04_objects.i");
  CHECK(vpi_get(vpiType, got[0]) == vpiIntegerVar, "i is a vpiIntegerVar");
  CHECK(vpi_get(vpiSize, got[0]) == 32, "an integer is 32 bits");
  CHECK(vpi_get(vpiArray, got[0]) == 0, "i is not an array");
  CHECK(vpi_compare_objects(vpi_handle(vpiScope, got[0]), top), "variable -> scope is the root");
  v.format = vpiIntVal;
  vpi_get_value(got[0], &v);
  CHECK(v.value.integer == 5, "i = 5, got %d", (int)v.value.integer);

  n = scan_all(vpi_iterate(vpiRealVar, top), got, 4);
  CHECK(n == 1, "one real variable, got %d", n);
  check_name(got[0], "x", "p04_objects.x");
  CHECK(vpi_get(vpiType, got[0]) == vpiRealVar, "x is a vpiRealVar");
  v.format = vpiRealVal;
  vpi_get_value(got[0], &v);
  CHECK(v.value.real == 2.5, "x = 2.5, got %g", v.value.real);
  expect_no_error("the variable walk");
}

static void parameters(void)
{
  vpiHandle got[4];
  s_vpi_value v;
  int n = scan_all(vpi_iterate(vpiParameter, top), got, 4);
  CHECK(n == 2, "the root declares two parameters, got %d", n);
  check_name(got[0], "W", "p04_objects.W");
  check_name(got[1], "M", "p04_objects.M");
  CHECK(vpi_get(vpiType, got[0]) == vpiParameter, "W is a vpiParameter");
  CHECK(vpi_compare_objects(vpi_handle(vpiScope, got[0]), top), "parameter -> scope is the root");
  v.format = vpiIntVal;
  vpi_get_value(got[0], &v);
  CHECK(v.value.integer == 8, "NOTE 1: W = 8, got %d", (int)v.value.integer);
  vpi_get_value(got[1], &v);
  CHECK(v.value.integer == 7, "NOTE 1: M = W - 1 = 7, got %d", (int)v.value.integer);
  expect_no_error("the parameter walk");
}

static PLI_INT32 walk(p_cb_data cb_data)
{
  (void)cb_data;
  module_and_11_3_1();
  ports();
  nets();
  variables();
  parameters();
  p02_done("p04_01_object_traversal");
  return 0;
}

static void setup(void)
{
  static s_vpi_time t = { vpiSimTime, 0, 0, 0.0 };
  static s_cb_data cb;
  cb.reason = cbReadOnlySynch;
  cb.cb_rtn = walk;
  cb.time = &t;
  CHECK(vpi_register_cb(&cb) != NULL, "cbReadOnlySynch(0) registration failed");
}

void (*vlog_startup_routines[])(void) = { setup, 0 };
