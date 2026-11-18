# zihdl — Remaining Work

This file tracks unfinished work. The current implementation and verification
commands are in [README.md](README.md); API limits are in [docs/api.md](docs/api.md).
Simulation, proof, synthesis, timing analysis and physical implementation are
`../oasic`'s and are not planned here.

## Next

1. Review the 0.1 authoring features (SDC lowered from intent, checked reset
   release, signal arrays, clock edges, memory ports and generated contents,
   source locations, temporal properties, clock generation, register banks),
   then tag `0.1.0` in `build.zig.zon` and freeze `zihdl.design/1`,
   `zihdl.timing_intent/1`, `/2`, `zihdl.provenance/1` and `zihdl.regmap/1`
   against that release.

## Deferred expansion

1. Multicycle-path exceptions, after 0.1.0 and once a design needs one, as a
   checked claim. A wrong multicycle path hides a real failure from STA, and
   simulation never shows it.
   - **Authoring:** an N-cycle path from a source register to a destination
     register, with a launch enable that gates every write to the source and
     a capture enable that gates every write to the destination. The two may
     be separate strobes N cycles apart, as in multi-cycle dividers and FSMs.
   - **Structure, checked at elaboration:** both registers are synchronous
     flops on one clock and edge, every write to the source is under the
     launch enable, and every write to the destination is under the capture
     enable. A destination that loads every cycle is rejected, including a
     quasi-static configuration path: a live write would be sampled while it
     settles in cycles 1 … N-1.
   - **Timing, checked by assertion:** "for N-1 cycles after the launch
     enable, the source holds and the capture enable stays low" is a
     sequential property, not structure. zihdl emits it as an immediate
     assertion through the property lowering, so simulators and oasic's BMC
     check it. zihdl has no solver.
   - **Lowering:** `set_multicycle_path -setup N` and `-hold N-1` between
     the two registers. This needs a register-to-cell/pin naming convention
     agreed with Yosys, OpenSTA and oasic, because a multi-bit RTL register
     becomes per-bit cells; today the SDC names only instance ports.
   - **Additive:** the metadata rows and SDC lines appear only when declared,
     so the 0.1 schemas don't change. The conformance design gains a case,
     and oasic's SDC reader needs `set_multicycle_path`.
2. Ranged and repeated sequences (`##[m:n]`, `[*n]`) for `lib.assertProperty`,
   lowered the same way as fixed delays.
3. A neutral structural or cell-level export only if an `oasic` consumer needs
   to bypass Verilog parsing.
