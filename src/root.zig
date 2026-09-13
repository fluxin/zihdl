pub const netlist = @import("netlist.zig");
pub const lib = @import("lib.zig");
pub const blocks = @import("blocks.zig");
pub const backend = @import("backend.zig");

test {
    _ = netlist;
    _ = lib;
    _ = blocks;
    _ = backend;
    _ = @import("backend/verilog_test.zig");
    _ = @import("backend/systemverilog_test.zig");
    _ = @import("backend/metadata_test.zig");
    _ = @import("backend/provenance_test.zig");
    _ = @import("backend/timing_test.zig");
    _ = @import("backend/sdc_test.zig");
    _ = @import("backend/golden_test.zig");
}
