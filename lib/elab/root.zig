//! Elaboration: a parsed `Ast.SourceFile` → one flattened `Design` (§6.2.2),
//! plus the rule tables lowering reads too. Re-exports only; the files import
//! each other directly. It imports no `ir` file: lowering (`analog`) reads it,
//! and `vera.Elaborate` re-exports it. `kernels` is a dependency so §9.13
//! folds use the device's rng (`elaborate/clone.zig`); `base` holds the rows
//! it publishes to `Lowered` (`Inserted`, `ParamOverride`, `hier_param.Kind`).

/// Hierarchy flattening, AST → one flat module (§6).
pub const Elaborate = @import("elaborate.zig");
/// §9.13 Table 9-10's distributions, one row per source spelling.
pub const dist = @import("dist.zig");
/// §3.6 disciplines and natures and §3.11.1 compatibility, from the AST alone.
pub const discipline_rules = @import("discipline_rules.zig");
/// §6.3.6/§9.18 hierarchical system-parameter names (Table 9-29).
pub const hier_param = @import("hier_param.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
