//! SSA construction (Braun et al., "Simple and Efficient Construction of
//! Static Single Assignment Form"): per-block variable writes and reads for
//! §5.8 conditionals and §5.9 loops → MIR Values and phis. Consumers must pass
//! every Value through `Mir.resolveAlias` (a collapsed phi is aliased, not
//! rewritten), and must treat `.phi` rows as block headers: a phi is minted on
//! demand, so its row can sit anywhere in the chain, even after the terminator.

const std = @import("std");
const Mir = @import("mir.zig");
const assert = std.debug.assert;

// Spelled out, not inferred: readFrom, readVariableRecursive and
// addPhiOperands are mutually recursive.
const Error = std.mem.Allocator.Error;

/// A "place" is an assignable location (a variable or a lowered temp).
pub const Place = enum(u32) { _ };

/// End-of-list sentinel for the intrusive pools. Not 0: index 0 is a real slot.
const list_end: u32 = std.math.maxInt(u32);

/// "No definition recorded for this (place, block)" in the builder's map.
///
/// Not `Mir.Value.undef`, which is a legitimate stored result (a phi over only
/// self-references collapses to it); confusing the two would re-run the
/// recursive read and re-create the collapsed phi. Cells hold
/// `@intFromEnum(value) + 1` so a zeroed chunk already reads as empty.
/// `writeVariable` asserts no overflow.
const absent: u32 = 0;

/// "This (place, block) is a join whose predecessors are being read right
/// now"; see the ≥2-preds arm of `readVariableRecursive`. A read that meets
/// it has come round a cycle and mints the phi there (`readFrom`). Never
/// a biased Value: `writeVariable` keeps the Value space two short of it.
const pending: u32 = std.math.maxInt(u32);

/// log2 of the cells per chunk of the `(place, slot)` map. A chunk is the
/// unit that becomes resident, so this is the map's memory granularity: 64
/// cells (256 B) against the 1024 of a 4 KiB page. A place's cells cluster
/// along the slots between its definition and its last read, so finer
/// chunks keep the map near its written cells and coarser ones only add
/// zeros; a narrower one makes the directory, which is dense, grow instead.
/// Measured on the memo cells psp103 and hisimhv_va leave behind: 64 cells
/// fill 70-77%, 16 fill 89-92% but double the directory, which costs more
/// than the zeros it saves.
const chunk_bits = 6;
const chunk_len = 1 << chunk_bits;

/// `BlockState.slot` of a block with no memo cell yet.
const no_slot: u32 = std.math.maxInt(u32);
/// `BlockState.slot` of a block whose cells live in `arm_cells`, not the map.
const arm_slot: u32 = no_slot - 1;

/// The builder's own tables (the map, the predecessor and phi-user pools,
/// the per-block state) live outside the caller's allocator: lowering passes
/// its compilation arena, which frees nothing before the compile ends, and
/// these are scratch for the lowering phase alone. `deinit` frees them.
/// `gpa` is for the MIR the builder writes into.
const map_gpa = std.heap.page_allocator;

/// Braun-style SSA builder over one `Mir`. Blocks are created by the caller
/// (`Mir.addBlock`); the builder records edges, writes and reads, and emits
/// phis into the Mir as reads require.
pub const SsaBuilder = struct {
    gpa: std.mem.Allocator,
    mir: *Mir,
    /// (place, slot) → Value as a two-level place-major table: `dir[place *
    /// dir_stride + slot >> chunk_bits]` names a `chunk_len`-cell chunk of
    /// `cells`, and the cell is `slot`'s low bits within it. A cell holds
    /// `absent` (= 0) where unwritten and `@intFromEnum(value) + 1` where
    /// written. Chunk 0 is all `absent` and never written: every directory
    /// entry starts on it, so a read needs no presence test.
    ///
    /// The column is a block's `slot`, numbered in order of its first memo
    /// cell, not the block itself: `readFrom` memoizes only in joins, so
    /// keyed by block a place's cells sat one block in three (the arms in
    /// between) and the chunks were 29% full. Numbered by slot they are
    /// 70-77% full, and the map is a third the size (psp103 9.2 → 3.7 MB,
    /// hisimhv_va 13.3 → 5.2 MB): the largest table alive while lowering.
    ///
    /// Two-level, not one dense matrix: a place has cells only between its
    /// definition and its last read. The dense matrix touched each page that
    /// held one cell, and regrowing it copied every row whole, zeros
    /// included, while the old copy was still mapped: a 100 MB transient on
    /// psp103. A hash map cost more in both time and memory. Place-major
    /// because a read climbs predecessor blocks for one fixed place, so
    /// consecutive probes land in one chunk.
    dir: []u32 = &.{},
    /// Directory row length: chunks per place, capacity along the slot axis.
    dir_stride: u32 = 0,
    /// Directory rows: capacity along the place axis.
    place_cap: u32 = 0,
    /// The chunks, `chunk_len` cells each, appended as first written.
    cells: std.ArrayList(u32) = .empty,
    /// Slots handed out so far; the next block to need one gets this.
    next_slot: u32 = 0,
    /// The cells of arm blocks (sealed, one predecessor; `arm_slot`): a
    /// short list per block, headed by `BlockState.arm_head`. Only lowering
    /// writes there (an assignment inside an `if` arm), so a slot each would
    /// put back the gaps the slot numbering removes: psp103 has 3396 such
    /// cells, hisimhv_va 6955, a few per arm.
    arm_cells: std.ArrayList(ArmCell) = .empty,
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
    /// Places handed out so far (`newPlace`); directory rows past it are
    /// all chunk 0.
    next_place: u32 = 0,

    /// Per-block SSA state, one row per `Mir.Block`.
    pub const BlockState = struct {
        /// Braun: sealed ⇒ this block's predecessor set is final.
        sealed: bool = false,
        preds_head: u32 = list_end,
        preds_tail: u32 = list_end,
        /// Kept beside the list so `readFrom`'s single-predecessor
        /// test is a load, not a walk.
        preds_len: u32 = 0,
        /// Phis created before the block was sealed; filled by `sealBlock`.
        phis_head: u32 = list_end,
        /// The block's column in the memo map, fixed at its first cell:
        /// `no_slot` before that, `arm_slot` when its cells are `arm_cells`.
        slot: u32 = no_slot,
        /// The block's first `arm_cells` node, or `list_end`.
        arm_head: u32 = list_end,
        /// Bit `place % 32` set for every place in the block's `arm_cells`:
        /// a climb through an arm skips the list for a place it never wrote.
        arm_mask: u32 = 0,
    };

    const PredNode = struct { block: Mir.Block, next: u32 };
    /// One memo cell of an arm block (`raw` as in `cells`).
    const ArmCell = struct { place: Place, raw: u32, next: u32 };
    const IncompletePhi = struct { place: Place, value: Mir.Value, next: u32 };
    const UserNode = struct { phi: Mir.Value, next: u32 };

    // Row budgets: per block (psp103 4,234), per pool node (psp103: 5,682
    // edges, 4,997 phi users, 3,396 arm cells).
    comptime {
        assert(std.MultiArrayList(BlockState).capacityInBytes(1) == 29);
        assert(@sizeOf(PredNode) == 8);
        assert(@sizeOf(IncompletePhi) == 12);
        assert(@sizeOf(UserNode) == 8);
        assert(@sizeOf(ArmCell) == 12);
    }

    /// Returns an empty builder writing into `mir`, whose rows (phis) `gpa`
    /// allocates. Call `deinit` to free the builder's own tables.
    pub fn init(gpa: std.mem.Allocator, mir: *Mir) SsaBuilder {
        return .{ .gpa = gpa, .mir = mir };
    }

    /// Frees builder scratch only; the MIR it wrote into is untouched.
    pub fn deinit(self: *SsaBuilder) void {
        map_gpa.free(self.dir);
        self.cells.deinit(map_gpa);
        self.arm_cells.deinit(map_gpa);
        self.block_state.deinit(map_gpa);
        self.pred_pool.deinit(map_gpa);
        self.incomplete_pool.deinit(map_gpa);
        self.user_pool.deinit(map_gpa);
        self.user_head.deinit(map_gpa);
        self.scratch.deinit(map_gpa);
        self.phi_work.deinit(map_gpa);
        self.* = .{ .gpa = self.gpa, .mir = self.mir };
    }

    /// Returns a fresh assignable location (a §3.4.4 variable or a lowered
    /// temporary).
    pub fn newPlace(self: *SsaBuilder) Place {
        defer self.next_place += 1;
        return @fromBackingInt(@intCast(self.next_place));
    }

    // ------------------------------------------------------------- CFG edges --

    /// Declares the CFG edge `pred → block` (§5.8, §5.9).
    /// Asserts that `block` is not sealed yet, and that both blocks exist.
    pub fn addPredecessor(self: *SsaBuilder, block: Mir.Block, pred: Mir.Block) Error!void {
        const b = try self.ensureState(block);
        assert(!self.block_state.items(.sealed)[b]); // preds are final once sealed
        _ = try self.ensureState(pred);

        const node: u32 = @intCast(self.pred_pool.items.len);
        try self.pred_pool.append(map_gpa, .{ .block = pred, .next = list_end });
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
        assert(@backingInt(value) < std.math.maxInt(u32) - 1);
        const b = try self.ensureState(block);
        const raw = @backingInt(value) + 1;
        const slot = self.slotOf(b);
        if (slot != arm_slot) {
            self.cells.items[try self.cellIndex(place, slot)] = raw;
            return;
        }
        const head = &self.block_state.items(.arm_head)[b];
        var node = head.*;
        while (node != list_end) : (node = self.arm_cells.items[node].next) {
            if (self.arm_cells.items[node].place == place) {
                self.arm_cells.items[node].raw = raw;
                return;
            }
        }
        const new: u32 = @intCast(self.arm_cells.items.len);
        try self.arm_cells.append(map_gpa, .{ .place = place, .raw = raw, .next = head.* });
        self.block_state.items(.arm_head)[b] = new;
        self.block_state.items(.arm_mask)[b] |= armBit(place);
    }

    /// Returns the value of `place` in `block`, emitting phis as needed. A place
    /// undefined on some path yields `.undef` there; initializing declared
    /// variables (§3.4.4) is the caller's job.
    pub fn readVariable(self: *SsaBuilder, place: Place, block: Mir.Block) Error!Mir.Value {
        _ = try self.ensureState(block);
        return self.readFrom(place, block);
    }

    /// `readVariable` for a block that has a `block_state` row. Every block it
    /// reaches has one too: `addPredecessor` gives each predecessor a row.
    fn readFrom(self: *SsaBuilder, place: Place, block: Mir.Block) Error!Mir.Value {
        // A sealed block with one predecessor reads what that predecessor
        // ends with, so the walk climbs through it and memoizes nothing
        // there: two thirds of Braun's memo writes landed in such blocks (the
        // arms of every `if`), and skipping them is 4-5% of a compact
        // model's whole compile (callgrind, psp103/bsim4va/hisimhv_va). It
        // also makes the climb a loop, so a long single-predecessor chain no
        // longer costs a stack frame per block.
        assert(@backingInt(block) < self.block_state.len);
        const sealed = self.block_state.items(.sealed);
        const preds_len = self.block_state.items(.preds_len);
        const preds_head = self.block_state.items(.preds_head);
        const slots = self.block_state.items(.slot);
        var b = block;
        while (true) {
            const raw = self.cellRaw(place, @backingInt(b), slots[@backingInt(b)]);
            if (raw == pending) {
                // The read came round a cycle (§5.9) into a join whose
                // predecessors are still being read: the join needs a real
                // phi after all. Mint it empty; the frame that set `pending`
                // fills it.
                const phi = try self.mir.emitPhi(self.gpa, b, &.{});
                try self.writeVariable(place, b, phi);
                return phi;
            }
            if (raw != absent) return @fromBackingInt(@intCast(raw - 1));
            const i = @backingInt(b);
            if (!sealed[i] or preds_len[i] != 1) return self.readVariableRecursive(place, b);
            b = self.pred_pool.items[preds_head[i]].block;
        }
    }

    /// Load without growing: an unallocated cell reads as absent, exactly like an
    /// allocated-but-unwritten one. Keeps the read path free of the resize branch.
    fn defsRaw(self: *const SsaBuilder, place: Place, block: Mir.Block) u32 {
        const b = @backingInt(block);
        if (b >= self.block_state.len) return absent;
        return self.cellRaw(place, b, self.block_state.items(.slot)[b]);
    }

    fn armBit(place: Place) u32 {
        return @as(u32, 1) << @truncate(@backingInt(place));
    }

    /// `defsRaw` for block row `b`, whose slot the caller has read.
    fn cellRaw(self: *const SsaBuilder, place: Place, b: u32, slot: u32) u32 {
        const p = @backingInt(place);
        if (slot == no_slot) return absent;
        if (slot == arm_slot) {
            if (self.block_state.items(.arm_mask)[b] & armBit(place) == 0) return absent;
            var node = self.block_state.items(.arm_head)[b];
            while (node != list_end) : (node = self.arm_cells.items[node].next) {
                const c = self.arm_cells.items[node];
                if (c.place == place) return c.raw;
            }
            return absent;
        }
        if (p >= self.place_cap or slot >> chunk_bits >= self.dir_stride) return absent;
        const chunk: usize = self.dir[@as(usize, p) * self.dir_stride + (slot >> chunk_bits)];
        return self.cells.items[chunk << chunk_bits | (slot & (chunk_len - 1))];
    }

    fn defsPeek(self: *const SsaBuilder, place: Place, block: Mir.Block) ?Mir.Value {
        const v = self.defsRaw(place, block);
        assert(v != pending);
        return if (v == absent) null else @fromBackingInt(@intCast(v - 1));
    }

    /// Returns block `b`'s slot, giving it one at its first cell: `arm_slot`
    /// for a sealed single-predecessor block, the next map column otherwise.
    /// Fixed from then on, so the cell is always looked for where it was put;
    /// an unsealed block that ends with one predecessor keeps its column.
    fn slotOf(self: *SsaBuilder, b: u32) u32 {
        const slots = self.block_state.items(.slot);
        if (slots[b] != no_slot) return slots[b];
        const arm = self.block_state.items(.sealed)[b] and self.block_state.items(.preds_len)[b] == 1;
        assert(self.next_slot < arm_slot);
        slots[b] = if (arm) arm_slot else self.next_slot;
        if (!arm) self.next_slot += 1;
        return slots[b];
    }

    /// Index into `cells` of (place, slot), growing the directory to cover it
    /// and giving the pair's chunk its own cells on first write. Both axes
    /// grow geometrically: exact growth on either axis is quadratic. The
    /// index stays valid for the builder's life (chunks are only appended and
    /// keep their numbers when the directory regrows); a pointer into `cells`
    /// does not survive the next new chunk.
    fn cellIndex(self: *SsaBuilder, place: Place, slot: u32) Error!usize {
        assert(slot < arm_slot);
        const p = @backingInt(place);
        const col = slot >> chunk_bits;

        if (col >= self.dir_stride or p >= self.place_cap) {
            const stride = if (col < self.dir_stride) self.dir_stride else @max(col + 1, self.dir_stride * 2, 1);
            const cap = if (p < self.place_cap) self.place_cap else @max(p + 1, self.place_cap * 2, 16);
            const grown = try map_gpa.alloc(u32, @as(usize, cap) * stride);
            @memset(grown, 0);
            // Rows past `next_place` are still all chunk 0.
            for (0..@min(self.place_cap, self.next_place)) |row| {
                const src = self.dir[row * self.dir_stride ..][0..self.dir_stride];
                @memcpy(grown[row * stride ..][0..self.dir_stride], src);
            }
            map_gpa.free(self.dir);
            self.dir = grown;
            self.dir_stride = stride;
            self.place_cap = cap;
            if (self.cells.items.len == 0) try self.cells.appendNTimes(map_gpa, absent, chunk_len); // chunk 0
        }
        const d = @as(usize, p) * self.dir_stride + col;
        if (self.dir[d] == 0) {
            const chunk = self.cells.items.len >> chunk_bits;
            if (chunk > std.math.maxInt(u32)) return error.OutOfMemory;
            try self.cells.appendNTimes(map_gpa, absent, chunk_len);
            self.dir[d] = @intCast(chunk);
        }
        return @as(usize, self.dir[d]) << chunk_bits | (slot & (chunk_len - 1));
    }

    /// Braun §readVariableRecursive, for a block `readFrom` cannot climb.
    /// Both paths memoize their result in the block's cell, which is also
    /// what breaks cycles on the loop path.
    // ponytail: recursive, with depth the number of joins the first read of a
    // place climbs (single-predecessor blocks are `readFrom`'s loop), not a
    // nesting depth. Ceiling: a few frames per join, so ~10⁵ sequential `if`s
    // in one module would blow the stack.
    // The fix is an explicit stack with a resume state for the ≥2-preds arm.
    fn readVariableRecursive(self: *SsaBuilder, place: Place, block: Mir.Block) Error!Mir.Value {
        const b = @backingInt(block);
        assert(b < self.block_state.len); // `readVariable` ensured it

        if (!self.block_state.items(.sealed)[b]) {
            // Preds not final yet (loop header, §5.9): incomplete phi, filled by sealBlock.
            const phi = try self.mir.emitPhi(self.gpa, block, &.{});
            const node: u32 = @intCast(self.incomplete_pool.items.len);
            try self.incomplete_pool.append(map_gpa, .{
                .place = place,
                .value = phi,
                .next = self.block_state.items(.phis_head)[b],
            });
            self.block_state.items(.phis_head)[b] = node;
            try self.writeVariable(place, block, phi);
            return phi;
        }
        assert(self.block_state.items(.preds_len)[b] != 1); // `readFrom` climbs those
        // ≥2 preds (or 0: an undefined read in a source-less block).
        //
        // Braun emits the phi first and collapses a trivial one by aliasing,
        // which leaves a dead row behind; on a compact model with long `if`
        // chains nearly every phi row was dead. So the cell is marked
        // `pending` instead, and a phi is emitted only when a read cycles
        // back here (`readFrom` mints it) or the predecessors disagree.
        // An acyclic trivial join gets no row at all.
        //
        // `cell` stays valid across the reads: they may regrow `cells` and
        // the directory, but a chunk keeps its number in both.
        const slot = self.slotOf(b);
        assert(slot != arm_slot); // sealed and not single-predecessor
        const cell = try self.cellIndex(place, slot);
        self.cells.items[cell] = pending;
        const top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(top);
        try self.readPreds(place, block);
        const pairs = self.scratch.items[top..];
        const now = self.cells.items[cell];
        const val = if (now != pending)
            try self.fillPhi(@fromBackingInt(@intCast(now - 1)), pairs)
        else if (sameValue(self.mir, pairs)) |same|
            same
        else blk: {
            const phi = try self.mir.emitPhi(self.gpa, block, pairs);
            for (pairs) |p| try self.addUser(p.value, phi);
            break :blk phi;
        };
        assert(@backingInt(val) < std.math.maxInt(u32) - 1); // see `writeVariable`
        self.cells.items[cell] = @backingInt(val) + 1;
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
            const v = try self.readFrom(place, pred.block);
            try self.scratch.append(map_gpa, .{ .block = pred.block, .value = v });
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
                    try self.phi_work.append(map_gpa, u.phi);
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
        const i = @backingInt(block);
        assert(i < self.mir.blockCount());
        while (self.block_state.len <= i) try self.block_state.append(map_gpa, .{});
        return i;
    }

    /// Record "`user` (a phi) reads `value`". Sentinels never collapse, so they
    /// get no list.
    fn addUser(self: *SsaBuilder, value: Mir.Value, user: Mir.Value) Error!void {
        const i = @backingInt(value);
        if (i < Mir.Value.first_dynamic) return;
        const slot = i - Mir.Value.first_dynamic;
        while (self.user_head.items.len <= slot) try self.user_head.append(map_gpa, list_end);
        const node: u32 = @intCast(self.user_pool.items.len);
        try self.user_pool.append(map_gpa, .{ .phi = user, .next = self.user_head.items[slot] });
        self.user_head.items[slot] = node;
    }

    fn userHead(self: *const SsaBuilder, value: Mir.Value) u32 {
        const i = @backingInt(value);
        if (i < Mir.Value.first_dynamic) return list_end;
        const slot = i - Mir.Value.first_dynamic;
        if (slot >= self.user_head.items.len) return list_end;
        return self.user_head.items[slot];
    }

    fn predsHead(self: *const SsaBuilder, block: Mir.Block) u32 {
        const b = @backingInt(block);
        if (b >= self.block_state.len) return list_end;
        return self.block_state.items(.preds_head)[b];
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

test "ssa: map growth preserves values, undefined cells and unused rows" {
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
    const w = b.newPlace();
    for (0..2 * chunk_len) |_| { // a slot per block: grows the slot axis with spare rows
        last = try mir.addBlock(gpa);
        try b.writeVariable(w, last, .f_ten);
    }
    try b.writeVariable(x, last, .f_two);
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

test "ssa: an arm block's cells live in arm_cells and the climb finds them" {
    const gpa = std.testing.allocator;
    var mir: Mir = .{ .name = "ssa_arm" };
    defer mir.deinit(gpa);
    var b = SsaBuilder.init(gpa, &mir);
    defer b.deinit();

    const entry = try mir.addBlock(gpa);
    const arm = try mir.addBlock(gpa);
    const inner = try mir.addBlock(gpa);
    try b.sealBlock(entry);
    try b.addPredecessor(arm, entry);
    try b.sealBlock(arm);
    try b.addPredecessor(inner, arm);
    try b.sealBlock(inner);

    const x = b.newPlace();
    const y = b.newPlace();
    try b.writeVariable(x, entry, .f_one);
    try b.writeVariable(x, arm, .f_two);
    try b.writeVariable(y, arm, .f_ten);
    try b.writeVariable(x, arm, .f_inf); // overwrites, no second node
    try std.testing.expectEqual(arm_slot, b.block_state.items(.slot)[@backingInt(arm)]);
    try std.testing.expectEqual(@as(usize, 2), b.arm_cells.items.len);
    try std.testing.expectEqual(Mir.Value.f_inf, try b.readVariable(x, inner));
    try std.testing.expectEqual(Mir.Value.f_ten, try b.readVariable(y, inner));
    try std.testing.expectEqual(Mir.Value.f_one, try b.readVariable(x, entry));
}
