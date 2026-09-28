/* IEEE 1364-2005 §26.2.2, §26.3-§26.3.5, §26.5.2-§26.5.3 and the structural
 * diagrams §26.6.1-§26.6.2, §26.6.5-§26.6.12, §26.6.16, §26.6.43-§26.6.44,
 * walked over
 * b_26_6_structure.v at time 0's read-only region.
 *
 * §26.2.2, p. 376: "VPI routines provide access to objects in an instantiated
 *   Verilog design. An instantiated design is one where each instance of an
 *   object is uniquely accessible. For instance, if a module m contains wire w
 *   and is instantiated twice as m1 and m2, then m1.w and m2.w are two distinct
 *   objects, each with its own set of related objects and properties."
 * §26.3, p. 378: "if an application has a handle to a net and wants to go to
 *   the module instance where the net is defined, the call would be as
 *   follows: modH = vpi_handle(vpiModule,netH); ... As another example, to
 *   access a “named event” object, use the type vpiNamedEvent."
 * §26.3.1, p. 378: "net = vpi_handle_by_name("top.m1.w1", NULL); mod =
 *   vpi_handle(vpiModule, net); The call to vpi_handle() in the above example
 *   shall return a handle to module top.m1." p. 379: "For boolean properties,
 *   a value of 1 shall represent TRUE and a value of 0 shall represent FALSE."
 * §26.3.2, p. 379-380: "All objects have a vpiType property ... Using
 *   vpi_get_str(vpiType, <object_handle>) returns a pointer to a string
 *   containing the name of the type constant." "Some objects have additional
 *   type properties ... vpiNetType".
 * §26.3.3, p. 380: "Most objects have two location properties ... vpiLineNo
 *   ... vpiFile ... These properties are applicable to every object that
 *   corresponds to some object within the HDL. The exceptions are objects of
 *   the following types: ... vpiIterator".
 * §26.3.5, p. 381: "The vpiIsProtected property shall be TRUE if the
 *   object_handle represents code that is protected; otherwise, it shall be
 *   FALSE." (Annex G has no vpiIsProtected. Its nearest constant is
 *   vpiProtected, 10, "source protected module (boolean)", which §26.6.1
 *   and §26.6.44 draw on module and gen scope only.)
 * §26.5.2, p. 384: "Integer and boolean properties are accessed with the
 *   routine vpi_get(). ... String properties are accessed with routine
 *   vpi_get_str()."
 * §26.5.3, p. 385: "A single arrow indicates a one-to-one relationship
 *   accessed with the routine vpi_handle(). ... A one-to-one relationship
 *   which originates from a circle is traversed using NULL for the ref_h. ...
 *   A double arrow indicates a one-to-many relationship accessed with the
 *   routine vpi_scan()."
 * §26.6.1, p. 387-388 Details: "a) Top-level modules shall be accessed using
 *   vpi_iterate() with a NULL reference object. b) Passing a NULL handle to
 *   vpi_get() with properties vpiTimePrecision or vpiTimeUnit shall return the
 *   smallest time precision of all modules in the instantiated design. ...
 *   d) If a module is an element within a module array, the vpiIndex
 *   transition is used to access the index within the array. If a module is
 *   not part of a module array, this transition shall return NULL."
 * §26.6.2, p. 388: "Traversing from the instance array to expr shall return a
 *   simple expression object of type vpiOperation with a vpiOpType of
 *   vpiListOp."
 * §26.6.5, p. 390 Details: "a) vpiHighConn shall indicate the hierarchically
 *   higher (closer to the top module) port connection. ... c) Properties
 *   vpiScalar and vpiVector shall indicate if the port is 1 bit or more than
 *   1 bit. ... f) vpiPortIndex can be used to determine the port order. The
 *   first port has a port index of zero."
 * §26.6.6, p. 392 Details: "a) For vectors, net bits shall be available
 *   regardless of vector expansion. ... s) vpi_get(vpiSize, net_handle)
 *   returns the number of bits in the net. vpi_get(vpiSize, net_array_handle)
 *   returns the total number of nets in the array. t) vpi_iterate(vpiIndex,
 *   net_handle) shall return the set of indices for a net within an array
 *   ... If the net is not part of an array, a NULL shall be returned."
 * §26.6.7, p. 394 Details: "l) vpi_get(vpiSize, reg_handle) returns the
 *   number of bits in the reg. vpi_get(vpiSize, reg_array_handle) returns the
 *   total number of regs in the array. m) vpi_iterate(vpiIndex, reg_handle)
 *   ... If the reg is not part of an array, a NULL shall be returned."
 * §26.6.8, p. 395 Details: "c) The boolean property vpiArray shall be TRUE if
 *   the variable handle references an array of variables and FALSE otherwise.
 *   If the variable is an array, iterate on vpiVarSelect to obtain handles to
 *   each variable in the array. d) vpi_handle(vpiIndex, var_select_handle)
 *   shall return the index of a var select in a one-dimensional array. ...
 *   g) vpiSize for a variable array shall return the number of variables in
 *   the array. For nonarray variables, it shall return the size of the
 *   variable in bits. h) vpiSize for a var select shall return the number of
 *   bits in the var select. i) Variables whose boolean property vpiArray is
 *   TRUE do not have a value property."
 * §26.6.9, p. 396: "The objects vpiMemory and vpiMemoryWord have been
 *   generalized with the addition of arrays of regs. To preserve backward
 *   compatibility, they have been converted into methods that will return
 *   objects of type vpiRegArray and vpiReg, respectively."
 * §26.6.10, p. 396: range -> vpiLeftRange expr, -> vpiRightRange expr,
 *   "-> size int: vpiSize"; §26.6.7 draws reg array ->> range.
 * §26.6.11, p. 397: "vpi_iterate(vpiIndex, named_event_handle) shall return
 *   the set of indices for a named event within an array ... If the named
 *   event is not part of an array, a NULL shall be returned."
 * §26.6.12, p. 398 Details: "a) Obtaining the value from the object parameter
 *   shall return the final value of the parameter after all module
 *   instantiation overrides and defparams have been resolved. ... c) If a
 *   parameter does not have an explicitly defined range, vpiLeftRange and
 *   vpiRightRange shall return a NULL handle."
 * §26.6.16, p. 401: inter mod path ->> ports; "To get to an intermodule path,
 *   vpi_handle_multi(vpiInterModPath, port1, port2) can be used."
 * §26.6.43, p. 416 Details: "a) vpi_handle(vpiUse, iterator_handle) shall
 *   return the reference handle used to create the iterator. b) It is
 *   possible to have a NULL reference handle, in which case
 *   vpi_handle(vpiUse, iterator_handle) shall return NULL."
 * §26.6.44, p. 417 Details: "a) The size for a genscope array is the number
 *   of elements in the array."
 *
 * ------------------------------------------------------------------ DERIVATION
 *
 * All read off b_26_6_structure.v's source (its header lists the objects).
 *
 * §26.6.1  One top-level module (b26_leaf, b26_cell and b26_buf are all
 *   instantiated): b26_structure, vpiTopModule 1, vpiDefName
 *   "b26_structure". Its child instances include u, w4 and c1;
 *   u is b26_leaf, not top, not an array member, so vpiIndex(u) is NULL
 *   (Details d), and vpiIndex(top) likewise. `timescale 1ns/1ps: vpiTimeUnit
 *   of the module is -9, and NULL's vpiTimePrecision -12 (Details b; §27.6's
 *   "simulation time unit" for a NULL object is also -12, since §19.8 makes
 *   the smallest time_precision the simulation's precision). §26/§27 never
 *   state the integer encoding; -9 and -12 are §17.3.2 Table 17-10's
 *   units_number exponents.
 * §26.6.2  arr is a vpiModuleArray named "arr" of vpiSize 2 (two instances),
 *   whose members are arr[0] and arr[1]; each member has vpiArray TRUE and
 *   leads back to arr; vpi_handle_by_index(arr, 1) is arr[1]; its declared
 *   range [1:0] gives vpiLeftRange 1; its connection list (s) is, as an
 *   expr, a vpiOperation of vpiOpType vpiListOp.
 * §26.2.2  b26_leaf is instantiated as u (W 8) and w4 (W 4): u.a and w4.a
 *   are two distinct objects, each leading back to its own instance, with
 *   its own vpiSize (8 and 4) and its own W (8 and 4, §26.6.12 Details a).
 *   "b26_leaf.a" names the definition, not an instance: no object.
 * §26.3/§26.3.1  vpi_handle(vpiModule, u.inner) is u, whose vpiFullName is
 *   "b26_structure.u"; the top's named event is reached with vpiNamedEvent.
 *   bus is [7:0]: vpiVector 1, vpiScalar 0 (§26.3.1's 1/0 booleans).
 * §26.3.2  vpi_get_str(vpiType, ...) is "vpiModule", "vpiNet", "vpiPort" and,
 *   for an iterator, "vpiIterator". bus is a `wire`: vpiNetType vpiWire.
 * §26.3.3  u.inner appears on one line only, line 28 of b_26_6_structure.v
 *   (its declaration; nothing reads or writes it), so vpiLineNo is 28
 *   whether it reports the declaration or a use, and vpiFile names that
 *   file.
 * §26.5.2/§26.5.3  vpiSize through vpi_get(), vpiName through vpi_get_str();
 *   net -> module through vpi_handle(), module ->> net through vpi_iterate(),
 *   the circled top-module arrow through a NULL reference.
 * §26.6.5  u's ports by vpiPortIndex (Details f): a (index 0, input, 8 bits: vector) and y
 *   (index 1, output, 1 bit: scalar); u.a's high connection is bus, and it
 *   is connected by name.
 * §26.6.6  bus: vpiNet, 8 bits (Details s), 8 net bits (Details a), value
 *   8'h09 (9 in vpiIntVal); s and s3: 1 (vpi1). na is a net ARRAY of
 *   two nets: vpiNetArray, vpiSize 2. bus is no array member, so
 *   vpi_iterate(vpiIndex, bus) is NULL (Details t).
 * §26.6.7  r: vpiReg, 4 bits, 9 ("1001" in vpiBinStrVal); not an array
 *   member, so vpi_iterate(vpiIndex, r) is NULL (Details m). mem: vpiRegArray
 *   of 4 regs (Details l); mem[1] (vpi_handle_by_index) is a vpiReg of 8 bits
 *   whose vpiParent is mem, whose vpiIndex reads 1, whose value is "11" hex,
 *   and which is an array member (vpiArray TRUE). m2 is 2 x 3: vpiSize 6.
 * §26.6.8  i: vpiIntegerVar, not an array, 32 bits (Details g), 5. ia:
 *   vpiArray TRUE, vpiSize 3 (Details g), var selects ia[0..2]; ia[2] is a
 *   vpiVarSelect of 32 bits (Details h), index 2, parent ia, value 3. x is a
 *   vpiRealVar reading 2.5 (exact in binary64). t is a `time`: vpiTimeVar.
 *   The module's variables are i, ia, x, t: four.
 * §26.6.9  vpiMemory from the module yields the one-dimensional mem (whether
 *   the 2-D m2 is a memory is left open), each result of type vpiRegArray; vpiMemoryWord from mem gives its 4 words, each a vpiReg.
 *   mem is a memory: vpiIsMemory TRUE.
 * §26.6.10 mem's one range [0:3]: vpiSize 4.
 * §26.6.11 ev: vpiNamedEvent "ev", full name "b26_structure.ev", not an array
 *   (vpiArray FALSE), so vpi_iterate(vpiIndex, ev) is NULL.
 * §26.6.12 P = 5, vpiLocalParam FALSE; L = P + 1 = 6, vpiLocalParam TRUE;
 *   u.W = 8, w4.W = 4 (its override). u.W has no range: vpiLeftRange NULL
 *   (Details c); P is [7:0]: vpiLeftRange reads 7. w4's #(.W(4)) is one
 *   param assign.
 * §26.6.16 §27.20 says only that vpi_handle_multi "can be used" to reach an
 *   intermodule path, so no path is required between two given ports: this
 *   fixture asserts only the refusal below. §27.20, p. 439: "vpi_handle_multi()
 *   can be used to return a handle to an object of type vpiInterModPath
 *   associated with a list of output port and input port reference objects."
 * §26.6.43 vpi_iterate(vpiNet, top) is a vpiIterator whose vpiUse is top and
 *   vpiIteratorType vpiNet; the iterator of top modules has a NULL ref, so
 *   its vpiUse is NULL (Details b).
 * §26.6.44 gen is a genscope array of 2 (Details a); gen[0].gw is its net.
 *
 * REFUSALS, each NULL / vpiUndefined with vpi_chk_error() nonzero:
 *   §26.2.2  "b26_leaf.a": a definition's port, which is no one object.
 *   §26.3    vpi_handle(vpiNamedEvent, bus): no net -> named event arrow.
 *   §26.3.2  vpi_get(vpiType, NULL): NULL is no object.
 *   §26.3.3  vpi_get(vpiLineNo, iterator): an iterator is on the exception
 *            list.
 *   §26.5.2  vpi_get(vpiName, bus) and vpi_get_str(vpiSize, bus): a string
 *            property through vpi_get(), an integer through vpi_get_str().
 *   §26.5.3  vpi_handle(vpiNet, top): a double arrow through vpi_handle();
 *            vpi_iterate(vpiModule, bus): a single arrow through vpi_iterate().
 *   §26.6.1  vpi_get(vpiSize, top): the module diagram draws no size.
 *   §26.6.2  vpi_get(vpiDirection, arr): nor does the instance array's.
 *   §26.6.5  vpi_get(vpiTopModule, u.a): a module's property, not a port's.
 *   §26.6.6  vpi_get(vpiDirection, bus); §26.6.7 vpi_get(vpiDirection, r).
 *   §26.6.8  vpi_get_value(ia): Details i, an array has no value property.
 *   §26.6.9  vpi_iterate(vpiMemoryWord, r): r is no reg array.
 *   §26.6.11 vpi_get(vpiSize, ev): the named event diagram draws no size.
 *   §26.6.12 vpi_put_value(P): the parameter diagram draws only
 *            vpi_get_value(); P still reads 5 afterwards.
 *   §26.6.16 vpi_handle_multi(vpiInterModPath, top, bus): not two ports.
 *   §26.6.43 vpi_get(vpiSize, iterator): the iterator diagram draws no size.
 */

//! inherited IEEE 1364-2005 26.2.2
//! inherited-reject IEEE 1364-2005 26.2.2
//! inherited IEEE 1364-2005 26.3
//! inherited-reject IEEE 1364-2005 26.3
//! inherited IEEE 1364-2005 26.3.1
//! inherited IEEE 1364-2005 26.3.2
//! inherited-reject IEEE 1364-2005 26.3.2
//! inherited IEEE 1364-2005 26.3.3
//! inherited-reject IEEE 1364-2005 26.3.3
//! inherited IEEE 1364-2005 26.3.5
//! inherited IEEE 1364-2005 26.5.2
//! inherited-reject IEEE 1364-2005 26.5.2
//! inherited IEEE 1364-2005 26.5.3
//! inherited-reject IEEE 1364-2005 26.5.3
//! inherited IEEE 1364-2005 26.6.1
//! inherited-reject IEEE 1364-2005 26.6.1
//! inherited IEEE 1364-2005 26.6.2
//! inherited-reject IEEE 1364-2005 26.6.2
//! inherited IEEE 1364-2005 26.6.5
//! inherited-reject IEEE 1364-2005 26.6.5
//! inherited IEEE 1364-2005 26.6.6
//! inherited-reject IEEE 1364-2005 26.6.6
//! inherited IEEE 1364-2005 26.6.7
//! inherited-reject IEEE 1364-2005 26.6.7
//! inherited IEEE 1364-2005 26.6.8
//! inherited-reject IEEE 1364-2005 26.6.8
//! inherited IEEE 1364-2005 26.6.9
//! inherited-reject IEEE 1364-2005 26.6.9
//! inherited IEEE 1364-2005 26.6.10
//! inherited IEEE 1364-2005 26.6.11
//! inherited-reject IEEE 1364-2005 26.6.11
//! inherited IEEE 1364-2005 26.6.12
//! inherited-reject IEEE 1364-2005 26.6.12
//! inherited-reject IEEE 1364-2005 26.6.16
//! inherited IEEE 1364-2005 26.6.43
//! inherited-reject IEEE 1364-2005 26.6.43
//! inherited IEEE 1364-2005 26.6.44

#include "b_check.h"

/* Annex G numbers that src/vpi/vpi_user.h does not define. */
#ifndef vpiFile
#define vpiFile 5
#endif
#ifndef vpiLineNo
#define vpiLineNo 6
#endif
#ifndef vpiProtected
#define vpiProtected 10
#endif
#ifndef vpiTimeUnit
#define vpiTimeUnit 11
#endif
#ifndef vpiTimePrecision
#define vpiTimePrecision 12
#endif
#ifndef vpiConnByName
#define vpiConnByName 21
#endif
#ifndef vpiNetType
#define vpiNetType 22
#endif
#ifndef vpiWire
#define vpiWire 1
#endif
#ifndef vpiParamAssign
#define vpiParamAssign 40
#endif
#ifndef vpiIteratorType
#define vpiIteratorType 57
#endif
#ifndef vpiTimeVar
#define vpiTimeVar 63
#endif
#ifndef vpiHighConn
#define vpiHighConn 76
#endif
#ifndef vpiBit
#define vpiBit 90
#endif
#ifndef vpiVariables
#define vpiVariables 100
#endif
#ifndef vpiUse
#define vpiUse 101
#endif
#ifndef vpiNetArray
#define vpiNetArray 114
#endif
#ifndef vpiRange
#define vpiRange 115
#endif
#ifndef vpiListOp
#define vpiListOp 37
#endif
#ifndef vpiGenScopeArray
#define vpiGenScopeArray 133
#endif

static vpiHandle top;

/* The number of objects vpi_iterate(type, ref) yields; 0 for a NULL
 * iterator. The NULL that ends the scan frees the iterator. */
static int count(PLI_INT32 type, vpiHandle ref)
{
  vpiHandle itr = vpi_iterate(type, ref);
  int n = 0;
  if (itr != NULL)
    while (vpi_scan(itr) != NULL) n++;
  return n;
}

/* Does vpi_iterate(type, ref) yield an object whose vpiFullName is `full`? */
static int yields(PLI_INT32 type, vpiHandle ref, const char *full)
{
  vpiHandle itr = vpi_iterate(type, ref), h;
  int found = 0;
  if (itr == NULL) return 0;
  while ((h = vpi_scan(itr)) != NULL)
    if (strcmp(vpi_get_str(vpiFullName, h), full) == 0) found++;
  return found == 1;
}

static int int_value(vpiHandle h)
{
  s_vpi_value v;
  v.format = vpiIntVal;
  vpi_get_value(h, &v);
  return (int)v.value.integer;
}

static void module_and_arrays(void)
{
  vpiHandle itr, arr, m1, u;

  /* §26.6.1 Details a */
  itr = vpi_iterate(vpiModule, NULL);
  CHECK(itr != NULL, "26.6.1 a: the top modules");
  top = vpi_scan(itr);
  CHECK(top != NULL && vpi_scan(itr) == NULL, "26.6.1 a: exactly one top module");
  CHECK_STR(vpi_get_str(vpiName, top), "b26_structure", "26.6.1 name");
  CHECK_STR(vpi_get_str(vpiFullName, top), "b26_structure", "26.6.1 full name");
  CHECK_STR(vpi_get_str(vpiDefName, top), "b26_structure", "26.6.1 definition name");
  CHECK(vpi_get(vpiTopModule, top) == 1, "26.6.1: the root is a top module");
  CHECK(vpi_handle(vpiIndex, top) == NULL, "26.6.1 d: no array, no index");
  CHECK(yields(vpiModule, top, "b26_structure.u") && yields(vpiModule, top, "b26_structure.w4") &&
        yields(vpiModule, top, "b26_structure.c1"), "26.6.1: module ->> module");
  CHECK(yields(vpiModuleArray, top, "b26_structure.arr"), "26.6.1: module ->> module array");
  CHECK(count(vpiReg, top) == 1 && yields(vpiReg, top, "b26_structure.r"), "26.6.1: module ->> reg");
  CHECK(count(vpiRegArray, top) == 2, "26.6.1: module ->> reg array: mem, m2");
  CHECK(count(vpiNamedEvent, top) == 1, "26.6.1: module ->> named event");
  CHECK(count(vpiProcess, top) == 1, "26.6.1: module ->> process");
  CHECK(count(vpiContAssign, top) == 1, "26.6.1: module ->> cont assign");
  CHECK(count(vpiParameter, top) == 2, "26.6.1: module ->> parameter: P, L");
  u = p02_by_name("b26_structure.u");
  CHECK_STR(vpi_get_str(vpiDefName, u), "b26_leaf", "26.6.1: u's definition");
  CHECK(vpi_get(vpiTopModule, u) == 0, "26.6.1: u is not a top module");
  CHECK(vpi_get(vpiArray, u) == 0, "26.6.1: u is no array member");
  CHECK(vpi_handle(vpiIndex, u) == NULL, "26.6.1 d: u has no index");
  expect_no_error("the module walk");
  XFAIL(vpi_get(vpiTimeUnit, top) == -9, "26.6.1", "vpiTimeUnit of a `timescale 1ns module is not -9");
  XFAIL(vpi_get(vpiTimePrecision, NULL) == -12, "26.6.1", "vpi_get(vpiTimePrecision, NULL) is not the smallest precision, -12");
  CHECK(vpi_get(vpiSize, top) == vpiUndefined, "26.6.1: a module has no vpiSize");
  expect_refusal("vpi_get(vpiSize, module)");

  /* §26.6.2 */
  arr = p02_by_name("b26_structure.arr");
  CHECK(vpi_get(vpiType, arr) == vpiModuleArray, "26.6.2: a module array");
  CHECK_STR(vpi_get_str(vpiName, arr), "arr", "26.6.2 name");
  CHECK_STR(vpi_get_str(vpiFullName, arr), "b26_structure.arr", "26.6.2 full name");
  CHECK(vpi_get(vpiSize, arr) == 2, "26.6.2: two instances");
  CHECK(count(vpiModule, arr) == 2 && yields(vpiModule, arr, "b26_structure.arr[0]") &&
        yields(vpiModule, arr, "b26_structure.arr[1]"), "26.6.2: instance array ->> module");
  m1 = vpi_handle_by_index(arr, 1);
  CHECK(m1 != NULL, "26.6.2: access by index");
  CHECK_STR(vpi_get_str(vpiFullName, m1), "b26_structure.arr[1]", "26.6.2: index 1");
  CHECK(vpi_get(vpiArray, m1) == 1, "26.6.1: arr[1] is an array member");
  CHECK(vpi_compare_objects(vpi_handle(vpiModuleArray, m1), arr), "26.6.1: member -> module array");
  CHECK(int_value(vpi_handle(vpiIndex, m1)) == 1, "26.6.1 d: arr[1]'s index reads 1");
  expect_no_error("the module array walk");
  {
    vpiHandle lr = vpi_handle(vpiLeftRange, arr);
    XFAIL(lr != NULL && int_value(lr) == 1, "26.6.2", "instance array -> vpiLeftRange does not read 1");
  }
  {
    vpiHandle e = vpi_handle(vpiExpr, arr);
    XFAIL(e != NULL && vpi_get(vpiType, e) == vpiOperation && vpi_get(vpiOpType, e) == vpiListOp, "26.6.2",
          "instance array -> expr is not a vpiListOp operation");
  }
  CHECK(vpi_get(vpiDirection, arr) == vpiUndefined, "26.6.2: an instance array has no direction");
  expect_refusal("vpi_get(vpiDirection, module array)");
}

static void instances_and_access(void)
{
  vpiHandle u = p02_by_name("b26_structure.u");
  vpiHandle w4 = p02_by_name("b26_structure.w4");
  vpiHandle ua = p02_by_name("b26_structure.u.a");
  vpiHandle wa = p02_by_name("b26_structure.w4.a");
  vpiHandle inner = p02_by_name("b26_structure.u.inner");
  vpiHandle bus = p02_by_name("b26_structure.bus");
  vpiHandle mod, itr;

  /* §26.2.2 */
  CHECK(!vpi_compare_objects(ua, wa), "26.2.2: u.a and w4.a are two distinct objects");
  CHECK(vpi_compare_objects(vpi_handle(vpiModule, ua), u) && vpi_compare_objects(vpi_handle(vpiModule, wa), w4),
        "26.2.2: each with its own related objects");
  CHECK(vpi_get(vpiSize, ua) == 8 && vpi_get(vpiSize, wa) == 4, "26.2.2: and its own properties");
  CHECK(int_value(p02_by_name("b26_structure.u.W")) == 8 && int_value(p02_by_name("b26_structure.w4.W")) == 4,
        "26.2.2 / 26.6.12 a: each instance's own W");
  expect_no_error("the instance walk");
  CHECK(vpi_handle_by_name((PLI_BYTE8 *)"b26_leaf.a", NULL) == NULL, "26.2.2: a definition path names no object");
  expect_refusal("vpi_handle_by_name(\"b26_leaf.a\")");

  /* §26.3 / §26.3.1 */
  mod = vpi_handle(vpiModule, inner);
  CHECK(vpi_compare_objects(mod, u), "26.3.1: vpi_handle(vpiModule, net) is the instance");
  CHECK_STR(vpi_get_str(vpiFullName, mod), "b26_structure.u", "26.3.1: top.m1");
  CHECK(vpi_compare_objects(vpi_handle(vpiModule, bus), top), "26.3: modH = vpi_handle(vpiModule,netH)");
  CHECK(yields(vpiNamedEvent, top, "b26_structure.ev"), "26.3: a named event through vpiNamedEvent");
  CHECK(vpi_get(vpiVector, bus) == 1 && vpi_get(vpiScalar, bus) == 0, "26.3.1: TRUE is 1, FALSE is 0");
  CHECK(yields(vpiNet, u, "b26_structure.u.inner"), "26.3.1: itr = vpi_iterate(vpiNet,mod)");
  expect_no_error("the 26.3 walk");
  CHECK(vpi_handle(vpiNamedEvent, bus) == NULL, "26.3: a net draws no named event");
  expect_refusal("vpi_handle(vpiNamedEvent, net)");

  /* §26.3.2 */
  CHECK(vpi_get(vpiType, top) == vpiModule && vpi_get(vpiType, bus) == vpiNet && vpi_get(vpiType, ua) == vpiPort,
        "26.3.2: vpiType");
  CHECK_STR(vpi_get_str(vpiType, top), "vpiModule", "26.3.2 type name");
  CHECK_STR(vpi_get_str(vpiType, bus), "vpiNet", "26.3.2 type name");
  CHECK_STR(vpi_get_str(vpiType, ua), "vpiPort", "26.3.2 type name");
  expect_no_error("vpiType");
  itr = vpi_iterate(vpiNet, top);
  {
    const char *s = vpi_get_str(vpiType, itr);
    XFAIL(s != NULL && strcmp(s, "vpiIterator") == 0, "26.3.2", "vpi_get_str(vpiType, iterator) is not \"vpiIterator\"");
  }
  XFAIL(vpi_get(vpiNetType, bus) == vpiWire, "26.3.2", "vpiNetType of a wire is not vpiWire");
  CHECK(vpi_get(vpiType, NULL) == vpiUndefined, "26.3.2: NULL is no object");
  expect_refusal("vpi_get(vpiType, NULL)");

  /* §26.3.3 */
  XFAIL(vpi_get(vpiLineNo, inner) == 28, "26.3.3", "vpiLineNo of a net is not its source line");
  {
    const char *f = vpi_get_str(vpiFile, inner);
    size_t n = f ? strlen(f) : 0;
    XFAIL(n >= 18 && strcmp(f + n - 18, "b_26_6_structure.v") == 0, "26.3.3", "vpiFile of a net is not its source file");
  }
  CHECK(vpi_get(vpiLineNo, itr) == vpiUndefined, "26.3.3: an iterator has no location");
  expect_refusal("vpi_get(vpiLineNo, iterator)");

  /* §26.6.43 */
  CHECK(vpi_get(vpiType, itr) == vpiIterator, "26.6.43: an iterator object");
  expect_no_error("iterator type");
  XFAIL(vpi_compare_objects(vpi_handle(vpiUse, itr), top), "26.6.43", "vpi_handle(vpiUse, iterator) is not its reference handle");
  XFAIL(vpi_get(vpiIteratorType, itr) == vpiNet, "26.6.43", "vpiIteratorType is not the iterated type");
  CHECK(vpi_get(vpiSize, itr) == vpiUndefined, "26.6.43: an iterator has no size");
  expect_refusal("vpi_get(vpiSize, iterator)");
  vpi_free_object(itr);
  itr = vpi_iterate(vpiModule, NULL);
  CHECK(vpi_handle(vpiUse, itr) == NULL, "26.6.43 b: a NULL reference handle");
  vpi_free_object(itr);

  /* §26.3.5 */
  XFAIL(vpi_get(vpiProtected, top) == 0, "26.3.5", "vpiProtected of an unprotected module is not FALSE");

  /* §26.5.2 / §26.5.3 */
  CHECK(vpi_get(vpiSize, bus) == 8, "26.5.2: an int property through vpi_get()");
  CHECK_STR(vpi_get_str(vpiName, bus), "bus", "26.5.2: a string property through vpi_get_str()");
  CHECK(vpi_handle(vpiModule, bus) != NULL && count(vpiNet, top) >= 4 && count(vpiModule, NULL) == 1,
        "26.5.3: single arrow, double arrow, circle");
  expect_no_error("the key");
  CHECK(vpi_get(vpiName, bus) == vpiUndefined, "26.5.2: vpiName is a string");
  expect_refusal("vpi_get(vpiName, net)");
  CHECK(vpi_get_str(vpiSize, bus) == NULL, "26.5.2: vpiSize is an integer");
  expect_refusal("vpi_get_str(vpiSize, net)");
  CHECK(vpi_handle(vpiNet, top) == NULL, "26.5.3: module ->> net is a double arrow");
  expect_refusal("vpi_handle(vpiNet, module)");
  CHECK(vpi_iterate(vpiModule, bus) == NULL, "26.5.3: net -> module is a single arrow");
  expect_refusal("vpi_iterate(vpiModule, net)");
}

static void ports_and_paths(void)
{
  vpiHandle u = p02_by_name("b26_structure.u");
  vpiHandle bus = p02_by_name("b26_structure.bus");
  vpiHandle p[2] = { NULL, NULL }, h, itr = vpi_iterate(vpiPort, u);
  int n = 0, k;
  CHECK(itr != NULL, "26.6.5: u's ports");
  while ((h = vpi_scan(itr)) != NULL) {
    k = vpi_get(vpiPortIndex, h);
    CHECK(k == 0 || k == 1, "26.6.5 f: port index %d", k);
    CHECK(p[k] == NULL, "26.6.5 f: two ports share index %d", k);
    p[k] = h;
    n++;
  }
  CHECK(n == 2, "26.6.5: two ports, got %d", n);
  CHECK_STR(vpi_get_str(vpiName, p[0]), "a", "26.6.5: port 0");
  CHECK_STR(vpi_get_str(vpiName, p[1]), "y", "26.6.5: port 1");
  CHECK(vpi_get(vpiDirection, p[0]) == vpiInput && vpi_get(vpiDirection, p[1]) == vpiOutput, "26.6.5: direction");
  CHECK(vpi_get(vpiSize, p[0]) == 8 && vpi_get(vpiSize, p[1]) == 1, "26.6.5: size");
  CHECK(vpi_get(vpiVector, p[0]) == 1 && vpi_get(vpiScalar, p[0]) == 0, "26.6.5 c: a is more than 1 bit");
  CHECK(vpi_get(vpiScalar, p[1]) == 1 && vpi_get(vpiVector, p[1]) == 0, "26.6.5 c: y is 1 bit");
  expect_no_error("the port walk");
  XFAIL(vpi_compare_objects(vpi_handle(vpiHighConn, p[0]), bus), "26.6.5", "vpiHighConn of u.a is not bus");
  XFAIL(vpi_get(vpiConnByName, p[0]) == 1, "26.6.5", "vpiConnByName of a named connection is not TRUE");
  CHECK(vpi_get(vpiTopModule, p[0]) == vpiUndefined, "26.6.5: a port has no vpiTopModule");
  expect_refusal("vpi_get(vpiTopModule, port)");

  /* §26.6.16 */
  CHECK(vpi_handle_multi(vpiInterModPath, top, bus) == NULL, "26.6.16: a module and a net are not ports");
  expect_refusal("vpi_handle_multi(vpiInterModPath, module, net)");
}

static void nets_regs_variables(void)
{
  vpiHandle bus = p02_by_name("b26_structure.bus");
  vpiHandle na = p02_by_name("b26_structure.na");
  vpiHandle r = p02_by_name("b26_structure.r");
  vpiHandle mem = p02_by_name("b26_structure.mem");
  vpiHandle m2 = p02_by_name("b26_structure.m2");
  vpiHandle i = p02_by_name("b26_structure.i");
  vpiHandle ia = p02_by_name("b26_structure.ia");
  vpiHandle x = p02_by_name("b26_structure.x");
  vpiHandle t = p02_by_name("b26_structure.t");
  vpiHandle ev = p02_by_name("b26_structure.ev");
  vpiHandle w, vs;
  s_vpi_value v;

  /* §26.6.6 */
  CHECK(vpi_get(vpiType, bus) == vpiNet && vpi_get(vpiSize, bus) == 8, "26.6.6 s: bus is 8 bits");
  CHECK_STR(vpi_get_str(vpiFullName, bus), "b26_structure.bus", "26.6.6 full name");
  CHECK(int_value(bus) == 9, "26.6.6: bus = {4'b0000, r} = 9");
  v.format = vpiScalarVal;
  vpi_get_value(p02_by_name("b26_structure.s3"), &v);
  CHECK(v.value.scalar == vpi1, "26.6.6: s3 = s = bus[0] = 1");
  CHECK(vpi_iterate(vpiIndex, bus) == NULL, "26.6.6 t: no array, no indices");
  XFAIL(count(vpiBit, bus) == 8, "26.6.6", "net ->> net bit does not yield bus's 8 bits");
  XFAIL(vpi_get(vpiType, na) == vpiNetArray && vpi_get(vpiSize, na) == 2, "26.6.6",
        "a net array is not a vpiNetArray of vpiSize 2");
  CHECK(vpi_get(vpiDirection, bus) == vpiUndefined, "26.6.6: a net has no direction");
  expect_refusal("vpi_get(vpiDirection, net)");

  /* §26.6.7 */
  CHECK(vpi_get(vpiType, r) == vpiReg && vpi_get(vpiSize, r) == 4, "26.6.7 l: r is 4 bits");
  v.format = vpiBinStrVal;
  vpi_get_value(r, &v);
  CHECK_STR(v.value.str, "1001", "26.6.7: r = 9");
  CHECK(vpi_iterate(vpiIndex, r) == NULL, "26.6.7 m: no array, no indices");
  CHECK(vpi_get(vpiType, mem) == vpiRegArray && vpi_get(vpiSize, mem) == 4, "26.6.7 l: mem holds 4 regs");
  CHECK(count(vpiReg, mem) == 4, "26.6.7: reg array ->> reg");
  w = vpi_handle_by_index(mem, 1);
  CHECK(w != NULL && vpi_get(vpiType, w) == vpiReg && vpi_get(vpiSize, w) == 8, "26.6.7: mem[1] is an 8-bit reg");
  CHECK(vpi_compare_objects(vpi_handle(vpiParent, w), mem), "26.6.7: reg -> vpiParent reg array");
  CHECK(int_value(vpi_handle(vpiIndex, w)) == 1, "26.6.7: its index reads 1");
  v.format = vpiHexStrVal;
  vpi_get_value(w, &v);
  CHECK_STR(v.value.str, "11", "26.6.7: mem[1] = 8'h11");
  expect_no_error("the reg walk");
  XFAIL(vpi_get(vpiArray, w) == 1, "26.6.7", "vpiArray of a reg array member is not TRUE");
  XFAIL(vpi_get(vpiSize, m2) == 6, "26.6.7", "vpiSize of a 2x3 reg array is not its 6 regs");
  CHECK(vpi_get(vpiDirection, r) == vpiUndefined, "26.6.7: a reg has no direction");
  expect_refusal("vpi_get(vpiDirection, reg)");

  /* §26.6.8 */
  CHECK(vpi_get(vpiType, i) == vpiIntegerVar && vpi_get(vpiArray, i) == 0 && vpi_get(vpiSize, i) == 32,
        "26.6.8 c/g: i, not an array, 32 bits");
  CHECK(int_value(i) == 5, "26.6.8: i = 5");
  CHECK(vpi_get(vpiArray, ia) == 1 && vpi_get(vpiSize, ia) == 3, "26.6.8 c/g: ia is an array of 3");
  CHECK(count(vpiVarSelect, ia) == 3 && yields(vpiVarSelect, ia, "b26_structure.ia[0]") &&
        yields(vpiVarSelect, ia, "b26_structure.ia[2]"), "26.6.8 c: ia ->> var select");
  vs = vpi_handle_by_index(ia, 2);
  CHECK(vs != NULL && vpi_get(vpiType, vs) == vpiVarSelect && vpi_get(vpiSize, vs) == 32, "26.6.8 h: ia[2], 32 bits");
  CHECK(int_value(vpi_handle(vpiIndex, vs)) == 2, "26.6.8 d: its index is 2");
  CHECK(vpi_compare_objects(vpi_handle(vpiParent, vs), ia), "26.6.8: var select -> vpiParent");
  CHECK(int_value(vs) == 3, "26.6.8: ia[2] = 3");
  CHECK(vpi_get(vpiType, x) == vpiRealVar, "26.6.8: x is a real var");
  v.format = vpiRealVal;
  vpi_get_value(x, &v);
  CHECK(v.value.real == 2.5, "26.6.8: x = 2.5");
  expect_no_error("the variable walk");
  XFAIL(vpi_get(vpiType, t) == vpiTimeVar, "26.6.8", "a time variable is not a vpiTimeVar");
  XFAIL(count(vpiVariables, top) == 4, "26.6.8", "module ->> variables does not yield i, ia, x, t");
  v.format = vpiIntVal;
  vpi_get_value(ia, &v);
  expect_refusal("26.6.8 i: vpi_get_value(variable array)");

  /* §26.6.9 */
  CHECK(yields(vpiMemory, top, "b26_structure.mem"), "26.6.9: vpiMemory from the module yields mem");
  {
    vpiHandle itr = vpi_iterate(vpiMemory, top), h;
    while ((h = vpi_scan(itr)) != NULL)
      CHECK(vpi_get(vpiType, h) == vpiRegArray, "26.6.9: vpiMemory returns vpiRegArray objects");
    itr = vpi_iterate(vpiMemoryWord, mem);
    {
      int n = 0;
      while ((h = vpi_scan(itr)) != NULL) {
        CHECK(vpi_get(vpiType, h) == vpiReg, "26.6.9: vpiMemoryWord returns vpiReg objects");
        n++;
      }
      CHECK(n == 4, "26.6.9: mem's 4 words");
    }
  }
  CHECK(vpi_get(vpiIsMemory, mem) == 1, "26.6.9: mem is a memory");
  expect_no_error("the memory walk");
  CHECK(vpi_iterate(vpiMemoryWord, r) == NULL, "26.6.9: r is no memory");
  expect_refusal("vpi_iterate(vpiMemoryWord, reg)");

  /* §26.6.10 */
  {
    vpiHandle itr = vpi_iterate(vpiRange, mem);
    vpiHandle rg = itr ? vpi_scan(itr) : NULL;
    XFAIL(rg != NULL && vpi_get(vpiSize, rg) == 4, "26.6.10", "reg array ->> range yields no range of size 4");
    if (rg != NULL) vpi_free_object(itr);
  }

  /* §26.6.11 */
  CHECK(vpi_get(vpiType, ev) == vpiNamedEvent, "26.6.11: a named event");
  CHECK_STR(vpi_get_str(vpiName, ev), "ev", "26.6.11 name");
  CHECK_STR(vpi_get_str(vpiFullName, ev), "b26_structure.ev", "26.6.11 full name");
  CHECK(vpi_iterate(vpiIndex, ev) == NULL, "26.6.11: not in an array, so NULL");
  XFAIL(vpi_get(vpiArray, ev) == 0, "26.6.11", "vpiArray of a scalar named event is not FALSE");
  CHECK(vpi_get(vpiSize, ev) == vpiUndefined, "26.6.11: a named event has no size");
  expect_refusal("vpi_get(vpiSize, named event)");
}

static void parameters_and_generates(void)
{
  vpiHandle P = p02_by_name("b26_structure.P");
  vpiHandle L = p02_by_name("b26_structure.L");
  vpiHandle uW = p02_by_name("b26_structure.u.W");
  vpiHandle w4 = p02_by_name("b26_structure.w4");
  s_vpi_value v;

  /* §26.6.12 */
  CHECK(int_value(P) == 5 && vpi_get(vpiLocalParam, P) == 0, "26.6.12: P = 5, a parameter");
  CHECK(int_value(L) == 6 && vpi_get(vpiLocalParam, L) == 1, "26.6.12: L = P + 1 = 6, a localparam");
  CHECK(int_value(uW) == 8, "26.6.12 a: u keeps W = 8");
  CHECK(vpi_handle(vpiLeftRange, uW) == NULL, "26.6.12 c: W has no range");
  {
    vpiHandle lr = vpi_handle(vpiLeftRange, P);
    XFAIL(lr != NULL && int_value(lr) == 7, "26.6.12", "vpiLeftRange of P [7:0] does not read 7");
  }
  XFAIL(count(vpiParamAssign, w4) == 1, "26.6.12", "w4 ->> param assign does not yield its #(.W(4))");
  v.format = vpiIntVal;
  v.value.integer = 9;
  vpi_put_value(P, &v, NULL, vpiNoDelay);
  expect_refusal("26.6.12: vpi_put_value(parameter)");
  CHECK(int_value(P) == 5, "26.6.12: P still reads 5");

  /* §26.6.44 */
  XFAIL(vpi_handle_by_name((PLI_BYTE8 *)"b26_structure.gen[0].gw", NULL) != NULL, "26.6.44",
        "gen[0].gw names no object");
  {
    vpiHandle itr = vpi_iterate(vpiGenScopeArray, top);
    vpiHandle ga = itr ? vpi_scan(itr) : NULL;
    XFAIL(ga != NULL && vpi_get(vpiSize, ga) == 2, "26.6.44", "module ->> gen scope array yields no gen of size 2");
    if (ga != NULL) vpi_free_object(itr);
  }
}

static PLI_INT32 walk(p_cb_data cb_data)
{
  (void)cb_data;
  module_and_arrays();
  instances_and_access();
  ports_and_paths();
  nets_regs_variables();
  parameters_and_generates();
  p02_done("b_26_6_structure");
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
