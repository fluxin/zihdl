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
| `MemOpts`, `ReadKind`, `WriteMode` | memory modes |
| `EnumGroup`, `EnumEntry`, `FsmInfo`, `Bundle`, `BundleMember` | metadata shapes |
| `InputTiming`, `OutputTiming`, `SlewTiming`, `LoadValue`, `SyncStage` | timing intent |
| `ClockRelation`, `ClockRelationship` | clock-domain relationship intent |
| `ForeignSource`, `BlackBox` | verbatim foreign modules with typed ports |
| `FoldEvent`, `GroupTag` | provenance inputs |

### ModuleBuilder methods

| Group | Methods |
|---|---|
| Declarations | `input`, `signedInput`, `inout`, `outputPort`, `signedOutputPort`, `output`, `wire`, `signedWire`, `reg`, `signedReg`, `constant`, `moduleParam`, `mem` |
| Bundles | `declareInputs`, `declareOutputs`, `declarePorts`, `wireBundle`, `connect` |
| Assignment | `assign`, `assignExpr` |
| Processes | `seq`, `seqNoReset`, `seqReset`, `seqEnable`, `seqResetEnable`, `comb` |
| Memory ports | `syncRead`, `readWritePort` |
| Hierarchy | `instantiate` (typed `Inputs`/`Outputs` binding + `Params` overrides), `instantiateShape` (comptime `Shape` specialization forwarded to a child) |
| Clocking | `addClockDomain`, `createClockDomain` |
| Metadata | `addEnumGroup`, `addEnumType`, `tagGroup`, `addInputTiming`, `addOutputTiming` |
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
| Select/concat | `ternary`, `mux`, `bit`, `bitDyn`, `slice`, `concat`, `fill` |
| Reductions | `andAll`, `orAll`, `xorAll` |
| Memory | `memRead` |
| Statements | `nop`, `assign`, `sliceAssign`, `memWrite`, `memWriteBytes`, `when`, `caseBranch`, `caseBranchSym`, `case_` |
| Assertions | `assert_`, `assume_`, `cover_` (immediate, `ifdef`-guarded) |

### lib

`regNext`, `regEnable`, `muxLookup`, `rotl`, `rotr`, `past`, `rose`, `fell`,
`stable`, `changed` (the register/sync helpers mirror a signed source
declaration, so their outputs stay signed); `Stream(W)` and
`SignedStream(W)` with `streamSource`/`streamSink`/`streamWire`,
`signedStreamSource`/`signedStreamSink`/`signedStreamWire`,
`connectStream`/`regStream`; `sync2`, `syncInput`, `pulseSync`,
`resetSync`, `resetSyncStages`; `decode`, `priorityEncode`, `isOneHot`;
`stateWidth`, `StateEncoding`, `StateMachine` (`create`, `current`, `param`,
`goto`, `arm`, `case_`, `run`).

### blocks

`SramBlock`, `TtSramBlock` (foreign macro), `FifoBlock`, `AsyncFifoBlock`,
`ReqAckBridgeBlock`, `MailboxBlock`, `FifoMailboxBlock`, `ResetSyncBlock`,
`ShiftRegisterBlock`, `EdgeDetectorBlock`, `CounterBlock`.

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
reported. On flat modules the lint also reports an input classified
`asynchronous` with any data bit covered by fewer than two declared
synchronizer stages, one finding per uncovered bit (`kind ==
.unsynchronized_input`; a whole-port row when no stage names a bit); parent
boundary rows that resolve through instances are left to the consumer.
Descriptive only: the lint never changes RTL.

### backend

| Writer | Output |
|---|---|
| `verilog.emitModule` / `emitModuleInto` / `emitDesign` | Verilog-2001 (portable default) |
| `systemverilog.emitModule` / `emitDesign` | SystemVerilog (`logic`, `always_*`, enums, packed struct bundles) |
| `metadata.emitDesignJson` | `design.json`: hierarchy, widths, memories, bundles, enums/FSMs, clocks, assertions, timing intent (v1 default; v2 opt-in adds slew, per-bit slew/load, output load/required and clock relationship/reset-release topology), provenance |
| `sdc.emitDesignSdc` | `create_clock`, uncertainty, reset false paths |
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
   groups never change RTL bytes. Products emit `js_asic.timing_intent/1`;
   `/2` (slew/load/required, clock relationships, reset-release topology) is
   opt-in and adds fields without changing `/1` or existing `/2` field bytes.
   Declaration-level signedness adds `is_signed` to port/signal rows only when
   declared, so unsigned designs keep byte-identical `design.json`.
5. **DCE preserves declared identity.** Anything named by sidecar metadata
   stays live (e.g. declared synchronizer stages).

## Completeness verdict

For the scope the repository actually exercises — the protocol emulator, the
elemental blocks and the contract fixture — the authoring API is closed: every
construct those designs use has a typed path, validation, and at least one
artifact-level test. The remaining holes are known and mostly tracked in
`PLAN.md`; they matter if js_asic is to become a general-purpose generator
rather than the authoring half of this specific project.

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
  concatenation); dynamic rotate is built from shifts/ors.
- No dynamic-width part-select: `slice` is comptime-only; `bitDyn` selects one
  bit at runtime. Variable field extraction needs `shift`+`mask` today.
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
  child, producing a distinct checked module per shape. Runtime `ParamSpec`
  values remain 64-bit Verilog overrides and still cannot size ports or
  memories.
- No IR-level generate/loop construct: elaboration loops are Zig `inline for`.
  Intentional, but it means no reproducible "same source, runtime parameter
  set" flow.
- Runtime parameters flow only through explicit `ParamOverride`; there is no
  automatic propagation or symbol visibility guarantee across hierarchy.
  Structural `Shape` values are explicit at each instantiation.

**Memory**
- One read port plus one write path per memory (`syncRead`, `readWritePort`);
  no true dual-port, banked or multi-address memories.
- No multidimensional or nested memories; `MemOpts` covers read kind,
  write mode and file init only.
- Initialization is `$readmemh` from a file path; no inline data or generated
  init content.

**Clocking, reset, CDC**
- `ResetRelease` is descriptive; `lib.resetSync` lowers an async-assert /
  sync-release chain in place, and `blocks.ResetSyncBlock` packages the same
  chain as a flat module that declares its `release_synchronizer` and is meant
  to drive the released domain's reset. The policy field itself still does not
  generate the chain.
- `sync2`, `syncInput`, `pulseSync`, `AsyncFifoBlock`, `ReqAckBridgeBlock`,
  `MailboxBlock` and `FifoMailboxBlock` cover level, edge, gray-pointer and
  bundled-data handshake crossings, and `cdc.lint` audits elaborated designs
  structurally. The lint is heuristic: it cannot see metastability risk beyond
  structure, it tracks ownership and structural first flops per data bit but
  falls back to whole-signal reporting for shapes or widths it cannot map
  precisely, and a formal crossing proof is future work.
- No clock divider/PLL/gating primitives; PLLs are foreign macros.
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
- SDC emits clocks, uncertainty and reset false paths; no IO delays, generated
  clocks or multicycle paths.

**Verification-facing artifacts**
- Assertions are immediate and structural only; no concurrent SVA, sequences
  or coverage.
- No in-tree simulator or reusable reference interpreter; each fixture carries
  its own cycle model, and `oasic` is the long-term replay authority.
- `design.json` has no physical/pin/power (UPF) or test/scan data.

**IP library**
- No AXI4-Lite, UART, SPI master/target, I2C target, arbiter/crossbar, timer or
  ROM/RAM wrapper as library blocks (Phase 3). I2C/SPI controllers exist only
  as example blocks.

**Backends and packaging**
- Verilog-2001 and SystemVerilog only: no VHDL, no structural netlist/cell
  export, no GDS (physical lives in `oasic`), no C/RTL co-simulation model.
- No standalone CLI; each design is its own Zig executable.
- Package metadata ships only `build.zig`, `build.zig.zon` and `src`
  (`build.zig.zon.paths`), the version is `0.0.0`, and there is no `LICENSE`
  file; zip package consumers therefore get no docs or license.
- Zig 0.16.0 is pinned; the project tracks Zig's `std.Io` churn closely.

### Suggested next steps, in order

1. **CDC depth.** The bridge, mailbox, FIFO mailbox, async FIFO and structural
   lint, now with per-bit ownership and per-bit declared/structural coverage,
   landed; next are wider bundled-data handshake shapes and a formal crossing
   proof rather than a heuristic audit.
2. **Parameter propagation**: structural `Shape` specialization from a
   parent's comptime values landed with `instantiateShape`. Remaining: runtime
   parameter propagation (constrained by comptime widths), richer shape
   constraint errors, and recording resolved shape values in `design.json`.
3. **Consume the per-bit timing rows**: declaration, validation and additive
   `/2` export for per-bit slew/load landed, and hierarchy contradictions are
   rejected transitively through silent levels and siblings. The live consumer
   still reads whole-port rows only and constraint resolution stays
   consumer-side; `/3` remains reserved for incompatible schema changes.
4. **Reusable reference model**: lift the per-fixture cycle models into a
   small interpreter/testbench generator so stimulus expectations are not
   rewritten per test.
5. **Process**: add a `LICENSE`, decide whether docs ship in the package
   `paths`, and tag versions when consumers pin hashes.

## Stability policy

- `netlist`, `lib`, `blocks` and `backend` are one crate with no semver
  promise yet (version `0.0.0`). Internal churn is expected.
- The artifact schemas carry their own version strings and are the actual
  compatibility contract: `js_asic.design/1`, `js_asic.timing_intent/1` and
  `js_asic.provenance/1` are byte-stable, and `/2` timing intent is opt-in.
  Optional fields added under `/2` are ignored by consumers that do not read
  them, so `/3` is reserved for incompatible changes.
- `oasic.stimulus/1` is the fixture/consumer stimulus contract; it lives in
  `src/backend/timing_contract_fixture.zig` and is built by an independent
  cycle model, never from emitted RTL.
