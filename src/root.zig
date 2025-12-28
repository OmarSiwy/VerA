//! VerA — a Verilog-A / Verilog compiler with a shared device backend.
//!
//! Two frontends, one contract:
//!
//!   src/va   Verilog-AMS analog subset, compiled in-process: preprocessor →
//!            lexer → parser → MIR/SSA → finiteness proof → device.zig.
//!            Owns its whole pipeline; shells out to `zig` only to BUILD.
//!   src/vf   the Verilog family, translated by shelling out to verilator
//!            (via sv2v for `.sv`, `ghdl synth` for `.vhd`) and reading back
//!            its JSON AST.
//!
//! Both emit Zig that imports the `contract` module — `src/contract.zig`, which
//! ships here rather than in a consumer because it IS the codegen target. A
//! simulator embedding VerA imports the same file, so there is one definition of
//! the ABI and no copy to drift.

pub const va = @import("va/root.zig");
pub const vf = @import("vf/root.zig");
pub const contract = @import("contract.zig");

test {
    _ = va;
    _ = vf;
    _ = contract;
}
