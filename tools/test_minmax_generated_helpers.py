#!/usr/bin/env python3
"""Execute the actual emitted helper text, including a host without min/max.

This is a bounded helper regression, not a complete external simulator test.
NaN/signed-zero checks pin literal conditional selection, not extra LRM claims.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def emitted(path):
    return "\n".join(line.split("\\\\", 1)[1]
                     for line in path.read_text().splitlines()
                     if line.lstrip().startswith("\\\\"))


class MinMaxHelpers(unittest.TestCase):
    def test_actual_helpers_and_minmax_independent_host(self):
        codegen = emitted(ROOT / "lib/backend/codegen.zig")
        helpers = "\n".join(line for line in codegen.splitlines()
                            if line.startswith(("fn zMin(", "fn zMax(")))
        self.assertEqual(len(helpers.splitlines()), 2)
        runner = emitted(ROOT / "lib/backend/tb.zig")
        start = runner.index("const Dual = struct {")
        end = runner.index("\n};", start) + len("\n};")
        dual = runner[start:end]
        # This host deliberately has NO min/max/minC/maxC methods. Successful
        # execution proves the production helpers use the existing mask API.
        host = "\n".join(line for line in dual.splitlines()
                         if not any(f"pub fn {name}(" in line
                                    for name in ("min", "max", "minC", "maxC")))
        host = host.replace("const Dual = struct", "const Host = struct", 1)
        tests = r'''
test "actual generated helpers select the second tie operand without host minmax" {
    const a: Host = .{ .v = 0.5, .d = .{ 1, 0 } };
    const b: Host = .{ .v = 0.5, .d = .{ 0, 1 } };
    inline for (.{ zMin, zMax }) |f| {
        try std.testing.expectEqual(b, f(Host, a, b));
        try std.testing.expectEqual(a, f(Host, b, a));
        try std.testing.expectEqual(Host.con(0.5), f(Host, a, Host.con(0.5)));
        const minus_zero: Host = .{ .v = -0.0, .d = .{ 0, 1 } };
        const tied = f(Host, Host.con(0.0), minus_zero);
        try std.testing.expect(std.math.signbit(tied.v));
        try std.testing.expectEqual(minus_zero.d, tied.d);
        try std.testing.expectEqual(b, f(Host, Host.con(std.math.nan(f64)), b));
    }
    const low: Host = .{ .v = -1, .d = .{ 1, 0 } };
    try std.testing.expectEqual(low, zMin(Host, low, b));
    try std.testing.expectEqual(b, zMax(Host, low, b));
    try std.testing.expectEqual(low, zMin(Host, b, low));
    try std.testing.expectEqual(b, zMax(Host, b, low));
}
test "actual runner dual primitives use strict equality branches" {
    const a: Dual = .{ .v = 0.5, .d = .{ 1, 0 } };
    const b: Dual = .{ .v = 0.5, .d = .{ 0, 1 } };
    try std.testing.expectEqual(b, a.min(b));
    try std.testing.expectEqual(b, a.max(b));
    try std.testing.expectEqual(Dual.con(0.5), a.minC(0.5));
    try std.testing.expectEqual(Dual.con(0.5), a.maxC(0.5));
}
'''
        source = 'const std = @import("std");\nconst n_u = 2;\n'
        with tempfile.TemporaryDirectory(prefix="vera-minmax-helpers-") as tmp:
            path = Path(tmp) / "helpers.zig"
            path.write_text(source + dual + "\n" + host + "\n" + helpers + tests)
            result = subprocess.run(["zig", "test", str(path)], text=True,
                                    capture_output=True, cwd=ROOT)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
