# js_asic

A pure Zig (0.16.0) hardware construction library and synthesizable ASIC generator.

- **`src/`**: Pure hardware construction library (`netlist.zig` IR, `lib.zig` conveniences like FSMs, register helpers, `muxLookup` and structural temporal helpers, `blocks.zig` elemental blocks, `backend/` renderers and artifact writers). The IR is target-language neutral; HDL is only involved at export.
- **`examples/`**: Reference projects built on the library: `protocol_emulator/` (the 120 MHz I2C/SPI-programmable ISA core with iverilog testbenches), shared example design blocks in `blocks/`, and the `z80/` scaffold for the FOSSi Z80 port (Track D).

See [PLAN.md](PLAN.md) for full architecture details, roadmap, and next phases.
See [docs/](docs/README.md) for [code structure](docs/code-structure.md),
[migration guides](docs/migration.md), [competitor comparisons](docs/competitors.md)
and the [API review](docs/api.md).

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
section plus input slew, output load/required declarations and clock
relationship/reset-release topology. The default stays v1 and v1 output is
byte-for-byte unchanged, so products and existing consumers never see a new
schema unless a runner asks for one. The fixture passes v2; product runners
stay v1. New fields are additive under `/2` because consumers skip unknown
JSON fields and the version gate promises capabilities, not byte layout; a
consumer that does not read a field keeps it unknown. `/3` is reserved for
incompatible schema changes.

| Field | Meaning |
|---|---|
| `inputs[].slew.threshold.low_fraction` / `high_fraction` | Explicit fractions of the transition's low/high levels (for example `0.1` and `0.9` for a 10 %–90 % measurement). Always authored: the library never defaults a measurement basis. |
| `inputs[].slew.rise` / `.fall` | Transition windows with `min`/`max` time values in explicit units (`ps`, `ns`, `us`, `ms`). A null bound is unknown, never zero. |
| `outputs[].load.value` / `.unit` | Additional external load per port bit, `ff` or `pf` (exactly one unit per value). Excludes internal cell-pin and wire capacitance. A null load is unknown. |
| `outputs[].required.min` / `.max` | Required arrival window relative to the destination clock's active edge, same explicit-time shape as `arrival`. A null bound is unknown, never zero; the destination clock stays consumer-resolved. |
| `clocks[].reset.release_synchronizer` | `[{ module, signal, bit }]` reset-release chain, first stage first. Empty when none is declared; stages must be registers matching the reset width. |
| `clocks[].relationship.relation` / `.related_to` / `.source_period` / `.jitter` | Relation to a reference clock (`synchronous`, `asynchronous`, `mesochronous`, `plesiochronous`), the related 1-bit input in the declaring module (`null` means an external reference), and explicit source period / jitter times. |

#### Hierarchy resolution

Rows are authored per module definition and may be refined at the instantiating
port. Consumers resolve them when joining parent ports to child rows through
the `instances` connection table:

- **Output rows:** a parent output row replaces the child module's whole output
  row for that physical port — load and required together, including explicit
  `null`s (unknown), which mask the child's value. With no parent row, the
  child's declaration stays in force.
- **Input timing:** parent and child rows merge field by field only when
  compatible (same classification, clock/domain and synchronizer shape);
  fields declared on one side fill in the other. Conflicting declarations for
  the same physical input are errors: consumers must report them rather than
  silently choosing one.

The fixture's canonical artifact is `out/contract/timing_contract.json` (v2);
`out/contract/timing_contract_v1.json` is the byte-stable `/1` projection for
consumers that do not parse v2 yet. Both bind the same RTL and stimulus. It
covers both arrival bounds, a 2-bit vector synchronizer (per-bit vector stage
identities are unit-test covered; current consumers reject them), an
intentionally unsynchronized input, reset policy with a declared
async-assert/sync-release chain, an asynchronous parent and child clock
relationship to an external reference, declared-but-unknown (null)
slew/load/required values, both load units, output required windows, child
output defaults with per-instance parent row overrides (value, unit change,
explicit null and required replacement) and no-parent-row fallback, plus
compatible parent/child input merges (parent slew, child
classification/synchronizer/arrival).

Per-bit slew/load stays whole-port: one row applies to every bit of its port
and per-bit distinct values remain deferred until a consumer analysis can act
on them. Deeper-than-immediate-child resolution and a destination-clock
identity on outputs remain open as well.

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

# Dual-clock async FIFO witness: emit, lint and replay (iverilog)
zig build async-fifo

# Division/remainder witness: operators and folded constants (iverilog)
zig build divmod

# Lint and simulate every emitted artifact
zig build verify
```

## Known gaps

The authoring API is closed for what this repository actually builds (the
protocol emulator, the elemental blocks, the contract fixture). The remaining
holes matter for general-purpose use; the detailed review is in
[docs/api.md](docs/api.md#gaps-by-category).

| Area | Gap |
|---|---|
| Expressions | `add`/`sub`/`mul`/`div`/`mod`/bitwise extend unequal-width operands explicitly and are verified end-to-end through oasic; comparisons still lean on Verilog operator context; constant rotates are `lib.rotl`/`rotr` (no dynamic rotate); `slice` is comptime-only; signedness is expression-level (`asSigned`), not a port/register declaration; no `x`/`z` or tristate driving (`inout` ports exist but pads are modeled as in/out/oe) |
| Parameterization | Widths/depths are comptime type arguments; value parameters are 64-bit and cannot size ports or memories, so a parent cannot specialize a child's shape |
| Memory | One read and one write port per memory; no dual-port, banked or multidimensional memories; init is `$readmemh` from a file path only |
| Clocking / CDC / IP | Async FIFO and pulse/reset synchronizers landed; remaining: request/ack bridge, mailboxes, CDC structural lint, and Phase 3 IP (AXI4-Lite, UART, SPI/I2C targets, arbiter, crossbar, timers); `ResetPolicy.release` itself still does not lower a synchronizer |
| Timing / constraints | Output required times, clock relationships and reset-release topology are authored (v2); per-bit slew/load, destination-clock identity on outputs and deeper-than-immediate-child resolution remain deferred; SDC has no IO delays, multicycle or generated clocks |
| Verification | No in-tree simulator or reusable reference interpreter; immediate assertions only (no concurrent SVA); `oasic`'s Verilog front end is still landing, so `zig build sim` uses transitional iverilog |
| Backends / packaging | Verilog-2001 and SystemVerilog only (no VHDL, structural netlist export or GDS); no standalone CLI; package version is `0.0.0` with no `LICENSE` and docs not shipped in `build.zig.zon` paths |

