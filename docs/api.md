# API review

This document is the completeness review of the authoring API: what the public
surface is, the contracts it guarantees, and where it is still incomplete. It
tracks the code in `src/`; when the two disagree, the code and its tests win.

## Entry points

A design is a Zig program with three moves:

```zig
var design = netlist.Design.init(allocator);
_ = try design.elaborate(TopBlock);          // build the root module
const rtl = try verilog.emitDesign(alloc, &design, .{});
```

Everything else hangs off that. The public surface is exported through
`src/root.zig`: `netlist`, `lib`, `blocks`, `backend`, `cdc`.

- `netlist` — the IR and builder: the only way to create hardware.
- `lib` — idioms built on the public builder (`Stream`, FSM, registers, CDC).
- `blocks` — parameterized structural IP.
- `backend` — artifact writers and the target hub.
- `cdc` — structural clock-domain-crossing lint over an elaborated design.

## The authoring surface

### Handles and types (`netlist`)

| Item | Purpose |
|---|---|
| `Signal(W)`, `SignedSignal(W)`, `Param(W)`, `Mem(W)` | nameless, width-typed handles; names live in the `Scope`. `SignedSignal` declares signed ports/wires/registers, `MemOpts.signed` declares a signed memory whose reads inherit it, and `asSigned` is only reinterpretation |
| `Expr(W)` / `AnyExpr` | width-carrying expressions; `AnyExpr` is the erased form |
| `ParamSpec(W)` | a value-parameter field type for `Params` schemas |
| `specializeShape(Family, overrides)` | resolves a family `Shape` schema (with defaults) to a concrete block type |
| `Design` | module registry; `elaborate`, `ensureModule`, `findModule`, `validateTimingHierarchy` |
| `ModuleBuilder` | elaborates exactly one module definition |
| `ExprBuilder` (`mb.exprs()`) | canonicalizing expression/statement factory |
| `Stmt`, `CaseBranch`, `CaseVal` | statement tree |
| `ClockDomain`, `PowerDomain`, `ResetPolicy`, `Reset`, `ResetSpec` | clock/reset intent |
| `MemOpts`, `ReadKind`, `WriteMode`, `MemPort`, `MemPortKind` | memory modes and declared ports |
| `EnumGroup`, `EnumEntry`, `FsmInfo`, `Bundle`, `BundleMember` | metadata shapes |
| `InputTiming`, `OutputTiming`, `SlewTiming`, `LoadValue`, `SyncStage` | timing intent |
| `ClockRelation`, `ClockRelationship` | clock-domain relationship intent |
| `ClockEdge`, `ActiveEdge` | active clock edge of a domain or process (`clk.negedge()`) |
| `GeneratedClock` | a clock generated on an output port from an input clock |
| `SourceLoc` | Zig source position recorded by `ModuleBuilder.at` |
| `ForeignSource`, `BlackBox` | verbatim foreign modules with typed ports |
| `FoldEvent`, `GroupTag` | provenance inputs |

### ModuleBuilder methods

| Group | Methods |
|---|---|
| Declarations | `input`, `signedInput`, `inout`, `outputPort`, `signedOutputPort`, `output`, `wire`, `signedWire`, `reg`, `signedReg`, `regArray`, `wireArray`, `constant`, `moduleParam`, `mem` |
| Bundles | `declareInputs`, `declareOutputs`, `declarePorts`, `wireBundle`, `connect` |
| Assignment | `assign`, `assignExpr` |
| Processes | `seq`, `seqNoReset`, `seqReset`, `seqEnable`, `seqResetEnable`, `comb` |
| Memory ports | `readPort`, `writePort`, `readWritePort` (each records a `MemPort`; any number per memory, each on its own clock) |
| Hierarchy | `instantiate` (typed `Inputs`/`Outputs` binding + `Params` overrides, literal or a parent `Param`/constant forwarded by name), `instantiateShape` (comptime `Shape` specialization forwarded to a child) |
| Clocking | `addClockDomain`, `createClockDomain`, `addGeneratedClock` |
| Metadata | `addEnumGroup`, `addEnumType`, `tagGroup`, `addInputTiming`, `addOutputTiming`, `at` (source locations) |
| Lifecycle | `init`, `deinit`, `exprs`, `intern`, `finish` |

### ExprBuilder methods

| Group | Methods |
|---|---|
| Literals/refs | `lit`, `ref`, `intern` |
| Sign/width | `asSigned`, `asUnsigned` (reinterpret an expression's signedness), `zext`, `sext`, `trunc`, `resize` |
| Logic | `not`, `bitNot`, `neg`, `and_`, `or_`, `band`, `bor`, `bxor` |
| Arithmetic | `add`, `sub`, `mul`, `div`, `mod` |
| Compare | `eq`, `ne`, `lt`, `le`, `gt`, `ge`, `slt`, `sle`, `sgt`, `sge` |
| Shift | `shl`, `shr` (signed operands emit `>>>`) |
| Select/concat | `ternary`, `mux`, `bit`, `bitDyn`, `slice`, `sliceDyn`, `index`, `concat`, `fill` |
| Reductions | `andAll`, `orAll`, `xorAll` |
| Memory | `memRead` |
| Statements | `nop`, `assign`, `sliceAssign`, `indexAssign`, `memWrite`, `memWriteBytes`, `when`, `caseBranch`, `caseBranchSym`, `case_` |
| Assertions | `assert_`, `assume_`, `cover_` (immediate, `ifdef`-guarded) |

### lib

`regNext`, `regEnable`, `muxLookup`, `rotl`, `rotr`, `rotlDyn`, `rotrDyn`,
`past`, `rose`, `fell`, `stable`, `changed`; `assertProperty`,
`assumeProperty`, `coverSequence`, `cycles`, `Implication` (bounded temporal
properties over history registers); `releasedDomain` (lowers a synchronous
reset release) (the register/sync helpers mirror a signed source
declaration, so their outputs stay signed); `Stream(W)` and
`SignedStream(W)` with `streamSource`/`streamSink`/`streamWire`,
`signedStreamSource`/`signedStreamSink`/`signedStreamWire`,
`connectStream`/`regStream`; `sync2`, `syncInput`, `pulseSync`,
`resetSync`, `resetSyncStages`; `decode`, `priorityEncode`, `isOneHot`;
`stateWidth`, `StateEncoding`, `StateMachine` (`create`, `current`, `param`,
`goto`, `arm`, `case_`, `run`).

### blocks

`SramBlock`, `TtSramBlock` (foreign macro), `FifoBlock`, `AsyncFifoBlock`,
`ReqAckBridgeBlock`, `BundledDataBlock`, `MailboxBlock`, `FifoMailboxBlock`,
`ResetSyncBlock`, `UartBlock`, `SpiSlaveProgrammerBlock`,
`I2cSlaveLoaderBlock`, `ShiftRegisterBlock`, `EdgeDetectorBlock`,
`CounterBlock`, `TimerBlock`, `RomBlock`, `RamBlock`,
`RoundRobinArbiterBlock`, `StreamCrossbarBlock`,
`Axi4LiteRegisterBlock`, `RegisterBankBlock` (AXI4-Lite, APB or Wishbone, with
`cHeader`/`regmapJson`), `ClockDividerBlock`, `ClockGateBlock`,
`Ethernet10BaseTBlock`.

### cdc

`lint(allocator, design)` returns `[]Crossing` for sequential captures that
read a signal driven only by another clock domain without a declared
synchronizer stage, a structurally recognized two-flop first flop, a declared
synchronous clock relationship or a request/acknowledge handshake. Domain
ownership, combinational observation and edge reads are tracked per data bit
(the first 64 bits of every signal; expressions propagate bit by bit where the
mapping is exact and stay whole-signal conservative otherwise), so a mixed
vector reports only its foreign bits and a structurally clean first flop
exempts only the bits that form it. A declared stage exempts the whole signal
when it names no bit and only its data bit otherwise; per-bit declared and
structural coverage applies to width-aligned direct captures, while a slice,
bit select or expression capture is exempt only when every bit is covered.
Findings carry `bit` for the affected data bit, or null when the whole signal is
reported. The lint also reports an input classified `asynchronous` with any
data bit covered by fewer than two declared synchronizer stages, one finding per
uncovered bit (`kind == .unsynchronized_input`; a whole-port row when no stage
names a bit). Coverage is gathered over the row's instance subtree, so a
parent's boundary row draws on the descendant stages that capture the signal,
each distinct declaration counted once; ancestor rows are not inherited
downward. Descriptive only: the lint never changes RTL.

### backend

| Writer | Output |
|---|---|
| `verilog.emitModule` / `emitModuleInto` / `emitDesign` | Verilog-2001 (portable default) |
| `systemverilog.emitModule` / `emitDesign` | SystemVerilog (`logic`, `always_*`, enums, packed struct bundles) |
| `metadata.emitDesignJson` | `design.json`: hierarchy, widths, memories, bundles, enums/FSMs, clocks, assertions, timing intent (v1 default; v2 opt-in adds slew, per-bit slew/load, output load/required and clock relationship/reset-release topology), resolved per-instance `Shape` values, forwarded-parameter sources, provenance |
| `sdc.emitDesignSdc` | `create_clock`, `create_generated_clock`, uncertainty, asynchronous clock groups, input/output delays, input transitions, loads, reset false paths |
| `meminit.files` | `$readmemh` files for memories with generated contents (`MemOpts.init_words`) |
| `stimulus.Writer` | `oasic.stimulus/1` schedule: one header (top, clock, period, input/output bit order) plus per-cycle `drive`/`expect` rows shared by fixtures |
| `provenance.Collector` | operation rows, authored groups, byte-exact RTL spans, artifact hash binding |
| `timing_contract` fixture | the consumer contract fixture (RTL, v2 JSON, v1 projection, stimulus, manifest) |

## Contracts the API relies on

1. **Widths are comptime.** `Expr(W)` and `Signal(W)` carry width; binops and
   `assign` check and coerce at compile time. No implicit truncation.
2. **Names resolve at emission.** Handles are nameless; deterministic symbol
   order and emission are pinned by byte-stability tests.
3. **`finish()` validates the module.** Duplicate signals/instances, multiple
   drivers, combinational loops, latch inference, undriven outputs, slice
   bounds, reset legality, parameter schema and timing references are rejected
   before any backend runs. `elaborate()` additionally validates cross-instance
   timing compatibility (`validateTimingHierarchy`): conflicting parent/child
   input rows or clock relationships fail the build, and the subtree pass
   rejects rows that resolve to the same module signal through silent levels or
   sibling branches, instead of reaching the consumer.
4. **Metadata is additive and versioned.** Provenance, timing intent and enum
   groups never change RTL bytes. Products emit `zihdl.timing_intent/1`;
   `/2` (slew/load/required, clock relationships, reset-release topology) is
   opt-in and adds fields without changing `/1` or existing `/2` field bytes.
   Declaration-level signedness adds `is_signed` to port/signal rows only when
   declared, so unsigned designs keep byte-identical `design.json`.
5. **DCE preserves declared identity.** Anything named by sidecar metadata
   stays live (e.g. declared synchronizer stages).

## Completeness verdict

Every construct the repository builds has a typed path, validation and at
least one artifact-level test, and the general-purpose constructs a generator
needs beyond them (signal arrays with runtime indexing, falling-edge flops,
multi-port and dual-clock memories with generated contents, bounded temporal
properties, clock generation, register banks, source locations and SDC lowered
from every authored timing intent) are witnessed by `zig build features`. The
holes that remain are listed below; work that belongs to the checker is in
`oasic`.

### Gaps by category

**Expression language**
- Binary arithmetic (`+`, `-`, `*`, `/`, `%`), bitwise (`&`, `|`, `^`) and
  comparison (`==`, `!=`, `<`, `<=`, `>`, `>=`, signed variants) operators
  normalize unequal-width operands to the operation width with explicit
  zero/sign extension (signed only when both operands are signed), so the
  emitted RTL is self-determined and constant folds match simulation; the
  `both signed` rule matches iverilog. Division by zero stays unfolded: Icarus
  yields `x` and `oasic` reports an explicit unknown-value failure. Shifts are
  width-typed by the left operand and assignments force explicit extension, so
  the shift amount never inherits operator context.
- Rotate has no operator: constant rotate is `lib.rotl`/`rotr` (slice
  concatenation); runtime rotate is `lib.rotlDyn`/`rotrDyn`, a `sliceDyn` of
  the doubled word.
- `sliceDyn(x, lo, W)` is the variable-position part-select (`x[lo +: W]`) and
  `index(items, i)` selects an element of a `[N]` array at runtime; both
  lower to a logical shift and read zero past the end, so out-of-range selects
  have one two-state value. Elements the index cannot reach are dropped from
  `index` and `indexAssign`. The selected width is always comptime. A
  register that is read but never assigned fails `finish()`.
- Signedness is declaration-level through `SignedSignal(W)` for ports, wires
  and registers, `MemOpts.signed` for memories and `SignedStream(W)` for
  streams (the symbol records it and references inherit it), and
  expression-level through `asSigned`/`asUnsigned` for reinterpretation.
- No `x`/`z`/tristate value; `inout` ports can be declared but not driven as
  high-impedance. Bidirectional pads are modeled as separate in/out/oe pins.
- No user-authored `initial`, `$display`, `$finish`, or file I/O. The IR has no
  initial construct; backends emit `$readmemh` initial blocks for declared
  memory init files. Testbench behavior lives in foreign modules or generated
  benches.

**Elaboration and parameterization**
- Structural parameters (widths, depths, port counts) are comptime type
  arguments. Block families declare a `Shape` schema of elaboration-time
  values and `specialize(shape) type`; `instantiateShape` merges instance-site
  overrides with the defaults and forwards a parent's comptime value into the
  child, producing a distinct checked module per shape. A family may declare
  `pub fn validateShape(comptime shape) void`; `resolveShape` runs it once on
  the merged shape before `specialize`, so cross-field constraints fail with a
  family-specific compile error. Runtime `ParamSpec` values remain 64-bit
  Verilog overrides and still cannot size ports or memories.
- No IR-level generate/loop construct: elaboration loops are Zig `inline for`.
  Intentional, but it means no reproducible "same source, runtime parameter
  set" flow.
- Runtime parameters flow through explicit `ParamOverride`, and a parent
  `Param(W)` or constant can be forwarded by name into a child override
  (emitted `#(.CHILD(PARENT))`), so a top-level override reaches descendants
  without being frozen to a literal; forwarded widths are checked against the
  child parameter. Forwarding is explicit by design: same-name symbols are
  never connected implicitly. Structural `Shape` values are explicit at each
  instantiation, and `instantiateShape` records the resolved shape (defaults
  merged with overrides) on the instance as `instances[].shape` in
  `design.json`.

**Memory**
- Ports are `readPort`, `writePort` and `readWritePort` (names unique per
  memory); a memory takes any number, each on its own clock and edge, with
  optional byte enables. When write ports on one clock write one address in
  one cycle, each 8-bit lane goes to the earliest port that writes it; ports
  on different clocks have no defined order on a same-instant collision, as
  in silicon. A read port returns the stored word;
  read-during-write behavior (`write_mode`) belongs to a read/write port.
  Array writes are reset-free processes, so a write during reset lands. A
  memory with ports is accessed only through them, so its `design.json` port
  rows and counts are complete. Register or latch storage takes writes on one
  clock and edge only.
- Banked and multidimensional storage are Zig arrays of memories; there is no
  nested memory type.
- Initialization is `$readmemh`, from a checked-in file or from
  `MemOpts.init_words` (width at most 64 bits), written by
  `backend.meminit.files` with every entry defined and hashed in
  `design.json`.

**Clocking, reset, CDC**
- `ResetRelease = .synchronous` is a checked claim: `Design.elaborate` traces
  the domain's reset, with its clock net, to the final stage of a declared
  `release_synchronizer` on the same clock and edge
  (`error.UnsynchronizedResetRelease` otherwise); only a top-level input stays
  external. `finish()` checks that a declared chain is at least two flops on
  the row's clock and edge, reset by one raw asynchronous reset to the
  asserted level, the first sampling the released level and each later stage
  the previous one. `lib.releasedDomain` lowers the policy in place and
  `blocks.ResetSyncBlock` packages the chain as a module.
- `sync2`, `syncInput`, `pulseSync`, `AsyncFifoBlock`, `ReqAckBridgeBlock`,
  `BundledDataBlock`, `MailboxBlock` and `FifoMailboxBlock` cover level, edge,
  gray-pointer and bundled-data handshake crossings, and `cdc.lint` audits
  elaborated designs structurally. The lint is heuristic: it cannot see
  metastability risk beyond structure, it tracks ownership and structural first
  flops per data bit but falls back to whole-signal reporting for shapes or
  widths it cannot map precisely, and a formal crossing proof is future work.
- `ClockDividerBlock` (even ratios, a declared generated clock) and
  `ClockGateBlock` (the technology ICG cell) cover clock generation; PLLs are
  foreign macros. Domains and processes capture on either edge.
- No multi-clock-domain structural check beyond per-process reset coverage and
  the opt-in `cdc.lint` pass.

**Timing and constraints**
- Timing intent covers input classification, synchronizer stages, arrival
  windows, reset policy, slew/load (whole-port plus per-bit overrides), output
  required windows (each with an explicit reference clock and edge), clock
  relationships and reset-release topology. Hierarchy contradictions are
  rejected transitively through silent levels and siblings, but constraint
  resolution stays consumer-side and no consumer analysis reads per-bit values
  yet.
- SDC lowers clocks, generated clocks, uncertainty, asynchronous clock
  groups, input and output delays, input transitions (rescaled to the library's
  slew thresholds) and loads, plus the explicit reset waiver. There are no
  multicycle paths yet.

**Verification-facing artifacts**
- Immediate assertions, plus bounded temporal properties (`##n` sequences
  with `|->`/`|=>` implication, assumptions and sequence covers) lowered to
  history registers; a sequence needs a condition and only a consequent may
  start with a delay. No `##[m:n]` ranges, repetition or native SVA.
- Simulation and proof belong to `oasic` (and to Verilator/Icarus for the
  witnesses); each fixture carries its own cycle model.
- `design.json` has no physical/pin/power (UPF) or test/scan data; scan
  insertion and power intent belong to the physical flow.

**IP library**
- `UartBlock` (single-clock TX/RX, 5..8 data bits, mid-bit sampling),
  `SpiSlaveProgrammerBlock` (write/start/stop command decode, host write pulse)
  and `I2cSlaveLoaderBlock` (parameterized device address, control-register
  pokes, host write-ack and read-valid handshakes) landed; `TimerBlock` and
  ROM/RAM wrappers, round-robin arbitration, a ready/valid crossbar and an
  AXI4-Lite single-register slave have RTL witnesses. The AXI4-Lite slave
  accepts independent AW/W channels in either order, applies byte strobes,
  and holds B/R responses under backpressure.
- `RegisterBankBlock(spec, bus)` generates a multi-register slave from the
  `registers.bank` layout (a struct of `bitfield` formats; `rw`, `ro`, `w1c`,
  `w1p` per field through the format's `access` declaration) on AXI4-Lite,
  APB4 or Wishbone classic, with field ports, a C header and a
  `zihdl.regmap/1` map; each bus has an Icarus witness running the same
  software scenario.

**Backends and packaging**
- Verilog-2001 and SystemVerilog only. Netlist/cell export, GDS and a
  command-line driver belong to `oasic`; each design is its own Zig
  executable.
- Generated RTL may carry `// @[file:line]` comments from `ModuleBuilder.at`;
  designs that never call it emit unchanged bytes.
- Package metadata ships the source, examples, documentation and MIT license
  (`build.zig.zon.paths`). The version remains `0.0.0` while the API is
  pre-release.
- Zig 0.17.1 is pinned; the project tracks Zig's `std.Io` churn closely.

The prioritized remaining work is in [PLAN.md](../PLAN.md).

## Stability policy

- `netlist`, `lib`, `blocks` and `backend` are one crate with no semver
  promise yet (version `0.0.0`). Internal churn is expected.
- The artifact schemas carry their own version strings and are the actual
  compatibility contract: `zihdl.design/1`, `zihdl.timing_intent/1` and
  `zihdl.provenance/1` are byte-stable, and `/2` timing intent is opt-in.
  The namespace rename from the former package name is a breaking artifact
  change for consumers that match the schema string.
  Optional fields added under `/2` are ignored by consumers that do not read
  them, so `/3` is reserved for incompatible changes.
- `oasic.stimulus/1` is the fixture/consumer stimulus contract; it lives in
  `src/backend/timing_contract_fixture.zig` and is built by an independent
  cycle model, never from emitted RTL.
