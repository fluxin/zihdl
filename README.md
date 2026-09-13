# js_asic

A pure Zig (0.16.0) hardware construction library and synthesizable ASIC generator.

- **`src/`**: Pure hardware construction library (`netlist.zig` IR, `lib.zig` conveniences like FSMs, register helpers, `muxLookup` and structural temporal helpers, `blocks.zig` elemental blocks, `backend/` renderers and artifact writers). The IR is target-language neutral; HDL is only involved at export.
- **`examples/`**: Reference projects built on the library: `protocol_emulator/` (the 120 MHz I2C/SPI-programmable ISA core with iverilog testbenches), shared example design blocks in `blocks/`, and the `z80/` scaffold for the FOSSi Z80 port (Track D).

See [PLAN.md](PLAN.md) for full architecture details, roadmap, and next phases.

## Artifacts

`zig build run` writes:

| File | Contents |
|---|---|
| `out/asic_core.v` | Verilog-2001 RTL (portable default target) |
| `out/design.json` | Metadata sidecar: hierarchy, widths, FSMs, opcodes, clocks, assertions |
| `out/asic_core.sdc` | Timing constraints for oasic's `timing/sta.odin` |

Add `--sv` (`zig build run -- --sv`) to also emit `out/asic_core.sv`: the same
design with `logic`, `always_comb`/`always_ff`, FSM `enum` typedefs and packed
struct bundle ports.

When provenance is enabled, `design.json` also carries a `provenance` section
(`js_asic.provenance/1`): per-module operation rows with deterministic integer
ids, authored functional groups with explicit membership, and a source map of
zero-based half-open byte ranges into the exact emitted RTL, anchored by the
artifact SHA-256. Expressions folded during elaboration are reported as
`omitted` with a reason and no spans. It is descriptive only: RTL bytes are
identical with or without it. Schema: `src/backend/provenance.zig`.

Declared input timing intent adds an optional `timing_intent` section
(`js_asic.timing_intent/1`): per-input classification (synchronous,
asynchronous, unknown) and destination clock/domain, synchronizer stage
identities as `(module, register, bit)`, reset polarity and assertion/release
policy, and synchronous arrival windows with explicit units only where a real
requirement exists. Anything not declared stays unknown. Schema and emitted
example: `src/backend/metadata.zig`.

## Quick Start

```bash
# Run unit tests
zig build test

# Synthesize complete RTL plus metadata and constraints
zig build run

# Lint the generated Verilog-2001 / SystemVerilog with Verilator
zig build lint
zig build lint-sv        # also emits out/asic_core.sv

# Transitional behavioral regressions (iverilog; oasic's simulator replaces them)
zig build sim

# Lint and simulate every emitted artifact
zig build verify
```
