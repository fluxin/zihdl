# js_asic: Programmable Protocol Emulator ASIC & Silicon Compiler

## 1. Project Status & Architecture

`js_asic` is a hardware construction library in pure Zig (0.16.0) that elaborates a
typed design directly into synthesizable Verilog-2001.

### Core model

- **Scope owns names.** Every module definition has a `Scope` symbol table.
  `Signal(W)`, `Param(W)` and `Mem(W)` are nameless, width-typed handles into it.
  Names are resolved at emission, so blocks are reusable and two instances (or two
  parameterizations) can never collide by name.
- **ModuleBuilder elaborates one module.** Schema-declared ports
  (`declareInputs` / `declareOutputs`), wires, registers, memories, parameters,
  continuous assigns, `seq` / `seqNoReset` / `comb` processes, and `instantiate`.
- **Design is the module registry.** Block definitions are built on first
  instantiation, keyed by their comptime-mangled name (`sram_256x32`,
  `i2c_slave_loader_42`), and emitted exactly once. A root design is elaborated
  with `Design.elaborate(Block)`.
- **One block contract for library and application code** (`assertBlock`):
  `name`, `Inputs` / `Outputs` structs of `Signal(W)`, and
  `build(mb: *ModuleBuilder) !void`. The top-level ASIC is itself a block.
- **Validation at `finish()`**: duplicate signals and instance names, multiple
  drivers, procedural/continuous assignment legality, slice bounds, memory
  references. Reset branches are generated per process from exactly the signals
  that process assigns, so multi-clock modules cannot cross-reset.

### File tree

```
src/                         <-- Generic hardware construction library (js_asic)
├── root.zig                 # Module root: exports IR, lib, blocks & backends
├── netlist.zig              # Core IR: Scope, Signal/Param/Mem, Expr/Stmt, ModuleBuilder, Design
├── lib.zig                  # Convenience layer: StateMachine, register/stream helpers (built on the public builder API)
├── blocks.zig               # Elemental primitives export hub
├── blocks/
│   ├── sram.zig             # Parameterized Dual-Port SRAM (1W1R) + TT-SRAM foreign macro
│   ├── fifo.zig             # Parameterized Synchronous FIFO
│   ├── async_fifo.zig       # Dual-clock gray-pointer FIFO (Cummings structure)
│   ├── cdc.zig              # Request/ack bridge, bundled data, mailboxes, reset sync
│   ├── uart.zig             # Single-clock UART (5..8 data bits, mid-bit sampling)
│   ├── spi.zig              # SPI target programmer (write/start/stop command decode)
│   ├── i2c.zig              # I2C target loader (parameterized device address)
│   ├── shift_reg.zig        # Parameterized Shift Register (SIPO / PISO)
│   ├── edge_det.zig         # 2-FF Synchronizer & Edge Detector
│   └── counter.zig          # Parameterized Up/Down Timer & Cycle Counter
└── backend/
    ├── render.zig           # Shared hoisting pre-pass + expression/statement text
    ├── verilog.zig          # Verilog-2001 target: portable default
    ├── systemverilog.zig    # SystemVerilog target: logic, always_*, enums, packed structs
    ├── metadata.zig         # design.json sidecar (hierarchy, widths, FSMs, opcodes, assertions)
    ├── sdc.zig              # SDC constraints (create_clock, uncertainty, false paths)
    └── *_test.zig           # Emission conformance, golden, metadata and SDC tests

examples/                    <-- Reference projects built on js_asic
├── blocks/                  # Block witnesses (RTL generators + Icarus benches)
│   ├── blocks.zig           # `protocol_blocks` hub module (vector_tb)
│   ├── *_gen.zig            # Witness RTL generators (divmod, CDC, FIFO, UART, SPI, I2C)
│   └── *_tb.v               # Handwritten Icarus benches replayed by `zig build sim`
├── protocol_emulator/       # Programmable protocol emulator ASIC (I2C/SPI + ISA)
│   ├── main.zig             # Runner: elaborate root block, emit RTL + design.json + SDC
│   ├── isa.zig              # The 32-bit microcode instruction set
│   ├── timing_execution_unit.zig# 120 MHz microsequencer core executing the ISA
│   ├── programmable_asic.zig# ProgrammableAsicBlock(loader, addr) top-level composition
│   ├── asic_i2c_tb.v        # iverilog I2C programming testbench
│   └── asic_rx_tb.v         # iverilog RX loopback testbench
└── z80/                     # FOSSi Z80 clone (Track D; empty scaffold)
```

---

## 2. Generator / Checker Split with `oasic`

`js_asic` authors; `oasic` verifies and recovers. The two meet at an artifact
contract, never at shared memory or shared code.

| | **js_asic — authoring** | **oasic — analysis** |
|---|---|---|
| Input | typed design source, ISA/microcode, stimulus/traces | GDSII, Verilog, traces, metadata |
| Output | synthesizable RTL (+ planned metadata, SDC), reference behavior | netlists, simulation, SAT proofs/CEX, STA, recovered RTL/program |
| Owns | elaboration, parameters, width/interface checks, RTL emission, reference interpreter | simulation, functional equivalence, BMC/reachability, timing, recovery |
| Never owns | SAT, unrolling, STA, physical modeling, the simulator | design intent, elaboration, ISA semantics |

Composed flows:

- **F1 — pre-layout functional:** `out/asic_core.v` → `sim/verilog_synth.odin` →
  `Circuit_Model` → `formal/unroll.odin` → miter/BMC against an ISA-level
  reference or captured traces.
- **F2 — synthesis equivalence:** RTL model ↔ post-synthesis cell model.
- **F3 — physical:** post-layout extracted netlist ↔ post-synthesis model, plus
  `timing/sta.odin` for 120 MHz closure. Function and timing are orthogonal gates.
- **F4 — recovery:** GDS-only path, no js_asic involvement.
- **F5 — provenance (planned):** js_asic metadata (FSM encodings, opcodes, widths,
  hierarchy) anchors oasic's recovered names to authored intent.

Integration is a process boundary (CLI + files/JSON), not an FFI library. Batch
proofs and simulations run through `zig build sim` / `zig build verify`;
interactive use, if ever needed, goes through a persistent `oasic --serve`
worker rather than a `.so`.

Integration performance (measured 2026-09-12): the loop is not IPC-bound.
`zig build run` emits every artifact in ~30 ms, `oasic -synth -sta` parses and
synthesizes the reference ASIC (3414 gates, 279 DFFs) and reports timing in
~8 ms, and `zig build verify` (emit + both Verilator lints + three iverilog
regressions) is ~280 ms warm. Process exec and file I/O are single-digit
milliseconds, so a shared library would save under 1% while coupling the two
languages through an ABI and putting Odin's runtime inside the js_asic process.
If latency becomes a problem (much larger designs, many variants, interactive
tools), the order is: (1) content-hash caching in `oasic` keyed by artifact +
flags, (2) `oasic --serve` with warm caches over the same CLI/JSON schema,
(3) batch mode and process fan-out, and only then (4) an optional exported C
ABI for a concrete per-cycle co-simulation workload, behind a non-default build
step. The file/JSON seam stays the contract either way: checker independence is
a verification property, not just packaging.

### Simulation authority

**oasic's Verilog simulator is the one semantic reference, and we develop it
rather than depending on `iverilog`.** The path is
`parsers/verilog.odin` → `sim/verilog_synth.odin` → `sim/circuit_sim.odin`
(eventually the compiled `codegen/circuit_model.odin` fast path). iverilog and
Verilator remain lint/regression tools only; the checked-in
`examples/protocol_emulator/asic_i2c_tb.v` is transitional until the F1-sim path replays it.

oasic-side development required for this:

1. **Verilog front end (`parsers/verilog.odin`).** Currently missing pieces
   js_asic emits or will emit: `*`, `<<`, `>>`, `>>>`, `/`, `%`; `$signed` /
   `$unsigned` and signed declarations; `initial` + `$readmemh`; dynamic
   bit-select with a non-constant index; `parameter` / `localparam` resolution in
   `case` labels; `` `timescale `` / `` `default_nettype `` directives.
2. **Technology mapper (`sim/verilog_synth.odin`).** Map the above to cells and
   keep width/sign semantics identical to Verilog; model memories explicitly
   (arrays with address decode, or a macro cell) instead of skipping them.
3. **Sim driver and CLI.** A `-sim-verilog` mode: parse → synth → `Circuit_Model`
   → run N cycles against a stimulus file → emit VCD (and optional expected-output
   assertions), with the compiled Odin model as the fast path.
4. **Stimulus / trace contract.** A small format (JSON-lines or VCD) that js_asic
   can emit from its reference interpreter and replay in oasic.
5. **js_asic enablers.** Stay inside the supported synthesizable subset, emit
   metadata (widths, hierarchy, FSM encodings) so the simulator can pack buses and
   name states, and wrap the invocation in `zig build sim`.

---

## 3. Backend Roadmap (authoring layer)

### Phase 0 — semantic core (done)

1. **Width-typed expressions.** `Expr(W)` (and signed `SInt`-like handling) so
   binops, slices, concat, ternary and literals carry width through elaboration;
   explicit `zext` / `sext` / `trunc` / `resize`; width-matched literal emission.
   `assign` becomes compile-time width-checked everywhere, not just at ports.
2. **Signedness.** Signed compare/shift/arithmetic emission (`$signed`),
   `asSigned` / `asUnsigned`, sign extension.
3. **Memory modes.** `Mem(W)`: comb vs sync read, read-during-write behavior
   (read-first / write-first / no-change), byte enables, `$readmemh` init.
4. **Parameters and symbolic constants.** `moduleParam` / `constant` symbols
   usable in expressions and `case` labels; named FSM encodings, opcode IDs,
   register addresses. Keeps generated RTL readable and reduces per-value
   module duplication.
5. **BlackBox / foreign source.** Language-tagged `ForeignSource` modules with
   a port schema, emitted verbatim by the matching backend, for IO cells, PLLs,
   vendor macros and ROM initialization.

### Phase 1 — authoring expressiveness (done)

6. **FSM abstraction (done).** `lib.StateMachine(E, reset, encoding)`: named
   states emitted as `localparam`s, binary / one-hot / gray encodings, reset
   encoding, `arm` / `goto` / `case_` / `run`, and a hold-by-default arm so lint
   sees a complete case. The I2C loader state machine is migrated as the
   reference.
7. **Register/utility library (done).** `regNext`, `regEnable`, `mux`,
   reductions (`andAll` / `orAll` / `xorAll`), replication (`fill`), priority
   encoder (`priorityEncode`), decoder (`decode`), one-hot detect (`isOneHot`),
   dynamic bit-select (`bitDyn`), `Cat` via `concat`, and `muxLookup` (comptime
   lookup table with a default and width resizing).
8. **Bundles and interfaces (done).** `lib.Stream(W)` with `streamSource` /
   `streamSink` / `streamWire` port and wire helpers, `connectStream` (forward
   data/valid, backward ready) and `regStream` pipeline stage. Bundles are
   recursive structs of `Signal(W)`: `declareInputs` / `declareOutputs` /
   `declarePorts` flatten nested fields to `parent_child` ports, a bundle's
   `dirs` decl (producer perspective) selects per-leaf direction and is flipped
   for sink-side declarations, `wireBundle` creates bundle wires, and
   `connect(src, dst)` bulk-wires whole bundles with direction-aware flow.
   `instantiate` binds bundle ports recursively, generating wires for unbound
   outputs.
9. **Clock/reset semantics (done).** `Reset` with async/sync × active-low/high
   kinds (`seqReset`, `seqResetEnable`), clock enables (`seqEnable`), multiple
   clock domains (already per-process), and `sync2` two-flop synchronizer for
   CDC. The async FIFO landed as `blocks.AsyncFifoBlock`, with the
   `blocks.FifoMailboxBlock` ready/valid wrapper above it.
10. **Assertions (partial).** `assert_` / `assume_` / `cover_` are emitted as
    immediate SVA guarded by `` `ifdef JS_ASIC_ASSERT `` (opt-in, so the
    portable Verilog-2001 baseline and lint stay clean), and exported as text in
    `design.json`. Temporal checks are expressed structurally, not as concurrent
    SVA: `lib.past` / `rose` / `fell` / `stable` / `changed` lower to flops and
    comparisons, so they work in every OSS tool (iverilog immediate-only,
    Verilator's growing SVA subset, SymbiYosys immediate + `$past`). Full
    sequence/property SVA remains an optional future target; the open front end
    for it (Yosys Property IR, Verific-free) is still landing through 2026.

### Phase 1.5 — parameterization, bundles, and elaboration passes (done)

- **Verilog parameter emission and instance-site overrides (done).** A comptime
  `Params` schema (`ParamSpec(W)` fields) on blocks and black boxes, with
  `instantiate(..., .{ .NAME = value })` emitting `module #(.NAME(value)) inst
  (...)`. Structure checks reject unknown parameters, widths over 64 bits and
  out-of-range values; elaborated blocks verify the schema against their
  `mb.parameter` declarations. Structural parameters (widths, port counts,
  memory depth, FSM encodings) are comptime by construction and now propagate
  through a family `Shape` schema: `instantiateShape(Family, ..., .{ .DEPTH =
  parent_depth }, ...)` merges defaults, builds the specialized child and
  checks its ports, so a parent's comptime value sizes a child's shape without
  duplicating the definition. Runtime `Param(W)` overrides stay 64-bit Verilog
  parameters and cannot size structure; this targets value parameters and
  external parameterized modules (the TT SRAM macro, PLL/IO wrappers, vendor
  IP) that cannot be specialized by elaboration.
  `BlackBox` gains a parameter list.
- **Bundle ports and bulk connect (done).** Recursive
  `declareInputs`/`declareOutputs` over nested structs of `Signal(W)`,
  direction flip via `dirs` metadata, `wireBundle` and a direction-aware
  `connect(src, dst)` for whole bundles, so `Stream` and future bus interfaces
  can be block ports without hand wiring. `instantiate` binds nested bundles and
  emits flattened port connections.
- **Elaboration passes (done).** Structural CSE via hash-consing and
  width/sign-aware constant folding run as expressions enter the IR
  (`ExprBuilder.dup`); dead-code elimination prunes unreachable symbols,
  assigns, and processes; the Verilog backend hoists subexpressions shared by
  two or more statement roots into deterministic `tmpN` wires. `finish()`
  rejects latch inference in comb processes, combinational loops, and undriven
  outputs, while reset coverage is structural (each process resets exactly
  what it assigns).
- **CDC lint (done).** `src/cdc.zig` reports unsynchronized sequential captures
  and unprotected asynchronous inputs, with per-bit domain ownership, declared
  per-bit synchronizer stages, per-bit structural first-flop recognition and
  asynchronous-input coverage resolved through instance subtrees (a parent's
  boundary row draws on the descendant declarations, each counted once).
  Crossing resolution through instance boundaries remains the consumer's.

### Phase 2 — backend targets and artifact contract (done)

11. **SystemVerilog backend (done).** `backend.zig` exposes a `Target` hub;
    `verilog.zig` remains the portable default. `systemverilog.zig` emits
    `logic`, `always_comb`/`always_ff`, FSM `enum` typedefs and inline packed
    structs for declared bundles (grouped instance connections, flat fallback
    for mixed-direction bundles). Verilog-2001 rejects `.systemverilog` foreign
    bodies; SystemVerilog accepts both languages.
12. **Metadata sidecar (done).** `backend/metadata.zig` writes `design.json`
    (`schema: js_asic.design/1`): module hierarchy, ports and signal widths,
    parameters, memories (modes/init files), bundle shapes, FSM/opcode enum
    groups, clock domains, and assertions with rendered expressions, for
    oasic's recovery and program views.
13. **SDC export (done).** `backend/sdc.zig` writes `asic_core.sdc`:
    `create_clock` per registered clock domain (period from `freq_hz`), clock
    uncertainty, and reset false paths for `timing/sta.odin`.
14. **Build integration (done; oasic simulator swap pending).** `zig build run`
    emits `asic_core.v` + `design.json` + `asic_core.sdc` (`--sv` adds
    `asic_core.sv`); `zig build lint` / `lint-sv` / `sim` / `verify` wrap
    Verilator and the transitional Icarus regressions. Every emitted module
    carries `` `timescale `` and restores `` `default_nettype wire ``.
    Embedded golden literals plus emit-twice byte-determinism tests pin the
    emission shape. `zig build sim` / `verify` are repointed at oasic's
    simulator and F1 flow once its Verilog front end lands.

### Phase 3 — IP library (in progress)

15. **Protocol blocks**: AXI4-Lite, UART, SPI master/target, I2C target, async
    FIFO, arbiter/round-robin, crossbar, timers, ROM/RAM wrappers. Landed
    beyond the CDC set: `blocks.UartBlock` (5..8 data bits, mid-bit sampling)
    with the `zig build uart` loopback witness, and the promoted
    `blocks.SpiSlaveProgrammerBlock` / `blocks.I2cSlaveLoaderBlock` (command
    decode, host write/ack and read/valid handshakes) with the `zig build spi`
    and `zig build i2c` witnesses. Remaining: AXI4-Lite, arbiter/round-robin,
    crossbar, timers, ROM/RAM wrappers.
16. **Testbench scaffolding**: emit TB skeletons and trace-driven checks
    (execution stays external). First instance done: `examples/blocks/vector_tb.zig`
    (a generated vector player with sampled-input checks) plus
    `examples/protocol_emulator/loader_read_tb.zig`, emitted by `zig build tb`;
    only the generic simulation harness (clock, bus combine, VCD, verdict glue)
    is a tagged `ForeignSource`.
17. **Optional structural export**: cell/netlist or a neutral IR to skip Verilog
    parsing for tighter round-trips.

### Explicit non-goals on this side

SAT/BMC/reachability, STA/timing closure, layout/extraction, RTL recovery,
waveform/VCD analysis, cycle-accurate simulation. These belong to `oasic`
(flows F1–F4). The seam stays: **Verilog + metadata + assertions out;
proofs/counterexamples/traces back.**

---

## 4. Verification Baseline

All components pass unit tests, synthesis, Verilator RTL linting, and behavioral
simulation:

```bash
# 1. Zig unit tests across library and example modules
zig build test

# 2. Synthesize complete ASIC Verilog netlist (out/asic_core.v, out/design.json,
#    out/asic_core.sdc); add --sv for out/asic_core.sv
zig build run

# 3. Verilator multi-module RTL linting (0 warnings, 0 errors)
zig build lint
zig build lint-sv          # also emits and lints out/asic_core.sv

# 3b. Enforced lint + behavioral simulation of every artifact
zig build verify

# 4. Icarus Verilog regressions (transitional; oasic's simulator replaces them)
#    all generated artifacts (netlist, binaries, VCDs) land in out/
#    a. host programs microcode over I2C -> 120 MHz GPIO execution
zig build sim
#    b. full RX loopback: host loads IN microcode, core samples gpio_in into
#       RX SRAM, host reads the word back over I2C read transactions (0x85)

# The raw commands behind `zig build sim` / `verify`:
iverilog -g2001 -o out/asic_i2c_iv out/asic_core.v examples/protocol_emulator/asic_i2c_tb.v && vvp out/asic_i2c_iv
iverilog -g2001 -o out/asic_rx_iv out/asic_core.v examples/protocol_emulator/asic_rx_tb.v && vvp out/asic_rx_iv
iverilog -g2012 -o out/asic_i2c_sv out/asic_core.sv examples/protocol_emulator/asic_i2c_tb.v && vvp out/asic_i2c_sv
```

Planned build integration (Phase 2): `zig build sim` (js_asic → oasic simulator,
stimulus/trace in and VCD out) and `zig build verify` (js_asic → oasic F1), so the
simulation claims above become enforced in CI rather than scripted.

---

## 5. Application Roadmap

### Track A — Physical layout & formal round-trip in `../oasic`
1. **(done) Verilog front end → synthesis → placement → GDS.**
   `js_asic/out/asic_core.v` parses (4 modules), synthesizes (3455 gates,
   278 DFFs), places (0.400mm x 0.240mm), and exports GDSII:
   ```bash
   ./oasic -synth ../js_asic/out/asic_core.v -synth-top programmable_asic_i2c_42 \
           -sta --clock-mhz 120 --gds-out asic_core.gds
   ```
   Cross-project regressions live in `oasic`: `parsers/verilog_test.odin`,
   `sim/verilog_synth_test.odin`, `sim/placement_test.odin`,
   `timing/sta_test.odin`.
2. **(in progress) Close the synthesis/timing gaps.** STA reports worst setup
   slack -2782 ps and worst hold slack -300 ps at 120 MHz, with 30 high-fanout
   nets. Also, only 278 DFFs appear, so the memory arrays are not yet expanded
   or modeled; memory macros must be represented before functional equivalence
   or meaningful timing is possible.
3. After placement/routing, re-run the functional miter on the extracted
   netlist and re-run `timing/sta.odin` for 120 MHz closure (F3).
4. Validate standard-cell routing and power grid integrity.

### Track B — Bidirectional Hardware RX & Data Streaming (done)

1. **Core RX opcode (`IN PINS, n`) (done):** each `IN` shifts `gpio_in[3:0]`
   into the 32-bit `isr`; after the eighth nibble the core pulses `rx_we`,
   writes `{isr[27:0], pin_in}` to the RX SRAM at `rx_ptr`, and increments the
   pointer.
2. **I2C slave read mode (`0x85`) (done):** the loader ACKs the read address,
   streams four bytes per word MSB-first, ACKs each byte (master NACK ends the
   transfer), and advances the read pointer, with `host_raddr`/`host_rdata`
   wired to the RX SRAM.
3. **Verification (done):** `examples/protocol_emulator/asic_rx_tb.v` programs `IN` microcode over
   I2C, samples a constant `gpio_in = 4'h5`, and reads back `0x55555555` from
   the RX SRAM. The I2C write regression (`asic_i2c_tb.v`) still passes.

### Track C — High-Level Protocol Microcode Suite
1. **10BASE-T Ethernet:** Manchester II encoder (12 cycles/bit), NLP generator.
2. **USB 1.1 Low-Speed:** NRZI encoder, bit-stuffing, SE0 EOP and bus reset.
3. **SPI master engine:** configurable CPOL/CPHA, baud divider.
4. **JTAG TAP controller:** IEEE 1149.1 16-state TAP FSM.

### Track D — FOSSi Z80 in js_asic (`examples/z80/`)

1. **Reference:** [openz80](https://github.com/rejunity/z80-open-silicon)
   (Apache-2.0): a silicon-proven Z80 clone built around Guy Hutchison's TV80
   Verilog core, taped out through Tiny Tapeout/OpenROAD on SKY130, IHP SG13g2
   and GF180, with ZEXALL/ZEXDOC as the correctness bar. Its bus interface and
   40-pin DIP40 pinout define the behavioral contract to match.
2. **Goal:** author the js_asic equivalent — a cycle-accurate Z80 core with the
   full DIP40 bus (`M1`//`RFSH`, `/MREQ`, `/IORQ`, `/RD`, `/WR`, `/WAIT`,
   `/INT`, `/NMI`, `/HALT`, `/BUSRQ`, `/BUSAK`), documented and undocumented
   instruction semantics and flags, emitting RTL + `design.json` + SDC like any
   other root design so oasic can run F1/F2/F3 against it.
3. **Planned breakdown:** `examples/z80/` gets its own blocks module with the
   datapath (8-bit ALU, register file incl. shadow registers, flags),
   instruction decode + microcycle sequencer, and bus interface; a test
   harness loads ZEXALL/ZEXDOC ROM images and replays them over the bus, first
   under iverilog, later through oasic's F1 flow with trace comparison.
4. **Milestones:** instruction subset in RTL → ZEXALL pass in simulation →
   timing/pin-compatibility checks against the openz80 reference → oasic
   equivalence and 120 MHz-class STA.
