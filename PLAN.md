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
2. oasic's SDC reader must accept what the SDC now emits: `set_input_transition`,
   `set_load`, and `create_generated_clock` with `get_pins` targets and sources.
   Until it does, a design that declares input slew, output load or a generated
   clock produces SDC that oasic rejects (the other readers accept it).

## Deferred expansion

1. Multicycle-path exceptions, once a design needs one: authored on a
   register-to-register path and lowered to `set_multicycle_path`.
2. Ranged and repeated sequences (`##[m:n]`, `[*n]`) for `lib.assertProperty`,
   lowered the same way as fixed delays.
3. A neutral structural or cell-level export only if an `oasic` consumer needs
   to bypass Verilog parsing.
