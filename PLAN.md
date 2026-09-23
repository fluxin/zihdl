# zihdl — Remaining Work

This file tracks unfinished work. The current implementation and verification
commands are in [README.md](README.md); API limits are in [docs/api.md](docs/api.md).
Physical implementation and signoff are tracked in `../oasic`.

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
