// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const build_options = @import("build_options");
const builtins = @import("builtin");
const std = @import("std");
const Io = std.Io;
const fmt = std.fmt;
const log = std.log;
const mem = std.mem;
const process = std.process;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const river = wayland.client.river;

const kwm = @import("kwm");
const flags = @import("flags");
const Config = @import("config");

var runtime_log_level: std.log.Level = if (builtins.mode == .Debug) .debug else .info;
const usage =
    \\usage: kwm [options]
    \\  -h,-help               Print this help message and exit.
    \\  -v,-version            Print the version number and exit.
    \\  -c,-config             Specify custom configuration file path.
    \\  -log-level             Specify log level.
    \\
;

const Globals = struct {
    wl_compositor: ?*wl.Compositor = null,
    wl_subcompositor: ?*wl.Subcompositor = null,
    wl_shm: ?*wl.Shm = null,
    wp_viewporter: ?*wp.Viewporter = null,
    wp_cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
    wp_fractional_scale_manager: ?*wp.FractionalScaleManagerV1 = null,
    wp_single_pixel_buffer_manager: ?*wp.SinglePixelBufferManagerV1 = null,
    rwm: ?*river.WindowManagerV1 = null,
    rwm_xkb_bindings: ?*river.XkbBindingsV1 = null,
    rwm_layer_shell: ?*river.LayerShellV1 = null,
    rwm_inputs: kwm.RiverInputs = .{},
};


pub fn main(init: process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const options = flags.parser(
        &.{
            .{ .name = "h", .kind = .boolean },
            .{ .name = "help", .kind = .boolean },
            .{ .name = "c", .kind = .arg },
            .{ .name = "config", .kind = .arg },
            .{ .name = "v", .kind = .boolean },
            .{ .name = "version", .kind = .boolean },
            .{ .name = "log-level", .kind = .arg },
        },
    ).parse(args[1..]) catch {
        try print(init.io, .stderr, usage);
        process.exit(1);
    };
    if (options.flags.h or options.flags.help) {
        try print(init.io, .stdout, usage);
        process.exit(0);
    }
    if (options.flags.v or options.flags.version) {
        try print(init.io, .stdout, build_options.version++"\n");
        process.exit(0);
    }
    if (options.flags.@"log-level") |level| {
        if (mem.eql(u8, level, "error")) {
            runtime_log_level = .err;
        } else if (mem.eql(u8, level, "warning")) {
            runtime_log_level = .warn;
        } else if (mem.eql(u8, level, "info")) {
            runtime_log_level = .info;
        } else if (mem.eql(u8, level, "debug")) {
            runtime_log_level = .debug;
        } else {
            log.err("invalid log level '{s}'", .{level});
            try print(init.io, .stderr, usage);
            process.exit(1);
        }
    }
    if (options.args.len != 0) {
        log.err("unknown option '{s}'", .{options.args[0]});
        try print(init.io, .stderr, usage);
        process.exit(1);
    }

    var path_buffer: [256]u8 = undefined;
    const config_path = options.flags.c orelse options.flags.config orelse (
        if (init.environ_map.get("XDG_CONFIG_HOME")) |config_home|
            fmt.bufPrint(&path_buffer, "{s}/kwm/config.zon", .{ config_home })
        else if (init.environ_map.get("HOME")) |home|
            fmt.bufPrint(&path_buffer, "{s}/.config/kwm/config.zon", .{ home })
        else return error.GetConfigHomeFailed
    ) catch |err| {
        log.err("format config path failed: {}", .{ err });
        return err;
    };

    const display = try wl.Display.connect(null);
    defer display.disconnect();

    {
        const registry = display.getRegistry() catch return error.GetRegistryFailed;

        var globals: Globals = .{};
        registry.setListener(*Globals, registry_listener, &globals);

        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        const wl_compositor = globals.wl_compositor orelse return error.MissingCompositor;
        const wl_subcompositor = globals.wl_subcompositor orelse return error.MissingSubcompositor;
        const wl_shm = globals.wl_shm orelse return error.MissingShm;
        const wp_cursor_shape_manager = globals.wp_cursor_shape_manager orelse return error.MissingCursorShapeManagerV1;
        const wp_fractional_scale_manager = globals.wp_fractional_scale_manager orelse return error.MissingFractionalScaleManagerV1;
        const wp_single_pixel_buffer_manager = globals.wp_single_pixel_buffer_manager orelse return error.MissingSinglePixelBufferManagerV1;
        const wp_viewporter = globals.wp_viewporter orelse return error.MissingViewporter;
        const rwm = globals.rwm orelse return error.MissingRiverWindowManagerV1;
        const rwm_xkb_bindings = globals.rwm_xkb_bindings orelse return error.MissingRiverXkbBindingsV1;
        const rwm_layer_shell = globals.rwm_layer_shell orelse return error.MissingRiverLayerShellV1;

        try kwm.init(
            init.gpa,
            init.io,
            &init.minimal.environ,
            config_path,
            registry,
            wl_compositor,
            wl_subcompositor,
            wl_shm,
            wp_viewporter,
            wp_cursor_shape_manager,
            wp_fractional_scale_manager,
            wp_single_pixel_buffer_manager,
            rwm,
            rwm_xkb_bindings,
            rwm_layer_shell,
            globals.rwm_inputs,
        );
    }
    defer kwm.deinit();
    try kwm.run(display);
}


fn registry_listener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |global| {
            if (mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                globals.wl_compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
            } else if (mem.orderZ(u8, global.interface, wl.Subcompositor.interface.name) == .eq) {
                globals.wl_subcompositor = registry.bind(global.name, wl.Subcompositor, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                globals.wl_shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, wp.Viewporter.interface.name) == .eq) {
                globals.wp_viewporter = registry.bind(global.name, wp.Viewporter, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, wp.CursorShapeManagerV1.interface.name) == .eq) {
                globals.wp_cursor_shape_manager = registry.bind(global.name, wp.CursorShapeManagerV1, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, wp.FractionalScaleManagerV1.interface.name) == .eq) {
                globals.wp_fractional_scale_manager = registry.bind(global.name, wp.FractionalScaleManagerV1, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, wp.SinglePixelBufferManagerV1.interface.name) == .eq) {
                globals.wp_single_pixel_buffer_manager = registry.bind(global.name, wp.SinglePixelBufferManagerV1, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, river.WindowManagerV1.interface.name) == .eq) {
                globals.rwm = registry.bind(global.name, river.WindowManagerV1, 4) catch return;
            } else if (mem.orderZ(u8, global.interface, river.XkbBindingsV1.interface.name) == .eq) {
                globals.rwm_xkb_bindings = registry.bind(global.name, river.XkbBindingsV1, 2) catch return;
            } else if (mem.orderZ(u8, global.interface, river.LayerShellV1.interface.name) == .eq) {
                globals.rwm_layer_shell = registry.bind(global.name, river.LayerShellV1, 1) catch return;
            } else if (comptime build_options.kwim_enabled) {
                if (mem.orderZ(u8, global.interface, river.InputManagerV1.interface.name) == .eq) {
                    globals.rwm_inputs.input_manager = registry.bind(global.name, river.InputManagerV1, 1) catch return;
                } else if (mem.orderZ(u8, global.interface, river.LibinputConfigV1.interface.name) == .eq) {
                    globals.rwm_inputs.libinput_config = registry.bind(global.name, river.LibinputConfigV1, 1) catch return;
                } else if (mem.orderZ(u8, global.interface, river.XkbConfigV1.interface.name) == .eq) {
                    globals.rwm_inputs.xkb_config = registry.bind(global.name, river.XkbConfigV1, 1) catch return;
                }
            }
        },
        .global_remove => {},
    }
}


fn print(io: Io, dest: enum { stdout, stderr }, bytes: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var writer = switch (dest) {
        .stdout => Io.File.stdout(),
        .stderr => Io.File.stderr(),
    }.writer(io, &buffer);
    const interface = &writer.interface;
    try interface.writeAll(bytes);
    try interface.flush();
}


pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log_fn,
};


pub fn log_fn(
    comptime level: log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) > @intFromEnum(runtime_log_level)) return;

    log.defaultLog(level, scope, format, args);
}
