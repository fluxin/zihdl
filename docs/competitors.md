# Competitors and alternatives

This is a comparison for choosing a direction, not a scorecard. Every project
listed here is more mature than js_asic in some dimension, and several are
better choices for most users. The comparison states what each tool optimizes
for so you can decide.

## The landscape

There are two families:

- **Classical HDLs** — Verilog/SystemVerilog, VHDL, Veryl, Spade. The source
  *is* the hardware description; tools are mature and portable.
- **Host-language generators** — Chisel (Scala), Amaranth/Migen (Python),
  SpinalHDL (Scala), Clash (Haskell). The source is a program that elaborates
  an IR; "elaboration" is ordinary execution of the host language.

js_asic is in the second family: a Zig library that elaborates typed handles
and emits Verilog. Its distinguishing choices are (a) a compiled, statically
typed host with explicit widths, (b) artifacts as the product — RTL plus
`design.json`, SDC, provenance and timing intent — and (c) a deliberate split
from its checker, `oasic`, at a file/JSON boundary.

## Comparison

| | Host language | Elaboration | Emits | Simulation / formal | Primary focus |
|---|---|---|---|---|---|
| **js_asic** | Zig (library) | compiled Zig program runs once | Verilog-2001, SystemVerilog, JSON/SDC/provenance | none in-tree; external `oasic`/Verilator/iverilog | typed ASIC authoring + machine-readable artifact contract |
| Verilog / SystemVerilog | HDL | elaboration in the tool | itself | every commercial/OSS tool; SVA, UVM | universal interchange, verification |
| VHDL | HDL | elaboration in the tool | itself | mature toolchains | strongly typed classical HDL |
| Chisel | Scala (embedded DSL) | JVM program, FIRRTL IR | Verilog | chiseltest (Verilator); Treadle historically | parameterized generator libraries; Rocket Chip ecosystem |
| Amaranth (and Migen) | Python (embedded DSL) | Python elaboration | Verilog | Python simulator; Verilator | approachable generator language; LiteX SoCs |
| SpinalHDL | Scala (embedded DSL) | JVM elaboration | Verilog, VHDL | SpinalSim (Verilator) | Scala-typed RTL with strong bus/stream libraries |
| Clash | Haskell | compiled, functional | VHDL, Verilog, SystemVerilog | Haskell testbenches; external tools | type-driven, function/pipeline design |
| Veryl | Veryl (Rust-like HDL) | compiler | SystemVerilog | external tools | modern HDL ergonomics in a real HDL |
| Spade | Spade (Rust-like HDL) | compiler | Verilog | testbench framework + simulation tooling | pipelines, explicit timing annotations |

Licenses and maturity vary; check each project before adopting. None of these
values are niche in the way js_asic is: outside this repository, js_asic has no
published package, no release process and no external user base.

## Where js_asic differs technically

1. **Compiled host, explicit widths.** `Expr(W)` carries width in the Zig type;
   `Signal(W)` handles carry width in the type; `assign` is compile-time
   checked. You get IDE navigation, `zig test` and compile errors, but you also
   get no REPL and no runtime introspection.
2. **No simulator, by design.** js_asic owns elaboration and reference intent;
   `oasic` owns simulation, SAT/BMC, STA and physical. The seam is files and
   JSON, not a library call, which keeps the checker independent.
3. **Artifacts are first-class.** `design.json` carries hierarchy, widths,
   memories, bundles, FSMs/opcodes, clock domains, assertions and timing
   intent; a provenance collector emits operation rows and byte-exact source
   spans against the artifact hash. This is oriented at recovery and checker
   provenance in a way HDLs and most DSLs do not address.
4. **Strict structural validation.** Multiple drivers, combinational loops,
   latches, undriven outputs and reset coverage are rejected in `finish()`
   rather than left to lint. This is more restrictive than Verilog and more
   comparable to SpinalHDL/Chisel's structural checks.
5. **No four-state semantics.** Only 0/1 exist; there is no `x`/`z` and no
   tristate expression. Verification of unknowns belongs to simulation tools.
6. **Comptime parameters, not runtime generics.** Widths and depths are
   specialization-time decisions, mirroring Chisel's elaboration-time
   parameters but without a separate IR (`FIRRTL`) or an interpreter to debug.

## When to choose something else

- **You need the ecosystem.** Existing IP, vendor primitives, mixed-language
  projects and thousands of pages of SVA/UVM point to Verilog/SystemVerilog or
  VHDL.
- **You want Python or Scala productivity.** Amaranth/Migen and Chisel/
  SpinalHDL have years of libraries, simulators and community answers.
- **You need a built-in simulator today.** Amaranth, SpinalHDL and Spade ship
  one; js_asic does not, and `oasic` is still landing its Verilog front end.
- **You need functional/system-level modeling (untimed, transactions,
  testbenches).** SystemC/SystemVerilog or a host-language testbench fits
  better; js_asic is RTL-only.
- **You need parameteric generators without recompiling a host program.**
  Classic HDL `parameter`/`generate` or Chisel's parameter system can be more
  ergonomic than comptime Zig for some suites.
- **You want a real HDL with modern syntax.** Veryl or Spade are closer to
  drop-in HDL replacements; js_asic is a generator library, not a language.

## When js_asic is a good fit

- The design is authored as code with strong width/type checking and no
  runtime.
- You want emitted Verilog plus a machine-readable contract for an independent
  checker, not a simulator built into the authoring tool.
- You value deterministic, byte-stable artifacts (hashing, provenance, SARIF-
  like downstream tooling).
- The team already builds in Zig and accepts a young, single-maintainer
  library with a small IP set.
- The target flow is ASIC-style: synthesize/lint/formal/STA downstream rather
  than FPGA-vendor-specific flows.

## Non-goals

js_asic intentionally does not own: SAT/BMC/reachability, STA or timing
closure, layout/extraction, RTL recovery, waveform analysis or cycle-accurate
simulation. Those live in `oasic`. It also does not attempt SystemVerilog
testbench/UVM support, vendor inference pragmas or mixed-signal modeling.
