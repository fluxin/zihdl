# js_asic

A pure Zig (0.16.0) hardware construction library and synthesizable ASIC generator.

- **`src/`**: Pure hardware construction library (`netlist.zig` core, `lib.zig` conveniences like FSMs and register helpers, `blocks.zig` elemental blocks).
- **`examples/`**: Reference 120 MHz programmable protocol emulator ASIC with I2C/SPI loader, custom ISA, and testbenches.

See [PLAN.md](PLAN.md) for full architecture details, roadmap, and next phases.

## Quick Start

```bash
# Run unit tests
zig build test

# Synthesize complete Verilog RTL (asic_core.v)
zig build run

# Lint with Verilator
verilator --lint-only -Wno-MULTITOP asic_core.v

# Run end-to-end simulation
iverilog -Wall -g2001 -o asic_core_iv asic_core.v examples/asic_i2c_tb.v && vvp asic_core_iv
```
