# zihdl

A pure Zig (0.17.1) hardware construction library and RTL generator.
The Zig package, import module and generated executable are all named `zihdl`.
The project is available under the [MIT license](LICENSE), copyright 2026
Bob Klosinski (fluxin). The package version is `0.0.0`; no stable API promise
has been made yet.

- **`src/`**: Pure hardware construction library (`netlist.zig` IR, `lib.zig` conveniences like FSMs, register helpers, `muxLookup` and structural temporal helpers, `blocks.zig` reusable blocks including the 10BASE-T serializer, `backend/` renderers and artifact writers). The IR is target-language neutral; HDL is only involved at export.
- **`examples/`**: Reference projects built on the library: `protocol_emulator/` (the configurable I2C/SPI-programmable ZIO core with replay witnesses), shared design blocks in `blocks/`, and the [Jane Street ASIC puzzle](examples/jane_street/README.md) warmup and rule-level checker in `jane_street/`.

See [PLAN.md](PLAN.md) for remaining work.

`zig build jane-street` solves the 11×11 Two Stars puzzle from its region map,
emits a serial key feeder and rule-level checker as Verilog, and replays all
four output messages. `zig build verify-jane-street-puzzle` compares generated
behavior with the puzzle's extracted Verilog and GDS simulator using the
sibling checkouts; see the [example guide](examples/jane_street/README.md).
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
limit.

The core also runs a firmware UART (`uart_microcode.zig`, 8N1): TX frames
bytes from the OSR itself (count header, four bytes per word) and RX takes one
mid-bit sample per data bit, one RX word per byte. Rates must round to within
1/34 of the bit time, half of the 8N1 frame budget. An I2C controller
(`i2c_microcode.zig`, standard/fast/fast-mode plus, open drain on pins 0/1)
plans START, repeated START, ACK/NACK and STOP as slots, waits for SCL to rise
(clock stretching) and samples mid-high; SCL low/high times come from the
UM10204 minimums. `zig build protocols` checks UART TX bit edges to the cycle
at 1 Mbaud and 115200, RX at both rates and with the far end 2.9% fast and
slow, and I2C writes and a repeated-START read against zihdl's own I2C target
RTL at all three speeds (every SDA/SCL transition to the cycle) and with clock
stretching.

The ZIO instruction set is defined once in `isa.zig` as packed payload
formats (`zihdl.bitfield`); the RTL decoder, assembler, reference model and
`docs/zio-isa.md` (`zig build isa-doc`) all derive from it. `zio_model.zig` is
an independent cycle-accurate reference, and `zig build zio-diff` compares
every output bit of the RTL with it over 192k random cycles (random valid
programs from the ISA table, faults, pins, TX writes, configuration, start,
stop and reset). Testbenches for these come from typed `oasic.stimulus/1`
schedules (`backend.stimulus.Typed`), the same rows oasic's simulator replays.
`zig build verify` includes these direct ZIO RTL witnesses. The
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
not change the v1 projection. The contract fixture and protocol emulator runners request v2.
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

The integrated protocol emulator uses a two-stage `ResetSyncBlockWithClock`
release chain. Only that chain receives raw reset; the core and both loader
variants use its output. `I2cSlaveLoaderBlockWithTiming` carries the enclosing
frequency and reset-release policy into child metadata. Existing constructors
retain their 120 MHz defaults.

SDC export no longer cuts reset paths by default. `reset_false_paths = true`
is an explicit input-wide waiver and is rejected for internal reset nets or
synchronous reset assertion. Physical consumers must still check released-reset
recovery/removal and clock distribution; declaring a chain is not timing closure.

The `zio_asic_60_manifest.txt` and `zio_asic_120_manifest.txt` bundles record
SHA-256 hashes of their RTL, metadata and SDC. Use all three files from the same
bundle. For the 60 MHz target, pass `-sdc out/zio_asic_60.sdc` explicitly to OASIC:
the filename alone does not select the timing period (16.666 ns, 250 ps uncertainty).

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

## Authoring features

**Constraints from intent.** `backend.sdc` lowers everything the top module
authors: one `create_clock` per clock port (further domains on that port, such
as its falling edge, share it and must agree on its period),
`create_generated_clock` for every
generated clock in the hierarchy (on its instance pin, or on the port when the
top generates it, sourced from the declared top clock or generated pin it
traces to; anything else is an error), `set_clock_groups -asynchronous` for declared
non-synchronous clock relationships (each group carries the clocks generated
from its clock), `set_input_delay` from arrival windows,
`set_output_delay` from required windows, `set_input_transition` from input
slew (rescaled to `Options.library_slew_threshold`, which is required once a
slew is declared) and `set_load` from output loads. A required window is
absolute within the cycle: data launched on the reference clock's rising edge
must arrive between `phase + min` and `phase + max`, where `phase` is 0 for the
rising and half a period for the falling edge; every delay is emitted against
the rising edge (`max` lowers to `period - (phase + max)`, `min` to
`-(phase + min)`), which STA tools and oasic's SDC reader agree on. An IO
window on a clock with no domain is an error rather than a dropped line.

**Reset release is checked.** `ResetPolicy.release = .synchronous` must be
backed by a declared release chain on the domain's own clock net and edge:
`Design.elaborate` follows the domain's reset (and its clock, through the same
instance connections) through assignments, instance outputs and instance
inputs to the final stage of a `release_synchronizer`, and fails with
`error.UnsynchronizedResetRelease` otherwise. Only a top-level input stays an
external claim. A declared chain must be real: at least two stages, every
stage a flop on the row's clock and edge, asynchronously reset by one raw
reset to the asserted level, the first sampling the released level and each
later stage the previous one. `lib.releasedDomain` builds the chain and returns
the released domain.

**Signal arrays.** `[N]Signal(W)` fields are legal anywhere in `Inputs`,
`Outputs` and bundles (ports `name_0` .. `name_{N-1}`), and
`mb.regArray`/`wireArray` declare them. `b.index(items, i)` reads element `i`
at runtime and `b.indexAssign(items, i, v)` writes it (elements the index
cannot reach get no branch); `b.sliceDyn(x, lo, W)` is `x[lo +: W]`, and
`lib.rotlDyn`/`rotrDyn` rotate by `n mod W` for any runtime `n`. Out-of-range
reads return zero, so every select has one two-state value, and a register
that is read but never assigned fails elaboration instead of simulating as
`x`.

**Clock edges.** `ClockDomain.edge = .falling` makes `seq`, `seqEnable` and
the memory ports capture on the falling edge; `seqNoReset`/`seqReset` take
`clk.negedge()`.

**Memory ports.** `mb.readPort`, `mb.writePort` and `mb.readWritePort` are the
one memory port model: each records a port row (`memories[].ports` in
`design.json`), takes its own clock domain and optional byte enables, and a
memory may have any number of them, so true dual-port and dual-clock RAMs
come from the same primitive. A memory with ports is reached only through
them (direct `memRead`/`memWrite` on it is `error.InvalidMemoryPort`), and
its `read_ports`/`write_ports` counts are its port rows. Register or latch
storage (`MemOpts.storage`) gives each word one clock pin, so its write ports
must share one clock and edge; writes from several clocks need `.macro` or
`.any`. When write ports on one clock hit the same
address in one cycle, each byte lane goes to the earliest port that writes
it, so disjoint lanes both land; a read/write port follows the memory's
`write_mode`, merging lanes for a byte-masked write-first read at any width. Array writes sit in reset-free processes so synthesis
infers a memory (Yosys infers one true dual-port `$mem_v2` for the witness).
`MemOpts.init_file` is emitted verbatim in `$readmemh` and `design.json`.
Tools resolve it from the current directory, then the RTL file's directory, so
a bare name written next to the RTL keeps a bundle relocatable (the
conformance bundle does this). `MemOpts.init_words` generates initial contents
from Zig:
`backend.meminit.files` returns the exact `$readmemh` file (every entry
written, zero past the data) and `design.json` records its SHA-256.

**Source locations.** `mb.at(@src())` stamps later declarations, assignments,
processes and instances; both HDL backends end those lines with
`// @[file:line]`. Modules that never call it emit unchanged RTL.

**Temporal properties.** `lib.assertProperty`, `assumeProperty` and
`coverSequence` take bounded sequences, tuples of 1-bit conditions and
`lib.cycles(n)` delays (`.{ req, lib.cycles(1), gnt }` is `req ##1 gnt`), with
`.overlapping` (`|->`) or `.next` (`|=>`) implication. A sequence needs at least
one condition, and only a consequent may start with a delay; both are compile
errors otherwise. They lower to one shared history chain per condition and one
immediate assertion, so every simulator and oasic see the same two-state
semantics.

**Clock generation.** `blocks.ClockDividerBlock(n)` divides by an even `n`
from a flop and declares its output as a generated clock;
`blocks.ClockGateBlock(technology)` wraps the technology's ICG cell
(`sky130_fd_sc_hd__dlclkp_1`, `sg13g2_lgcp_1`) under `SYNTHESIS` and its
latch-and-AND function otherwise.

**Register banks.** `blocks.RegisterBankBlock(spec, bus)` takes the same
layout as `zihdl.registers.bank`: a struct of `bitfield` packed formats whose
defaults are the reset values. A format's `access` declaration marks fields
`ro`, `w1c` or `w1p` (the rest are `rw`), reserved fields read zero, and the
block is an AXI4-Lite, APB or Wishbone slave with byte-strobed writes and
hardware-facing field ports, plus `cHeader` and `regmapJson`
(`zihdl.regmap/1`, enum tags included) for software.

`zig build features` emits every witness through both HDL backends, lints
each with Verilator and replays each in Icarus, including a byte-lane witness
across 1-, 8-, 16- and 72-bit memories and a property trace that must trip its
assertion. It also writes the format conformance design
(`backend.conformance`) to `out/conformance/`: Verilog, SystemVerilog, SDC,
`design.json` (timing intent v2 and v1) and generated memory contents from one
design that uses every SDC command and every optional `design.json` field. A
unit test pins the SDC text and each field, so a consumer validated against
these files is validated against the whole format.

## Quick Start

Install Zig 0.17.1 for generation and unit tests. `zig build verify` also
requires Verilator, Icarus Verilog and `vvp` on `PATH`. `oasic` is only needed
for the separate replay commands above.

RTL, protocol stimulus, and testbench checks are authored in Zig. `zig build
testbenches` generates the 26 simulator cases under `out/testbenches/`; the
additional ROM-driven witnesses use the same Zig models and a shared generated
simulator shell. Generated `.v` and `.sv` files live under `out/`.

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

# Timer, initialized ROM and RAM read/write collision modes (iverilog)
zig build timer-memory

# Round-robin arbitration and ready/valid crossbar contention (iverilog)
zig build arbiter

# AXI4-Lite register slave channel handshakes and responses (iverilog)
zig build axi4-lite

# Division/remainder witness: operators and folded constants (iverilog)
zig build divmod

# Arrays, edges, memory ports, properties, clock generation, register banks
zig build features

# Lint and simulate every emitted artifact
zig build verify

# Replay generated contract and ZIO RTL with metadata through the sibling oasic
zig build verify-oasic
```

## Scope and remaining gaps

zihdl owns elaboration and the artifacts it emits. Simulation, formal proof
(including a formal CDC crossing check), synthesis, timing analysis, layout,
netlist/GDS export and a command-line driver belong to
[oasic](https://fluxin.com/oasic) and are not planned here. Two-state values
are deliberate: there is no `x`/`z` and no tristate driving (`inout` ports
exist; pads are modeled as in/out/oe). The API review is in
[docs/api.md](docs/api.md#gaps-by-category).

| Area | Still open |
|---|---|
| Parameterization | Runtime `Param(W)` values are 64-bit Verilog overrides and cannot size ports or memories; widths and depths are comptime `Shape` values by design |
| Timing / constraints | No multicycle paths; per-bit slew/load has no consumer analysis; SDC covers the top module's IO and generated clocks, and constraint resolution beyond that stays consumer-side |
| Properties | Fixed `##n` delays only (no `##[m:n]` ranges or repetition); no native SVA emission |
| Memory | One memory per declaration: banks and multidimensional storage are Zig arrays of memories; generated contents need a width of at most 64 bits |
| Backends / packaging | Verilog-2001 and SystemVerilog only; pre-release package version `0.0.0` until 0.1.0 is tagged |
