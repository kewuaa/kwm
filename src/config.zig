// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const Self = @This();

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const zon = std.zon;
const process = std.process;
const log = std.log.scoped(.config);

const wayland = @import("wayland");
const river = wayland.client.river;

const kwm = @import("kwm");

const rule = @import("config/rule.zig");
const constants = @import("config/constants.zig");
const preprocess = @import("config/preprocess.zig");
pub const meta = @import("config/meta.zig");

// work around for zig issue: https://codeberg.org/ziglang/zig/issues/31570
pub const Modifiers = meta.unpacked(river.SeatV1.Modifiers);

pub const Config = struct {
    env: []const struct { []const u8, []const u8 },

    working_directory: union(enum) {
        none,
        home,
        custom: []const u8,
    },

    startup_cmds: []const []const []const u8,

    xcursor_theme: ?struct {
        name: [:0]const u8,
        size: u32,
    },

    background: ?u32,

    bar: @import("config/bar.zig"),

    single_tagset: bool,

    sloppy_focus: bool,

    cursor_warp: enum {
        none,
        on_output_changed,
        on_focus_changed,
    },

    disable_wrap_around_for_scroller: bool,

    remember_floating_geometry: bool,

    auto_swallow: bool,

    default_attach_mode: meta.enum_struct(kwm.Layout.Type, kwm.WindowAttachMode),

    default_window_decoration: kwm.WindowDecoration,

    border: struct {
        width: i32,
        color: struct {
            focus: u32,
            unfocus: u32,
            swallowing: u32,
        }
    },

    default_layout: kwm.Layout.Type,
    layout: kwm.Layout,

    bindings: struct {
        repeat_info: struct {
            rate: i32,
            delay: i32,
        },
        key: []const struct {
            mode: ?[]const u8 = null,
            keysym: []const u8,
            modifiers: Modifiers,
            event: kwm.XkbBindingEvent,
        },
        pointer: []const struct {
            mode: ?[]const u8 = null,
            button: kwm.Button,
            modifiers: Modifiers,
            event: kwm.PointerBindingEvent,
        }
    },

    window_rules: []const rule.Window,
    output_rules: []const rule.Output,
};

pub const default: Config = @import("default_config");
pub const lock_mode = constants.lock_mode;
pub const default_mode = constants.default_mode;
pub const WindowRule = rule.Window;
pub const OutputRule = rule.Output;


pub fn load(
    ctx: struct {
        gpa: mem.Allocator,
        io: Io,
        env: *const process.Environ.Map,
    },
    path: []const u8,
) !Config {
    log.info("loading configuration from `{s}`", .{ path });

    var buffer = try preprocess.preprocess(.{ .gpa = ctx.gpa, .io = ctx.io, .env = ctx.env }, path);
    defer buffer.deinit(ctx.gpa);

    @setEvalBranchQuota(20000);
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(ctx.gpa);
    const config = zon.parse.fromSliceAlloc(
        meta.add_default(Config, default),
        ctx.gpa,
        buffer.items[0..buffer.items.len-1:0],
        &diag,
        .{.ignore_unknown_fields = true},
    ) catch |err| {
        if (err == error.ParseZon) {
            log.err("parse configuration failed: {f}", .{ diag });
        }
        return err;
    };
    return @as(*const Config, @ptrCast(&config)).*;
}


pub fn reload(
    ctx: struct {
        gpa: mem.Allocator,
        io: Io,
        env: *const process.Environ.Map,
    },
    old: *Config,
    path: []const u8
) !meta.field_mask(Config) {
    log.debug("reload configuration from `{s}`", .{ path });

    var new = try load(.{ .gpa = ctx.gpa, .io = ctx.io, .env = ctx.env }, path);
    defer free(ctx.gpa, new);

    var mask: meta.field_mask(Config) = .{};

    const struct_info = @typeInfo(Config).@"struct";
    inline for (struct_info.fields) |field| {
        if (
            !meta.deep_equal(
                @FieldType(Config, field.name),
                &@field(old, field.name),
                &@field(new, field.name),
            )
        ) {
            mem.swap(
                @FieldType(Config, field.name),
                &@field(old, field.name),
                &@field(new, field.name),
            );
            @field(mask, field.name) = true;
        }
    }

    return mask;
}


pub fn free(gpa: mem.Allocator, config: Config) void {
    log.debug("free configuration", .{});

    meta.zon_free(
        gpa,
        @as(*const meta.add_default(Config, default), @ptrCast(&config)).*,
        null
    );
}
