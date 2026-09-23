# zihdl

A pure Zig (0.16.0) hardware construction library and RTL generator.
The Zig package, import module and generated executable are all named `zihdl`.
The project is available under the [MIT license](LICENSE), copyright 2026
Bob Klosinski (fluxin). The package version is `0.0.0`; no stable API promise
has been made yet.

- **`src/`**: Pure hardware construction library (`netlist.zig` IR, `lib.zig` conveniences like FSMs, register helpers, `muxLookup` and structural temporal helpers, `blocks.zig` reusable blocks including the 10BASE-T serializer, `backend/` renderers and artifact writers). The IR is target-language neutral; HDL is only involved at export.
- **`examples/`**: Reference projects built on the library: `protocol_emulator/` (the configurable I2C/SPI-programmable ZIO core with replay witnesses) and shared example design blocks in `blocks/`. A Z80 port is proposed in the plan; it has no implementation yet.

See [PLAN.md](PLAN.md) for remaining work.
See [docs/](docs/README.md) for [code structure](docs/code-structure.md),
[migration guides](docs/migration.md), [competitor comparisons](docs/competitors.md)
and the [API review](docs/api.md).

The protocol emulator has host-assembled 10BASE-T, USB low-speed packet,
SPI master (all four modes) and JTAG TAP microcode. USB token/data constructors
generate CRC5/CRC16; the decoder checks PID, CRC, NRZI, stuffing and EOP.
SPI RX words unpack into bytes. SPI preloads up to 16 TX FIFO words and refills
the remaining ordered stream whenever `tx_full` clears. `zig build protocols`
checks USB data/token/ACK packets and 10 ms reset at 60/120 MHz, plus all four
SPI modes with varied MISO and an eight-byte transfer that crosses the FIFO
limit. `zig build verify` includes these direct ZIO RTL witnesses. The
standalone 10BASE-T RTL serializer is a reusable library block under
`src/blocks/`, with its witness under `examples/blocks/`.

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

### One programmable core

`examples/protocol_emulator/programmable_asic.zig::Config` selects the host,
SRAM arrangement, program capacity, counter width, TX FIFO depth and clock rate.
`ProgrammableAsicBlock(config)` is the sole top; it instantiates the sole
`ZioTimingUnit(counter_bits, fifo_depth)` execution implementation. The default
artifacts and the 60/120 MHz witness bundles use this same composition with RX
capture enabled. The split-memory artifact uses the same instruction semantics.

Instructions execute every `delay + 1` cycles, including taken branches. The
current input instruction is **IN PINS,4**: eight nibbles produce one RX word;
the partition owns ring addresses and loss accounting. Start discards partial
capture state and resets ring counters. TX uses the OSR and host-fed FIFO at
write addresses 0xF8..0xFF. `WAIT` selects GPIO 0..3. Unsupported opcodes,
IN widths/sources, OUT targets/counts, MOV operands, branch conditions and WAIT
pins fault before instruction side effects. See the decode table in
`zio_timing_unit.zig`; the ISA enum also reserves encodings not implemented yet.

Generate and replay the focused control/capture witness:

```sh
zig build zio-core
../oasic/oasic -sim-verilog out/zio_core.v -stimulus out/zio_core.jsonl
zig build verify
../oasic/scripts/protocol_replay.sh . /tmp/zio-protocol-replay
../oasic/oasic -sim-verilog out/zio_asic_60.v -stimulus out/zio_asic_60.jsonl
../oasic/oasic -sim-verilog out/zio_asic_120.v -stimulus out/zio_asic_120.jsonl
```

Icarus remains an independent oracle for the integrated host/RX trace; oasic
replays every edge and compares every top output. The TX waveform and focused
core expectations come from independent Zig models. Passing digital replay at a
clock rate does not establish routed timing closure.

When provenance is enabled, `design.json` also carries a `provenance` section
(`zihdl.provenance/1`): per-module operation rows with deterministic integer
ids, authored functional groups with explicit membership, and a source map of
zero-based half-open byte ranges into the exact emitted RTL, anchored by the
artifact SHA-256. Expressions folded during elaboration are reported as
`omitted` with a reason and no spans. It is descriptive only: RTL bytes are
identical with or without it. Schema: `src/backend/provenance.zig`.

Declared input timing intent adds an optional `timing_intent` section
(`zihdl.timing_intent/1`): per-input classification (synchronous,
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

`Options.timing_intent_version = 2` emits `zihdl.timing_intent/2`: the v1
section plus input slew, output load/required declarations and clock
relationship/reset-release topology. The default stays v1; requesting v2 does
not change the v1 projection. The fixture passes v2; product runners stay v1.
New fields are additive under `/2` because consumers skip unknown
JSON fields and the version gate promises capabilities, not byte layout; a
consumer that does not read a field keeps it unknown. The `oasic` consumer
binds v2 fields (required windows, release topology, clock relationships) and
accepts both the former `js_asic.*` and current `zihdl.*` schema names. The
timing equations, recovery/removal and relationship analysis remain its
responsibility. `/3` is reserved for incompatible schema changes.

| Field | Meaning |
|---|---|
| `inputs[].slew.threshold.low_fraction` / `high_fraction` | Explicit fractions of the transition's low/high levels (for example `0.1` and `0.9` for a 10 %–90 % measurement). Always authored: the library never defaults a measurement basis. |
| `inputs[].slew.rise` / `.fall` | Transition windows with `min`/`max` time values in explicit units (`ps`, `ns`, `us`, `ms`). A null bound is unknown, never zero. |
| `outputs[].load.value` / `.unit` | Additional external load per port bit, `ff` or `pf` (exactly one unit per value). Excludes internal cell-pin and wire capacitance. A null load is unknown. |
| `outputs[].required.clock` / `.edge` / `.min` / `.max` | Required arrival window relative to an explicit reference clock port and its active edge (`rising`/`falling`). A null bound is unknown, never zero. zihdl rejects a required window without a clock, so consumers must treat a missing clock as an error rather than infer one. |
| `clocks[].reset.release_synchronizer` | `[{ module, signal, bit }]` reset-release chain, first stage first, declared by the module that owns the chain registers. A released domain's reset is the chain output (directly or through hierarchy), never the raw reset; empty when none is declared. |
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
- **Clock relationships:** parent and child rows describing the same connected
  clock pair must agree on relation, source period and jitter.

`zihdl` enforces these rules itself in `Design.elaborate` (through
`Design.validateTimingHierarchy`), so a contradiction written into one design
fails elaboration with `error.InvalidTimingIntent` instead of reaching the
consumer. Resolution and analysis still belong to the consumer; the build-time
check only rejects contradictory authoring.

The fixture's canonical artifact is `out/contract/timing_contract.json` (v2);
`out/contract/timing_contract_v1.json` is the byte-stable `/1` projection for
consumers that do not parse v2 yet. Both bind the same RTL and stimulus. It
covers both arrival bounds, a 2-bit vector synchronizer (per-bit vector stage
identities are unit-test covered; current consumers reject them), an
intentionally unsynchronized input, a real async-assert/sync-release reset
chain (`reset_sync_2`) whose output resets the flat child domains, with the
two-edge release latency replayed across the contract stimulus, matching
asynchronous parent and child clock relationships to the shared external
reference (the conflict check rejects disagreement), declared-but-unknown
(null) slew/load/required values, both load units, output required windows,
child output defaults with per-instance parent row overrides (value, unit
change, explicit null and required replacement) and no-parent-row fallback,
plus compatible parent/child input merges (parent slew, child
classification/synchronizer/arrival).

Per-bit slew/load is authored as optional overrides next to the whole-port row
(`inputs[].per_bit_slew` / `outputs[].per_bit_load`, emitted only when
declared): a bit without an override keeps the whole-port value, and no live
consumer acts on per-bit values yet. Required windows always name their
reference clock (zihdl rejects a window without one). Hierarchy validation
joins rows through every instance level it can map back to a module signal and
rejects contradictions between a descendant and its ancestor or between
siblings sharing a net; consumers still perform the actual constraint
resolution.

## Quick Start

Install Zig 0.16.0 for generation and unit tests. `zig build verify` also
requires Verilator, Icarus Verilog and `vvp` on `PATH`. `oasic` is only needed
for the separate replay commands above.

```bash
# Run unit tests
zig build test

# Generate complete RTL plus metadata and constraints
zig build run

# Lint the generated Verilog-2001 / SystemVerilog with Verilator
zig build lint
zig build lint-sv        # also emits out/asic_core.sv

# Transitional behavioral regressions (iverilog; oasic's simulator replaces them)
zig build sim

# Dual-clock async FIFO witness: emit, lint and replay (iverilog)
zig build async-fifo

# Single-clock UART loopback witness: emit, lint and replay (iverilog)
zig build uart

# SPI target programmer witness: emit, lint and replay (iverilog)
zig build spi

# I2C target loader witness: emit, lint and replay (iverilog)
zig build i2c

# Request/acknowledge bridge + bundled-data + mailbox/FIFO-mailbox witness: emit, lint and replay (iverilog)
zig build cdc

# Division/remainder witness: operators and folded constants (iverilog)
zig build divmod

# Lint and simulate every emitted artifact
zig build verify

# Replay generated contract and ZIO RTL with metadata through the sibling oasic
zig build verify-oasic
```

## Known gaps

The authoring API is closed for what this repository actually builds (the
protocol emulator, the elemental blocks, the contract fixture). The remaining
holes matter for general-purpose use; the detailed review is in
[docs/api.md](docs/api.md#gaps-by-category).

| Area | Gap |
|---|---|
| Expressions | `add`/`sub`/`mul`/`div`/`mod`/bitwise/comparisons extend unequal-width operands explicitly and are verified end-to-end through oasic; constant rotates are `lib.rotl`/`rotr` (no dynamic rotate); `slice` is comptime-only; signedness is declaration-level (`SignedSignal(W)`, `MemOpts.signed`, `SignedStream(W)`) and flows through lib register/synchronizer helpers, so `asSigned` is reinterpretation only; no `x`/`z` or tristate driving (`inout` ports exist but pads are modeled as in/out/oe) |
| Parameterization | Widths/depths are comptime type arguments: block families declare a `Shape` schema and `instantiateShape` merges instance-site overrides, so a parent's comptime value parameter forwards into a child's shape (each distinct shape is its own checked module) and resolved shapes are recorded per instance in `design.json`; runtime `Param(W)` values stay 64-bit Verilog overrides and cannot size ports or memories, though a parent parameter or constant can be forwarded by name into a child override (`#(.CHILD(PARENT))`) |
| Memory | One read and one write port per memory; no dual-port, banked or multidimensional memories; init is `$readmemh` from a file path only |
| Clocking / CDC / IP | Async FIFO, pulse/reset/level synchronizers, a four-phase request/acknowledge bridge, a quasi-static bundled-data crossing, single-slot and FIFO-backed mailboxes, a single-clock UART, SPI target and I2C target loader blocks and a structural CDC lint landed; the lint tracks domain ownership and structural first flops per data bit (first 64 bits, whole-signal fallbacks for unmappable shapes) and honors per-bit declared synchronizer stages; remaining: AXI4-Lite, arbiter, crossbar, timers, ROM/RAM wrappers and a formal (not just structural) crossing check; `ResetPolicy.release` itself still does not lower a synchronizer |
| Timing / constraints | Output required times (with explicit clock and edge), clock relationships, reset-release topology and per-bit slew/load overrides are authored (v2), and hierarchy contradictions are rejected transitively through silent levels and siblings; per-bit values still have no consumer analysis and constraint resolution stays consumer-side; SDC has no IO delays, multicycle or generated clocks |
| Verification | No in-tree simulator or reusable reference interpreter; immediate assertions only (no concurrent SVA); `oasic`'s Verilog front end is still landing, so `zig build sim` uses transitional iverilog |
| Backends / packaging | Verilog-2001 and SystemVerilog only (no VHDL, structural netlist export or GDS); no standalone CLI; pre-release package version `0.0.0` |
