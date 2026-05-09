const Self = @This();

const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const zon = std.zon;
const log = std.log.scoped(.config);

const wayland = @import("wayland");
const river = wayland.client.river;

const kwm = @import("kwm");

const rule = @import("config/rule.zig");
const constants = @import("config/constants.zig");
const preprocess = @import("config/preprocess.zig");
pub const meta = @import("config/meta.zig");
const Bar = @import("config/bar.zig");

var allocator: mem.Allocator = undefined;

const Config = meta.add_default(Self, @as(Self, @import("default_config")));
var config: Config = undefined;

pub var path: []const u8 = undefined;
pub const lock_mode = constants.lock_mode;
pub const default_mode = constants.default_mode;
pub const WindowRule = rule.Window;
pub const OutputRule = rule.Output;


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

bar: Bar,

sloppy_focus: bool,

cursor_warp: enum {
    none,
    on_output_changed,
    on_focus_changed,
},

disable_wrap_around_for_scroller: bool,

remember_floating_geometry: bool,

minimize: union(enum) {
    disabled,
    send_to_tag: u32,
},

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
        modifiers: river.SeatV1.Modifiers,
        event: kwm.XkbBindingEvent,
    },
    pointer: []const struct {
        mode: ?[]const u8 = null,
        button: kwm.Button,
        modifiers: river.SeatV1.Modifiers,
        event: kwm.PointerBindingEvent,
    }
},

window_rules: []const rule.Window,
output_rules: []const rule.Output,


pub fn init(al: *const mem.Allocator, config_path: []const u8) void {
    log.debug("config init", .{});

    allocator = al.*;
    path = config_path;

    config = try_load_user_config() orelse .{};
}


pub inline fn deinit() void {
    log.debug("config deinit", .{});

    meta.zon_free(allocator, config, null);
}


pub fn reload() meta.field_mask(Self) {
    log.debug("reload user config", .{});

    var mask: meta.field_mask(Self) = .{};
    var new_config = try_load_user_config();
    if (new_config) |*new_cfg| {
        defer meta.zon_free(allocator, new_cfg.*, null);
        const struct_info = @typeInfo(Self).@"struct";
        inline for (struct_info.fields) |field| {
            if (!meta.deep_equal(
                @FieldType(@TypeOf(new_cfg.*), field.name),
                &@field(config, field.name),
                &@field(new_cfg.*, field.name),
            )) {
                @field(mask, field.name) = true;
                mem.swap(
                    @FieldType(@TypeOf(new_cfg.*), field.name),
                    &@field(config, field.name),
                    &@field(new_cfg.*, field.name),
                );
            }
        }
    }
    return mask;
}


fn try_load_user_config() ?Config {
    log.info("try load user config from `{s}`", .{ path });

    const file = fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| {
        switch (err) {
            error.FileNotFound => {
                log.warn("`{s}` not exists", .{ path });
            },
            else => {
                log.err("access file `{s}` failed: {}", .{ path, err });
            }
        }
        return null;
    };
    defer file.close();

    var buffer = preprocess.preprocess(allocator, file) catch |err| {
        log.err("preprocess `{s}` failed: {}", .{ path, err });
        return null;
    };
    defer buffer.deinit(allocator);

    @setEvalBranchQuota(20000);
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(allocator);
    return zon.parse.fromSlice(
        Config,
        allocator,
        buffer.items[0..buffer.items.len-1:0],
        &diag,
        .{.ignore_unknown_fields = true},
    ) catch |err| {
        switch (err) {
            error.ParseZon => log.err("load user config failed: {f}", .{ diag }),
            else => log.err("load user config failed: {}", .{ err }),
        }
        return null;
    };
}


pub inline fn get() *Self {
    return @ptrCast(&config);
}
