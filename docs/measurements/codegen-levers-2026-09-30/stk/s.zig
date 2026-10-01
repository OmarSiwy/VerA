//! Four 4 KiB arrays in sequential scopes: does Zig 0.16 + LLVM share their stack slots?
extern fn use(p: [*]f64) void;
export fn blocks(k: u32) void {
    B0: {
        var a: [512]f64 = undefined;
        a[k] = 1;
        use(&a);
        break :B0;
    }
    B1: {
        var b: [512]f64 = undefined;
        b[k] = 2;
        use(&b);
        break :B1;
    }
    {
        var c: [512]f64 = undefined;
        c[k] = 3;
        use(&c);
    }
    {
        var d: [512]f64 = undefined;
        d[k] = 4;
        use(&d);
    }
}
