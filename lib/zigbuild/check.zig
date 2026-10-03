//! `--check`: generated device text in, a `zig build-obj -fno-emit-bin` of it
//! beside the `contract` module out, as a verdict (null, or an exit status
//! with its message on `err`). Moved from `src/main.zig` with the spine
//! (ARCHITECTURE.md Phase 10); the messages are user-visible and frozen.

const std = @import("std");
const Io = std.Io;

/// How long one device's `zig build-obj` gets before it is killed. A check
/// takes well under a second per device, so a child past this is wedged, and
/// an unbounded one is a hang the parent build cannot report.
const check_budget_s = 120;

/// Kills `child` once the budget is up. Returns whether it had to; a cancel
/// (the check finished first) short-circuits the sleep and answers false.
fn killAfter(io: Io, child: *std.process.Child, seconds: i64) bool {
    io.sleep(.fromSeconds(seconds), .awake) catch return false;
    child.kill(io);
    return true;
}

/// `typeCheck`'s root: the contract's checks on, over the device.
const check_root =
    \\pub const vera_validate_contract = true;
    \\comptime {
    \\    @import("contract").validate(@import("device"));
    \\}
    \\
;

/// Runs `zig build-obj -fno-emit-bin` over the generated device with the
/// `contract` module. Returns null when it type-checks, else the exit code,
/// with the reason (naming `in_path`) written on `err`.
///
/// Proves only that the file parses and its `comptime` blocks hold: analysis
/// is lazy and `contract.validate` is reflection, so a type error inside an
/// `eval`/`q` body exits 0 here.
pub fn typeCheck(
    gpa: std.mem.Allocator,
    io: Io,
    err: *Io.Writer,
    zig_exe: []const u8,
    contract: []const u8,
    device_zig: []const u8,
    in_path: []const u8,
) !?u8 {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, ".zig-cache/vera-check");
    var tmp = try cwd.openDir(io, ".zig-cache/vera-check", .{});
    defer tmp.close(io);

    const stem = std.fs.path.stem(in_path);
    const dev_name = try gpa.print("{s}.device.zig", .{stem});
    defer gpa.free(dev_name);
    try tmp.writeFile(io, .{ .sub_path = dev_name, .data = device_zig });

    // The device is not the root: the root turns the contract's checks on
    // (`contract.validating`), which `--check` is for.
    const root_name = try gpa.print("{s}.check.zig", .{stem});
    defer gpa.free(root_name);
    try tmp.writeFile(io, .{ .sub_path = root_name, .data = check_root });
    const contract_arg = try gpa.print("-Mcontract={s}", .{contract});
    defer gpa.free(contract_arg);
    const root_arg = try gpa.print("-Mroot=.zig-cache/vera-check/{s}", .{root_name});
    defer gpa.free(root_arg);
    const device_arg = try gpa.print("-Mdevice=.zig-cache/vera-check/{s}", .{dev_name});
    defer gpa.free(device_arg);

    // `--dep` applies to the NEXT `-M`, and the FIRST `-M` is the root module —
    // the ordering rule `buildArgv` in orchestrator.zig follows.
    const argv = [_][]const u8{
        zig_exe,       "build-obj",  "-fno-emit-bin",
        "--dep",       "device",     "--dep",
        "contract",    root_arg,     "--dep",
        "contract",    device_arg,   contract_arg,
        "--cache-dir", ".zig-cache",
    };

    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });

    // `concurrent`, not `async`: `async` is permitted to run the watchdog
    // inline on this thread, which would sleep out the whole budget before the
    // child was ever read from. An Io that cannot spare a second thread gets
    // an unbounded wait rather than a wrong one.
    var watchdog = io.concurrent(killAfter, .{ io, &child, check_budget_s }) catch null;

    var buf: [1 << 16]u8 = undefined;
    var reader = child.stderr.?.readerStreaming(io, &buf);
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    _ = reader.interface.streamRemaining(&aw.writer) catch {};

    // Retired BEFORE `wait` reaps, because after the reap this pid belongs to
    // whoever the OS hands it to next and a watchdog still holding it would
    // signal a stranger. `killAfter` reaps what it kills, so the timed-out
    // path must not `wait` again (an assert in Child.wait).
    const timed_out = if (watchdog) |*w| w.cancel(io) else false;
    if (timed_out) {
        try err.print(
            "error: {s}: type check did not finish in {d}s and was killed. " ++
                "The generated Zig is at .zig-cache/vera-check/{s}; run the " ++
                "`zig build-obj` from typeCheck() by hand to see where it sticks.\n",
            .{ in_path, check_budget_s, dev_name },
        );
        return 1;
    }

    const term = try child.wait(io);
    const failed = switch (term) {
        .exited => |c| c != 0,
        else => true,
    };
    if (!failed) return null;

    try err.print(
        "error: {s}: codegen produced Zig that does not compile — this is an engine bug, " ++
            "not a problem with the model:\n",
        .{in_path},
    );
    try err.writeAll(aw.writer.buffered());
    return 1;
}
