const std = @import("std");
const Io = std.Io;
const mem = std.mem;

const wayland = @import("wayland");

const io = Io.Threaded.global_single_threaded.io();
const manifest = @import("build.zig.zon");
const version = manifest.version;

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

    const full_version = blk: {
        if (b.option([]const u8, "version-string", "Override `kwm -version` output.")) |version_override| {
            break :blk version_override;
        } else if (mem.endsWith(u8, version, "-dev")) {
            var ret: u8 = undefined;

            const git_describe_long = b.runAllowFail(
                &.{ "git", "-C", b.build_root.path orelse ".", "describe", "--long" },
                &ret,
                .ignore,
            ) catch break :blk version;

            var it = mem.splitSequence(u8, mem.trim(u8, git_describe_long, &std.ascii.whitespace), "-");
            _ = it.next().?; // previous tag
            const commit_count = it.next().?;
            const commit_hash = it.next().?;
            std.debug.assert(it.next() == null);
            std.debug.assert(commit_hash[0] == 'g');

            // Follow semantic versioning, e.g. 0.2.0-dev.42+d1cf95b
            break :blk b.fmt(version ++ ".{s}+{s}", .{ commit_count, commit_hash[1..] });
        } else {
            break :blk version;
        }
    };

    const use_llvm = b.option(bool, "llvm", "if to use LLVM compiler and linker");
    const pie = b.option(bool, "pie", "if enable pie") orelse false;
    const default_config_path = b.option([]const u8, "config", "path to config file") orelse "config.zon";
    const background_enabled = b.option(bool, "background", "if enable background") orelse false;
    const bar_enabled = b.option(bool, "bar", "if enable bar") orelse true;
    const kwim_enabled = b.option(bool, "kwim", "if to call `kwim` automatically") orelse true;

    const scanner = wayland.Scanner.create(b, .{});

    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("staging/fractional-scale/fractional-scale-v1.xml");
    scanner.addSystemProtocol("staging/single-pixel-buffer/single-pixel-buffer-v1.xml");
    scanner.addCustomProtocol(b.path("protocol/river-window-management-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-xkb-bindings-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/river-layer-shell-v1.xml"));
    if (kwim_enabled) {
        scanner.addCustomProtocol(b.path("protocol/river-input-management-v1.xml"));
        scanner.addCustomProtocol(b.path("protocol/river-libinput-config-v1.xml"));
        scanner.addCustomProtocol(b.path("protocol/river-xkb-config-v1.xml"));
    }

    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_output", 4);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("zwp_tablet_manager_v2", 2);
    scanner.generate("wp_cursor_shape_manager_v1", 1);
    scanner.generate("wp_fractional_scale_manager_v1", 1);
    scanner.generate("wp_single_pixel_buffer_manager_v1", 1);
    scanner.generate("river_window_manager_v1", 4);
    scanner.generate("river_xkb_bindings_v1", 2);
    scanner.generate("river_layer_shell_v1", 1);
    if (kwim_enabled) {
        scanner.generate("river_input_manager_v1", 1);
        scanner.generate("river_libinput_config_v1", 1);
        scanner.generate("river_xkb_config_v1", 1);
    }

    const wayland_mod = b.createModule(.{ .root_source_file = scanner.result });
    const xkbcommon_mod = b.dependency("xkbcommon", .{}).module("xkbcommon");
    const mvzr_mod = b.dependency("mvzr", .{}).module("mvzr");

    const flags_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/flags.zig"),
    });
    const posix_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/posix.zig"),
    });

    const backup_default_config_path = "config.def.zon";
    const config_path = blk: {
        const cwd = Io.Dir.cwd();
        cwd.access(io, default_config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.warn(
                    "Config file `{s}` not found, creating from `{s}`",
                    .{ default_config_path, backup_default_config_path },
                );

                cwd.copyFile(backup_default_config_path, cwd, default_config_path, io, .{}) catch |copy_err| {
                    std.log.err(
                        "Failed to copy `{s}` to `{s}`: {}",
                        .{ backup_default_config_path, default_config_path, copy_err },
                    );
                    break :blk b.path(backup_default_config_path);
                };

                std.log.info(
                    "Config file `{s}` created successfully. Please review and customize it.",
                    .{ default_config_path },
                );
            },
            else => {
                std.log.err(
                    "Access config file `{s}` failed: {}, use `{s}`",
                    .{ default_config_path, err, backup_default_config_path },
                );
                break :blk b.path(backup_default_config_path);
            }
        };
        break :blk b.path(default_config_path);
    };
    const default_config_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = blk: {
            const preprocess = b.addExecutable(.{
                .name = "preprocess",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/preprocess_config.zig"),
                    .target = target,
                    .optimize = .ReleaseSafe,
                    .imports = &.{
                        .{ .name = "mvzr", .module = mvzr_mod },
                    },
                }),
                .use_llvm = use_llvm,
                .use_lld = use_llvm,
            });
            const preprocess_run = b.addRunArtifact(preprocess);
            preprocess_run.addArg("-i");
            preprocess_run.addFileArg(config_path);
            preprocess_run.addArg("-o");
            break :blk preprocess_run.addOutputFileArg("config.zon");
        },
    });
    const config_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/config.zig"),
        .imports = &.{
            .{ .name = "wayland", .module = wayland_mod },
            .{ .name = "xkbcommon", .module = xkbcommon_mod },
            .{ .name = "mvzr", .module = mvzr_mod },

            .{ .name = "default_config", .module = default_config_mod },
        }
    });

    const kwm_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/kwm.zig"),
        .imports = &.{
            .{ .name = "wayland", .module = wayland_mod },
            .{ .name = "xkbcommon", .module = xkbcommon_mod },
            .{ .name = "mvzr", .module = mvzr_mod },

            .{ .name = "posix", .module = posix_mod },
        },
    });

    config_mod.addImport("kwm", kwm_mod);
    kwm_mod.addImport("config", config_mod);
    if (bar_enabled) blk: {
        const pixman_mod = (b.lazyDependency("pixman", .{}) orelse break :blk).module("pixman");
        const fcft_mod = (b.lazyDependency("fcft", .{}) orelse break :blk).module("fcft");
        kwm_mod.addImport("pixman", pixman_mod);
        kwm_mod.addImport("fcft", fcft_mod);
    }

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
        .name = "kwm",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                .{ .name = "wayland", .module = wayland_mod },

                .{ .name = "flags", .module = flags_mod },
                .{ .name = "config", .module = config_mod },
                .{ .name = "kwm", .module = kwm_mod },
            },

            .link_libc = true,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    exe.pie = pie;
    exe.root_module.linkSystemLibrary("wayland-client", .{});
    exe.root_module.linkSystemLibrary("xkbcommon", .{});
    if (bar_enabled) {
        exe.root_module.linkSystemLibrary("pixman-1", .{});
        exe.root_module.linkSystemLibrary("fcft", .{});
    }

    const kwm_options = b.addOptions();
    kwm_options.addOption(bool, "background_enabled", background_enabled);
    kwm_options.addOption(bool, "bar_enabled", bar_enabled);
    kwm_options.addOption(bool, "kwim_enabled", kwim_enabled);
    kwm_mod.addOptions("build_options", kwm_options);

    const root_options = b.addOptions();
    root_options.addOption([]const u8, "version", full_version);
    root_options.addOption(bool, "kwim_enabled", kwim_enabled);
    exe.root_module.addOptions("build_options", root_options);

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    b.installFile("doc/kwm.1", "share/man/man1/kwm.1",);
    b.installFile("config.def.zon", "share/doc/kwm/config.zon",);
    b.installFile("contrib/kwm.desktop", "share/wayland-sessions/kwm.desktop",);
    b.installFile("logo/kwm-64px.png", "share/pixmaps/kwm.png");
    b.installFile("logo/kwm-128px.png", "share/icons/hicolor/128x128/apps/kwm.png");
    b.installFile("logo/kwm-256px.png", "share/icons/hicolor/256x256/apps/kwm.png");
    b.installFile("logo/kwm.svg", "share/icons/hicolor/scalable/apps/kwm.svg");


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

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const config_tests = b.addTest(.{ .root_module = config_mod });
    const run_config_tests = b.addRunArtifact(config_tests);

    const kwm_tests = b.addTest(.{ .root_module = kwm_mod });
    const run_kwm_tests = b.addRunArtifact(kwm_tests);

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
    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_kwm_tests.step);
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


fn get_path(b: *std.Build, path: std.Build.LazyPath) []const u8 {
    const p = path.getPath3(b, null);
    return b.pathResolve(&.{ p.root_dir.path orelse ".", p.sub_path });
}
