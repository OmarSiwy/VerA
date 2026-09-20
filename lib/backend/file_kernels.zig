// §9.5 file descriptor I/O kernels — EMITTED VERBATIM into a device built with
// `--display=emit` that calls the §9.5 family (`codegen.file_txt` is
// `@embedFile` of this file) and `@import`ed by codegen.zig's tests. One source,
// so the descriptors the tests check are the descriptors the device opens.
//
// WHERE THIS SITS IN THE CONTRACT, AND WHY IT IS NOT EVERYWHERE. A residual has
// to be a pure function of x or the host's Newton iteration cannot converge —
// opening a file, advancing a read position or appending a line are none of
// those things. So the whole family is sequenced in the ONE per-point phase the
// contract already has for side effects: the optional `display` decl, which
// §9.5.2 makes the natural home ("$fdisplay ... the same as $display", with a
// descriptor prepended) and §9.5.9 makes the correct one ("if a file is being
// written to during an iterative solve, then the file write operations shall not
// be performed unless the iteration is accepted"). `codegen.emitSysCall` renders
// these calls ONLY while emitting that unit; in every other unit the family
// keeps the constant it always had.
//
// That is also what makes a host with no file table CONFORMANT rather than
// stubbed. A device compiled for a solver has no `display` decl, so it never
// reaches this table, so its `$fopen` answers 0 — and §9.5.1 reserves exactly
// that: "if a file cannot be opened ... a zero is returned for the mcd or fd".
// A device that genuinely has no file table genuinely cannot open a file.
//
// SCOPE. §9.5.1 $fopen/$fclose in both descriptor shapes, §9.5.2's five output
// tasks, §9.5.4.1 $fgets, §9.5.4.2 $fscanf, §9.5.5 $ftell/$fseek/$rewind,
// §9.5.6 $fflush, §9.5.7 $ferror, §9.5.8 $feof. NOT here, because §9.2 Table 9-2
// marks every one of them analog-context "No" and `lower.isDigitalOnlySysFunc`
// refuses the call: the b/h/o radix spellings, $fgetc/$ungetc/$fread,
// $readmemb/$readmemh and $sdf_annotate.

// `std` is spelled `zfstd` HERE for the reason `str_kernels.zig` spells it
// `zstd`: this text is embedded verbatim into device.zig, which already declares
// `const std` — and a DIFFERENT alias from the string kernels', because a device
// that scans a file carries both blocks in the same file scope.
const zfstd = @import("std");

/// One open channel. `pos` is §9.5.5's own quantity — "the offset from the
/// beginning of the file of the current byte of the file fd, which shall be read
/// or written by a subsequent operation" — and it is kept HERE rather than left
/// to the OS file position because every read below is POSITIONAL. That is what
/// makes `$ftell` exact after a `$fgets`: a buffered reader would have consumed
/// ahead of the newline and reported a position no clause allows.
const ZFSlot = struct {
    open: bool = false,
    f: zfstd.Io.File = undefined,
    pos: u64 = 0,
    /// §9.5.8 "EOF has previously been detected reading fd".
    eof: bool = false,
    /// §9.5.7's errno for the most recent operation on THIS descriptor.
    err: i64 = 0,
    can_read: bool = false,
    can_write: bool = false,
    /// The most recent §9.5.4.1/§9.5.4.2 line. `$fgets` returns a COUNT and
    /// writes a string, and `$fscanf` returns a count and writes its items —
    /// neither is expressible as one value, so lowering splits each source call
    /// into the count plus one reader per destination, exactly as `lowerScan`
    /// splits `$sscanf`. The readers are pure over this latch, so the read
    /// happens once however many destinations there are.
    /// 4096 and not 512, for the reason `str_kernels.zSBuf`'s row is: §9.5.4.1
    /// puts no length limit on a line ("until a newline character is read and
    /// transferred to str, or an EOF condition is encountered") and §3.3's
    /// `string` is not a fixed-width type, so a short row does not truncate a
    /// record — it silently splits it across two reads.
    line: [4096]u8 = undefined,
    line_len: usize = 0,
};

/// §9.5.1: "limiting an implementation to at most 31 files opened for output via
/// multichannel descriptors" — bit 0 is standard output and bit 31 is reserved
/// clear, so 30 is the mcd shape's own ceiling and the fd shape shares the table.
const zf_max = 30;

// ponytail: file scope, one table per device image, for the reason `zSBuf` is
// file scope — a descriptor outlives the expression that produced it and a
// `[]const u8` line has to point somewhere stable. Two instances of the same
// module therefore SHARE the table; per-instance channels are the upgrade the
// day the harness runs more than one instance of a model that opens files.
var zf_slots: [zf_max]ZFSlot = @splat(.{});

/// §9.5.1: "Applications can call $ferror to determine the cause of the most
/// recent error" — after a FAILED open there is no descriptor to hang that on,
/// since the fd is 0, so the cause lands here and `$ferror(0, str)` reports it.
var zf_last_err: i64 = 0;

fn zfIo() zfstd.Io {
    return zfstd.Io.Threaded.global_single_threaded.io();
}

/// §9.5.1 `$fopen`. `mcd` selects Syntax 9-2's first line (one argument, a
/// multichannel descriptor) over its second (two arguments, a file descriptor).
///
/// The two encodings are the clause's, verbatim: an mcd is "a 32-bit integer in
/// which a single bit is set indicating which file is opened", bit 0 being
/// standard output and bit 31 "reserved and shall always be cleared"; an fd has
/// bit 31 "reserved and shall always be set" with "the remaining bits hold a
/// small number indicating what file is opened", and 0/1/2 are STDIN/STDOUT/
/// STDERR, so a fresh channel starts at 3.
pub fn zFOpen(path: []const u8, ty: []const u8, mcd: bool) i64 {
    // "The $fopen function shall reuse channels that have been closed" — a
    // linear scan for the first free slot is that rule.
    var k: usize = 0;
    while (k < zf_max and zf_slots[k].open) k += 1;
    if (k == zf_max) {
        zf_last_err = 24; // EMFILE
        return 0;
    }
    const io = zfIo();
    // §9.5.1 Table 9-24: "b" only distinguishes hosts that translate line
    // endings; nothing here translates. Omitted type defaults to writing.
    const mode: u8 = if (zfstd.mem.indexOfAny(u8, ty, "rwa")) |at| ty[at] else 'w';
    const plus = zfstd.mem.indexOfScalar(u8, ty, '+') != null;
    const cwd: zfstd.Io.Dir = .cwd();
    const f: zfstd.Io.File = switch (mode) {
        // Table 9-24 "r"/"r+": open an EXISTING file. §9.5.1's failure case is
        // exactly this one — "the file does not exist and the type specified is
        // r, rb, r+, r+b, or rb+" — and 0 is what it asks for, not C's -1.
        'r' => cwd.openFile(io, path, .{ .mode = if (plus) .read_write else .read_only }) catch |e| {
            zf_last_err = zfErrno(e);
            return 0;
        },
        else => cwd.createFile(io, path, .{ .read = plus, .truncate = mode != 'a' }) catch |e| {
            zf_last_err = zfErrno(e);
            return 0;
        },
    };
    zf_slots[k] = .{
        .open = true,
        .f = f,
        .can_read = mode == 'r' or plus,
        .can_write = mode != 'r' or plus,
    };
    // "at end of file" is a POSITION, and the position is ours to keep.
    if (mode == 'a') zf_slots[k].pos = f.length(io) catch 0;
    zf_last_err = 0;
    return if (mcd)
        @as(i64, 1) << @intCast(k + 1) // bit 0 is standard output
    else
        (@as(i64, 1) << 31) | @as(i64, @intCast(k + 3)); // 0..2 are the std streams
}

/// A nonzero errno for §9.5.7. The numeric value is deliberately the C one where
/// there is an obvious match and deliberately NOT asserted by any fixture:
/// §9.5.7 says only "an error code is returned" and fixes no value.
fn zfErrno(e: anyerror) i64 {
    return switch (e) {
        error.FileNotFound => 2, // ENOENT
        error.AccessDenied, error.PermissionDenied => 13, // EACCES
        error.IsDir => 21, // EISDIR
        error.NoSpaceLeft => 28, // ENOSPC
        else => 5, // EIO — "should any error be detected"
    };
}

/// The slot a descriptor names, or null when it names none — which is every
/// §9.5 call on the 0 a failed open returned, and on one of the three pre-opened
/// standard channels this table does not hold.
fn zfSlot(d: i64) ?usize {
    if (d == 0) return null;
    if (d & (@as(i64, 1) << 31) != 0) { // an fd: bit 31 set
        const ch = d & 0x7fff_ffff;
        if (ch < 3) return null; // STDIN/STDOUT/STDERR
        const k: usize = @intCast(ch - 3);
        return if (k < zf_max and zf_slots[k].open) k else null;
    }
    // An mcd: the LOWEST set bit above bit 0 names the channel a single-channel
    // operation acts on. §9.5.1 lets several bits be OR'd together, which is a
    // WRITE-side rule (`zFPut` honours it); everything else here is per-channel.
    var b: u6 = 1;
    while (b <= zf_max) : (b += 1) {
        if (d & (@as(i64, 1) << b) == 0) continue;
        const k: usize = b - 1;
        return if (zf_slots[k].open) k else null;
    }
    return null;
}

/// §9.5.2's five output tasks, after the §9.4.3 formatter has produced the text.
/// Returns the byte count, which nothing in §9.5 asks for — the tasks are void —
/// but which gives the call a value the emitter can sequence.
///
/// §9.5.1: "file descriptors cannot be combined via bitwise OR" but mcds can, so
/// an mcd write goes to EVERY channel its bits name, and bit 0 is the transcript.
pub fn zFPut(d: i64, text: []const u8) i64 {
    if (d == 0) {
        zf_last_err = 9; // EBADF
        return 0;
    }
    if (d & (@as(i64, 1) << 31) != 0) return zfPut1(zfSlot(d) orelse {
        // An fd naming no slot: bit 31 set with a small number of 1 or 2 is
        // §9.5.1's pre-opened STDOUT/STDERR, which is the transcript.
        if ((d & 0x7fff_ffff) == 1 or (d & 0x7fff_ffff) == 2) {
            zfstd.debug.print("{s}", .{text});
            return @intCast(text.len);
        }
        zf_last_err = 9;
        return 0;
    }, text);
    var n: i64 = 0;
    if (d & 1 != 0) { // bit 0 "always refers to the standard output"
        zfstd.debug.print("{s}", .{text});
        n = @intCast(text.len);
    }
    var b: u6 = 1;
    while (b <= zf_max) : (b += 1) {
        if (d & (@as(i64, 1) << b) == 0) continue;
        if (!zf_slots[b - 1].open) continue;
        n = zfPut1(b - 1, text);
    }
    return n;
}

fn zfPut1(k: usize, text: []const u8) i64 {
    const s = &zf_slots[k];
    if (!s.can_write) {
        s.err = 9; // EBADF — opened "r"
        zf_last_err = 9;
        return 0;
    }
    s.f.writePositionalAll(zfIo(), text, s.pos) catch |e| {
        s.err = zfErrno(e);
        zf_last_err = s.err;
        return 0;
    };
    s.pos += text.len;
    s.err = 0;
    zf_last_err = 0;
    return @intCast(text.len);
}

/// §9.5.4.1 `code = $fgets( str, fd )`: "reads characters from the file
/// specified by fd into the string variable, str until a newline character is
/// read AND TRANSFERRED to str, or an EOF condition is encountered. If an error
/// occurs reading from the file, then code is set to zero. Otherwise, the number
/// of characters read is returned in code."
///
/// So the newline is INCLUDED in both the string and the count — C's `fgets`
/// keeps it too, but a port that stops before the delimiter returns one less.
//
// ponytail: one positional read per byte, because the count and `$ftell`'s
// answer are both exact byte offsets and a chunked read would consume past the
// newline. A fixture line is four bytes; a model reading a large file wants a
// buffer that tracks `pos` itself, which is the upgrade.
pub fn zFGets(d: i64) i64 {
    const k = zfSlot(d) orelse {
        zf_last_err = 9;
        return 0;
    };
    const s = &zf_slots[k];
    if (!s.can_read) {
        s.err = 9;
        zf_last_err = 9;
        return 0;
    }
    const io = zfIo();
    var n: usize = 0;
    var b: [1]u8 = undefined;
    while (n < s.line.len) {
        const got = s.f.readPositionalAll(io, &b, s.pos + n) catch |e| {
            s.err = zfErrno(e);
            zf_last_err = s.err;
            s.line_len = n;
            s.pos += n;
            return 0;
        };
        if (got == 0) {
            s.eof = true;
            break;
        }
        s.line[n] = b[0];
        n += 1;
        if (b[0] == '\n') break;
    }
    s.pos += n;
    s.line_len = n;
    s.err = 0;
    zf_last_err = 0;
    return @intCast(n);
}

/// The line `$fgets` or `$fscanf` last read from this descriptor.
///
/// `n` is the COUNT the call that performed the read returned. It is an operand
/// for one structural reason — passing it makes the reader data-dependent on the
/// read, so the emitter cannot order the pair the wrong way round — and it is
/// then READ, because §9.5.4.1 sets code to zero exactly when nothing was
/// transferred into the string.
pub fn zFLine(n: i64, d: i64) []const u8 {
    if (n <= 0) return "";
    const k = zfSlot(d) orelse return "";
    return zf_slots[k].line[0..zf_slots[k].line_len];
}

/// §9.5.4.2's INPUT: one line of the file, for `str_kernels.zScan` to convert.
/// The scanner itself is not duplicated here — `$fscanf` "reads from the file
/// specified by fd" what `$sscanf` reads from a string, so it is the same
/// formatter and codegen composes the two kernels rather than this file
/// importing one into the other's embedded text.
///
/// The empty slice is §9.5.4.2's EOF case by construction: `zScan` on no input
/// returns -1 when nothing was tried, which is "if the input ends before the
/// first matching failure or conversion, EOF is returned".
//
// ponytail: a LINE is consumed, where C's `fscanf` consumes only what the format
// matched. §9.5.4.2 fixes the return and the assignments and says nothing about
// the file position afterwards, and the difference is only observable through a
// `$ftell` between two scans. Matching C means pushing the tail back, which is
// `$ungetc`'s job — and §9.2 Table 9-2 marks that one analog-context "No".
pub fn zFRead(d: i64) []const u8 {
    return zFLine(zFGets(d), d);
}

/// §9.5.5 `pos = $ftell( fd )` — "the offset from the beginning of the file of
/// the current byte". "If an error occurs, EOF is returned"; EOF's value is
/// IEEE 1364's, i.e. -1.
pub fn zFTell(d: i64) i64 {
    const k = zfSlot(d) orelse return -1;
    return @intCast(zf_slots[k].pos);
}

/// §9.5.5 `code = $fseek( fd, offset, operation )` — "0 sets position equal to
/// offset bytes, 1 sets position to current location plus offset, 2 sets
/// position to EOF plus offset" — and the return is a STATUS, not a position:
/// "if an error occurs repositioning the file, then code is set to -1.
/// Otherwise, code is set to 0."
///
/// `$rewind` is the same kernel: "$rewind is equivalent to $fseek (fd,0,0)".
pub fn zFSeek(d: i64, off: i64, op: i64) i64 {
    const k = zfSlot(d) orelse return -1;
    const s = &zf_slots[k];
    const base: i64 = switch (op) {
        1 => @intCast(s.pos),
        2 => @intCast(s.f.length(zfIo()) catch {
            s.err = 5;
            return -1;
        }),
        else => 0,
    };
    const np = base + off;
    if (np < 0) {
        s.err = 22; // EINVAL
        zf_last_err = 22;
        return -1;
    }
    s.pos = @intCast(np);
    // §9.5.5: a reposition clears the end-of-file condition, which is why the
    // clause bothers to say $fseek and $rewind "undo the effect of any $ungetc".
    s.eof = false;
    s.err = 0;
    zf_last_err = 0;
    return 0;
}

/// §9.5.8 `code = $feof( fd )` — "returns a nonzero value when EOF has
/// previously been detected reading fd; returns zero otherwise."
pub fn zFEof(d: i64) i64 {
    const k = zfSlot(d) orelse return 0;
    return @intFromBool(zf_slots[k].eof);
}

/// §9.5.7 `errno = $ferror( fd, str )` — "the integral value of the error code
/// is returned in errno. If the most recent operation did not result in an
/// error, then the value returned shall be zero."
///
/// A descriptor of 0 is the one §9.5.1 sends here: "if a file cannot be opened
/// ... a zero is returned for the mcd or fd. Applications can call $ferror to
/// determine the cause of the most recent error."
pub fn zFError(d: i64) i64 {
    const k = zfSlot(d) orelse return zf_last_err;
    return zf_slots[k].err;
}

/// The description half. "A string description of type of error encountered by
/// the most recent file I/O operation is written into str"; and, when there was
/// none, "the string variable str shall be EMPTY" — which is what `e == 0` is.
pub fn zFErrorStr(e: i64, _: i64) []const u8 {
    return switch (e) {
        0 => "",
        2 => "no such file or directory",
        9 => "bad file descriptor",
        13 => "permission denied",
        21 => "is a directory",
        22 => "invalid argument",
        24 => "too many open files",
        28 => "no space left on device",
        else => "i/o error",
    };
}

/// §9.5.6 `$fflush( fd )` — "writes any buffered output to the file specified by
/// fd". Every write above is a positional write straight to the descriptor, so
/// there is never buffered output to flush and this is a no-op with nothing
/// hidden behind it. `$fflush` with no argument "writes any buffered output to
/// all open files", which is the same nothing.
pub fn zFFlush(_: i64) i64 {
    return 0;
}

/// §9.5.1 `$fclose( mcd )` / `$fclose( fd )`. Closing frees the channel for
/// reuse, which is the sentence `zFOpen`'s free-slot scan implements.
pub fn zFClose(d: i64) i64 {
    if (d == 0) return 0;
    if (d & (@as(i64, 1) << 31) != 0) {
        zfClose1(zfSlot(d) orelse return 0);
        return 0;
    }
    var b: u6 = 1;
    while (b <= zf_max) : (b += 1) {
        if (d & (@as(i64, 1) << b) == 0) continue;
        if (zf_slots[b - 1].open) zfClose1(b - 1);
    }
    return 0;
}

fn zfClose1(k: usize) void {
    zf_slots[k].f.close(zfIo());
    zf_slots[k].open = false;
}
