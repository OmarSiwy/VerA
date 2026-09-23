/* IEEE 1364-2005 Annex G, printed 522-536. Compile-only positive clients.
 * Select exactly one PROBE_* macro. Every selected client must compile;
 * compilation failure is missing API compatibility, NOT a valid rejection.
 * This file does not link or claim any VPI runtime behavior.
 */
/* Emulate another PLI header providing the shared vector type first. */
#if defined(PROBE_VECTOR_PREDEFINED)
#define VPI_VECVAL
typedef struct t_vpi_vecval { int aval, bval; } s_vpi_vecval, *p_vpi_vecval;
#endif
#include "vpi_user.h"
#include "vpi_user.h"
#include <stddef.h>
#define TYPE_IS(expr, type) _Generic((expr), type: 1, default: 0)

#if defined(PROBE_BASELINE)
_Static_assert(TYPE_IS(((s_vpi_time *)0)->high, PLI_UINT32), "time high unsigned");
_Static_assert(TYPE_IS(((s_vpi_time *)0)->type, PLI_INT32), "time type signed");
_Static_assert(TYPE_IS(((s_vpi_error_info *)0)->message, PLI_BYTE8 *), "error message");
_Static_assert(vpiModule == 32 && vpiNet == 36 && vpiSigned == 65, "property identifiers");
#elif defined(PROBE_VECTOR_SIGNED)
_Static_assert(TYPE_IS(((s_vpi_vecval *)0)->aval, PLI_INT32), "Annex G aval signed");
_Static_assert(TYPE_IS(((s_vpi_vecval *)0)->bval, PLI_INT32), "Annex G bval signed");
#elif defined(PROBE_VECTOR_GUARD)
#ifndef VPI_VECVAL
#error Annex G VPI_VECVAL guard absent
#endif
#elif defined(PROBE_VECTOR_PREDEFINED)
_Static_assert(TYPE_IS(((s_vpi_value *)0)->value.vector, s_vpi_vecval *), "shared vector retained");
#elif defined(PROBE_VECTOR_LAYOUT)
/* Signedness repair preserves this host ABI, not a universal size assumption. */
struct previous_vector_layout { PLI_UINT32 aval, bval; };
_Static_assert(sizeof(s_vpi_vecval) == sizeof(struct previous_vector_layout), "vector size unchanged");
_Static_assert(_Alignof(s_vpi_vecval) == _Alignof(struct previous_vector_layout), "vector alignment unchanged");
_Static_assert(offsetof(s_vpi_vecval, bval) == offsetof(struct previous_vector_layout, bval), "vector offset unchanged");
#elif defined(PROBE_STRENGTH)
_Static_assert(TYPE_IS(((s_vpi_value *)0)->value.strength, struct t_vpi_strengthval *), "strength union member");
_Static_assert(TYPE_IS(((s_vpi_strengthval *)0)->s0, PLI_INT32), "strength type");
_Static_assert(vpiSupplyDrive == 0x80 && vpiWeakDrive == 0x08 && vpiHiZ == 0x01, "strength masks");
#elif defined(PROBE_NAME_SIGNATURE)
_Static_assert(TYPE_IS(&vpi_handle_by_name, vpiHandle (*)(PLI_BYTE8 *, vpiHandle)), "Annex G name signature");
#elif defined(PROBE_CALLBACK)
_Static_assert(TYPE_IS(((s_cb_data *)0)->index, PLI_INT32), "callback index");
_Static_assert(TYPE_IS(&vpi_register_cb, vpiHandle (*)(p_cb_data)), "callback registration signature");
_Static_assert(cbReadOnlySynch == 7 && cbSignal == 29, "callback identifiers");
#elif defined(PROBE_VALUE_ROUTINES)
_Static_assert(TYPE_IS(&vpi_get_value, void (*)(vpiHandle, p_vpi_value)), "get value signature");
_Static_assert(TYPE_IS(&vpi_put_value, vpiHandle (*)(vpiHandle, p_vpi_value, p_vpi_time, PLI_INT32)), "put value signature");
#else
#error Select a PROBE macro
#endif
