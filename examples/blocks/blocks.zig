//! Example design blocks shared across the reference projects. These are
//! application-level compositions built on the `zihdl` library; reusable
//! target-neutral primitives live in `src/blocks`, and each project's own
//! application blocks (ISA, execution core) live with the project.

pub const vector_tb = @import("vector_tb.zig");
pub const ethernet_10base_t_tb = @import("ethernet_10base_t_tb.zig");

test {
    _ = vector_tb;
    _ = ethernet_10base_t_tb;
}
