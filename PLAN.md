# zihdl — Remaining Work

This file tracks unfinished work. The current implementation and verification
commands are in [README.md](README.md); API limits are in [docs/api.md](docs/api.md).
Physical implementation and signoff are tracked in `../oasic`.

## Deferred expansion

1. Add a neutral structural or cell-level export only if an `oasic` consumer
   needs to bypass Verilog parsing. Define the artifact contract and prove it
   represents the same elaborated design as Verilog and `design.json`.
2. Add concurrent SVA sequences and properties only with a backend and
   open-tool witness that preserves their semantics. Immediate and structural
   assertions already cover the current designs.
3. Choose and tag a package version when a pinned API contract is needed.
   `0.0.0` remains the stated pre-release version until then.
