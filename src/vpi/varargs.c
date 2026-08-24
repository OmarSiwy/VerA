/* The variadic half of the VPI ABI: §12.28 vpi_printf, §12.27
 * vpi_mcd_printf, IEEE 1364-2005 §27.3/§27.37 vpi_control, vpi_sim_control,
 * vpi_vprintf and vpi_mcd_vprintf.
 *
 * In C because Zig 0.17 refuses `@cVaStart` and `std.lang.VaList` where LLVM
 * miscompiles them (x86_64-windows, aarch64 outside Apple and Windows). C
 * starts the va_list on every target, and the Zig half (`va.zig`) reads it
 * only through the accessors below, so no Zig code names a C ABI's va_list.
 * Needs no libc: <stdarg.h> and <stddef.h> are the compiler's own headers. */

#include <stddef.h>
#include "vpi_user.h"

int vera_vpi_emit(unsigned mcd, const char *format, va_list *ap);
int vera_vpi_control(int operation, va_list *ap);
size_t vera_vpi_cformat(char *buf, size_t len, const char *format, va_list *ap);
/* VD-044: nonzero when IEEE 1364-2005 26.2.4 refuses the routine (startup). */
int vera_vpi_refused(int which);

PLI_INT32 vpi_printf(const PLI_BYTE8 *format, ...) {
  if (vera_vpi_refused(0)) return -1;
  va_list ap;
  va_start(ap, format);
  int r = vera_vpi_emit(1 | 4, format, &ap);
  va_end(ap);
  return r;
}

PLI_INT32 vpi_mcd_printf(PLI_UINT32 mcd, PLI_BYTE8 *format, ...) {
  if (vera_vpi_refused(1)) return -1;
  va_list ap;
  va_start(ap, format);
  int r = vera_vpi_emit(mcd, format, &ap);
  va_end(ap);
  return r;
}

/* A va_list parameter of array type has decayed to a pointer, so `&ap` is
 * not a `va_list *`: copy it into one that is. */
PLI_INT32 vpi_vprintf(PLI_BYTE8 *format, va_list ap) {
  if (vera_vpi_refused(2)) return -1;
  va_list cp;
  va_copy(cp, ap);
  int r = vera_vpi_emit(1 | 4, format, &cp);
  va_end(cp);
  return r;
}

PLI_INT32 vpi_mcd_vprintf(PLI_UINT32 mcd, PLI_BYTE8 *format, va_list ap) {
  if (vera_vpi_refused(3)) return -1;
  va_list cp;
  va_copy(cp, ap);
  int r = vera_vpi_emit(mcd, format, &cp);
  va_end(cp);
  return r;
}

PLI_INT32 vpi_sim_control(PLI_INT32 operation, ...) {
  if (vera_vpi_refused(4)) return 0;
  va_list ap;
  va_start(ap, operation);
  int r = vera_vpi_control(operation, &ap);
  va_end(ap);
  return r;
}

PLI_INT32 vpi_control(PLI_INT32 operation, ...) {
  if (vera_vpi_refused(4)) return 0;
  va_list ap;
  va_start(ap, operation);
  int r = vera_vpi_control(operation, &ap);
  va_end(ap);
  return r;
}

/* `print.zig`'s tests: C's printf into their 512-byte `buf`, through a real
 * variadic. */
size_t vera_vpi_format(char *buf, const char *format, ...) {
  va_list ap;
  va_start(ap, format);
  size_t n = vera_vpi_cformat(buf, 512, format, &ap);
  va_end(ap);
  return n;
}

int vera_va_int(va_list *ap) { return va_arg(*ap, int); }
long vera_va_long(va_list *ap) { return va_arg(*ap, long); }
long long vera_va_longlong(va_list *ap) { return va_arg(*ap, long long); }
size_t vera_va_size(va_list *ap) { return va_arg(*ap, size_t); }
double vera_va_double(va_list *ap) { return va_arg(*ap, double); }
void *vera_va_ptr(va_list *ap) { return va_arg(*ap, void *); }
