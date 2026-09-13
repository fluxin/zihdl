//! Pure Elemental Hardware Building Blocks
//! Protocol-agnostic, parameterized silicon blocks that can be composed
//! into arbitrary digital circuits and controllers.

pub const sram = @import("blocks/sram.zig");
pub const fifo = @import("blocks/fifo.zig");
pub const async_fifo = @import("blocks/async_fifo.zig");
pub const cdc = @import("blocks/cdc.zig");
pub const shift_reg = @import("blocks/shift_reg.zig");
pub const edge_det = @import("blocks/edge_det.zig");
pub const counter = @import("blocks/counter.zig");

pub const SramBlock = sram.SramBlock;
pub const TtSramBlock = sram.TtSramBlock;
pub const FifoBlock = fifo.FifoBlock;
pub const AsyncFifoBlock = async_fifo.AsyncFifoBlock;
pub const ReqAckBridgeBlock = cdc.ReqAckBridgeBlock;
pub const MailboxBlock = cdc.MailboxBlock;
pub const ResetSyncBlock = cdc.ResetSyncBlock;
pub const ShiftRegisterBlock = shift_reg.ShiftRegisterBlock;
pub const ShiftDirection = shift_reg.ShiftDirection;
pub const EdgeDetectorBlock = edge_det.EdgeDetectorBlock;
pub const CounterBlock = counter.CounterBlock;

test {
    _ = sram;
    _ = fifo;
    _ = async_fifo;
    _ = cdc;
    _ = shift_reg;
    _ = edge_det;
    _ = counter;
}
