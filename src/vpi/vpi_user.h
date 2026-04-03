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
#define vpiConstant             7   /* an array element's index expression */
#define vpiIntegerVar          25   /* §11.6.10 integer variable (or array of) */
#define vpiIterator            27   /* §12.23 the iterator vpi_scan() drives */
#define vpiMemory              29   /* IEEE 1364 §26.6.9 legacy iteration tag */
#define vpiMemoryWord          30   /* ...and its words' tag */
#define vpiModule              32   /* §11.6.1 module instance */
#define vpiNet                 36   /* §11.6.8/§11.6.5 scalar or vector net */
#define vpiParameter           41   /* §11.6.12 module parameter */
#define vpiPort                44   /* §11.6.4 module port */
#define vpiRealVar             47   /* §11.6.10 real variable (or array of) */
#define vpiReg                 48   /* §11.6.9 scalar or vector reg; a memory word */
#define vpiVarSelect           68   /* §11.6.11 one element of a variable array */
#define vpiModuleArray        112   /* §6.2.2 an instance array, `u[1:0]` */
#define vpiRegArray           116   /* §11.6.11 a reg array (memory) */

/* --------------------------------------------------------------------------
 * The analog classes — §11.6.2, §11.6.5–§11.6.7. Verilog-AMS names these and
 * numbers none; the numbers are VerA's, and agree with the P03 draft header
 * (tests/fixtures/ch12_vpi_routines/p03_vpi_analog.h) on every name the two
 * share, so a plugin including both sees one value per name.
 *
 *   vpi_iterate(vpiDiscipline, NULL)          every discipline declared
 *   vpi_iterate(vpiNature,     NULL)          every nature declared
 *   vpi_handle(vpiFlowNature | vpiPotentialNature, discipline)
 *   vpi_handle(vpiParent, nature)             a derived nature's parent;
 *                                             NULL, no error, for a base one
 *   vpi_iterate(vpiChild,      nature)        the natures derived from it
 *   vpi_iterate(vpiDiscipline, nature)        the disciplines binding it
 *   vpi_iterate(vpiNode,       module)        §11.6.5 one per continuous net
 *   vpi_handle(vpiNode | vpiDiscipline, net)
 *   vpi_iterate(vpiNet,        node)          the net the node is
 *   vpi_iterate(vpiBranch,     module)        §11.6.6 declared branches
 *   vpi_handle(vpiPosNode | vpiNegNode | vpiDiscipline, branch)
 *   vpi_handle(vpiFlow | vpiPotential, branch) §11.6.7 its two quantities
 *   vpi_handle(vpiBranch | vpiNature, quantity)
 *
 * A quantity has no name (§11.6.7 lists none). Values are not answered here:
 * vpi_get_analog_value() needs an analysis this process does not run.
 * -------------------------------------------------------------------------- */
#define vpiQuantity           720
#define vpiBranch             721
#define vpiPotential          722
#define vpiFlow               723
#define vpiPosNode            724
#define vpiNegNode            725
#define vpiNode               726
#define vpiDiscipline         727
#define vpiNature             728
#define vpiFlowNature         729
#define vpiPotentialNature    731
#define vpiChild              732

/* --------------------------------------------------------------------------
 * The behavioural objects — §11.6.3, §11.6.10's named event, §11.6.16–
 * §11.6.24 — Annex G numbering, plus four Verilog-AMS names VerA numbers.
 *
 *   vpi_iterate(vpiProcess | vpiContAssign | vpiTask | vpiFunction |
 *               vpiNamedEvent, module)
 *   process -> vpiStmt; begin/fork ->> vpiStmt; task/function -> vpiStmt,
 *   ->> vpiIODecl; assignment -> vpiLhs, vpiRhs, vpiDelayControl,
 *   vpiEventControl (NULL, no error, when absent); if -> vpiCondition,
 *   vpiStmt (+ vpiElseStmt for vpiIfElse); case -> vpiCondition,
 *   ->> vpiCaseItem; case item ->> vpiExpr (NULL for default), -> vpiStmt;
 *   for -> vpiForInitStmt, vpiCondition, vpiForIncStmt, vpiStmt; while,
 *   repeat, wait -> vpiCondition, vpiStmt; delay control -> vpiDelay,
 *   vpiStmt; event control -> vpiCondition, vpiStmt; force/assign stmt ->
 *   vpiLhs, vpiRhs; release/deassign -> vpiLhs; disable -> vpiScope;
 *   event stmt -> vpiNamedEvent; task call -> vpiTask; func call ->
 *   vpiFunction; tf call ->> vpiArgument, sys tf call -> vpiUserSystf
 *   (NULL for a built-in name); operation ->> vpiOperand; part select ->
 *   vpiParent, vpiLeftRange, vpiRightRange; net/reg bit -> vpiParent,
 *   vpiIndex; contrib -> vpiBranch, vpiRhs (+ vpiLhs, indirect);
 *   accessfunc -> vpiBranch, vpiDiscipline.
 *
 * An identifier in an expression IS the object it names (§11.6.18): the
 * vpiLhs of `a = ...` is the reg a. Every relationship a diagram does not
 * draw is an error; vpi_get_value() reads a constant, not an operation.
 * -------------------------------------------------------------------------- */
#define vpiAlways               1
#define vpiAssignStmt           2
#define vpiAssignment           3
#define vpiBegin                4
#define vpiCase                 5
#define vpiCaseItem             6
#define vpiContAssign           8
#define vpiDeassign             9
#define vpiDelayControl        11
#define vpiDisable             12
#define vpiEventControl        13
#define vpiEventStmt           14
#define vpiFor                 15
#define vpiForce               16
#define vpiForever             17
#define vpiFork                18
#define vpiFuncCall            19
#define vpiFunction            20
#define vpiIf                  22
#define vpiIfElse              23
#define vpiInitial             24
#define vpiIODecl              28
#define vpiNamedBegin          33
#define vpiNamedEvent          34
#define vpiNamedFork           35
#define vpiNetBit              37
#define vpiNullStmt            38
#define vpiOperation           39
#define vpiPartSelect          42
#define vpiRegBit              49
#define vpiRelease             50
#define vpiRepeat              51
#define vpiSysFuncCall         56
#define vpiSysTaskCall         57
#define vpiTask                59
#define vpiTaskCall            60
#define vpiWait                69
#define vpiWhile               70
#define vpiGate                21   /* §11.6.13 a gate primitive */
#define vpiPrimTerm            46   /* §11.6.13 a primitive's terminal */
#define vpiTableEntry          58   /* §11.6.14 a UDP table entry */
#define vpiUdp                 65   /* §11.6.13 a UDP instance */
#define vpiUdpDefn             66   /* §11.6.14; vpi_iterate(vpiUdpDefn, NULL) */
#define vpiPrimitive          103   /* module ->> primitive; term -> primitive */
#define vpiPrimType            33   /* int: §11.6.13/§11.6.14, one of below */
#define vpiTermIndex           30   /* int: §11.6.13, 0 for the output */
#define vpiAndPrim              1
#define vpiNandPrim             2
#define vpiNorPrim              3
#define vpiOrPrim               4
#define vpiXorPrim              5
#define vpiXnorPrim             6
#define vpiBufPrim              7
#define vpiNotPrim              8
#define vpiBufif0Prim           9
#define vpiBufif1Prim          10
#define vpiNotif0Prim          11
#define vpiNotif1Prim          12
#define vpiSeqPrim             27
#define vpiCombPrim            28
#define vpiAnalog             733   /* §11.6.21 the analog process */
#define vpiContrib            734   /* §11.6.20 a contribution */
#define vpiDirect             735   /* bool: §11.6.20, `<+` rather than indirect */
#define vpiAccessFunc         736   /* §11.6.19 an access function */

#define vpiCondition           71
#define vpiDelay               72
#define vpiElseStmt            73
#define vpiForIncStmt          74
#define vpiForInitStmt         75
#define vpiLhs                 77
#define vpiLeftRange           79
#define vpiRhs                 82
#define vpiRightRange          83
#define vpiOperand             97
#define vpiProcess             99
#define vpiExpr               102
#define vpiStmt               104

#define vpiOpType              39   /* int: §11.6.19, one of the values below */
#define vpiBlocking            41   /* bool: §11.6.22 */
#define vpiCaseType            42   /* int: §11.6.23 */
#define vpiCaseExact            1
#define vpiCaseX                2
#define vpiCaseZ                3

#define vpiMinusOp              1
#define vpiPlusOp               2
#define vpiNotOp                3
#define vpiBitNegOp             4
#define vpiUnaryAndOp           5
#define vpiUnaryNandOp          6
#define vpiUnaryOrOp            7
#define vpiUnaryNorOp           8
#define vpiUnaryXorOp           9
#define vpiUnaryXNorOp         10
#define vpiSubOp               11
#define vpiDivOp               12
#define vpiModOp               13
#define vpiEqOp                14
#define vpiNeqOp               15
#define vpiCaseEqOp            16
#define vpiCaseNeqOp           17
#define vpiGtOp                18
#define vpiGeOp                19
#define vpiLtOp                20
#define vpiLeOp                21
#define vpiLShiftOp            22
#define vpiRShiftOp            23
#define vpiAddOp               24
#define vpiMultOp              25
#define vpiLogAndOp            26
#define vpiLogOrOp             27
#define vpiBitAndOp            28
#define vpiBitOrOp             29
#define vpiBitXorOp            30
#define vpiBitXNorOp           31
#define vpiConditionOp         32
#define vpiConcatOp            33
#define vpiMultiConcatOp       34
#define vpiEventOrOp           35
#define vpiPosedgeOp           39
#define vpiNegedgeOp           40
#define vpiArithLShiftOp       41
#define vpiArithRShiftOp       42
#define vpiPowerOp             43

/* §12.11 Figure 12-4, with Annex G's PLI_INT32 flags. vpi_get_delays() reads
 * a primitive (2 or 3 delays), a continuous assignment (1-3: rise, fall,
 * turn-off, IEEE 1364 §7.14 deriving the ones not written) and a delay
 * control (1). */
typedef struct t_vpi_delay {
  struct t_vpi_time *da;        /* user-allocated, Table 12-3's size */
  PLI_INT32  no_of_delays;
  PLI_INT32  time_type;         /* vpiScaledRealTime, vpiSimTime */
  PLI_INT32  mtm_flag;
  PLI_INT32  append_flag;
  PLI_INT32  pulsere_flag;
} s_vpi_delay, *p_vpi_delay;

/* --------------------------------------------------------------------------
 * Relationships — the `type` argument of vpi_handle()/vpi_iterate() when what
 * is being traversed is an edge of a §11.6 diagram rather than an object class.
 * -------------------------------------------------------------------------- */
#define vpiScope               84   /* one-to-one: the containing scope */
#define vpiInternalScope       92   /* one-to-many: §11.6.1 scopes in a module */
#define vpiIndex               78   /* one-to-one: element -> its vpiConstant
                                       index; NULL, no error, for a module
                                       that is not in an array */
#define vpiParent              81   /* one-to-one: word/var select -> its array */

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
#define vpiArray               28   /* bool: an array, or a module in one */
#define vpiIsMemory            73   /* bool: a reg array */

/* vpiDirection values — §6.5.2.2. */
#define vpiInput                1
#define vpiOutput               2
#define vpiInout                3
#define vpiMixedIO              4
#define vpiNoDirection          5

/* vpiConstType values — §11.6.12, over §3.4.1's parameter types; an index
 * constant is vpiDecConst. */
#define vpiDecConst             1
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

/* §12.30 vpi_put_value flags. vpiForceFlag and vpiReleaseFlag perform
 * IEEE 1364 §9.3.2's force and release, and fire cbForce/cbRelease. */
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

/* ARRAYS (§11.6.10/§11.6.11, IEEE 1364 §26.6.1/§26.6.7-9):
 *
 *   vpi_iterate(vpiMemory | vpiRegArray, module)   the reg arrays
 *   vpi_iterate(vpiMemoryWord | vpiReg,  regarray) its words, each a vpiReg
 *   vpi_iterate(vpiIntegerVar | vpiRealVar, module) variables and their arrays
 *   vpi_iterate(vpiVarSelect,  vararray)           its elements
 *   vpi_iterate(vpiModuleArray, module)            the instance arrays
 *   vpi_iterate(vpiModule,      modulearray)       its member instances
 *   vpi_handle_by_index(array, i)                  the element declared at i
 *
 * vpiSize of an array counts elements; of an element, bits. */

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
/* §12.12 string properties, into one buffer reused by every call. vpiType
 * is answered here too, as the constant's name ("vpiModule"). */
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

/* §12.17 Figure 12-12. argc/argv are the product's own invocation (the
 * host's `main`), product is "VerA"; the strings are VerA's, not the
 * application's to free or modify. TRUE on success, FALSE for a NULL
 * vlog_info_p. */
typedef struct t_vpi_vlog_info {
  PLI_INT32   argc;
  PLI_BYTE8 **argv;
  PLI_BYTE8  *product;
  PLI_BYTE8  *version;
} s_vpi_vlog_info, *p_vpi_vlog_info;
extern PLI_INT32  vpi_get_vlog_info(p_vpi_vlog_info vlog_info_p);

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
/* §12.18 real properties: the analysis's, asked of NULL. "available to analog
 * tasks and functions only" — outside an analog systf's callback the answer
 * is vpiUndefined with vpiError; inside one this process has no analysis to
 * report either, so it is the same. VerA's numbers. */
#define vpiStartTime          742
#define vpiEndTime            743
#define vpiTransientMaxStep   744
#define vpiStartFrequency     745
#define vpiEndFrequency       746
extern double     vpi_get_real(PLI_INT32 prop, vpiHandle obj);
/* §12.11 the delays of a primitive, continuous assignment or delay control. */
extern void       vpi_get_delays(vpiHandle obj, p_vpi_delay delay_p);
/* --------------------------------------------------------------------------
 * §12.32/§12.33 user system tasks and functions.
 *
 * REGISTRATION is complete: the `$` rule, the type/sysfunctype constants,
 * §12.32's per-domain uniqueness (a name may be registered once digital and
 * once analog), the info read-back and vpi_iterate(vpiUserSystf, NULL).
 *
 * INVOCATION is not. compiletf/sizetf/derivtf/calltf run at a CALL of the
 * name, and neither engine here makes one: the digital engine has no
 * user-systf call form, and an analog call runs inside a compiled device a
 * host binds through contract.SystfHost in its own process. So
 * vpi_handle(vpiSysTfCall, NULL) is NULL, and the call-object names below
 * (vpiArgument, vpiUserDefn, vpiSysFuncType, vpiDerivative) name
 * relationships of an object this process never hands out.
 * -------------------------------------------------------------------------- */

/* §12.33.1 type and sysfunctype. VAMS spells the function vpiSysFunction,
 * Annex G vpiSysFunc: one number. */
#define vpiSysTask              1
#define vpiSysFunc              2
#define vpiSysFunction          2
#define vpiIntFunc              1
#define vpiRealFunc             2
#define vpiTimeFunc             3
#define vpiSizedFunc            4
#define vpiSizedSignedFunc      5

/* §12.32.1. Verilog-AMS names these and numbers none: VerA's numbers.
 * §12.22.2's listing spells the task vpiSysAnalogTask and Figure 12-18 the
 * function vpiAnalogSysFunc; both spellings are given. */
#define vpiAnalogSysTask      740
#define vpiSysAnalogTask      740
#define vpiAnalogSysFunc      741
#define vpiAnalogSysFunction  741
#define vpiDerivative         730   /* §12.22.1 vpi_handle_multi's first argument */

#define vpiUserSystf           67   /* vpi_get(vpiType) of a registration handle */
#define vpiSysTfCall           85   /* vpi_handle(vpiSysTfCall, NULL): the active call */
#define vpiArgument            89   /* call -> its arguments */
#define vpiUserDefn            45   /* bool: the call is to a registered systf */
#define vpiSysFuncType         44   /* int: the function call's sysfunctype */

typedef struct t_vpi_systf_data {
  PLI_INT32  type;              /* vpiSysTask, vpiSysFunction */
  PLI_INT32  sysfunctype;       /* vpi[Int,Real,Time,Sized,SizedSigned]Func */
  PLI_BYTE8 *tfname;            /* first character shall be `$` */
  PLI_INT32 (*calltf)(PLI_BYTE8 *);
  PLI_INT32 (*compiletf)(PLI_BYTE8 *);
  PLI_INT32 (*sizetf)(PLI_BYTE8 *);
  PLI_BYTE8 *user_data;
} s_vpi_systf_data, *p_vpi_systf_data;

/* §12.32.2. The LRM prints the third member twice, as `derivative_wrt` in the
 * structure definition and `derivative_to` in §12.22.2's example; both are the
 * same pointer. It also uses `t_vpi_stf_partials` as a type name in that
 * example, so the tag is a typedef name too. */
typedef struct t_vpi_stf_partials {
  PLI_INT32  count;
  PLI_INT32 *derivative_of;     /* 0 = returned value, 1 = 1st arg, ... */
  union {
    PLI_INT32 *derivative_wrt;  /* 1 = 1st arg, 2 = 2nd arg, ... */
    PLI_INT32 *derivative_to;
  };
} t_vpi_stf_partials, s_vpi_stf_partials, *p_vpi_stf_partials;

/* Figure 12-18. The analog callbacks take the s_cb_data §12.22.2 passes. */
typedef struct t_vpi_analog_systf_data {
  PLI_INT32           type;         /* vpiAnalogSysTask, vpiAnalogSysFunction */
  PLI_INT32           sysfunctype;  /* vpiIntFunc, vpiRealFunc */
  PLI_BYTE8          *tfname;       /* first character shall be `$` */
  PLI_INT32         (*calltf)(struct t_cb_data *);
  PLI_INT32         (*compiletf)(struct t_cb_data *);
  PLI_INT32         (*sizetf)(struct t_cb_data *);
  p_vpi_stf_partials (*derivtf)(struct t_cb_data *);
  PLI_BYTE8          *user_data;
} s_vpi_analog_systf_data, *p_vpi_analog_systf_data;

extern vpiHandle  vpi_register_systf(p_vpi_systf_data systf_data_p);
extern vpiHandle  vpi_register_analog_systf(p_vpi_analog_systf_data systf_data_p);
extern void       vpi_get_systf_info(vpiHandle obj, p_vpi_systf_data systf_data_p);
extern void       vpi_get_analog_systf_info(vpiHandle obj, p_vpi_analog_systf_data systf_data_p);
/* §12.22 many-to-one. vpiDerivative needs two arguments of an active analog
 * call; see above for why there never is one here. */
extern vpiHandle  vpi_handle_multi(PLI_INT32 type, vpiHandle refHandle1, vpiHandle refHandle2, ...);

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
