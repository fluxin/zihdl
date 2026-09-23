# Migrating to zihdl

zihdl is not an HDL dialect and not an embedded Python/Scala DSL. It is a Zig
library: your design is a Zig program that runs at build time, elaborates typed
handles into an IR, and exits after writing artifacts. If you are coming from
another HDL or generator, this page maps the concepts and calls out the traps.

## The mental model shift

| Old world | zihdl |
|---|---|
| A language interpreter/compiler reads your design | Your design is compiled by Zig and *runs*, then quits |
| Signals are values with runtime behavior | Signals are nameless, width-typed handles into a `Scope`; only the emitter resolves names |
| The simulator is authoritative | No simulator in-tree: artifacts are emitted for external tools (`oasic`, Verilator, iverilog) |
| Widths are checked at elaboration/simulation | Widths are checked at Zig compile time and again in `finish()` |
| Testbenches are part of the source language | Reuse `BlackBox`/`ForeignSource` for existing testbenches, or generate stimulus + replay externally |

Consequences worth internalizing: there is no `x`/`z` value, no user-authored
`initial` block (declared memory init files are lowered to `$readmemh`), no
`$display`, no four-state event queue, and no procedural loop that exists at
runtime. Anything that needs to *observe* hardware belongs in a testbench
artifact or in the checker (`oasic`), not in the design.

## From Verilog / SystemVerilog

| Verilog / SV | zihdl |
|---|---|
| `module m(...); ... endmodule` | `pub const M = struct { pub const name = "m"; pub const Inputs = ...; pub const Outputs = ...; pub fn build(mb: *ModuleBuilder) !void }` |
| `input wire [7:0] a` | `a: Signal(8)` in `Inputs` + `mb.declareInputs(Inputs)` |
| `output reg [7:0] y` | `y: Signal(8)` in `Outputs` + `mb.reg("y_r", 8, 0)` / `mb.output(...)` |
| `assign y = a & b;` | `try mb.assign(y, b.band(a, b))` |
| `always @(posedge clk)` | `try mb.seq(domain, &.{ ... })` |
| `always @(posedge clk or negedge rst_n)` with reset branch | `try mb.seq(domain, ...)` — the reset branch is generated per process from the signals the process assigns |
| `if (en) q <= d;` | `b.when(en, &.{b.assign(q, d)}, &.{})` |
| `case (state) ... endcase` | `lib.StateMachine(...)` + `arm`/`case_`/`run`, or `b.case_(...)` |
| `parameter W = 8;` / `#(.W(16))` | Structural widths are comptime Zig args; value parameters use `ParamSpec(W)` and `Params` + `.W = 16` at the instance site |
| `generate` / `for` | Comptime `inline for` in `build()`; the IR has no generate construct |
| `$signed(x)` / `>>>` | `b.asSigned(x)`, `b.sext(...)`, `b.shr(...)` (emits `>>>` when the operand is signed) |
| `'z` / tristate | Not modeled; use separate `out`/`oe`/`in` signals for bidirectional pads |
| `module m#(...) ( .a(a) ) u1 (...);` | `try mb.instantiate(M, "u1", .{ .a = a }, .{ .y = y }, .{ .W = 16 })` |
| `` `include `` / vendor primitives | `netlist.BlackBox(.{ .name = ..., .inputs = ..., .outputs = ..., .foreign = netlist.ForeignSource.verilog("...") })` |

Side by side, an 8-bit enabled counter:

```verilog
// counter.v
module counter(input wire clk, input wire rst_n, input wire en,
               output reg [7:0] count);
  always @(posedge clk or negedge rst_n)
    if (!rst_n) count <= 8'd0;
    else if (en) count <= count + 8'd1;
endmodule
```

```zig
// counter.zig
const zihdl = @import("zihdl");
const netlist = zihdl.netlist;
const Signal = netlist.Signal;

pub const Counter = struct {
    pub const name = "counter";
    pub const Inputs = struct { clk: Signal(1), rst_n: Signal(1), en: Signal(1) };
    pub const Outputs = struct { count: Signal(8) };

    pub fn build(mb: *netlist.ModuleBuilder) !void {
        const ins = try mb.declareInputs(Inputs);
        const outs = try mb.declareOutputs(Outputs);
        const domain = netlist.ClockDomain{ .clk = ins.clk, .rst_n = ins.rst_n };
        const b = mb.exprs();

        const count = try mb.reg("count", 8, 0);
        try mb.assign(outs.count, count);
        try mb.seq(domain, &.{
            b.when(ins.en, &.{b.assign(count, b.add(count.expr(), 1))}, &.{}),
        });
    }
};

// main.zig: elaborate and emit
var design = netlist.Design.init(alloc);
_ = try design.elaborate(Counter);
const rtl = try zihdl.backend.verilog.emitDesign(alloc, &design, .{});
```

### Reusing existing Verilog

`BlackBox` wraps a foreign body with a typed port schema so it wires like any
other block. The body is emitted verbatim by the matching backend: the
Verilog-2001 target accepts `verilog` bodies, and the SystemVerilog target
accepts both `verilog` and `systemverilog` bodies. This is the migration path
for vendor macros, PLLs, IO cells, and testbench-only modules such as clock
generators.

## From VHDL

| VHDL | zihdl |
|---|---|
| `entity` / `architecture` pair | one block struct: `Inputs`, `Outputs`, `build` |
| `std_logic_vector(7 downto 0)` | `Signal(8)` |
| `std_logic` | `Signal(1)` |
| `process(clk, rst)` | `mb.seq`, `mb.seqReset`, `mb.seqEnable`, `mb.comb` |
| `rising_edge(clk)` | `ClockDomain` passed to `seq` |
| `generic (W : integer := 8)` | comptime type argument (structural) or `ParamSpec(W)` (value) |
| `when`/`else`, `case` | `mb.when`, `StateMachine`/`mb.case_` |
| `others => '0'` | `b.fill(0, K)` or explicit literal |
| `assert` / `report` | `b.assert_(cond, "message")`, emitted as guarded immediate SVA |
| package of shared types | a Zig module imported by the blocks that use it |

## From Chisel

| Chisel / FIRRTL | zihdl |
|---|---|
| `class M extends Module` | `pub const M = struct { ... }` |
| `val io = IO(new Bundle { ... })` | `Inputs` / `Outputs` structs of `Signal(W)` |
| `UInt(8.W)` / `SInt(8.W)` | `Expr(8)` / `Expr(8)` + `asSigned`; signedness is expression-level, not a type |
| `Wire(UInt(8.W))` | `try mb.wire("w", 8)` |
| `RegNext(x)` / `RegInit(0.U)` | `lib.regNext(mb, "name", x, domain)` / `mb.reg("name", W, 0)` |
| `when (cond) { ... } .otherwise { ... }` | `b.when(cond, &.{...}, &.{...})` |
| `switch (state) { is (s) { ... } }` | `lib.StateMachine(E, reset, encoding)` with `arm`/`case_`/`run` |
| `Cat(a, b)` | `b.concat(.{ a, b })` |
| `Mux(sel, a, b)` | `b.mux(sel, a, b)` / `b.ternary(...)` |
| `Bundle` / `DecoupledIO` | plain structs of handles, recursive flattening, `dirs` metadata; `lib.Stream(W)` for ready/valid |
| FIRRTL / `emitVerilog` | no intermediate IR exposed; emit Verilog-2001/SystemVerilog plus `design.json`, SDC, provenance, timing intent |
| Treadle / Verilator via `chiseltest` | external: `oasic` (planned native), or generated iverilog benches |

The big differences: zihdl has no `Clock`/`Reset` implicit context (a
`ClockDomain` is passed explicitly), no implicit last-connect semantics
(`finish()` rejects multiple drivers instead), and no Scala meta-programming.
Compile-time generation is just Zig `inline for`, `comptime` and functions
returning handles.

## From Amaranth / Migen

| Amaranth (migen) | zihdl |
|---|---|
| `class M(Elaboratable)` | block struct with `build` |
| `Signal(8)` | `Signal(8)` |
| `m.d.comb += y.eq(a & b)` | `try mb.assign(y, b.band(a, b))` |
| `m.d.sync += q.eq(d)` | `try mb.seq(domain, &.{b.assign(q, d)})` |
| `with m.If(cond):` / `with m.Else():` | `b.when(cond, ..., ...)` |
| `m.FSM()` | `lib.StateMachine(E, reset, .binary|.one_hot|.gray)` |
| `Record` / `stream.Signature` | structs of handles + `dirs`, `lib.Stream(W)` |
| `Module()` hierarchy | explicit `Design` + `instantiate` |
| Python simulator (`m.d.sync`, `Simulator`) | none in-tree; replay externally with `oasic.stimulus/1` + `oasic` |
| `platform` / LiteX integration | none: physical integration belongs to `oasic` |

The largest process difference: Amaranth's statements are Python-side objects
built at elaboration, while zihdl statements are values returned by
`mb.exprs()` and assembled into arrays. There is no `+=` operator; call
`mb.assign` (or `b.assign` for statement values).

## From SpinalHDL

| SpinalHDL | zihdl |
|---|---|
| `class M extends Component` | block struct with `build` |
| `val io = new Bundle { ... }` | `Inputs` / `Outputs` structs |
| `Reg(UInt(8 bits))` / `RegInit` | `mb.reg("n", 8, init)` |
| `when(...) { ... } otherwise { ... }` | `b.when(cond, ..., ...)` |
| `switch(state) { is(...) { ... } }` | `lib.StateMachine` + `arm`/`case_`/`run` |
| `Stream` / `Flow` | `lib.Stream(W)` + `connectStream`/`regStream` |
| `ClockDomain` | `netlist.ClockDomain` passed to `seq`; `ResetPolicy` carries polarity/assertion/release |
| Verilog/VHDL generation | Verilog-2001 + SystemVerilog only |

SpinalHDL's strongest parallel is the explicit clock domain plus stream
helpers; the strongest difference is that zihdl emits no VHDL and has no
simulator or waveform debugger of its own.

## Migration checklist

1. Define the top block's `Inputs`/`Outputs` with explicit widths; declare the
   clock domain.
2. Port leaf logic first: assignments, comb, then registers with `seq`.
3. Replace `for`/`generate` with comptime `inline for`; replace parameter
   plumbing with a `Params` struct only where values are truly runtime
   parameters (bit widths and depths stay comptime).
4. Wrap vendor/VHDL/testbench code with `BlackBox`/`ForeignSource`.
5. Emit RTL and metadata, then run the design through `oasic` or iverilog.
6. If a construct does not fit, check [api.md](api.md) before inventing a
   workaround; missing IR capability is a library change, not a user patch.

## What does not carry over

- Behavioral testbenches, `$display`/`$finish`, file I/O, and `initial`
  blocks: keep them in a Verilog testbench (foreign source) or generate
  stimulus for an external player.
- Concurrent SVA, coverage, and UVM: assertions are immediate and structural;
  formal proof belongs to `oasic`.
- Four-state semantics, `x`-propagation and `z`/tristate: only two-state
  signals exist. Model bidirectionality with explicit `in`/`out`/`oe` pins.
- Vendor inference pragmas and timing constraints beyond SDC clocks,
  uncertainty and false paths.
