#!/usr/bin/env bash
set -euo pipefail

puzzle_dir=${1:-../asic-puzzle-2026}
extracted_rtl=${2:-../oasic/out/workbench-tests/golden/files/puzzle_rtl.v}
repo_dir=$(pwd -P)
extracted_rtl=$(realpath "$extracted_rtl")
read -r key < "$repo_dir/out/jane_street_key.txt"
[[ $key =~ ^[01]{121}$ ]]
cmp "$repo_dir/out/jane_street_key.txt" "$puzzle_dir/answer"

iverilog -g2012 -DORIGINAL_WARMUP -s warmup_tb \
    -o "$repo_dir/out/jane_street_original_iv" \
    "$repo_dir/out/jane_street_warmup.v" \
    "$repo_dir/out/testbenches/warmup_tb.v" \
    "$puzzle_dir/warmup/00_source.v"
vvp "$repo_dir/out/jane_street_original_iv"

iverilog -g2012 -s star_battle_miter \
    -o "$repo_dir/out/jane_street_miter_iv" \
    "$repo_dir/out/jane_street_star_battle.v" \
    "$repo_dir/out/testbenches/star_battle_miter.v" \
    "$extracted_rtl"
vvp "$repo_dir/out/jane_street_miter_iv"

cd "$puzzle_dir"
./gds_decompile puzzle.gds -trykey "$key" -vcd-out "$repo_dir/out/jane_street_replay.vcd"
cmp "$repo_dir/out/jane_street_replay.vcd" solution.vcd
echo "JANE STREET PUZZLE PASS: key, 385-cycle VCD, success and answer match"
