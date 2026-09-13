# Code structure

`js_asic` is a hardware construction library in pure Zig (0.16.0). There is no
separate HDL, no compiler binary and no runtime: a design is a Zig program that
elaborates typed handles into an IR and hands the IR to a backend. This document
is the map of that code and the rules for extending it.

## Layering

Dependencies point downward only. `lib`, `blocks` and every backend are ordinary
users of the `netlist` API; none of them can see private state or bypass
validation.

```
examples/            application designs + contract fixture (top of the tree)
   protocol_emulator/   reference ASIC, ISA, generated testbenches
   blocks/              shared example blocks
   contract/            timing-intent artifact fixture runner
backend/             artifact writers and HDL targets
   render.zig           shared hoisting pre-pass + expression/statement text
   verilog.zig          Verilog-2001 target (portable default)
   systemverilog.zig    SystemVerilog target
   metadata.zig         design.json sidecar
   sdc.zig              SDC constraints
   provenance.zig       optional operation/group/source-map collector
   backend.zig          Target hub + emission options
blocks/              elemental reusable IP (SRAM, sync + async FIFO, CDC bridge/bundled data/mailboxes/reset sync, shift reg, edge det, counter)
lib.zig              conveniences: registers, streams, CDC, encoders, FSMs
cdc.zig              structural clock-domain-crossing lint over elaborated designs
netlist.zig          the IR: Scope, handles, Expr/Stmt, ModuleBuilder, Design
root.zig             module root; exports netlist, lib, blocks, backend, cdc
```

`src/root.zig` is the single import surface: examples import `js_asic` and use
`js_asic.netlist`, `js_asic.lib`, `js_asic.blocks`, `js_asic.backend` and
`js_asic.cdc`.

## What each layer owns

| Layer | Owns | Does not own |
|---|---|---|
| `netlist.zig` | Names, width-typed handles, expressions, processes, elaboration, validation, DCE, design registry | HDL syntax, file formats, convenience idioms |
| `lib.zig` | Reusable idioms built only on the public builder API (`regNext`, `Stream`, `sync2`, `StateMachine`, ...) | New IR nodes or validation |
| `blocks/` | Parameterized structural IP with a `name`/`Inputs`/`Outputs`/`build` contract | Application logic |
| `backend/` | Target syntax, artifact schemas, determinism | Design intent or elaboration |
| `examples/` | Composition, parameters, microboot programs, testbench generation | Library semantics |

The split matters for a specific reason: `lib.zig` is a client of the same API
that user code uses. If a convenience helper needs something the public builder
cannot express, the fix goes into `netlist.zig` as a first-class capability,
not into a privileged path.

## The block contract

Every reusable definition is a struct with four members:

```zig
pub const Blinker = struct {
    pub const name = "blinker";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), en: Signal(1) };
    pub const Outputs = struct { led: Signal(1) };
    pub fn build(mb: *ModuleBuilder) !void { ... }
};
```

`assertBlock` compile-time-checks the shape when the type is first instantiated.
`Design.elaborate(Top)` builds the root and marks it top; `Design.ensureModule`
builds dependencies on first use, keyed by the comptime-mangled `name`, so a
definition is emitted exactly once no matter how many instances use it or how
they are parameterized.

A **block family** replaces `Inputs`/`Outputs` with a `Shape` schema plus
`specialize(comptime shape: Shape) type`:

```zig
pub const FifoFamily = struct {
    pub const Shape = struct { DEPTH: usize = 16, WIDTH: usize = 8 };
    pub fn specialize(comptime shape: Shape) type { return struct { ... }; }
};
```

`instantiateShape(FifoFamily, ..., .{ .DEPTH = 32 }, ...)` merges the override
with the schema defaults at comptime, builds the concrete block type and checks
the instance bindings against its ports. A parent can forward its own comptime
value (often a field of its own `Shape`) into the child, which is how
structural parameters propagate through hierarchy; each distinct shape is its
own emitted module. Runtime `Param(W)` overrides still apply to the concrete
module's `Params` schema and never change port widths.

Handles (`Signal(W)`, `Param(W)`, `Mem(W)`) are nameless and width-typed; the
`Scope` owns names. Two instances can never collide by name because names are
resolved at emission.

## Where a change belongs

| Change | Location |
|---|---|
| New arithmetic/select/statement capability, new validation | `src/netlist.zig` |
| New reusable idiom (register, stream, encoder) | `src/lib.zig` |
| New parameterized structural block | `src/blocks/<name>.zig` + export in `src/blocks.zig` |
| New analysis over an elaborated design | `src/cdc.zig` (lint) or a new `src/<pass>.zig`, exported from `src/root.zig` |
| New output artifact or HDL target | `src/backend/` + wire into `src/backend.zig` and `src/root.zig` tests |
| New application/example | `examples/` |
| Contract fixture coverage | `src/backend/<x>_fixture.zig` + runner in `examples/` when consumers replay it |

## Invariants

These are load-bearing; tests and review should reject changes that break them.

1. **Names are resolved at emission.** No hash-table ordering leaks into
   emitted text. Emission is byte-deterministic; `zig build test` contains
   emit-twice tests.
2. **Widths and signedness are comptime.** Every `Expr(W)` carries its width in
   the type; binaries coerce explicitly; `assign` is width-checked everywhere,
   not just at ports.
3. **`finish()` is the validation gate.** Duplicate signals and instances,
   multiple drivers, combinational loops, latch inference, undriven outputs,
   slice bounds and timing-intent references are all rejected there, not at
   emission time.
4. **Metadata never changes RTL.** Timing intent, provenance, enum groups,
   groups and timing declarations are descriptive. `bindArtifact` ties
   provenance to the exact bytes; emitting with or without it produces the same
   RTL.
5. **DCE keeps declared identities.** Dead-code elimination prunes unreachable
   symbols, but anything referenced by authored intent (synchronizer stages,
   ports) stays live so the artifact always contains what the sidecar names.
6. **Artifact schemas are versioned and opt-in.** `js_asic.design/1` and
   `js_asic.timing_intent/1` are byte-stable for products; `/2` timing intent is
   request-only. v1 output must not change when v2 is added.
7. **Fixture models are independent.** A contract fixture's expected behavior
   comes from a hand-written cycle model, never from the emitted RTL or the
   simulator under test.
8. **One direction across the seam.** js_asic emits Verilog/metadata; `oasic`
   parses, simulates, proves and places. No shared memory, no FFI, no oasic
   code in this repository.

## Build graph

`build.zig` is the whole project file. The steps used most:

| Step | What it does |
|---|---|
| `zig build test` | Unit tests across library, blocks and backends |
| `zig build run` | Elaborates the reference ASIC and writes `out/asic_core.v`, `design.json`, `.sdc` (+ split A/B build); `-- --sv` adds `asic_core.sv` |
| `zig build lint` / `lint-sv` | Verilator lint of the emitted RTL |
| `zig build sim` | Transitional iverilog regressions (oasic's simulator replaces these) |
| `zig build verify` | Enforced lint + simulation of every artifact + contract fixture |
| `zig build contract` | Emits the timing-intent fixture under `out/contract/` |
| `zig build async-fifo` | Emits, lints and Icarus-replays the dual-clock async FIFO witness |
| `zig build cdc` | Emits, lints and Icarus-replays the request/acknowledge bridge + bundled-data + mailbox/FIFO-mailbox witness |
| `zig build divmod` | Emits, lints and Icarus-replays the division/remainder fixtures (signal-driven probe + folded constants, zero-divisor x case) |
| `zig build tb`, `zio` | Generated testbench and ZIO witness bundles |

## Tests

Tests live next to the code they cover: `netlist.zig` unit tests at the bottom
of the file, `src/backend/*_test.zig`, `src/backend/*_fixture.zig` for golden
and contract fixtures, and example-local tests for the protocol emulator.
`src/root.zig` is what pulls the backend tests into `zig build test`.

New behavior should come with the narrowest test that proves it: an IR-level
unit test for validation, an emit-twice or golden test for byte shape, a
fixture test for anything a consumer parses, and an iverilog/`verify` artifact
test when the claim is about simulated behavior.
