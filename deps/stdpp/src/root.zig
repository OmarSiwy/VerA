//! Rust-style static iterator adapters. Random-access pipelines (slices,
//! arrays, ranges, ArrayList, MultiArrayList, and map/filter/take/enumerate/zip
//! over them) run their terminals as counted loops, and as explicit SIMD when
//! every callback is lanewise.
pub const iter = @import("iter.zig");
pub const lanes = @import("lanes.zig");
pub const Iterator = iter.Iterator;
pub const SizeHint = iter.SizeHint;
pub const of = iter.of;
pub const from = iter.from;
pub const fromRef = iter.fromRef;
pub const fromSlice = iter.fromSlice;
pub const fromSliceMut = iter.fromSliceMut;
pub const fromSliceRef = iter.fromSliceRef;
pub const fromArray = iter.fromArray;
pub const fromFn = iter.fromFn;
pub const empty = iter.empty;
pub const once = iter.once;
pub const repeat = iter.repeat;
pub const repeatWith = iter.repeatWith;
pub const successors = iter.successors;
pub const range = iter.range;
pub const lanewise = lanes.lanewise;
pub const splat = lanes.splat;
test {
    _ = iter;
    _ = lanes;
}
