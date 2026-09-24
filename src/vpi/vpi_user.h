/* vpi_user.h — VerA's Verilog Procedural Interface, as a C application sees it.
 *
 * LRM §11 (the object model) and §12 (the routines). Verilog-AMS 2.4 does not
 * print a header listing of its own: §12.2 and §12.31 both defer to "the
 * vpi_user.h file listing in Annex G of the IEEE Std 1364 Verilog
 * specification", so the types, the property numbers and the object numbers
 * below are IEEE 1364-2005 Annex G's and the relationships they are used in are
 * §11.6's.
 *
 * WHAT THIS FILE IS NOT. It is not the standard header truncated. Every
 * constant here is one VerA answers, and a constant VerA does not answer is
 * ABSENT rather than declared-and-unimplemented — an application that compiles
 * against this header cannot ask a question that silently returns garbage,
 * because the question does not compile. The cost of that choice is that
 * dropping in the full Annex G header is NOT a no-op: it makes names available
 * that `vpi_get` will answer with `vpiUndefined` and a `vpiError`, which is the
 * standard error indication and is safe, just less informative than a compile
 * error. The numbering is Annex G's throughout, so the two headers agree on
 * every name they share and an application built against either links against
 * this implementation.
 *
 * WHAT IS HERE (plan item P01): the object model over an elaborated design and
 * the handle/traversal/property routines over it.
 *
 * WHAT IS NOT HERE YET, and is a later plan item rather than an omission:
 *   P02  values — vpi_get_value/vpi_put_value, and the analog value family of
 *        §12.10. `s_vpi_value`/`s_vpi_time` ARE declared below because they are
 *        part of the type vocabulary §12.16/§12.30 are written in, and because
 *        an application's own `s_cb_data` needs them; no routine here consumes
 *        one.
 *   P03  callbacks (§12.31) and system task/function registration (§12.32,
 *        §12.33), which is what `vlog_startup_routines` is FOR. The array is
 *        declared here, and VerA does call its entries, because the object
 *        model is useless to an application that has no moment to walk it in.
 */

#ifndef VERA_VPI_USER_H
#define VERA_VPI_USER_H

#ifdef __cplusplus
extern "C" {
#endif

/* --------------------------------------------------------------------------
 * Annex G portable types.
 *
 * The PLI types exist so the interface's width does not follow the host C
 * compiler's `int`. They are guarded by `PLI_TYPES` exactly as Annex G guards
 * them, so an application that also includes a vendor's `vpi_user.h` or an
 * `acc_user.h` gets one definition rather than two conflicting ones.
 * -------------------------------------------------------------------------- */
#ifndef PLI_TYPES
#define PLI_TYPES
typedef int             PLI_INT32;
typedef unsigned int    PLI_UINT32;
typedef short           PLI_INT16;
typedef unsigned short  PLI_UINT16;
typedef char            PLI_BYTE8;
typedef unsigned char   PLI_UBYTE8;
#endif

/* §11.3.1: the handle is the application's opaque reference to one object.
 * Annex G spells it as a pointer to PLI_UINT32; it is never dereferenced by an
 * application, and VerA's handles do not point at PLI_UINT32 either. Two
 * handles to the same object compare equal under vpi_compare_objects() and
 * MUST NOT be compared with `==` (§12.3). */
typedef PLI_UINT32 *vpiHandle;

/* --------------------------------------------------------------------------
 * Object types — §11.6, Annex G numbering.
 *
 * `vpi_get(vpiType, obj)` returns one of these. Every one is also a legal
 * `type` argument to vpi_iterate() from some reference object; see the
 * relationship table further down.
 * -------------------------------------------------------------------------- */
#define vpiIterator            27   /* §12.23 the iterator vpi_scan() drives */
#define vpiModule              32   /* §11.6.1 module instance */
#define vpiNet                 36   /* §11.6.8/§11.6.5 scalar or vector net */
#define vpiParameter           41   /* §11.6.12 module parameter */
#define vpiPort                44   /* §11.6.4 module port */
#define vpiReg                 48   /* §11.6.9 scalar or vector reg */

/* --------------------------------------------------------------------------
 * Relationships — the `type` argument of vpi_handle()/vpi_iterate() when what
 * is being traversed is an edge of a §11.6 diagram rather than an object class.
 * -------------------------------------------------------------------------- */
#define vpiScope               84   /* one-to-one: the containing scope */
#define vpiInternalScope       92   /* one-to-many: §11.6.1 scopes in a module */

/* --------------------------------------------------------------------------
 * Properties — the `prop` argument of vpi_get() and vpi_get_str().
 * -------------------------------------------------------------------------- */
#define vpiUndefined           -1   /* §12.5 vpi_get()'s error return */
#define vpiType                 1   /* int: one of the object types above */
#define vpiName                 2   /* str: §11.6 local name */
#define vpiFullName             3   /* str: §11.6 full hierarchical name */
#define vpiSize                 4   /* int: bits of a net, reg or port */
#define vpiTopModule            7   /* bool: §11.6.1 */
#define vpiDefName              9   /* str: §11.6.1 module definition name */
#define vpiScalar              17   /* bool: §11.6.4 NOTE 3, §11.6.8 */
#define vpiVector              18   /* bool: §11.6.4 NOTE 3, §11.6.8 */
#define vpiDirection           20   /* int: §11.6.4, one of the values below */
#define vpiPortIndex           29   /* int: §11.6.4 position in the header */
#define vpiConstType           40   /* int: §11.6.12, one of the values below */
#define vpiSigned              65   /* bool: signedness of a reg */
#define vpiLocalParam          70   /* bool: §3.4.5 localparam */

/* vpiDirection values — §6.5.2.2. */
#define vpiInput                1
#define vpiOutput               2
#define vpiInout                3
#define vpiMixedIO              4
#define vpiNoDirection          5

/* vpiConstType values — §11.6.12, over §3.4.1's parameter types. */
#define vpiRealConst            2
#define vpiStringConst          6
#define vpiIntConst             7

/* --------------------------------------------------------------------------
 * §12.2 error handling.
 *
 * vpi_chk_error() reports on the PREVIOUS routine call. Every other routine in
 * this header resets the status on entry; vpi_chk_error() itself does not, so
 * it may be called twice in a row for the same error.
 * -------------------------------------------------------------------------- */

/* s_vpi_error_info.state — where the error was raised. VerA only ever raises
 * from an application's own call, so `vpiPLI` is the only state it reports;
 * the other two are declared because the field is read by the application and
 * a `switch` over it should be able to name what it is excluding. */
#define vpiCompile              1
#define vpiPLI                  2
#define vpiRun                  3

/* s_vpi_error_info.level, and vpi_chk_error()'s return — Table 12-1, in
 * increasing severity. FALSE (0) is returned when the previous call did not
 * fail. */
#define vpiNotice               1
#define vpiWarning              2
#define vpiError                3
#define vpiSystem               4
#define vpiInternal             5

/* Figure 12-1. The application owns this structure; VerA fills it in and the
 * `char *` members point into VerA's own static storage, valid until the next
 * VPI call. */
typedef struct t_vpi_error_info {
  PLI_INT32  state;             /* vpi[Compile,PLI,Run] */
  PLI_INT32  level;             /* vpi[Notice,Warning,Error,System,Internal] */
  PLI_BYTE8 *message;
  PLI_BYTE8 *product;
  PLI_BYTE8 *code;
  PLI_BYTE8 *file;
  PLI_INT32  line;
} s_vpi_error_info, *p_vpi_error_info;

/* --------------------------------------------------------------------------
 * §12.16/§12.30 value and time carriers, Figures 12-8 to 12-11.
 * -------------------------------------------------------------------------- */

/* s_vpi_time.type — §12.15. */
#define vpiScaledRealTime       1
#define vpiSimTime              2
#define vpiSuppressTime         3

typedef struct t_vpi_time {
  PLI_INT32  type;              /* vpi[ScaledRealTime,SimTime,SuppressTime] */
  PLI_UINT32 high, low;         /* for vpiSimTime */
  double     real;              /* for vpiScaledRealTime */
} s_vpi_time, *p_vpi_time;

/* Four-state bit encoding, ab: 00=0, 10=1, 11=X, 01=Z. */
#ifndef VPI_VECVAL
#define VPI_VECVAL
typedef struct t_vpi_vecval {
  PLI_INT32 aval, bval;
} s_vpi_vecval, *p_vpi_vecval;
#endif

/* Figure 12-11. Declared because it is a member of s_vpi_value's union; no
 * routine here reads or writes a strength (vpiStrengthVal is absent). */
typedef struct t_vpi_strengthval {
  PLI_INT32 logic;              /* vpi[0,1,X,Z] */
  PLI_INT32 s0, s1;
} s_vpi_strengthval, *p_vpi_strengthval;

typedef struct t_vpi_value {
  PLI_INT32 format;             /* vpi[...]Val below */
  union {
    PLI_BYTE8                *str;
    PLI_INT32                 scalar;
    PLI_INT32                 integer;
    double                    real;
    struct t_vpi_time        *time;
    struct t_vpi_vecval      *vector;
    struct t_vpi_strengthval *strength;
    PLI_BYTE8                *misc;
  } value;
} s_vpi_value, *p_vpi_value;

/* s_vpi_value.format — Table 12-4. vpi_get_value reads every one of these
 * from a digital object (and the ones a constant has from an analog
 * parameter); vpi_put_value writes all but vpiObjTypeVal and vpiSuppressVal.
 * Octal and hex print `x`/`z` for an all-unknown digit, `X`/`Z` for a partly
 * unknown one. */
#define vpiBinStrVal            1
#define vpiOctStrVal            2
#define vpiDecStrVal            3
#define vpiHexStrVal            4
#define vpiScalarVal            5
#define vpiIntVal               6
#define vpiRealVal              7
#define vpiStringVal            8
#define vpiVectorVal            9
#define vpiTimeVal             11
#define vpiObjTypeVal          12
#define vpiSuppressVal         13

/* vpiScalarVal values. */
#define vpi0                    0
#define vpi1                    1
#define vpiZ                    2
#define vpiX                    3
#define vpiH                    4
#define vpiL                    5

/* §12.30 vpi_put_value flags. vpiForceFlag and vpiReleaseFlag are declared
 * because an application names them to ask; VerA's digital engine performs no
 * force, so the put is refused with vpiError. */
#define vpiNoDelay              1
#define vpiInertialDelay        2
#define vpiTransportDelay       3
#define vpiPureTransportDelay   4
#define vpiForceFlag            5
#define vpiReleaseFlag          6
#define vpiCancelEvent          7
#define vpiReturnEvent     0x1000

#define vpiSchedEvent          53   /* §12.30 the handle vpiReturnEvent returns */
#define vpiScheduled           46   /* bool: that event has not yet happened */

/* --------------------------------------------------------------------------
 * §12.31 simulation callbacks — Figure 12-17, field for field (Figure 12-2 in
 * §12.6 omits `index`; §12.31.1 requires it, and Annex G has it).
 * -------------------------------------------------------------------------- */

typedef struct t_cb_data {
  PLI_INT32    reason;          /* cb... below */
  PLI_INT32  (*cb_rtn)(struct t_cb_data *);
  vpiHandle    obj;
  p_vpi_time   time;
  p_vpi_value  value;
  PLI_INT32    index;           /* memory word / var select that changed */
  PLI_BYTE8   *user_data;
} s_cb_data, *p_cb_data;

/* The reasons VerA delivers, Annex G numbering.
 *
 *   §12.31.1 event   cbValueChange        a net, reg, variable or array word
 *                                          changed value
 *                    cbForce, cbRelease   accepted; they fire on a force or
 *                                          release, and VerA's digital engine
 *                                          performs neither, so they never do
 *   §12.31.2 time    cbAtStartOfSimTime   absolute time, before its queue —
 *                                          "even if no event is present"
 *                    cbAfterDelay         a delay from now, before its queue
 *                    cbReadWriteSynch     a delay from now, after its queue
 *                    cbReadOnlySynch      likewise; puts are refused inside
 *                    cbNextSimTime        the next queue; time is ignored
 *   §12.31.4 action  cbEndOfCompile, cbStartOfSimulation, cbEndOfSimulation
 *
 * A time reason needs a vpiSimTime or vpiScaledRealTime time (IEEE 1364
 * 27.33.2); NULL or vpiSuppressTime is refused. Every callback is ONE-SHOT
 * except cbValueChange, cbForce and cbRelease, which stand until removed. */
#define cbValueChange           1
#define cbForce                 3
#define cbRelease               4
#define cbAtStartOfSimTime      5
#define cbReadWriteSynch        6
#define cbReadOnlySynch         7
#define cbNextSimTime           8
#define cbAfterDelay            9
#define cbEndOfCompile         10
#define cbStartOfSimulation    11
#define cbEndOfSimulation      12

#define vpiCallback           107   /* §11.6.25 vpi_get(vpiType, callback) */
#define vpiTimeQueue           64   /* §11.6.25 a pending time; vpi_iterate(vpiTimeQueue, NULL) */

/* --------------------------------------------------------------------------
 * The routines.
 *
 * WHAT IS TRAVERSABLE, which is the part of §11.6 VerA actually answers:
 *
 *   vpi_iterate(vpiModule,        NULL)    §11.6.1 NOTE 1 — the top modules
 *   vpi_iterate(vpiModule,        module)  child instances
 *   vpi_iterate(vpiInternalScope, module)  the same set, as scopes
 *   vpi_iterate(vpiPort,          module)  §11.6.4, in header order
 *   vpi_iterate(vpiNet,           module)  §11.6.8
 *   vpi_iterate(vpiReg,           module)  §11.6.9
 *   vpi_iterate(vpiParameter,     module)  §11.6.12
 *   vpi_handle(vpiScope,  obj)             the containing module, NULL at top
 *   vpi_handle(vpiModule, obj)             the same edge, read as §11.6.4's
 *                                          "one-to-one relationship back to
 *                                          module"
 *
 * Anything else is a request VerA does not answer: the routine returns its
 * documented failure value (NULL, or vpiUndefined for vpi_get) and records an
 * error vpi_chk_error() reports. It never crashes on a handle it did not
 * issue — every handle is checked against the objects VerA owns before it is
 * followed.
 * -------------------------------------------------------------------------- */

/* §12.19 one-to-one traversal. */
extern vpiHandle  vpi_handle(PLI_INT32 type, vpiHandle ref);
/* §12.21 by name, hierarchical or simple; NULL scope searches from the top. */
extern vpiHandle  vpi_handle_by_name(PLI_BYTE8 *name, vpiHandle scope);
/* §12.20 by index within a parent object. */
extern vpiHandle  vpi_handle_by_index(vpiHandle obj, PLI_INT32 index);
/* §12.23 one-to-many traversal; NULL when the set is empty. */
extern vpiHandle  vpi_iterate(PLI_INT32 type, vpiHandle ref);
/* §12.35 advance an iterator; NULL ends it AND frees it. */
extern vpiHandle  vpi_scan(vpiHandle itr);
/* §12.5 integer and Boolean properties; vpiUndefined on error. */
extern PLI_INT32  vpi_get(PLI_INT32 prop, vpiHandle obj);
/* §12.12 string properties, into one buffer reused by every call. */
extern PLI_BYTE8 *vpi_get_str(PLI_INT32 prop, vpiHandle obj);
/* §12.3 object identity; `==` on handles does not answer this. */
extern PLI_INT32  vpi_compare_objects(vpiHandle obj1, vpiHandle obj2);
/* §12.4 free an iterator abandoned before vpi_scan() returned NULL. */
extern PLI_INT32  vpi_free_object(vpiHandle obj);
/* VerA compatibility alias for vpi_free_object(); not an IEEE 1364-2005
 * Annex G declaration. */
extern PLI_INT32  vpi_release_handle(vpiHandle obj);
/* §12.2 the previous call's error, or FALSE. Pass NULL to test only. */
extern PLI_INT32  vpi_chk_error(p_vpi_error_info error_info_p);

/* §12.24–§12.28 printing and multichannel descriptors. Channel N is bit N-1
 * of an mcd; channels 1 (stdout), 2 (stderr) and 3 (the product log) are
 * predefined and cannot be closed. VerA keeps no product log, so channel 3
 * accepts output and discards it, and vpi_printf() writes stdout only.
 * vpi_printf's format is `const` here where Annex G's is not: the routine
 * never writes through it, and an application passing a string literal must
 * not need a cast. */
extern PLI_UINT32 vpi_mcd_open(PLI_BYTE8 *fileName);
extern PLI_UINT32 vpi_mcd_close(PLI_UINT32 mcd);
extern PLI_BYTE8 *vpi_mcd_name(PLI_UINT32 cd);
extern PLI_INT32  vpi_mcd_printf(PLI_UINT32 mcd, PLI_BYTE8 *format, ...);
extern PLI_INT32  vpi_printf(const PLI_BYTE8 *format, ...);

/* §12.16 read a value: from a digital net, reg, integer or memory word of a
 * running design, or from an analog parameter's folded constant. String,
 * vector and time storage is this routine's until its next call. */
extern void       vpi_get_value(vpiHandle expr, p_vpi_value value_p);
/* §12.30 write one: to a reg, integer or memory word (a net's value is its
 * drivers'). Refused inside cbReadOnlySynch. */
extern vpiHandle  vpi_put_value(vpiHandle object, p_vpi_value value_p,
                                p_vpi_time time_p, PLI_INT32 flags);

/* §12.15 the current time — or, for a vpiTimeQueue handle, that queue's
 * time. vpiSimTime is engine ticks (the global precision); vpiScaledRealTime
 * is in the object's time unit, or in ticks when obj is NULL. */
extern void       vpi_get_time(vpiHandle obj, p_vpi_time time_p);
/* §12.36 simulation control. vpiFinish (one int: the $finish diagnostic
 * level) ends the run when the calling routine returns, at the current time.
 * vpiStop, vpiReset and vpiSetInteractiveScope need an interactive mode VerA
 * does not have and are deliberately absent. */
#define vpiFinish              67
extern PLI_INT32  vpi_sim_control(PLI_INT32 operation, ...);

/* §12.31 register, §12.34 remove, §12.6 read back. A removed callback's
 * handle is invalid; a one-shot callback's handle is invalid once it fired. */
extern vpiHandle  vpi_register_cb(p_cb_data cb_data_p);
extern PLI_INT32  vpi_remove_cb(vpiHandle cb_obj);
extern void       vpi_get_cb_info(vpiHandle obj, p_cb_data cb_data_p);

/* §12.33.2. The APPLICATION defines this array and terminates it with 0; VerA
 * calls each entry in order, once, after the design is elaborated and the
 * object model above is walkable. Registering system tasks from it is P03 —
 * what an entry can usefully do today is walk the design. */
extern void (*vlog_startup_routines[])(void);

#ifdef __cplusplus
}
#endif

#endif /* VERA_VPI_USER_H */
