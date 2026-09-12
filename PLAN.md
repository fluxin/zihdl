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
├── root.zig                 # Module root: exports netlist, lib & blocks
├── netlist.zig              # Core: Scope, Signal/Param/Mem, Expr/Stmt, ModuleBuilder, Design, Verilog backend
├── lib.zig                  # Convenience layer: StateMachine, register helpers (built on the public builder API)
├── blocks.zig               # Elemental primitives export hub
└── blocks/
    ├── sram.zig             # Parameterized Dual-Port SRAM (1W1R)
    ├── fifo.zig             # Parameterized Synchronous FIFO
    ├── shift_reg.zig        # Parameterized Shift Register (SIPO / PISO)
    ├── edge_det.zig         # 2-FF Synchronizer & Edge Detector
    └── counter.zig          # Parameterized Up/Down Timer & Cycle Counter

examples/                    <-- Reference Programmable ASIC Design & Runner
├── main.zig                 # Runner: elaborate root block, emit asic_core.v
├── isa.zig                  # The 32-bit microcode instruction set
├── timing_execution_unit.zig# 120 MHz microsequencer core executing the ISA
├── i2c_slave_loader.zig     # I2C host programming controller (parameterized address)
├── spi_slave_programmer.zig # SPI host programming controller
├── programmable_asic.zig    # ProgrammableAsicBlock(loader, addr) top-level composition
└── asic_i2c_tb.v            # iverilog simulation testbench
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

- **F1 — pre-layout functional:** `asic_core.v` → `sim/verilog_synth.odin` →
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

### Simulation authority

**oasic's Verilog simulator is the one semantic reference, and we develop it
rather than depending on `iverilog`.** The path is
`parsers/verilog.odin` → `sim/verilog_synth.odin` → `sim/circuit_sim.odin`
(eventually the compiled `codegen/circuit_model.odin` fast path). iverilog and
Verilator remain lint/regression tools only; the checked-in
`examples/asic_i2c_tb.v` is transitional until the F1-sim path replays it.

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
4. **Parameters and symbolic constants.** Verilog `parameter` / `localparam`
   symbols usable in expressions and `case` labels; named FSM encodings, opcode
   IDs, register addresses. Keeps generated RTL readable and reduces per-value
   module duplication.
5. **BlackBox / inline Verilog.** Foreign modules with a port schema, emitted
   verbatim, for IO cells, PLLs, vendor macros and ROM initialization.

### Phase 1 — authoring expressiveness (done)

6. **FSM abstraction (done).** `lib.StateMachine(E, reset, encoding)`: named
   states emitted as `localparam`s, binary / one-hot / gray encodings, reset
   encoding, `arm` / `goto` / `case_` / `run`, and a hold-by-default arm so lint
   sees a complete case. The I2C loader state machine is migrated as the
   reference.
7. **Register/utility library (done).** `regNext`, `regEnable`, `mux`,
   reductions (`andAll` / `orAll` / `xorAll`), replication (`fill`), priority
   encoder (`priorityEncode`), decoder (`decode`), one-hot detect (`isOneHot`),
   dynamic bit-select (`bitDyn`), `Cat` via `concat`. A `muxLookup` helper can
   be added when a design needs it.
8. **Bundles and interfaces (done).** `lib.Stream(W)` with `streamSource` /
   `streamSink` / `streamWire` port and wire helpers, `connectStream` (forward
   data/valid, backward ready) and `regStream` pipeline stage. Larger bundles
   follow the same pattern (plain structs of typed handles).
9. **Clock/reset semantics (done).** `Reset` with async/sync × active-low/high
   kinds (`seqReset`, `seqResetEnable`), clock enables (`seqEnable`), multiple
   clock domains (already per-process), and `sync2` two-flop synchronizer for
   CDC. An async FIFO is deferred to the Phase 3 IP library.
10. **Assertions in the AST (done).** `assert_` / `assume_` / `cover_` emitted
    as immediate SVA guarded by `` `ifdef JS_ASIC_ASSERT `` (opt-in, so the
    portable Verilog-2001 baseline and lint remain clean). Neutral export to
    oasic is a Phase 2 item.

### Phase 2 — backend targets and artifact contract

11. **SystemVerilog backend** behind a target option (`always_comb`/`always_ff`,
    `logic`, enums/structs); Verilog-2001 remains the portable default.
12. **Metadata sidecar** (`design.json`): hierarchy, widths, FSM encodings,
    opcodes, assertions, for oasic's recovery and program views.
13. **SDC export** for `timing/sta.odin`.
14. **Build integration**: `zig build lint` (Verilator) done; `zig build sim`
    (oasic simulator) and `zig build verify` (invoke oasic on the emitted
    artifact) pending the oasic front end. Golden-file and
    emission-determinism tests, plus `` `timescale `` emission and
    `` `default_nettype `` restore.

### Phase 3 — IP library

15. **Protocol blocks**: AXI4-Lite, UART, SPI master/target, I2C target, async
    FIFO, arbiter/round-robin, crossbar, timers, ROM/RAM wrappers.
16. **Testbench scaffolding**: emit TB skeletons and trace-driven checks
    (execution stays external).
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

# 2. Synthesize complete ASIC Verilog netlist (asic_core.v)
zig build run

# 3. Verilator multi-module RTL linting (0 warnings, 0 errors)
zig build lint

# 4. Icarus Verilog regressions (transitional; oasic's simulator replaces them)
#    a. host programs microcode over I2C -> 120 MHz GPIO execution
iverilog -g2001 -o asic_i2c_iv asic_core.v examples/asic_i2c_tb.v && vvp asic_i2c_iv
#    b. full RX loopback: host loads IN microcode, core samples gpio_in into
#       RX SRAM, host reads the word back over I2C read transactions (0x85)
iverilog -g2001 -o asic_rx_iv asic_core.v examples/asic_rx_tb.v && vvp asic_rx_iv
```

Planned build integration (Phase 2): `zig build sim` (js_asic → oasic simulator,
stimulus/trace in and VCD out) and `zig build verify` (js_asic → oasic F1), so the
simulation claims above become enforced in CI rather than scripted.

---

## 5. Application Roadmap

### Track A — Physical layout & formal round-trip in `../oasic`
1. **(done) Verilog front end → synthesis → placement → GDS.** `asic_core.v`
   parses (4 modules), synthesizes (3455 gates, 278 DFFs), places
   (0.400mm x 0.240mm), and exports GDSII:
   ```bash
   ./oasic -synth asic_core.v -synth-top programmable_asic_i2c_42 \
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
3. **Verification (done):** `examples/asic_rx_tb.v` programs `IN` microcode over
   I2C, samples a constant `gpio_in = 4'h5`, and reads back `0x55555555` from
   the RX SRAM. The I2C write regression (`asic_i2c_tb.v`) still passes.

### Track C — High-Level Protocol Microcode Suite
1. **10BASE-T Ethernet:** Manchester II encoder (12 cycles/bit), NLP generator.
2. **USB 1.1 Low-Speed:** NRZI encoder, bit-stuffing, SE0 EOP and bus reset.
3. **SPI master engine:** configurable CPOL/CPHA, baud divider.
4. **JTAG TAP controller:** IEEE 1149.1 16-state TAP FSM.
