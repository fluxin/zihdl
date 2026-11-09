pub const netlist = @import("netlist.zig");
pub const lib = @import("lib.zig");
pub const blocks = @import("blocks.zig");
pub const backend = @import("backend.zig");
pub const cdc = @import("cdc.zig");
pub const bitfield = @import("bitfield.zig");
pub const registers = @import("registers.zig");

test {
    _ = netlist;
    _ = lib;
    _ = blocks;
    _ = backend;
    _ = cdc;
    _ = bitfield;
    _ = registers;
    _ = @import("backend/verilog_test.zig");
    _ = @import("backend/systemverilog_test.zig");
    _ = @import("backend/metadata_test.zig");
    _ = @import("backend/provenance_test.zig");
    _ = @import("backend/timing_test.zig");
    _ = @import("backend/timing_contract_fixture.zig");
    _ = @import("backend/sdc_test.zig");
    _ = @import("backend/golden_test.zig");
}
