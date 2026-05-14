//! SSA construction (Braun et al., "Simple and Efficient Construction of
//! Static Single Assignment Form"): per-block variable writes and reads for
//! §5.8 conditionals and §5.9 loops → MIR Values and phis. Consumers must pass
//! every Value through `Mir.resolveAlias` (a collapsed phi is aliased, not
//! rewritten), and must treat `.phi` rows as block headers: a phi is minted on
//! demand, so its row can sit anywhere in the chain, even after the terminator.

const std = @import("std");
const Mir = @import("mir.zig");
const assert = std.debug.assert;

// Spelled out, not inferred: readVariable, readVariableRecursive and
// addPhiOperands are mutually recursive.
const Error = std.mem.Allocator.Error;

/// A "place" is an assignable location (a variable or a lowered temp).
pub const Place = enum(u32) { _ };

/// End-of-list sentinel for the intrusive pools. Not 0: index 0 is a real slot.
const list_end: u32 = std.math.maxInt(u32);

/// "No definition recorded for this (place, block)" in the `defs` matrix.
///
/// Not `Mir.Value.undef`, which is a legitimate stored result (a phi over only
/// self-references collapses to it); confusing the two would re-run the
/// recursive read and re-create the collapsed phi. Cells hold
/// `@intFromEnum(value) + 1` so a freshly mapped, all-zero page already reads
/// as empty. `writeVariable` asserts no overflow.
const absent: u32 = 0;

/// "This (place, block) is a join whose predecessors are being read right
/// now"; see the ≥2-preds arm of `readVariableRecursive`. A read that meets
/// it has come round a cycle and mints the phi there (`readVariable`). Never
/// a biased Value: `writeVariable` keeps the Value space two short of it.
const pending: u32 = std.math.maxInt(u32);

// `defs` is mapped straight from the OS, whose fresh pages are zero: that is
// the `absent` fill for free, and untouched cells never become resident.
// `std.heap.page_allocator` will not do: the `Allocator` interface poisons
// fresh bytes with 0xAA under runtime safety. `mapZeroed` canary-checks it.
const PageAllocator = std.heap.PageAllocator;

/// Braun-style SSA builder over one `Mir`. Blocks are created by the caller
/// (`Mir.addBlock`); the builder records edges, writes and reads, and emits
/// phis into the Mir as reads require.
pub const SsaBuilder = struct {
    gpa: std.mem.Allocator,
    mir: *Mir,
    /// (place, block) → Value as a dense place-major matrix:
    /// `defs[place * block_stride + block]`, `absent` (= 0) where unwritten and
    /// `@intFromEnum(value) + 1` where written. Dense because on large compact
    /// models the pairs are not sparse, and a hash map cost more in both time
    /// and memory. Place-major because the hot recursion walks predecessor
    /// blocks for one fixed place, so consecutive probes land in adjacent cells.
    defs: []u32 = &.{},
    /// Row length of `defs`: capacity along the block axis, not the live count.
    block_stride: u32 = 0,
    /// Rows allocated in `defs`: capacity along the place axis.
    place_cap: u32 = 0,
    /// Row per Mir.Block, grown lazily (lower.zig owns block creation).
    block_state: std.MultiArrayList(BlockState) = .empty,
    /// Flat pools; BlockState holds head/tail indices into them.
    pred_pool: std.ArrayList(PredNode) = .empty,
    incomplete_pool: std.ArrayList(IncompletePhi) = .empty,
    /// Phi def-use edges: for a Value, the phis that name it as an operand.
    /// Intrusive list like pred_pool; `user_head` is a dense array parallel to
    /// `Mir.defs` (index = value - first_dynamic), `list_end` = no users.
    /// Only the trivial-phi re-check reads it.
    user_pool: std.ArrayList(UserNode) = .empty,
    user_head: std.ArrayList(u32) = .empty,
    /// Shared phi-operand scratch, used with stack discipline (save length,
    /// restore on exit) so re-entrant lowering needs no per-phi allocation.
    scratch: std.ArrayList(Mir.PhiPair) = .empty,
    /// Trivial-phi worklist, with the same save/restore discipline as `scratch`.
    phi_work: std.ArrayList(Mir.Value) = .empty,
    next_place: u32 = 0,

    /// Per-block SSA state, one row per `Mir.Block`.
    pub const BlockState = struct {
        /// Braun: sealed ⇒ this block's predecessor set is final.
        sealed: bool = false,
        preds_head: u32 = list_end,
        preds_tail: u32 = list_end,
        /// Kept beside the list so `readVariableRecursive`'s single-predecessor
        /// test is a load, not a walk.
        preds_len: u32 = 0,
        /// Phis created before the block was sealed; filled by `sealBlock`.
        phis_head: u32 = list_end,
    };

    const PredNode = struct { block: Mir.Block, next: u32 };
    const IncompletePhi = struct { place: Place, value: Mir.Value, next: u32 };
    const UserNode = struct { phi: Mir.Value, next: u32 };

    /// Returns an empty builder writing into `mir`. `gpa` backs the scratch
    /// tables; call `deinit` to free them.
    pub fn init(gpa: std.mem.Allocator, mir: *Mir) SsaBuilder {
        return .{ .gpa = gpa, .mir = mir };
    }

    /// Frees builder scratch only; the MIR it wrote into is untouched.
    pub fn deinit(self: *SsaBuilder) void {
        unmapMatrix(self.defs);
        self.block_state.deinit(self.gpa);
        self.pred_pool.deinit(self.gpa);
        self.incomplete_pool.deinit(self.gpa);
        self.user_pool.deinit(self.gpa);
        self.user_head.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
        self.phi_work.deinit(self.gpa);
        self.* = .{ .gpa = self.gpa, .mir = self.mir };
    }

    /// Returns a fresh assignable location (a §3.4.4 variable or a lowered
    /// temporary).
    pub fn newPlace(self: *SsaBuilder) Place {
        defer self.next_place += 1;
        return @enumFromInt(self.next_place);
    }

    // ------------------------------------------------------------- CFG edges --

    /// Declares the CFG edge `pred → block` (§5.8, §5.9).
    /// Asserts that `block` is not sealed yet, and that both blocks exist.
    pub fn addPredecessor(self: *SsaBuilder, block: Mir.Block, pred: Mir.Block) Error!void {
        const b = try self.ensureState(block);
        assert(!self.block_state.items(.sealed)[b]); // preds are final once sealed
        _ = try self.ensureState(pred);

        const node: u32 = @intCast(self.pred_pool.items.len);
        try self.pred_pool.append(self.gpa, .{ .block = pred, .next = list_end });
        const tail = self.block_state.items(.preds_tail)[b];
        if (tail == list_end) {
            self.block_state.items(.preds_head)[b] = node;
        } else {
            self.pred_pool.items[tail].next = node;
        }
        self.block_state.items(.preds_tail)[b] = node;
        self.block_state.items(.preds_len)[b] += 1;
    }

    /// Marks a block's predecessors final and fills every incomplete phi.
    /// Idempotent. Asserts that `block` exists.
    pub fn sealBlock(self: *SsaBuilder, block: Mir.Block) Error!void {
        const b = try self.ensureState(block);
        if (self.block_state.items(.sealed)[b]) return;
        // Seal FIRST: a recursive read that comes back here while we fill must
        // take the (now final) predecessor path instead of queueing another
        // incomplete phi onto the list we are walking.
        self.block_state.items(.sealed)[b] = true;

        var node = self.block_state.items(.phis_head)[b];
        self.block_state.items(.phis_head)[b] = list_end;
        while (node != list_end) {
            const rec = self.incomplete_pool.items[node]; // copy: recursion may realloc
            node = rec.next;
            _ = try self.addPhiOperands(rec.place, rec.value, block);
        }
    }

    // ------------------------------------------------------- read / write --

    /// Records the §5.7 assignment `place := value` in `block`.
    pub fn writeVariable(self: *SsaBuilder, place: Place, block: Mir.Block, value: Mir.Value) Error!void {
        // see `absent` and `pending`: the +1 bias lands on neither
        assert(@intFromEnum(value) < std.math.maxInt(u32) - 1);
        const i = try self.defsIndex(place, block);
        self.defs[i] = @intFromEnum(value) + 1;
    }

    /// Returns the value of `place` in `block`, emitting phis as needed. A place
    /// undefined on some path yields `.undef` there; initializing declared
    /// variables (§3.4.4) is the caller's job.
    pub fn readVariable(self: *SsaBuilder, place: Place, block: Mir.Block) Error!Mir.Value {
        const raw = self.defsRaw(place, block);
        if (raw == absent) return self.readVariableRecursive(place, block);
        if (raw != pending) return @enumFromInt(raw - 1);
        // The read came round a cycle (§5.9) into a join whose predecessors
        // are still being read: the join needs a real phi after all. Mint it
        // empty; the frame that set `pending` fills it.
        const phi = try self.mir.emitPhi(self.gpa, block, &.{});
        try self.writeVariable(place, block, phi);
        return phi;
    }

    /// Load without growing: an unallocated cell reads as absent, exactly like an
    /// allocated-but-unwritten one. Keeps the read path free of the resize branch.
    fn defsRaw(self: *const SsaBuilder, place: Place, block: Mir.Block) u32 {
        const p = @intFromEnum(place);
        const b = @intFromEnum(block);
        if (p >= self.place_cap or b >= self.block_stride) return absent;
        return self.defs[@as(usize, p) * self.block_stride + b];
    }

    fn defsPeek(self: *const SsaBuilder, place: Place, block: Mir.Block) ?Mir.Value {
        const v = self.defsRaw(place, block);
        assert(v != pending);
        return if (v == absent) null else @enumFromInt(v - 1);
    }

    /// `n` cells of `absent`, for free (see `PageAllocator`). The assert is a
    /// canary that the zero-page guarantee still holds.
    fn mapZeroed(n: usize) Error![]u32 {
        const bytes = std.math.mul(usize, n, @sizeOf(u32)) catch return error.OutOfMemory;
        const p = PageAllocator.map(bytes, .of(u32)) orelse return error.OutOfMemory;
        const buf = @as([*]u32, @ptrCast(@alignCast(p)))[0..n];
        assert(buf[0] == absent and buf[n - 1] == absent);
        return buf;
    }

    fn unmapMatrix(defs: []u32) void {
        if (defs.len == 0) return;
        const p: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(defs.ptr));
        PageAllocator.unmap(p[0 .. defs.len * @sizeOf(u32)]);
    }

    /// Index of (place, block), growing the matrix to cover it. Both axes grow
    /// geometrically: exact growth on either axis is quadratic.
    fn defsIndex(self: *SsaBuilder, place: Place, block: Mir.Block) Error!usize {
        const p = @intFromEnum(place);
        const b = @intFromEnum(block);

        if (b >= self.block_stride) {
            const new_stride = @max(b + 1, @max(self.block_stride * 2, 16));
            const new_cap = @max(self.place_cap, 1);
            const grown = try mapZeroed(@as(usize, new_cap) * new_stride);
            // Unminted rows are zero already; copying them would fault in pages.
            var row: usize = 0;
            while (row < @min(self.place_cap, self.next_place)) : (row += 1) {
                const src = self.defs[row * self.block_stride ..][0..self.block_stride];
                @memcpy(grown[row * new_stride ..][0..self.block_stride], src);
            }
            unmapMatrix(self.defs);
            self.defs = grown;
            self.block_stride = new_stride;
            self.place_cap = new_cap;
        }
        if (p >= self.place_cap) {
            const new_cap = @max(p + 1, @max(self.place_cap * 2, 16));
            // Appending rows moves nothing, so this is one flat copy. It is a
            // fresh mapping rather than a `realloc` because an in-place resize
            // would hand back tail bytes with no zero guarantee (see `absent`).
            const grown = try mapZeroed(@as(usize, new_cap) * self.block_stride);
            @memcpy(grown[0..self.defs.len], self.defs);
            unmapMatrix(self.defs);
            self.defs = grown;
            self.place_cap = new_cap;
        }
        return @as(usize, p) * self.block_stride + b;
    }

    /// Braun §readVariableRecursive. Every path memoizes its result with
    /// `writeVariable`, which is also what breaks cycles on the loop path.
    // ponytail: recursive, with depth a CFG chain length (the single-predecessor
    // arm), not a nesting depth. Ceiling: one frame per block on the first read
    // of a place, so ~10⁵ sequential `if`s in one module would blow the stack.
    // The fix is an explicit stack with a resume state for the ≥2-preds arm.
    fn readVariableRecursive(self: *SsaBuilder, place: Place, block: Mir.Block) Error!Mir.Value {
        const b = try self.ensureState(block);

        var val: Mir.Value = undefined;
        if (!self.block_state.items(.sealed)[b]) {
            // Preds not final yet (loop header, §5.9): incomplete phi, filled by sealBlock.
            val = try self.mir.emitPhi(self.gpa, block, &.{});
            const node: u32 = @intCast(self.incomplete_pool.items.len);
            try self.incomplete_pool.append(self.gpa, .{
                .place = place,
                .value = val,
                .next = self.block_state.items(.phis_head)[b],
            });
            self.block_state.items(.phis_head)[b] = node;
        } else if (self.predCount(block) == 1) {
            const head = self.predsHead(block);
            assert(head != list_end);
            val = try self.readVariable(place, self.pred_pool.items[head].block);
        } else {
            // ≥2 preds (or 0: an undefined read in a source-less block).
            //
            // Braun emits the phi first and collapses a trivial one by aliasing,
            // which leaves a dead row behind; on a compact model with long `if`
            // chains nearly every phi row was dead. So the cell is marked
            // `pending` instead, and a phi is emitted only when a read cycles
            // back here (`readVariable` mints it) or the predecessors disagree.
            // An acyclic trivial join gets no row at all.
            const cell = try self.defsIndex(place, block);
            self.defs[cell] = pending;
            const top = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(top);
            try self.readPreds(place, block);
            const pairs = self.scratch.items[top..];
            // Re-index: the reads may have re-strided the matrix.
            const now = self.defs[try self.defsIndex(place, block)];
            if (now != pending) {
                val = try self.fillPhi(@enumFromInt(now - 1), pairs);
            } else if (sameValue(self.mir, pairs)) |same| {
                val = same;
            } else {
                val = try self.mir.emitPhi(self.gpa, block, pairs);
                for (pairs) |p| try self.addUser(p.value, val);
            }
        }
        try self.writeVariable(place, block, val);
        return val;
    }

    /// Braun §addPhiOperands: one operand per predecessor edge, then collapse.
    fn addPhiOperands(self: *SsaBuilder, place: Place, phi: Mir.Value, block: Mir.Block) Error!Mir.Value {
        // One shared scratch used as a stack: this is re-entrant (readVariable
        // recurses back in), and a list per phi would allocate per phi.
        const top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(top);
        try self.readPreds(place, block);
        return self.fillPhi(phi, self.scratch.items[top..]);
    }

    /// Append `(pred, place's value at the end of pred)` to `scratch` for every
    /// predecessor edge of `block`, in declaration order.
    fn readPreds(self: *SsaBuilder, place: Place, block: Mir.Block) Error!void {
        var node = self.predsHead(block);
        while (node != list_end) {
            const pred = self.pred_pool.items[node]; // copy: recursion may realloc
            node = pred.next;
            const v = try self.readVariable(place, pred.block);
            try self.scratch.append(self.gpa, .{ .block = pred.block, .value = v });
        }
    }

    fn fillPhi(self: *SsaBuilder, phi: Mir.Value, pairs: []const Mir.PhiPair) Error!Mir.Value {
        try self.mir.setPhiPairs(self.gpa, self.mir.valueDef(phi).inst_result, pairs);
        for (pairs) |p| try self.addUser(p.value, phi);
        return self.tryRemoveTrivialPhi(phi);
    }

    /// The one value every pair resolves to (`.undef` for no pairs), or null
    /// when they disagree: `tryRemoveTrivialPhi`'s rule for a phi that does
    /// not exist yet, so there is no self-reference to skip.
    fn sameValue(mir: *const Mir, pairs: []const Mir.PhiPair) ?Mir.Value {
        if (pairs.len == 0) return .undef;
        const first = mir.resolveAlias(pairs[0].value);
        for (pairs[1..]) |p| if (mir.resolveAlias(p.value) != first) return null;
        return first;
    }

    /// Collapse a phi whose operands all resolve to one value (self-references
    /// ignored) to that value. Braun §tryRemoveTrivialPhi.
    ///
    /// Users are rerouted by aliasing, not rewriting: operand lists keep naming
    /// the dead phi and consumers resolve through `Mir.resolveAlias`. Dependent
    /// phis are then re-checked.
    //
    // An explicit worklist, not Braun's recursion: the recursion follows the
    // phi def-use graph, whose depth nothing syntactic bounds. It must match
    // the recursive form exactly, since the alias table decides the emitted
    // bytes:
    //   - Return: the recursion fixes `repl` for the root before descending and
    //     discards every nested result, so returning the first iteration's
    //     result is the same whatever the drain order.
    //   - Order: users are appended in list order and reversed, so the LIFO pops
    //     them head to tail and a popped phi's users drain before its siblings,
    //     the recursion's pre-order DFS. `hasAlias` is tested at pop time, as the
    //     recursion re-tests it after each sibling's subtree. Nothing on this
    //     path calls `addUser`, so `user_pool` cannot move mid-walk.
    //   - Termination: only the branch that just called `setAlias` pushes, and
    //     aliases are never cleared, so each phi pushes its users at most once.
    fn tryRemoveTrivialPhi(self: *SsaBuilder, phi: Mir.Value) Error!Mir.Value {
        // Stack discipline like `scratch`: this runs under re-entrant lowering.
        const top = self.phi_work.items.len;
        defer self.phi_work.shrinkRetainingCapacity(top);

        var root_repl: ?Mir.Value = null;
        var cur = phi; // the root is processed unconditionally, as in the recursion
        while (true) {
            const inst = self.mir.valueDef(cur).inst_result;
            assert(self.mir.instOp(inst) == .phi);

            var same: ?Mir.Value = null;
            const count = self.mir.instData(inst).phi.count;
            var i: u32 = 0;
            const repl = while (i < count) : (i += 1) {
                const op = self.mir.resolveAlias(self.mir.phiPair(inst, i).value);
                if (op == cur) continue; // self-reference (loop back edge)
                if (same) |s| {
                    if (op == s) continue;
                    break cur; // merges ≥2 distinct values ⇒ a real phi
                }
                same = op;
            } else same orelse Mir.Value.undef; // no operands / only self-refs ⇒ undefined

            if (repl != cur) {
                self.mir.setAlias(cur, repl);
                // Queue only the phis that named `cur` as an operand: they may now
                // be trivial. Walking every phi here dominated runtime.
                const mark = self.phi_work.items.len;
                var node = self.userHead(cur);
                while (node != list_end) {
                    const u = self.user_pool.items[node];
                    node = u.next;
                    try self.phi_work.append(self.gpa, u.phi);
                }
                // ponytail: append-then-reverse, because `user_pool` is singly
                // linked and cannot be walked backwards. Ceiling is one extra
                // pass over one phi's users; if that ever shows up in a profile
                // the fix is a tail pointer per value, not a smarter reversal.
                std.mem.reverse(Mir.Value, self.phi_work.items[mark..]);
            }
            if (root_repl == null) root_repl = repl;

            cur = while (self.phi_work.items.len > top) {
                const u = self.phi_work.pop().?;
                if (!self.mir.hasAlias(u)) break u;
            } else return root_repl.?;
        }
    }

    // ---------------------------------------------------------- internals --

    fn ensureState(self: *SsaBuilder, block: Mir.Block) Error!u32 {
        const i = @intFromEnum(block);
        assert(i < self.mir.blockCount());
        while (self.block_state.len <= i) try self.block_state.append(self.gpa, .{});
        return i;
    }

    /// Record "`user` (a phi) reads `value`". Sentinels never collapse, so they
    /// get no list.
    fn addUser(self: *SsaBuilder, value: Mir.Value, user: Mir.Value) Error!void {
        const i = @intFromEnum(value);
        if (i < Mir.Value.first_dynamic) return;
        const slot = i - Mir.Value.first_dynamic;
        while (self.user_head.items.len <= slot) try self.user_head.append(self.gpa, list_end);
        const node: u32 = @intCast(self.user_pool.items.len);
        try self.user_pool.append(self.gpa, .{ .phi = user, .next = self.user_head.items[slot] });
        self.user_head.items[slot] = node;
    }

    fn userHead(self: *const SsaBuilder, value: Mir.Value) u32 {
        const i = @intFromEnum(value);
        if (i < Mir.Value.first_dynamic) return list_end;
        const slot = i - Mir.Value.first_dynamic;
        if (slot >= self.user_head.items.len) return list_end;
        return self.user_head.items[slot];
    }

    fn predsHead(self: *const SsaBuilder, block: Mir.Block) u32 {
        const b = @intFromEnum(block);
        if (b >= self.block_state.len) return list_end;
        return self.block_state.items(.preds_head)[b];
    }

    fn predCount(self: *const SsaBuilder, block: Mir.Block) u32 {
        const b = @intFromEnum(block);
        if (b >= self.block_state.len) return 0;
        return self.block_state.items(.preds_len)[b];
    }
};

// -------------------------------------------------------------------------

test "ssa: diamond phi, trivial collapse, loop phi, undefined read" {
    const gpa = std.testing.allocator;
    var mir: Mir = .{ .name = "ssa_selfcheck" };
    defer mir.deinit(gpa);
    var b = SsaBuilder.init(gpa, &mir);
    defer b.deinit();

    //        entry
    //        /   \
    //     then   else       (LRM §5.8 conditional)
    //        \   /
    //         join
    const entry = try mir.addBlock(gpa);
    const then_b = try mir.addBlock(gpa);
    const else_b = try mir.addBlock(gpa);
    const join = try mir.addBlock(gpa);

    try b.sealBlock(entry); // no predecessors
    try b.addPredecessor(then_b, entry);
    try b.addPredecessor(else_b, entry);
    try b.sealBlock(then_b);
    try b.sealBlock(else_b);
    try b.addPredecessor(join, then_b);
    try b.addPredecessor(join, else_b);
    try b.sealBlock(join);

    const x = b.newPlace();
    const y = b.newPlace();
    const c1 = try mir.addFloatConst(gpa, 1.0);
    const c2 = try mir.addFloatConst(gpa, 2.0);
    const y0 = try mir.addFloatConst(gpa, 7.0);

    try b.writeVariable(y, entry, y0);
    try b.writeVariable(x, then_b, c1);
    try b.writeVariable(x, else_b, c2);

    // x differs per arm ⇒ a real phi, operands in predecessor-declaration order.
    const xj = try b.readVariable(x, join);
    try std.testing.expectEqual(xj, mir.resolveAlias(xj));
    const x_inst = mir.valueDef(xj).inst_result;
    try std.testing.expectEqual(Mir.Opcode.phi, mir.instOp(x_inst));
    try std.testing.expectEqual(@as(u32, 2), mir.instData(x_inst).phi.count);
    try std.testing.expectEqual(c1, mir.phiPair(x_inst, 0).value);
    try std.testing.expectEqual(then_b, mir.phiPair(x_inst, 0).block);
    try std.testing.expectEqual(c2, mir.phiPair(x_inst, 1).value);

    // y is the same on both arms ⇒ the join is trivial: y0 itself, and no phi
    // row at all (x's is the join's only one).
    const yj = try b.readVariable(y, join);
    try std.testing.expectEqual(y0, yj);
    {
        var it = mir.blockInsts(join);
        try std.testing.expectEqual(x_inst, it.next().?);
        try std.testing.expect(it.next() == null);
    }

    // Reading x again is memoized, not a second phi.
    try std.testing.expectEqual(xj, try b.readVariable(x, join));

    //   join → header ⇄ body        (LRM §5.9 loop: header sealed only after the
    //             ↘ exit             back edge exists)
    const header = try mir.addBlock(gpa);
    const body = try mir.addBlock(gpa);

    const i_pl = b.newPlace();
    const i_init = try mir.addIntConst(gpa, 0);
    try b.writeVariable(i_pl, join, i_init);

    try b.addPredecessor(header, join);
    try b.addPredecessor(body, header);
    try b.sealBlock(body);

    // Read before the header is sealed ⇒ INCOMPLETE phi in the header.
    const iv = try b.readVariable(i_pl, body);
    const i_inst = mir.valueDef(iv).inst_result;
    try std.testing.expectEqual(Mir.Opcode.phi, mir.instOp(i_inst));
    try std.testing.expectEqual(@as(u32, 0), mir.instData(i_inst).phi.count);

    const i_next = try mir.emit(gpa, body, .iadd, &.{ iv, .one });
    try b.writeVariable(i_pl, body, i_next);
    const yb = try b.readVariable(y, body); // loop-invariant ⇒ trivial header phi

    try b.addPredecessor(header, body); // back edge
    try b.sealBlock(header);

    // The induction variable's phi is real: {join: 0, body: i+1}.
    try std.testing.expectEqual(iv, mir.resolveAlias(iv));
    try std.testing.expectEqual(@as(u32, 2), mir.instData(i_inst).phi.count);
    try std.testing.expectEqual(i_init, mir.phiPair(i_inst, 0).value);
    try std.testing.expectEqual(join, mir.phiPair(i_inst, 0).block);
    try std.testing.expectEqual(i_next, mir.phiPair(i_inst, 1).value);
    try std.testing.expectEqual(body, mir.phiPair(i_inst, 1).block);

    // y's header phi is {join: <collapsed join phi>, body: itself} ⇒ collapses,
    // transitively through the already-aliased join phi, all the way to y0.
    try std.testing.expect(yb != y0);
    try std.testing.expectEqual(y0, mir.resolveAlias(yb));

    // Never written anywhere ⇒ undef, not a live phi.
    const z = b.newPlace();
    try std.testing.expectEqual(Mir.Value.undef, mir.resolveAlias(try b.readVariable(z, join)));

    // A read that enters the SEALED loop from below cycles back into the
    // header through the body: the pending header mints its phi, and the phi
    // collapses onto the value from outside the loop.
    const w = b.newPlace();
    const w0 = try mir.addFloatConst(gpa, 3.0);
    try b.writeVariable(w, join, w0);
    const exit = try mir.addBlock(gpa);
    try b.addPredecessor(exit, header);
    try b.sealBlock(exit);
    try std.testing.expectEqual(w0, mir.resolveAlias(try b.readVariable(w, exit)));
}

test "ssa: matrix growth preserves values, undefined cells and unused rows" {
    const gpa = std.testing.allocator;
    var mir: Mir = .{ .name = "ssa_growth" };
    defer mir.deinit(gpa);
    var b = SsaBuilder.init(gpa, &mir);
    defer b.deinit();

    const entry = try mir.addBlock(gpa);
    const x = b.newPlace();
    const y = b.newPlace();
    try b.writeVariable(x, entry, .f_one);
    try b.writeVariable(y, entry, .undef);
    var last = entry;
    for (0..16) |_| last = try mir.addBlock(gpa);
    try b.writeVariable(x, last, .f_two); // grow the block axis with spare rows
    try std.testing.expectEqual(Mir.Value.f_one, try b.readVariable(x, entry));
    try std.testing.expectEqual(Mir.Value.undef, try b.readVariable(y, entry));
    try std.testing.expectEqual(Mir.Value.f_two, try b.readVariable(x, last));
    try std.testing.expectEqual(null, b.defsPeek(y, last));

    const z = b.newPlace(); // this row was not copied during block growth
    try std.testing.expectEqual(null, b.defsPeek(z, entry));
    try std.testing.expectEqual(null, b.defsPeek(z, last));
    try b.writeVariable(z, last, .f_neg_one);
    const old_cap = b.place_cap;
    while (b.next_place <= old_cap) {
        try b.writeVariable(b.newPlace(), entry, .f_two); // grow the place axis
    }
    try std.testing.expectEqual(Mir.Value.f_one, try b.readVariable(x, entry));
    try std.testing.expectEqual(Mir.Value.undef, try b.readVariable(y, entry));
    try std.testing.expectEqual(Mir.Value.f_two, try b.readVariable(x, last));
    try std.testing.expectEqual(Mir.Value.f_neg_one, try b.readVariable(z, last));
    try std.testing.expectEqual(null, b.defsPeek(z, entry));
    try std.testing.expectEqual(null, b.defsPeek(y, last));
}
