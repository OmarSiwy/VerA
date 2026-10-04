//! A C `va_list`, read through `varargs.c`. That file holds every variadic
//! VPI routine and starts the list; Zig 0.17 refuses `@cVaStart` on
//! x86_64-windows and aarch64-linux, so no Zig code here names the ABI's
//! va_list type and the reads below work on every target.

/// A `va_list *`, opaque: only `varargs.c` knows its layout.
pub const List = opaque {};

extern fn vera_va_int(ap: *List) c_int;
extern fn vera_va_long(ap: *List) c_long;
extern fn vera_va_longlong(ap: *List) c_longlong;
extern fn vera_va_size(ap: *List) usize;
extern fn vera_va_double(ap: *List) f64;
extern fn vera_va_ptr(ap: *List) ?*anyopaque;

/// `va_arg(*ap, T)`. An unsigned type reads its signed twin, which C11
/// 7.16.1.1 allows for a value both represent and which passes in the same
/// place; `intmax_t` is read as `long long`, the same 64 bits on every target.
pub fn arg(ap: *List, comptime T: type) T {
    return switch (T) {
        c_int => vera_va_int(ap),
        c_long => vera_va_long(ap),
        c_ulong => @bitCast(vera_va_long(ap)),
        c_longlong, i64 => vera_va_longlong(ap),
        c_ulonglong, u64 => @bitCast(vera_va_longlong(ap)),
        usize => vera_va_size(ap),
        isize => @bitCast(vera_va_size(ap)),
        f64 => vera_va_double(ap),
        ?*anyopaque => vera_va_ptr(ap),
        ?[*:0]const u8 => @ptrCast(vera_va_ptr(ap)),
        else => @compileError("va.arg: no C accessor for " ++ @typeName(T)),
    };
}
