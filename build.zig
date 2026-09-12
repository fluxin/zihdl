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
    const mod = b.addModule("js_asic", .{
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

    // Example-level design blocks (ISA, loaders, execution units); depends on
    // the library module and is shared by the reference projects.
    const blocks_mod = b.createModule(.{
        .root_source_file = b.path("examples/blocks/blocks.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "js_asic", .module = mod },
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
        .name = "js_asic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protocol_emulator/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "js_asic", .module = mod },
                .{ .name = "protocol_blocks", .module = blocks_mod },
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
        .name = "js_asic_tbgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protocol_emulator/loader_read_tb.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "js_asic", .module = mod },
                .{ .name = "protocol_blocks", .module = blocks_mod },
            },
        }),
    });
    const tb_gen = b.addRunArtifact(tb_exe);

    // Partition testbench generator: reference-model vectors for the shared
    // 256x32 macro partition (arbiter, skid, ring, status).
    const part_tb_exe = b.addExecutable(.{
        .name = "js_asic_partition_tbgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protocol_emulator/partition_tb.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "js_asic", .module = mod },
                .{ .name = "protocol_blocks", .module = blocks_mod },
            },
        }),
    });
    const part_tb_gen = b.addRunArtifact(part_tb_exe);

    // Counter-width equivalence generator: drives the legacy 32-bit/6-bit core
    // and the narrowed 5-bit/3-bit core with the same stimulus and compares
    // every output cycle by cycle.
    const width_tb_exe = b.addExecutable(.{
        .name = "js_asic_width_tbgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protocol_emulator/width_tb.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "js_asic", .module = mod },
            },
        }),
    });
    const width_tb_gen = b.addRunArtifact(width_tb_exe);

    // Ethernet 10BASE-T transmit testbench generator: cycle-accurate expected
    // waveform for the Manchester encoder, NLP generator and stream handshake.
    const eth_tb_exe = b.addExecutable(.{
        .name = "js_asic_ethernet_10base_t_tbgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protocol_emulator/ethernet_10base_t_tb.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "js_asic", .module = mod },
            },
        }),
    });
    const eth_tb_gen = b.addRunArtifact(eth_tb_exe);

    // Integrated ZIO witness bundles (RTL, design.json, SDC, microcode,
    // payload, harness, model-checked JSONL) for 60 and 120 MHz.
    const zio_wit_exe = b.addExecutable(.{
        .name = "js_asic_zio_witness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/protocol_emulator/zio_witness.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "js_asic", .module = mod },
                .{ .name = "protocol_blocks", .module = blocks_mod },
            },
        }),
    });
    const zio_wit_gen = b.addRunArtifact(zio_wit_exe);
    zio_wit_gen.step.dependOn(&run_cmd.step);

    const tb_step = b.step("tb", "Generate the loader read, partition, width, 10BASE-T and ZIO testbenches from Zig");
    tb_step.dependOn(&tb_gen.step);
    tb_step.dependOn(&part_tb_gen.step);
    tb_step.dependOn(&width_tb_gen.step);
    tb_step.dependOn(&eth_tb_gen.step);
    tb_step.dependOn(&zio_wit_gen.step);

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
    const i2c_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-o", "out/asic_i2c_iv", "out/asic_core.v", "examples/protocol_emulator/asic_i2c_tb.v" });
    i2c_compile.step.dependOn(&run_cmd.step);
    const i2c_run = b.addSystemCommand(&.{ "vvp", "out/asic_i2c_iv" });
    i2c_run.step.dependOn(&i2c_compile.step);

    const rx_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-o", "out/asic_rx_iv", "out/asic_core.v", "examples/protocol_emulator/asic_rx_tb.v" });
    rx_compile.step.dependOn(&run_cmd.step);
    const rx_run = b.addSystemCommand(&.{ "vvp", "out/asic_rx_iv" });
    rx_run.step.dependOn(&rx_compile.step);

    // A/B regressions: the same I2C and RX fixtures run against the historical
    // two-macro composition emitted alongside the default single-macro build.
    const split_lint_cmd = b.addSystemCommand(&.{ "verilator", "--lint-only", "-Wno-MULTITOP", "out/asic_core_split.v" });
    split_lint_cmd.step.dependOn(&run_cmd.step);
    const i2c_split_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-o", "out/asic_i2c_split_iv", "out/asic_core_split.v", "examples/protocol_emulator/asic_i2c_tb.v" });
    i2c_split_compile.step.dependOn(&run_cmd.step);
    const i2c_split_run = b.addSystemCommand(&.{ "vvp", "out/asic_i2c_split_iv" });
    i2c_split_run.step.dependOn(&i2c_split_compile.step);
    const rx_split_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-o", "out/asic_rx_split_iv", "out/asic_core_split.v", "examples/protocol_emulator/asic_rx_tb.v" });
    rx_split_compile.step.dependOn(&run_cmd.step);
    const rx_split_run = b.addSystemCommand(&.{ "vvp", "out/asic_rx_split_iv" });
    rx_split_run.step.dependOn(&rx_split_compile.step);

    const sv_compile = b.addSystemCommand(&.{ "iverilog", "-g2012", "-o", "out/asic_i2c_sv", "out/asic_core.sv", "examples/protocol_emulator/asic_i2c_tb.v" });
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

    // Counter-width equivalence testbench: legacy vs narrowed core.
    const width_compile = b.addSystemCommand(&.{ "iverilog", "-g2001", "-s", "width_tb_harness", "-o", "out/width_tb_iv", "out/width_tb.v" });
    width_compile.step.dependOn(&width_tb_gen.step);
    const width_run = b.addSystemCommand(&.{ "vvp", "out/width_tb_iv" });
    width_run.step.dependOn(&width_compile.step);

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

    const sim_step = b.step("sim", "Run transitional Icarus regressions on the emitted RTL");
    sim_step.dependOn(&i2c_run.step);
    sim_step.dependOn(&rx_run.step);
    sim_step.dependOn(&i2c_split_run.step);
    sim_step.dependOn(&rx_split_run.step);
    sim_step.dependOn(&read_run.step);
    sim_step.dependOn(&part_run.step);
    sim_step.dependOn(&width_run.step);
    sim_step.dependOn(&eth_run.step);
    sim_step.dependOn(zio_step);

    const verify_step = b.step("verify", "Lint and simulate the emitted artifacts");
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
    verify_step.dependOn(&width_run.step);
    verify_step.dependOn(&eth_run.step);
    verify_step.dependOn(zio_step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

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
