//! Example design blocks shared across the reference projects. These are
//! application-level compositions built on the `js_asic` library; reusable
//! target-neutral primitives live in `src/blocks`, and each project's own
//! application blocks (ISA, execution core) live with the project.

pub const vector_tb = @import("vector_tb.zig");

test {
    _ = vector_tb;
}
