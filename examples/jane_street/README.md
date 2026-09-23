# Jane Street ASIC puzzle examples

This example uses the [Jane Street ASIC puzzle](https://github.com/janestreet/asic-puzzle-2026)
as a small, readable zihdl project. The region clues come from
[Mubin Shaikh's recovered map](https://github.com/shaikhmubin02/asic-puzzle-2026-solution/blob/main/results/region_map.txt).
The map is puzzle data; the winning key is computed by Zig.

- `warmup.zig` describes the supplied serial-adder warmup and emits
  `out/jane_street_warmup.v`.
- `puzzle_solution.zig` solves the 11×11 Two Stars puzzle, checks that its
  solution is unique, and writes the marked grid, serial key, and ROM image to
  `out/jane_street_solution.txt`, `out/jane_street_key.txt`, and
  `out/jane_street_key.hex`.
- `key_driver.zig` uses the reusable ROM block to emit a serial-key feeder.
- `star_battle.zig` builds a rule-level puzzle checker in zihdl and emits
  `out/jane_street_star_battle.v`. It checks two stars per row, column, and
  region, and rejects touching stars. Its output bus emits all four observed
  messages: `EMPTY SKY`, `BIG BANG`, `TRY AGAIN`, and `(* TWO STARS *)`.

From the zihdl root:

```sh
zig build jane-street
zig build verify-jane-street-puzzle
```

`jane-street` generates the Verilog, lints it, and runs standalone Icarus
witnesses for the warmup, key feeder, and all four checker messages. It is
included in `zig build verify`.

All checked-in design and testbench sources are Zig. `zig build testbenches`
emits the simulation `.v` files under `out/testbenches/`; no `.v` files are
kept in the source tree.

`verify-jane-street-puzzle` also needs sibling checkouts of `asic-puzzle-2026`
and `oasic`. It compares the warmup against the supplied Verilog, the generated
key against the solved key, and the checker against `oasic`'s lifted puzzle
Verilog. The miter samples both outputs after each edge in 144 runs: the winning
grid, zero/all-one grids, every single-bit change to the winning grid, and 20
other grids. It includes input pauses and extra enabled clocks. Finally the
GDS-derived simulator must reproduce the recorded 385-cycle solution VCD byte
for byte. Override the source paths with `-Dpuzzle-dir=...` and
`-Dpuzzle-rtl=...` as needed.

The zihdl checker uses the puzzle rules and readable strings. The lifted
Verilog implements those rules with counters, accumulators, a 12-stage history
register, and encoded output logic. The miter is a behavioral test under the
serial protocol; it is not an exhaustive formal proof for every possible input
and reset waveform.

The lifted RTL also agrees structurally with the
[published analysis](https://github.com/shaikhmubin02/asic-puzzle-2026-solution/blob/main/README.md):

| Published role | Lifted RTL state |
|---|---|
| Two 11-position coordinates | `state797`, `state1086` |
| End of the 121-bit input window | `q663` |
| Previous 12 input bits and adjacency flag | `sr889`, `q946` |
| Eight-bit total star count | `cnt1064` |
| Four-bit message position and success latch | `cnt102`, `q95` |

The lifted implementation has 92 flip-flops and uses gate-derived expressions
for its region checks and output bytes. The zihdl implementation stores the
board and describes the rules directly, so structural identity is not expected.
