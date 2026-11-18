# zihdl documentation

- [Code structure](code-structure.md) — how the authoring library is layered,
  where each kind of change belongs, and the invariants the layers rely on.
- [Migrating to zihdl](migration.md) — concept mapping and gotchas for people
  coming from Verilog/SystemVerilog, VHDL, Chisel, Amaranth/Migen and
  SpinalHDL, with a small side-by-side example.
- [Competitors and alternatives](competitors.md) — honest comparison against
  classical HDLs and host-language DSLs, and when zihdl is the wrong tool.
- [Design decisions](decisions.md) — the choices that shape zihdl (two-state
  values, errors at elaboration, the oasic split, versioned formats,
  constraints from intent, memory ports, register layouts), why each was made
  and what it costs.
- [API review](api.md) — the complete authoring surface, the contracts behind
  it, and the current gap list.

The top-level [README](../README.md) has artifact and quick-start material;
[PLAN.md](../PLAN.md) tracks remaining work. Current behavior and verification
commands are in the [README](../README.md).
