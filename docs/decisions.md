# Design decisions

The choices that shape zihdl, why they were made and what they cost. The
[API review](api.md) lists the resulting contracts and gaps. This page
explains them. Each entry is a decision, not a missing feature: changing one
is a format or semantics change, not a fix.

## 1. Two-state values: no `x`, no `z`, no internal tristate

**Decision.** Every signal is 0 or 1. There is no `x` or `z` value and no
tristate driver. A bidirectional pad is three plain signals, `in`, `out` and
`oe`. `inout` ports can be declared but never driven to high impedance.

**Why.** Verilog's `z` and VHDL's `std_logic` describe the wire as an
electrical object: several drivers share a net and a resolution function
decides its value. That matched 1980s and 1990s hardware: board buses,
internal tristate buses in early ASICs, and FPGA long lines such as the
XC4000's `TBUF`s. `x` describes what gate-level simulation cannot know: a flop
at power-up, two drivers fighting. Synthesis also reads it as "don't care".

zihdl targets standard-cell ASICs (oasic, sky130, IHP, Tiny Tapeout), where
none of that applies:

- **No on-chip tristate.** Standard-cell flows never use internal tristate:
  synthesis turns it into multiplexers or rejects it, and floating nets and
  driver contention break timing, power and test. The only real tristate is
  in the pad cell, which already has separate output, output-enable and input
  pins, so `in`/`out`/`oe` is that cell one to one, with nothing to resolve.
- **Mistakes that make `x` are errors instead** (decision 2), before any RTL
  exists. Verilog finds them by letting `x` spread through a simulation and
  hoping someone looks.
- **Every tool must agree bit for bit.** The same design gives identical
  values in Verilator, Icarus, oasic's simulator and a Zig reference model.
  zio-diff compares every output bit with the model over 192k random cycles,
  and equivalence checking compares netlists. With `x` that breaks:
  Verilator is two-state and makes up a value while Icarus is four-state,
  `if (x)` in Verilog RTL silently takes the `else` branch so simulation can
  look better than silicon, and formal encodings double.
- **Shared-bus behavior is modeled where it physically lives.** I2C is open
  drain on a wired-AND bus. The design drives a pin's output enable, and the
  test harness models the bus (wired-AND, pull-ups, the target) outside it.

Most newer frameworks make the same move. Chisel, Amaranth, SpinalHDL,
Bluespec and Clash are two-state inside the design and keep tristate at the
pads, through `Analog`, `TriState` bundles or I/O buffers with an output
enable. Some keep a don't-care value for optimization or an escape hatch for
`inout` IP. zihdl goes one step further and has neither.

**Cost.** IP with internal tristate buses has to be wrapped as a `BlackBox`
foreign module. Synthesis gets no don't-care freedom. Power-on `x` checking
happens downstream, in gate-level simulation. The RTL is ordinary Verilog,
so a four-state simulator such as Icarus can still show `x`, for example for
a memory word nothing has written. zihdl only keeps you from authoring one.

## 2. Mistakes are elaboration errors, not simulation surprises

**Decision.** `ModuleBuilder.finish()` and `Design.elaborate` reject, before
any backend runs:

- **Drivers:** multiple drivers, undriven outputs, and a register that is
  read but never assigned.
- **Logic:** combinational loops, and combinational processes that miss
  paths (latches).
- **Resets:** illegal resets.
- **Selects:** out-of-range selects; a dynamic select past the end reads zero.

Widths are checked at Zig compile time, and nothing truncates implicitly.

**Why.** These are the situations Verilog leaves to lint or to `x` in a
simulation. Failing the build is cheaper than finding them in silicon, and
it is what lets decision 1 hold.

**Cost.** zihdl is stricter than Verilog, so some legal Verilog idioms
(deliberate latches, wired buses) need a `BlackBox`.

## 3. zihdl authors; oasic checks and builds

**Decision.** zihdl elaborates designs and emits artifacts. Simulation, formal
proof, synthesis, timing analysis, layout and netlist/GDS export belong to
[oasic](https://fluxin.com/oasic), across a file and JSON boundary. Neither
links against the other.

**Why.** It keeps the checker independent of the generator: a bug in zihdl
cannot hide itself from the tool that checks its output. Any other consumer
(OpenSTA, LibreLane, Yosys, Verilator) reads the same files.

**Cost.** There is no in-tree simulator, so you run Icarus, Verilator or
oasic. Verilog-2001 and SystemVerilog are the only HDL outputs.

## 4. Artifacts are the product, and their formats are versioned

**Decision.** RTL, `design.json`, SDC, provenance, timing intent and register
maps carry schema strings (`zihdl.design/1`, `zihdl.timing_intent/1` and
`/2`, `zihdl.provenance/1`, `zihdl.regmap/1`). They freeze at 0.1.0. Optional
fields appear only when a design declares them, so a design that doesn't use
a feature emits byte-identical files. Every change to zihdl is proven by
diffing every generated artifact against the previous build, and any file
that changes is explained in the commit.

**Why.** Consumers match on schema strings and field shapes, not on zihdl's
source code.

**Cost.** Adding a field is easy; changing one needs a new schema version.

## 5. One test design covers the whole format

**Decision.** `backend.conformance` is one design that uses every SDC command
and every optional `design.json` field: clock edges, asynchronous clocks,
generated clocks on ports and pins, every memory port kind, storage intent,
generated contents, and every IO-timing form. `zig build features` writes it
to `out/conformance/`, and a unit test pins the SDC text and every field.

**Why.** zihdl is generic: it has to support every design, not just the ones
in this repository. A consumer tested against today's designs only handles
the forms those designs happen to use. Building the fixture found two SDC
bugs no existing design triggered.

**Cost.** The fixture must grow with every new form. The test fails if a
form disappears, not if a new one goes untested.

## 6. Constraints come only from authored intent

**Decision.** The SDC is lowered from what the design declares; nothing is
invented.

- **Clocks:**
  - Each clock port gets one `create_clock`. Further domains on that port,
    such as its falling edge, share it and must agree on its period.
  - A generated clock divides by 1 or an even number, so it keeps a 50% duty
    cycle and its edges stay on rising edges of its source clock.
- **Relationships:** an asynchronous pair's groups include the clocks
  generated from each side.
- **IO windows:**
  - Every IO delay is written against the rising edge. A falling-edge
    required window is folded into the numbers, never emitted as
    `-clock_fall`.
  - Input slew is rescaled to the target library's thresholds, which the user
    must give.
- **Resets:** reset release is timed by default. Cutting reset paths is an
  explicit, validated waiver.

**Why.** A constraint the author didn't write is a guess, and a wrong guess
can hide a timing failure. Rising-edge numbers and one clock per port are
what every STA tool reads the same way. zihdl never picks a slew measurement
basis, because that belongs to the cell library.

**Cost.** Multicycle paths and other exceptions have to wait until they can be
authored.

## 7. Synchronous reset release is a checked claim

**Decision.** `ResetPolicy.release = .synchronous` must be backed by a real
release synchronizer on the domain's own clock and edge. Elaboration traces
the reset, with its clock net, through the hierarchy to the final stage of a
declared chain. It also proves the chain is real:

- at least two flops on that clock and edge;
- reset by one raw asynchronous reset to the asserted level;
- the first stage samples the released level, and each later stage samples
  the one before.

**Why.** An unsynchronized release is a metastability bug that simulation
almost never shows. Writing "synchronous" in metadata must not make it true.

**Cost.** Only a top-level input's release stays an unchecked claim, because
it comes from outside the design.

## 8. One memory port model

**Decision.** `readPort`, `writePort` and `readWritePort` are the only way to
give a memory ports:

- **Ports:** any number of them, each with its own clock domain and optional
  byte enables.
- **Access:** a memory with ports is reached only through them, so
  `design.json` port rows and counts are complete.
- **Collisions:** writers on one clock resolve each byte lane in port order.
- **Reset:** writes sit in reset-free processes so synthesis infers a memory.
- **Storage:** register or latch storage takes writes on one clock and edge
  only, since each storage flop has one clock pin. `storage` is a hint
  (`ram_style`); the RTL stays behavioral.

**Why.** A macro mapper needs to know exactly which ports exist, with their
clocks and byte enables. That has to be read from the design, not inferred
from expressions.

**Cost.** You can't mix direct `memRead`/`memWrite` with ports on one memory.
A multi-clock RAM must be `storage = .macro` or `.any`.

## 9. Memory initial contents are emitted as written

**Decision.** `MemOpts.init_file` appears verbatim in `$readmemh` and
`design.json`. Tools resolve it from the current directory, then the RTL
file's directory; a bare name next to the RTL keeps a bundle movable.
`MemOpts.init_words` generates the file from Zig data, with every entry
written and a SHA-256 recorded. zihdl allows initial contents on a memory
that is also written.

**Why.** zihdl does not rewrite user paths. Initial contents on written
memories are real for FPGA bitstreams and simulation, so a generic generator
keeps them.

**Cost.** An ASIC consumer will refuse initial contents on a written memory,
because silicon flops and SRAM macros have no power-on value. oasic is adding
that check.

## 10. One register layout definition

**Decision.** A register bank is a struct of `bitfield` packed formats whose
defaults are the reset values:

- **One layout, two entry points:** `registers.bank` (registers inside a
  module) and `blocks.RegisterBankBlock` (an AXI4-Lite, APB or Wishbone
  slave) take the same layout.
- **Format declarations:** `access` (`ro`, `w1c`, `w1p`; the rest `rw`) and
  `summary`.
- **Reserved fields:** `reserved` and `reserved_<suffix>` read zero.
- **Register map:** the C header and `zihdl.regmap/1` carry enum tags, not
  free-text field docs.

**Why.** One definition serves the hardware, the host software, the docs and
the register map, so they cannot drift apart. Zig field types carry enums,
not docstrings.

**Cost.** Register offsets in `RegisterBankBlock` follow layout order. The
block has no sparse address map.

## 11. Properties lower to checks every tool sees the same way

**Decision.** `lib.assertProperty` and its siblings lower fixed-delay
sequences and implications to shared history registers and one immediate
assertion. There is no native SVA. A sequence made only of delays, or an
antecedent or cover that starts with a delay, is a compile error.

**Why.** Every simulator and oasic evaluate a plain two-state assertion
identically. SVA support varies by tool.

**Cost.** Only fixed delays (`##n`) are supported. Ranged and repeated
sequences are deferred.

## 12. Deterministic arithmetic corners

**Decision.** Dynamic rotates rotate by `n mod W`. Dynamic selects past the
end read zero. Every operator has one defined result for every input.

**Why.** It follows from decision 1: a value with two possible meanings is
an `x` in disguise.

**Cost.** None, beyond matching these definitions in reference models.
