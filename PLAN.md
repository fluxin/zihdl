# zihdl — Remaining Work

This file tracks unfinished work. The current implementation and verification
commands are in [README.md](README.md); API limits are in [docs/api.md](docs/api.md).
Physical implementation and signoff are tracked in `../oasic`.

## Consumer compatibility

1. Update `../oasic/parsers/design_json.odin` to accept the renamed
   `zihdl.design/1`, `zihdl.provenance/1`,
   `zihdl.timing_intent/1`, and `zihdl.timing_intent/2` schemas. The parser still checks the former
   namespace. After the change, generate the contract fixture with
   `zig build contract` and replay both
   `out/contract/timing_contract_v1.json` and
   `out/contract/timing_contract.json` with `../oasic/oasic -sim-verilog`,
   `-stimulus`, and `-design-json`.
2. Add an `oasic` functional replay gate for the generated protocol emulator
   when its Verilog front end can consume the emitted RTL and metadata. Check
   the same 60/120 MHz Ethernet stimuli already exercised by the in-tree
   witnesses. Keep the in-tree Icarus and Verilator checks as independent
   regressions.

## Protocol emulator

1. Complete the USB low-speed packet layer in
   `examples/protocol_emulator/usb_low_speed_microcode.zig`: generate and check
   CRC bytes, assemble transactions, and decode received packets. Add an RTL
   witness for the reset program; the current witness covers packet output and
   the unit test checks reset duration from the instructions. Verify packet
   and reset timing at 60 and 120 MHz.
2. Complete SPI receive handling in
   `examples/protocol_emulator/spi_master_microcode.zig`: unpack MISO samples
   into bytes and define a long-transfer strategy beyond the preloaded
   16-word TX FIFO. Verify all four CPOL/CPHA modes with varied input bits and
   a transfer longer than the current FIFO limit, without underrun or lost RX
   words.

## Reusable block library

1. Add AXI4-Lite interface blocks in `src/blocks/`, with typed ports and
   read/write handshake witnesses.
2. Add a round-robin arbiter and crossbar, including contention and fairness
   witnesses.
3. Add timers and ROM/RAM wrappers, with parameter and memory-mode witnesses.

Expose each block through `src/blocks.zig` and include its witness in
`zig build verify` before marking it complete.

## Deferred expansion

1. Add a neutral structural or cell-level export only if an `oasic` consumer
   needs to bypass Verilog parsing. Define the artifact contract and prove it
   represents the same elaborated design as Verilog and `design.json`.
2. Add concurrent SVA sequences and properties only with a backend and
   open-tool witness that preserves their semantics. Immediate and structural
   assertions already cover the current designs.
3. Build the proposed Z80 example in `examples/z80/`: implement the datapath,
   decode, microcycle sequencer, and DIP40 bus; pass an instruction subset,
   then ZEXALL/ZEXDOC, then compare pin and timing behavior with
   [openz80](https://github.com/rejunity/z80-open-silicon) before attempting
   `oasic` equivalence or physical timing work.
4. Choose and tag a package version when a pinned API contract is needed.
   `0.0.0` remains the stated pre-release version until then.
