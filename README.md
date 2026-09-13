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

Arrival windows are always author declarations relative to the destination
clock's active (rising) edge: `min` is the earliest arrival and `max` the
latest, either may be absent, negative values arrive before the edge and
positive values after it, and every bound carries an explicit unit (`ps`,
`ns`, `us`, `ms`). The library never invents a window, so consumers apply
their own documented defaults when it is `null`.

`zig build contract` emits the timing-intent contract fixture under
`out/contract/`: matching RTL, `design.json`, an independent
`oasic.stimulus/1` program and a manifest with SHA-256 hashes. It covers both
arrival bounds, a two-stage synchronizer, an intentionally unsynchronized
input, reset policy and two renamed instances of one child definition for
hierarchical binding tests.

### Timing intent v2 (opt-in)

`Options.timing_intent_version = 2` emits `js_asic.timing_intent/2`: the v1
section plus input slew and output load declarations. The default stays v1 and
v1 output is byte-for-byte unchanged, so products and existing consumers never
see a new schema unless a runner asks for one. The fixture passes v2; product
runners stay v1.

| Field | Meaning |
|---|---|
| `inputs[].slew.threshold.low_fraction` / `high_fraction` | Explicit fractions of the transition's low/high levels (for example `0.1` and `0.9` for a 10 %–90 % measurement). Always authored: the library never defaults a measurement basis. |
| `inputs[].slew.rise` / `.fall` | Transition windows with `min`/`max` time values in explicit units (`ps`, `ns`, `us`, `ms`). A null bound is unknown, never zero. |
| `outputs[].load.value` / `.unit` | Additional external load per port bit, `ff` or `pf` (exactly one unit per value). Excludes internal cell-pin and wire capacitance. A null load is unknown. |

The fixture's canonical artifact is `out/contract/timing_contract.json` (v2);
`out/contract/timing_contract_v1.json` is the byte-stable `/1` projection for
consumers that do not parse v2 yet. Both bind the same RTL and stimulus. It
covers both arrival bounds, distinct per-instance slew and load declarations
for two renamed child instances, a 2-bit vector synchronizer (per-bit vector
stage identities are unit-test covered; current consumers reject them), an
intentionally unsynchronized input, reset policy, declared-but-unknown (null)
slew/load values, and both load units.

Still deferred to a later version: output required times, reset-release
synchronization and external clock relationships.

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
