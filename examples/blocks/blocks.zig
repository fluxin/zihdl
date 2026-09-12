//! Example design blocks shared across the reference projects. These are
//! application-level compositions built on the `js_asic` library; reusable
//! target-neutral primitives live in `src/blocks`, and each project's own
//! application blocks (ISA, execution core) live with the project.

pub const i2c_slave_loader = @import("i2c_slave_loader.zig");
pub const spi_slave_programmer = @import("spi_slave_programmer.zig");
pub const vector_tb = @import("vector_tb.zig");

test {
    _ = i2c_slave_loader;
    _ = spi_slave_programmer;
    _ = vector_tb;
}
