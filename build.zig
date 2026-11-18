const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("zihdl", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from the
        // root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    const testbench_sources_exe = b.addExecutable(.{
        .name = "zihdl_testbench_sources",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/testbench_sources.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const testbench_sources_gen = b.addRunArtifact(testbench_sources_exe);
    const testbenches_step = b.step("testbenches", "Generate verification testbenches under out/testbenches");
    testbenches_step.dependOn(&testbench_sources_gen.step);

    const vector_bench_mod = b.createModule(.{
        .root_source_file = b.path("examples/testing/vector_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    const trace_harness_mod = b.createModule(.{
        .root_source_file = b.path("examples/testing/trace_harness.zig"),
        .target = target,
        .optimize = optimize,
    });
    const protocol_harness_mod = b.createModule(.{
        .root_source_file = b.path("examples/testing/protocol_harness.zig"),
        .target = target,
        .optimize = optimize,
    });
    const witness_wrapper_mod = b.createModule(.{
        .root_source_file = b.path("examples/testing/witness_wrapper.zig"),
        .target = target,
        .optimize = optimize,
    });
    const jane_bench_exe = b.addExecutable(.{
        .name = "zihdl_jane_street_benches",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/jane_street/bench_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "vector_bench", .module = vector_bench_mod }},
        }),
    });
    const jane_bench_gen = b.addRunArtifact(jane_bench_exe);
    testbenches_step.dependOn(&jane_bench_gen.step);
    b.step("jane-benches", "Generate Jane Street simulator vectors from Zig")
        .dependOn(&jane_bench_gen.step);

    // Example-level design blocks (ISA, loaders, execution units); depends on
    // the library module and is shared by the reference projects.
    const blocks_mod = b.createModule(.{
        .root_source_file = b.path("examples/blocks/blocks.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zihdl", .module = mod },
            .{ .name = "witness_wrapper", .module = witness_wrapper_mod },
        },
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "zihdl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protocol_emulator/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zihdl", .module = mod },
                .{ .name = "protocol_blocks", .module = blocks_mod },
                .{ .name = "witness_wrapper", .module = witness_wrapper_mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // Generated testbench runner: builds the vector stimulus in Zig and emits
    // out/loader_read_tb.v + out/loader_read_tb_stim.hex.
    const tb_exe = b.addExecutable(.{
        .name = "zihdl_tbgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protocol_emulator/loader_read_tb.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zihdl", .module = mod },
                .{ .name = "protocol_blocks", .module = blocks_mod },
                .{ .name = "witness_wrapper", .module = witness_wrapper_mod },
            },
        }),
    });
    const tb_gen = b.addRunArtifact(tb_exe);

    // Partition testbench generator: reference-model vectors for the shared
    // 256x32 macro partition (arbiter, skid, ring, status).
    const part_tb_exe = b.addExecutable(.{
        .name = "zihdl_partition_tbgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protocol_emulator/partition_tb.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zihdl", .module = mod },
                .{ .name = "protocol_blocks", .module = blocks_mod },
                .{ .name = "witness_wrapper", .module = witness_wrapper_mod },
            },
        }),
    });
    const part_tb_gen = b.addRunArtifact(part_tb_exe);

    const core_witness = b.addExecutable(.{
        .name = "zihdl_zio_core_witness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protocol_emulator/zio_core_witness.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zihdl", .module = mod }},
        }),
    });
    const core_gen = b.addRunArtifact(core_witness);
    const core_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-s", "zio_timing_unit_x16_f16_vectors_tb", "-o", "out/zio_core_iv", "out/zio_core.v", "out/zio_core_tb.v" });
    core_compile.step.dependOn(&core_gen.step);
    const core_run = b.addSystemCommand(&.{ "vvp", "out/zio_core_iv" });
    core_run.step.dependOn(&core_compile.step);
    const zio_core_step = b.step("zio-core", "Emit the ZIO capture/control witness and replay it in Icarus");
    zio_core_step.dependOn(&core_run.step);

    // Ethernet 10BASE-T transmit testbench generator: cycle-accurate expected
    // waveform for the Manchester encoder, NLP generator and stream handshake.
    const eth_tb_exe = b.addExecutable(.{
        .name = "zihdl_ethernet_10base_t_tbgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/blocks/ethernet_10base_t_tb.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zihdl", .module = mod },
                .{ .name = "witness_wrapper", .module = witness_wrapper_mod },
            },
        }),
    });
    const eth_tb_gen = b.addRunArtifact(eth_tb_exe);

    // Dual-clock async FIFO witness: emits the gray-pointer FIFO RTL and
    // replays Zig-authored fill, overflow, and wrap transactions.
    const async_fifo_exe = b.addExecutable(.{
        .name = "zihdl_async_fifo_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/blocks/async_fifo_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zihdl", .module = mod },
            },
        }),
    });
    const async_fifo_gen = b.addRunArtifact(async_fifo_exe);
    const async_fifo_lint = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wno-MULTITOP", "out/async_fifo_16x8.v" });
    async_fifo_lint.step.dependOn(&async_fifo_gen.step);
    const async_fifo_compile = b.addSystemCommand(&.{
        "iverilog",              "-g2001",                          "-o", "out/async_fifo_iv",
        "out/async_fifo_16x8.v", "out/testbenches/async_fifo_tb.v",
    });
    async_fifo_compile.step.dependOn(&async_fifo_gen.step);
    const async_fifo_run = b.addSystemCommand(&.{ "vvp", "out/async_fifo_iv" });
    async_fifo_run.step.dependOn(&async_fifo_compile.step);
    const async_fifo_step = b.step("async-fifo", "Emit, lint and replay the dual-clock async FIFO witness");
    async_fifo_step.dependOn(&async_fifo_lint.step);
    async_fifo_step.dependOn(&async_fifo_run.step);

    // UART witness: single-clock TX/RX loopback replayed with Icarus.
    const uart_exe = b.addExecutable(.{
        .name = "zihdl_uart_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/blocks/uart_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zihdl", .module = mod },
            },
        }),
    });
    const uart_gen = b.addRunArtifact(uart_exe);
    const uart_lint = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wno-MULTITOP", "out/uart_witness.v" });
    uart_lint.step.dependOn(&uart_gen.step);
    const uart_compile = b.addSystemCommand(&.{
        "iverilog",           "-g2001",                    "-o", "out/uart_iv",
        "out/uart_witness.v", "out/testbenches/uart_tb.v",
    });
    uart_compile.step.dependOn(&uart_gen.step);
    const uart_run = b.addSystemCommand(&.{ "vvp", "out/uart_iv" });
    uart_run.step.dependOn(&uart_compile.step);
    const uart_step = b.step("uart", "Emit, lint and replay the single-clock UART loopback witness");
    uart_step.dependOn(&uart_lint.step);
    uart_step.dependOn(&uart_run.step);

    // SPI target witness: host command decoding replayed with Icarus.
    const spi_exe = b.addExecutable(.{
        .name = "zihdl_spi_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/blocks/spi_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zihdl", .module = mod },
            },
        }),
    });
    const spi_gen = b.addRunArtifact(spi_exe);
    const spi_lint = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wno-MULTITOP", "out/spi_witness.v" });
    spi_lint.step.dependOn(&spi_gen.step);
    const spi_compile = b.addSystemCommand(&.{
        "iverilog",          "-g2001",                   "-o", "out/spi_iv",
        "out/spi_witness.v", "out/testbenches/spi_tb.v",
    });
    spi_compile.step.dependOn(&spi_gen.step);
    const spi_run = b.addSystemCommand(&.{ "vvp", "out/spi_iv" });
    spi_run.step.dependOn(&spi_compile.step);
    const spi_step = b.step("spi", "Emit, lint and replay the SPI target programmer witness");
    spi_step.dependOn(&spi_lint.step);
    spi_step.dependOn(&spi_run.step);

    // I2C target witness: write/read transactions against a modeled host bus.
    const i2c_exe = b.addExecutable(.{
        .name = "zihdl_i2c_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/blocks/i2c_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zihdl", .module = mod },
            },
        }),
    });
    const i2c_wit_gen = b.addRunArtifact(i2c_exe);
    const i2c_wit_lint = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wno-MULTITOP", "out/i2c_witness.v" });
    i2c_wit_lint.step.dependOn(&i2c_wit_gen.step);
    const i2c_wit_compile = b.addSystemCommand(&.{
        "iverilog",          "-g2001",                   "-o", "out/i2c_witness_iv",
        "out/i2c_witness.v", "out/testbenches/i2c_tb.v",
    });
    i2c_wit_compile.step.dependOn(&i2c_wit_gen.step);
    const i2c_wit_run = b.addSystemCommand(&.{ "vvp", "out/i2c_witness_iv" });
    i2c_wit_run.step.dependOn(&i2c_wit_compile.step);
    const i2c_step = b.step("i2c", "Emit, lint and replay the I2C target loader witness");
    i2c_step.dependOn(&i2c_wit_lint.step);
    i2c_step.dependOn(&i2c_wit_run.step);

    // CDC witness: request/acknowledge bridge and mailbox replayed across
    // asynchronous source/destination clocks.
    const cdc_exe = b.addExecutable(.{
        .name = "zihdl_cdc_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/blocks/cdc_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zihdl", .module = mod },
            },
        }),
    });
    const cdc_gen = b.addRunArtifact(cdc_exe);
    const cdc_lint = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wno-MULTITOP", "out/cdc_witness.v" });
    cdc_lint.step.dependOn(&cdc_gen.step);
    const cdc_compile = b.addSystemCommand(&.{
        "iverilog",          "-g2001",                   "-o", "out/cdc_iv",
        "out/cdc_witness.v", "out/testbenches/cdc_tb.v",
    });
    cdc_compile.step.dependOn(&cdc_gen.step);
    const cdc_run = b.addSystemCommand(&.{ "vvp", "out/cdc_iv" });
    cdc_run.step.dependOn(&cdc_compile.step);
    const cdc_step = b.step("cdc", "Emit, lint and replay the request/acknowledge bridge and mailbox witness");
    cdc_step.dependOn(&cdc_lint.step);
    cdc_step.dependOn(&cdc_run.step);

    // Division/remainder witness: signal-driven `/` and `%` plus folded
    // constants (including signed cases) replayed against the simulator.
    const divmod_exe = b.addExecutable(.{
        .name = "zihdl_divmod_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/blocks/divmod_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zihdl", .module = mod },
            },
        }),
    });
    const divmod_gen = b.addRunArtifact(divmod_exe);
    const divmod_lint = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wno-MULTITOP", "out/divmod/probe.v" });
    divmod_lint.step.dependOn(&divmod_gen.step);
    const divmod_zero_lint = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wno-MULTITOP", "out/divmod/zero.v" });
    divmod_zero_lint.step.dependOn(&divmod_gen.step);
    const divmod_compile = b.addSystemCommand(&.{
        "iverilog",           "-g2001",                      "-o", "out/divmod/probe_iv",
        "out/divmod/probe.v", "out/testbenches/divmod_tb.v",
    });
    divmod_compile.step.dependOn(&divmod_gen.step);
    const divmod_run = b.addSystemCommand(&.{ "vvp", "out/divmod/probe_iv" });
    divmod_run.step.dependOn(&divmod_compile.step);
    const divmod_zero_compile = b.addSystemCommand(&.{
        "iverilog",          "-g2001",                           "-o", "out/divmod/zero_iv",
        "out/divmod/zero.v", "out/testbenches/divmod_zero_tb.v",
    });
    divmod_zero_compile.step.dependOn(&divmod_gen.step);
    const divmod_zero_run = b.addSystemCommand(&.{ "vvp", "out/divmod/zero_iv" });
    divmod_zero_run.step.dependOn(&divmod_zero_compile.step);
    const divmod_step = b.step("divmod", "Emit, lint and replay the division/remainder fixtures (probe and zero divisor)");
    divmod_step.dependOn(&divmod_lint.step);
    divmod_step.dependOn(&divmod_zero_lint.step);
    divmod_step.dependOn(&divmod_run.step);
    divmod_step.dependOn(&divmod_zero_run.step);

    // Integrated ZIO witness bundles (RTL, design.json, SDC, microcode,
    // payload, harness, model-checked JSONL) for 60 and 120 MHz.
    const zio_wit_exe = b.addExecutable(.{
        .name = "zihdl_zio_witness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protocol_emulator/zio_witness.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zihdl", .module = mod },
                .{ .name = "protocol_blocks", .module = blocks_mod },
                .{ .name = "trace_harness", .module = trace_harness_mod },
            },
        }),
    });
    const competition_exe = b.addExecutable(.{
        .name = "zihdl_competition",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protocol_emulator/competition.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zihdl", .module = mod },
                .{ .name = "protocol_blocks", .module = blocks_mod },
                .{ .name = "trace_harness", .module = trace_harness_mod },
            },
        }),
    });
    const isa_doc_exe = b.addExecutable(.{
        .name = "zio_isa_doc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protocol_emulator/isa_doc.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zihdl", .module = mod }},
        }),
    });
    b.step("isa-doc", "Write docs/zio-isa.md from the ZIO ISA table").dependOn(&b.addRunArtifact(isa_doc_exe).step);
    const zio_diff_exe = b.addExecutable(.{
        .name = "zio_diff",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protocol_emulator/zio_diff.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zihdl", .module = mod }},
        }),
    });
    const zio_diff_gen = b.addRunArtifact(zio_diff_exe);
    const zio_diff_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-s", "zio_diff_top_vectors_tb", "-o", "out/zio_diff_iv", "out/zio_diff_top.v", "out/zio_diff_tb.v" });
    zio_diff_compile.step.dependOn(&zio_diff_gen.step);
    const zio_diff_run = b.addSystemCommand(&.{ "vvp", "out/zio_diff_iv" });
    zio_diff_run.step.dependOn(&zio_diff_compile.step);
    const zio_diff_step = b.step("zio-diff", "Randomized cycle-by-cycle comparison of the ZIO core RTL against the reference model");
    zio_diff_step.dependOn(&zio_diff_run.step);
    const zio_model_tests = b.addTest(.{ .root_module = zio_diff_exe.root_module });
    const cluster_diff_exe = b.addExecutable(.{
        .name = "zio_cluster_diff",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protocol_emulator/zio_cluster_diff.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zihdl", .module = mod }},
        }),
    });
    const cluster_diff_gen = b.addRunArtifact(cluster_diff_exe);
    const cluster_diff_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-s", "zio_cluster_4x64_vectors_tb", "-o", "out/zio_cluster_diff_iv", "out/zio_cluster.v", "out/zio_cluster_diff_tb.v" });
    cluster_diff_compile.step.dependOn(&cluster_diff_gen.step);
    const cluster_diff_run = b.addSystemCommand(&.{ "vvp", "out/zio_cluster_diff_iv" });
    cluster_diff_run.step.dependOn(&cluster_diff_compile.step);
    const cluster_diff_step = b.step("zio-cluster-diff", "Randomized cycle-by-cycle comparison of the four-machine cluster RTL against its model");
    cluster_diff_step.dependOn(&cluster_diff_run.step);
    const cluster_lint = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wno-MULTITOP", "--top-module", "zio_cluster_4x64", "out/zio_cluster.v" });
    cluster_lint.step.dependOn(&cluster_diff_gen.step);
    cluster_diff_step.dependOn(&cluster_lint.step);
    const cluster_model_tests = b.addTest(.{ .root_module = cluster_diff_exe.root_module });
    const chip_test_exe = b.addExecutable(.{
        .name = "zio_chip_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protocol_emulator/zio_chip_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zihdl", .module = mod }},
        }),
    });
    const chip_test_gen = b.addRunArtifact(chip_test_exe);
    const chip_test_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-s", "zio_chip_board_vectors_tb", "-o", "out/zio_chip_iv", "out/zio_chip_board.v", "out/zio_chip_tb.v" });
    chip_test_compile.step.dependOn(&chip_test_gen.step);
    const chip_test_run = b.addSystemCommand(&.{ "vvp", "out/zio_chip_iv" });
    chip_test_run.step.dependOn(&chip_test_compile.step);
    const chip_lint = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wno-MULTITOP", "--top-module", "zio_chip_board", "out/zio_chip_board.v" });
    chip_lint.step.dependOn(&chip_test_gen.step);
    const chip_test_step = b.step("zio-chip", "End-to-end chip test over SPI: two machines loop UART back through a pad");
    chip_test_step.dependOn(&chip_test_run.step);
    chip_test_step.dependOn(&chip_lint.step);
    const chip_tests = b.addTest(.{ .root_module = chip_test_exe.root_module });
    const competition_gen = b.addRunArtifact(competition_exe);
    const competition_step = b.step("competition", "Emit IHP CMOS5L Tiny Tapeout 6x4 composition and witness");
    competition_step.dependOn(&competition_gen.step);
    const zio_wit_gen = b.addRunArtifact(zio_wit_exe);
    zio_wit_gen.step.dependOn(&run_cmd.step);

    const protocol_wit_exe = b.addExecutable(.{
        .name = "zihdl_protocol_wave_witness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protocol_emulator/protocol_wave_witness.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zihdl", .module = mod },
                .{ .name = "protocol_harness", .module = protocol_harness_mod },
            },
        }),
    });
    const protocol_wit_gen = b.addRunArtifact(protocol_wit_exe);

    const tb_step = b.step("tb", "Generate the loader read, partition, width, 10BASE-T and ZIO testbenches from Zig");
    tb_step.dependOn(&tb_gen.step);
    tb_step.dependOn(&part_tb_gen.step);
    tb_step.dependOn(&core_gen.step);
    tb_step.dependOn(&eth_tb_gen.step);
    tb_step.dependOn(&zio_wit_gen.step);
    tb_step.dependOn(&protocol_wit_gen.step);

    // Timing-intent artifact contract fixture for consumers: RTL, design.json
    // (timing intent + provenance), model-derived stimulus and a hash manifest.
    const contract_exe = b.addExecutable(.{
        .name = "zihdl_contract",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/contract/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zihdl", .module = mod },
            },
        }),
    });
    const contract_gen = b.addRunArtifact(contract_exe);
    const contract_step = b.step("contract", "Emit the timing-intent contract fixture (RTL, design.json, stimulus, manifest)");
    contract_step.dependOn(&contract_gen.step);

    // Lint the generated Verilog with Verilator. Depends on the run step, which
    // writes out/asic_core.v.
    const lint_cmd = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wno-MULTITOP", "out/asic_core.v" });
    lint_cmd.step.dependOn(&run_cmd.step);
    const lint_step = b.step("lint", "Lint generated Verilog with Verilator");
    lint_step.dependOn(&lint_cmd.step);

    // SystemVerilog target: run the synthesizer with --sv and lint the result.
    const sv_cmd = b.addRunArtifact(exe);
    sv_cmd.addArg("--sv");
    sv_cmd.step.dependOn(&run_cmd.step);
    const lint_sv_cmd = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wno-MULTITOP", "out/asic_core.sv" });
    lint_sv_cmd.step.dependOn(&sv_cmd.step);
    const lint_sv_step = b.step("lint-sv", "Lint generated SystemVerilog with Verilator");
    lint_sv_step.dependOn(&lint_sv_cmd.step);

    // Transitional behavioral simulation with Icarus Verilog. oasic's own
    // simulator replaces this once its Verilog front end lands.
    const i2c_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-o", "out/asic_i2c_iv", "out/asic_core.v", "out/testbenches/asic_i2c_tb.v" });
    i2c_compile.step.dependOn(&run_cmd.step);
    const i2c_run = b.addSystemCommand(&.{ "vvp", "out/asic_i2c_iv" });
    i2c_run.step.dependOn(&i2c_compile.step);

    const rx_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-o", "out/asic_rx_iv", "out/asic_core.v", "out/testbenches/asic_rx_tb.v" });
    rx_compile.step.dependOn(&run_cmd.step);
    const rx_run = b.addSystemCommand(&.{ "vvp", "out/asic_rx_iv" });
    rx_run.step.dependOn(&rx_compile.step);

    // A/B regressions: the same I2C and RX fixtures run against the historical
    // two-macro composition emitted alongside the default single-macro build.
    const split_lint_cmd = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wno-MULTITOP", "out/asic_core_split.v" });
    split_lint_cmd.step.dependOn(&run_cmd.step);
    const i2c_split_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-o", "out/asic_i2c_split_iv", "out/asic_core_split.v", "out/testbenches/asic_i2c_tb.v" });
    i2c_split_compile.step.dependOn(&run_cmd.step);
    const i2c_split_run = b.addSystemCommand(&.{ "vvp", "out/asic_i2c_split_iv" });
    i2c_split_run.step.dependOn(&i2c_split_compile.step);
    const rx_split_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-o", "out/asic_rx_split_iv", "out/asic_core_split.v", "out/testbenches/asic_rx_tb.v" });
    rx_split_compile.step.dependOn(&run_cmd.step);
    const rx_split_run = b.addSystemCommand(&.{ "vvp", "out/asic_rx_split_iv" });
    rx_split_run.step.dependOn(&rx_split_compile.step);

    const sv_compile = b.addSystemCommand(&.{ "iverilog", "-g2012", "-o", "out/asic_i2c_sv", "out/asic_core.sv", "out/testbenches/asic_i2c_tb.v" });
    sv_compile.step.dependOn(&sv_cmd.step);
    const sv_run = b.addSystemCommand(&.{ "vvp", "out/asic_i2c_sv" });
    sv_run.step.dependOn(&sv_compile.step);

    // Generated testbench: the Zig-built vector stimulus drives the loader
    // through latch/NACK/commit scenarios and reports its own verdict.
    const read_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-s", "loader_read_tb_harness", "-o", "out/loader_read_iv", "out/loader_read_tb.v" });
    read_compile.step.dependOn(&tb_gen.step);
    const read_run = b.addSystemCommand(&.{ "vvp", "out/loader_read_iv" });
    read_run.step.dependOn(&read_compile.step);

    // Partition testbench: reference-model vectors drive the shared-macro
    // arbiter, skid buffer, capture ring and status words.
    const part_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-s", "partition_tb_harness", "-o", "out/partition_tb_iv", "out/partition_tb.v" });
    part_compile.step.dependOn(&part_tb_gen.step);
    const part_run = b.addSystemCommand(&.{ "vvp", "out/partition_tb_iv" });
    part_run.step.dependOn(&part_compile.step);

    // Ethernet 10BASE-T transmit testbench: expected waveform player.
    const eth_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-s", "ethernet_10base_t_tb_harness", "-o", "out/ethernet_10base_t_tb_iv", "out/ethernet_10base_t_tb.v" });
    eth_compile.step.dependOn(&eth_tb_gen.step);
    const eth_run = b.addSystemCommand(&.{ "vvp", "out/ethernet_10base_t_tb_iv" });
    eth_run.step.dependOn(&eth_compile.step);

    // Integrated ZIO witnesses: compile and run each clock, then check the
    // trace cycle by cycle against the interpreter model. The `inject` run
    // proves the checker reports the exact failing cycle.
    const zio_step = b.step("zio", "Generate, run and model-check the ZIO waveform witnesses");
    inline for (.{ "60", "120" }) |tag| {
        const compile = b.addSystemCommand(&.{
            "iverilog",                      "-g2001",                       "-s",                              "zio_witness_tb", "-o",
            "out/zio_asic_" ++ tag ++ "_iv", "out/zio_asic_" ++ tag ++ ".v", "out/zio_asic_" ++ tag ++ "_tb.v",
        });
        compile.step.dependOn(&zio_wit_gen.step);
        const run = b.addSystemCommand(&.{ "vvp", "out/zio_asic_" ++ tag ++ "_iv" });
        run.step.dependOn(&compile.step);
        const check = b.addRunArtifact(zio_wit_exe);
        check.addArgs(&.{ "convert", "out/zio_asic_" ++ tag ++ "_edges.txt", "out/zio_asic_" ++ tag ++ ".jsonl" });
        check.step.dependOn(&run.step);
        const fault = b.addRunArtifact(zio_wit_exe);
        fault.addArgs(&.{ "convert", "out/zio_asic_" ++ tag ++ "_edges.txt", "out/zio_asic_" ++ tag ++ "_inject.jsonl", "3" });
        fault.step.dependOn(&run.step);
        zio_step.dependOn(&check.step);
        zio_step.dependOn(&fault.step);
    }

    const protocols_step = b.step("protocols", "Simulate USB, SPI, JTAG, UART and I2C microcode on the ZIO RTL");
    inline for (.{ "usb60", "usb120", "token60", "token120", "ack60", "ack120", "reset60", "reset120", "spi0", "spi1", "spi2", "spi3", "jtag", "uart_tx1m", "uart_tx115k", "uart_rx1m", "uart_rx115k", "uart_rx115k_fast", "uart_rx115k_slow" }) |tag| {
        const compile = b.addSystemCommand(&.{
            "iverilog",                      "-g2001",              "-s",                              "protocol_wave_tb", "-o",
            "out/protocol_" ++ tag ++ "_iv", "out/protocol_core.v", "out/protocol_" ++ tag ++ "_tb.v",
        });
        compile.step.dependOn(&protocol_wit_gen.step);
        const run = b.addSystemCommand(&.{ "vvp", "out/protocol_" ++ tag ++ "_iv" });
        run.step.dependOn(&compile.step);
        protocols_step.dependOn(&run.step);
    }
    // The I2C controller cases also compile zihdl's I2C target onto the bus.
    inline for (.{ "i2c_std", "i2c_fast", "i2c_fastplus", "i2c_fast_stretch" }) |tag| {
        const compile = b.addSystemCommand(&.{
            "iverilog",                      "-g2001",              "-s",                        "protocol_wave_tb",                "-o",
            "out/protocol_" ++ tag ++ "_iv", "out/protocol_core.v", "out/protocol_i2c_target.v", "out/protocol_" ++ tag ++ "_tb.v",
        });
        compile.step.dependOn(&protocol_wit_gen.step);
        const run = b.addSystemCommand(&.{ "vvp", "out/protocol_" ++ tag ++ "_iv" });
        run.step.dependOn(&compile.step);
        protocols_step.dependOn(&run.step);
    }

    const sim_step = b.step("sim", "Run transitional Icarus regressions on the emitted RTL");
    sim_step.dependOn(&i2c_run.step);
    sim_step.dependOn(&rx_run.step);
    sim_step.dependOn(&i2c_split_run.step);
    sim_step.dependOn(&rx_split_run.step);
    sim_step.dependOn(&read_run.step);
    sim_step.dependOn(&part_run.step);
    sim_step.dependOn(&eth_run.step);
    sim_step.dependOn(&async_fifo_run.step);
    sim_step.dependOn(&uart_run.step);
    sim_step.dependOn(&spi_run.step);
    sim_step.dependOn(&i2c_wit_run.step);
    sim_step.dependOn(&cdc_run.step);
    sim_step.dependOn(&divmod_run.step);
    sim_step.dependOn(&divmod_zero_run.step);
    sim_step.dependOn(zio_step);
    sim_step.dependOn(protocols_step);

    const verify_step = b.step("verify", "Lint and simulate the emitted artifacts");
    verify_step.dependOn(&contract_gen.step);
    verify_step.dependOn(&lint_cmd.step);
    verify_step.dependOn(&lint_sv_cmd.step);
    verify_step.dependOn(&split_lint_cmd.step);
    verify_step.dependOn(&i2c_run.step);
    verify_step.dependOn(&rx_run.step);
    verify_step.dependOn(&sv_run.step);
    verify_step.dependOn(&i2c_split_run.step);
    verify_step.dependOn(&rx_split_run.step);
    verify_step.dependOn(&read_run.step);
    verify_step.dependOn(&part_run.step);
    verify_step.dependOn(&core_gen.step);
    verify_step.dependOn(&eth_run.step);
    verify_step.dependOn(&async_fifo_lint.step);
    verify_step.dependOn(&async_fifo_run.step);
    verify_step.dependOn(&uart_lint.step);
    verify_step.dependOn(&uart_run.step);
    verify_step.dependOn(&spi_lint.step);
    verify_step.dependOn(&spi_run.step);
    verify_step.dependOn(&i2c_wit_lint.step);
    verify_step.dependOn(&i2c_wit_run.step);
    verify_step.dependOn(&cdc_lint.step);
    verify_step.dependOn(&cdc_run.step);
    verify_step.dependOn(&divmod_lint.step);
    verify_step.dependOn(&divmod_zero_lint.step);
    verify_step.dependOn(&divmod_run.step);
    verify_step.dependOn(&divmod_zero_run.step);
    verify_step.dependOn(zio_step);
    verify_step.dependOn(protocols_step);

    const timer_memory_exe = b.addExecutable(.{
        .name = "zihdl_timer_memory_witness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/blocks/timer_memory_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zihdl", .module = mod }},
        }),
    });
    const timer_memory_gen = b.addRunArtifact(timer_memory_exe);
    const timer_memory_step = b.step("timer-memory", "Emit timer and ROM/RAM wrapper RTL");
    timer_memory_step.dependOn(&timer_memory_gen.step);
    const timer_memory_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-s", "timer_memory_tb", "-o", "out/timer_memory_iv", "out/timer_memory_witness.v", "out/testbenches/timer_memory_tb.v" });
    timer_memory_compile.step.dependOn(&timer_memory_gen.step);
    const timer_memory_run = b.addSystemCommand(&.{ "vvp", "out/timer_memory_iv" });
    timer_memory_run.step.dependOn(&timer_memory_compile.step);
    timer_memory_step.dependOn(&timer_memory_run.step);
    verify_step.dependOn(&timer_memory_run.step);

    const arbiter_exe = b.addExecutable(.{
        .name = "zihdl_arbiter_witness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/blocks/arbiter_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zihdl", .module = mod }},
        }),
    });
    const arbiter_gen = b.addRunArtifact(arbiter_exe);
    const arbiter_step = b.step("arbiter", "Emit round-robin arbiter and crossbar RTL");
    arbiter_step.dependOn(&arbiter_gen.step);
    const arbiter_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-s", "arbiter_tb", "-o", "out/arbiter_iv", "out/arbiter_witness.v", "out/testbenches/arbiter_tb.v" });
    arbiter_compile.step.dependOn(&arbiter_gen.step);
    const arbiter_run = b.addSystemCommand(&.{ "vvp", "out/arbiter_iv" });
    arbiter_run.step.dependOn(&arbiter_compile.step);
    arbiter_step.dependOn(&arbiter_run.step);
    verify_step.dependOn(&arbiter_run.step);

    const axi_exe = b.addExecutable(.{
        .name = "zihdl_axi4_lite_witness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/blocks/axi4_lite_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zihdl", .module = mod }},
        }),
    });
    const axi_gen = b.addRunArtifact(axi_exe);
    const axi_step = b.step("axi4-lite", "Emit AXI4-Lite register slave RTL");
    axi_step.dependOn(&axi_gen.step);
    const axi_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-s", "axi4_lite_tb", "-o", "out/axi4_lite_iv", "out/axi4_lite_witness.v", "out/testbenches/axi4_lite_tb.v" });
    axi_compile.step.dependOn(&axi_gen.step);
    const axi_run = b.addSystemCommand(&.{ "vvp", "out/axi4_lite_iv" });
    axi_run.step.dependOn(&axi_compile.step);
    axi_step.dependOn(&axi_run.step);
    verify_step.dependOn(&axi_run.step);

    const jane_warmup_exe = b.addExecutable(.{
        .name = "zihdl_jane_street_warmup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/jane_street/warmup.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zihdl", .module = mod }},
        }),
    });
    const jane_warmup_gen = b.addRunArtifact(jane_warmup_exe);
    const jane_warmup_lint = b.addSystemCommand(&.{ "verilator", "--lint-only", "out/jane_street_warmup.v" });
    jane_warmup_lint.step.dependOn(&jane_warmup_gen.step);
    const jane_warmup_compile = b.addSystemCommand(&.{ "iverilog", "-g2012", "-s", "warmup_tb", "-o", "out/jane_street_warmup_iv", "out/jane_street_warmup.v", "out/testbenches/warmup_tb.v" });
    jane_warmup_compile.step.dependOn(&jane_warmup_gen.step);
    jane_warmup_compile.step.dependOn(&jane_bench_gen.step);
    const jane_warmup_run = b.addSystemCommand(&.{ "vvp", "out/jane_street_warmup_iv" });
    jane_warmup_run.step.dependOn(&jane_warmup_compile.step);

    const jane_solution_exe = b.addExecutable(.{
        .name = "zihdl_jane_street_solution",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/jane_street/puzzle_solution.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const jane_solution_gen = b.addRunArtifact(jane_solution_exe);
    const jane_driver_exe = b.addExecutable(.{
        .name = "zihdl_jane_street_key_driver",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/jane_street/key_driver.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zihdl", .module = mod }},
        }),
    });
    const jane_driver_gen = b.addRunArtifact(jane_driver_exe);
    const jane_driver_lint = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wno-MULTITOP", "out/jane_street_key_driver.v" });
    jane_driver_lint.step.dependOn(&jane_driver_gen.step);
    const jane_driver_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-s", "key_driver_tb", "-o", "out/jane_street_key_driver_iv", "out/jane_street_key_driver.v", "out/testbenches/key_driver_tb.v" });
    jane_driver_compile.step.dependOn(&jane_driver_gen.step);
    jane_driver_compile.step.dependOn(&jane_bench_gen.step);
    const jane_driver_run = b.addSystemCommand(&.{ "vvp", "out/jane_street_key_driver_iv" });
    jane_driver_run.step.dependOn(&jane_driver_compile.step);
    jane_driver_run.step.dependOn(&jane_solution_gen.step);
    const jane_checker_exe = b.addExecutable(.{
        .name = "zihdl_jane_street_star_battle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/jane_street/star_battle.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zihdl", .module = mod }},
        }),
    });
    const jane_checker_gen = b.addRunArtifact(jane_checker_exe);
    const jane_checker_lint = b.addSystemCommand(&.{ "verilator", "--lint-only", "out/jane_street_star_battle.v" });
    jane_checker_lint.step.dependOn(&jane_checker_gen.step);
    const jane_checker_compile = b.addSystemCommand(&.{ "iverilog", "-g2012", "-s", "star_battle_tb", "-o", "out/jane_street_star_battle_iv", "out/jane_street_star_battle.v", "out/testbenches/star_battle_tb.v" });
    jane_checker_compile.step.dependOn(&jane_checker_gen.step);
    jane_checker_compile.step.dependOn(&jane_bench_gen.step);
    const jane_checker_run = b.addSystemCommand(&.{ "vvp", "out/jane_street_star_battle_iv" });
    jane_checker_run.step.dependOn(&jane_checker_compile.step);
    jane_checker_run.step.dependOn(&jane_solution_gen.step);
    const jane_step = b.step("jane-street", "Solve the puzzle; emit and replay the warmup, key driver and rule-level checker RTL");
    jane_step.dependOn(&jane_solution_gen.step);
    jane_step.dependOn(&jane_driver_lint.step);
    jane_step.dependOn(&jane_driver_run.step);
    jane_step.dependOn(&jane_checker_lint.step);
    jane_step.dependOn(&jane_checker_run.step);
    jane_step.dependOn(&jane_warmup_lint.step);
    jane_step.dependOn(&jane_warmup_run.step);
    verify_step.dependOn(jane_step);

    const puzzle_dir = b.option([]const u8, "puzzle-dir", "Path to the Jane Street ASIC puzzle source checkout") orelse "../asic-puzzle-2026";
    const puzzle_rtl = b.option([]const u8, "puzzle-rtl", "Path to the extracted puzzle Verilog for the Jane Street miter") orelse "../oasic/out/workbench-tests/golden/files/puzzle_rtl.v";
    const jane_puzzle_check = b.addSystemCommand(&.{ "bash", "examples/jane_street/check_puzzle.sh", puzzle_dir, puzzle_rtl });
    jane_puzzle_check.step.dependOn(jane_step);
    jane_puzzle_check.step.dependOn(&jane_solution_gen.step);
    jane_puzzle_check.step.dependOn(&jane_warmup_gen.step);
    jane_puzzle_check.step.dependOn(&jane_checker_gen.step);
    jane_puzzle_check.step.dependOn(&jane_bench_gen.step);
    b.step("verify-jane-street-puzzle", "Replay the generated key against the sibling GDS simulator and solution VCD")
        .dependOn(&jane_puzzle_check.step);

    // 0.1 feature witnesses: arrays, edges, multi-port memories, properties,
    // clock generation and the register bank on each bus. Every RTL file is
    // linted, every bench replayed; the property bench also has a failing
    // trace that must trip the assertion.
    const features_exe = b.addExecutable(.{
        .name = "zihdl_features_witness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/blocks/features_gen.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zihdl", .module = mod }},
        }),
    });
    const features_gen = b.addRunArtifact(features_exe);
    const features_step = b.step("features", "Lint and replay the 0.1 feature witnesses");
    const feature_cases = [_]struct { rtl: []const u8, tb: []const u8, assertions: bool = false }{
        .{ .rtl = "arrays", .tb = "feature_arrays_tb" },
        .{ .rtl = "edges", .tb = "feature_edges_tb" },
        .{ .rtl = "dpram", .tb = "feature_dpram_tb" },
        .{ .rtl = "wprio", .tb = "feature_wprio_tb" },
        .{ .rtl = "lanes", .tb = "feature_lanes_tb" },
        .{ .rtl = "props", .tb = "feature_props_tb", .assertions = true },
        .{ .rtl = "clocks", .tb = "feature_clocks_tb" },
        .{ .rtl = "regbank_axi4_lite", .tb = "regbank_axi4_lite_tb" },
        .{ .rtl = "regbank_apb", .tb = "regbank_apb_tb" },
        .{ .rtl = "regbank_wishbone", .tb = "regbank_wishbone_tb" },
    };
    for (feature_cases) |case| {
        // Both HDL backends: Verilog-2001 under -g2001 (SystemVerilog when the
        // bench enables assertions), SystemVerilog under -g2012.
        for ([_][]const u8{ "v", "sv" }) |ext| {
            const sv = std.mem.eql(u8, ext, "sv");
            const rtl = b.fmt("out/features/{s}.{s}", .{ case.rtl, ext });
            const lint = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wno-MULTITOP", rtl });
            lint.step.dependOn(&features_gen.step);
            features_step.dependOn(&lint.step);
            const image = b.fmt("out/features/{s}_{s}_iv", .{ case.tb, ext });
            const tb = b.fmt("out/testbenches/{s}.v", .{case.tb});
            const compile = if (case.assertions)
                b.addSystemCommand(&.{ "iverilog", "-g2012", "-DZIHDL_ASSERT", "-s", case.tb, "-o", image, rtl, tb })
            else if (sv)
                b.addSystemCommand(&.{ "iverilog", "-g2012", "-s", case.tb, "-o", image, rtl, tb })
            else
                b.addSystemCommand(&.{ "iverilog", "-g2001", "-s", case.tb, "-o", image, rtl, tb });
            compile.step.dependOn(&features_gen.step);
            compile.step.dependOn(&testbench_sources_gen.step);
            // A bench passes on its message with no assertion error logged.
            const run = b.addSystemCommand(&.{ "sh", "-c", b.fmt("vvp {s} > {s}.log 2>&1; status=$?; cat {s}.log; [ $status -eq 0 ] && grep -q PASS {s}.log && ! grep -q ERROR {s}.log", .{ image, image, image, image, image }) });
            run.step.dependOn(&compile.step);
            features_step.dependOn(&run.step);
        }
    }
    // The conformance design has no bench: it must lint and compile under
    // both backends (the clock gate's SYNTHESIS branch needs the cell library,
    // so its behavioral model is the one compiled here).
    for ([_][]const u8{ "v", "sv" }) |ext| {
        const rtl = b.fmt("out/conformance/conformance.{s}", .{ext});
        const lint = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wno-MULTITOP", "--top-module", "conformance_top", rtl });
        lint.step.dependOn(&features_gen.step);
        features_step.dependOn(&lint.step);
        const gen: []const u8 = if (std.mem.eql(u8, ext, "sv")) "-g2012" else "-g2001";
        const compile = b.addSystemCommand(&.{ "iverilog", gen, "-s", "conformance_top", "-o", b.fmt("out/conformance/conformance_{s}_iv", .{ext}), rtl });
        compile.step.dependOn(&features_gen.step);
        features_step.dependOn(&compile.step);
    }
    const props_fail_compile = b.addSystemCommand(&.{ "iverilog", "-g2012", "-DZIHDL_ASSERT", "-s", "feature_props_fail_tb", "-o", "out/features/feature_props_fail_iv", "out/features/props.v", "out/testbenches/feature_props_fail_tb.v" });
    props_fail_compile.step.dependOn(&features_gen.step);
    props_fail_compile.step.dependOn(&testbench_sources_gen.step);
    const props_fail_run = b.addSystemCommand(&.{ "sh", "-c", "vvp out/features/feature_props_fail_iv > out/features/feature_props_fail.log 2>&1; grep -q 'ERROR: .*grant_completes' out/features/feature_props_fail.log && echo 'FEATURE PROPS FAILING TRACE CAUGHT'" });
    props_fail_run.step.dependOn(&props_fail_compile.step);
    features_step.dependOn(&props_fail_run.step);
    verify_step.dependOn(features_step);

    for ([_]*std.Build.Step{
        &async_fifo_compile.step,   &uart_compile.step,     &spi_compile.step,
        &i2c_wit_compile.step,      &cdc_compile.step,      &divmod_compile.step,
        &divmod_zero_compile.step,  &i2c_compile.step,      &rx_compile.step,
        &i2c_split_compile.step,    &rx_split_compile.step, &sv_compile.step,
        &timer_memory_compile.step, &arbiter_compile.step,  &axi_compile.step,
    }) |compile_step| compile_step.dependOn(&testbench_sources_gen.step);

    // Consumer replay is an explicit cross-repository gate. It uses the
    // generated metadata as well as RTL, so schema drift fails the build.
    const oasic_bin = b.option([]const u8, "oasic-bin", "Path to the oasic executable for verify-oasic") orelse "../oasic/oasic";
    const verify_oasic = b.step("verify-oasic", "Replay contract and 60/120 MHz ZIO artifacts through oasic");
    const contract_v1_replay = b.addSystemCommand(&.{ oasic_bin, "-sim-verilog", "out/contract/timing_contract.v", "-stimulus", "out/contract/timing_contract.jsonl", "-design-json", "out/contract/timing_contract_v1.json" });
    contract_v1_replay.step.dependOn(&contract_gen.step);
    const contract_v2_replay = b.addSystemCommand(&.{ oasic_bin, "-sim-verilog", "out/contract/timing_contract.v", "-stimulus", "out/contract/timing_contract.jsonl", "-design-json", "out/contract/timing_contract.json" });
    contract_v2_replay.step.dependOn(&contract_v1_replay.step);
    var last_replay: *std.Build.Step = &contract_v2_replay.step;
    inline for (.{ "60", "120" }) |tag| {
        const replay = b.addSystemCommand(&.{ oasic_bin, "-sim-verilog", "out/zio_asic_" ++ tag ++ ".v", "-synth-top", "programmable_asic_i2c_42", "-stimulus", "out/zio_asic_" ++ tag ++ ".jsonl", "-design-json", "out/zio_asic_" ++ tag ++ ".json" });
        replay.step.dependOn(zio_step);
        replay.step.dependOn(last_replay);
        last_replay = &replay.step;
    }
    verify_oasic.dependOn(last_replay);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    run_cmd.addPassthruArgs();

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Example design blocks are their own module; test them separately from the
    // protocol emulator executable (test binaries only cover one module).
    const blocks_tests = b.addTest(.{
        .root_module = blocks_mod,
    });
    const run_blocks_tests = b.addRunArtifact(blocks_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_blocks_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    const protocol_tests = b.addTest(.{ .root_module = protocol_wit_exe.root_module });
    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    test_step.dependOn(&run_protocol_tests.step);
    verify_step.dependOn(&run_protocol_tests.step);

    const run_zio_model_tests = b.addRunArtifact(zio_model_tests);
    test_step.dependOn(&run_zio_model_tests.step);
    verify_step.dependOn(&run_zio_model_tests.step);
    verify_step.dependOn(zio_diff_step);
    verify_step.dependOn(zio_core_step);
    const run_cluster_model_tests = b.addRunArtifact(cluster_model_tests);
    test_step.dependOn(&run_cluster_model_tests.step);
    verify_step.dependOn(&run_cluster_model_tests.step);
    verify_step.dependOn(cluster_diff_step);
    const run_chip_tests = b.addRunArtifact(chip_tests);
    test_step.dependOn(&run_chip_tests.step);
    verify_step.dependOn(&run_chip_tests.step);
    verify_step.dependOn(chip_test_step);
    const zio_tests = b.addTest(.{ .root_module = zio_wit_exe.root_module });
    const run_zio_tests = b.addRunArtifact(zio_tests);
    test_step.dependOn(&run_zio_tests.step);
    verify_step.dependOn(&run_zio_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
