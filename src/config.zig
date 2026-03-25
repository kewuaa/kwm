const Self = @This();

const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const zon = std.zon;
const log = std.log.scoped(.config);

const xkbcommon = @import("xkbcommon");
const Keysym = xkbcommon.Keysym;
const wayland = @import("wayland");
const river = wayland.client.river;

const kwm = @import("kwm");

const rule = @import("config/rule.zig");
const constants = @import("config/constants.zig");
pub const meta = @import("config/meta.zig");

var allocator: mem.Allocator = undefined;

var path: []const u8 = undefined;
var config: ?Self = null;
var user_config: ?meta.make_fields_optional(Self) = null;
const default_config: Self = @import("default_config");

const BindingType = enum {
    key,
    pointer,
};
const KeyBindingID = struct {
    mode: []const u8,
    modifiers: u32,
    keysym: u32,
};
const PointerBindingID = struct {
    mode: []const u8,
    modifiers: u32,
    button: u32,
};
var key_binding_list: std.ArrayList(@TypeOf(default_config.bindings.key[0])) = .empty;
var pointer_binding_list: std.ArrayList(@TypeOf(default_config.bindings.pointer[0])) = .empty;

pub const lock_mode = constants.lock_mode;
pub const default_mode = constants.default_mode;
pub const WindowRule = rule.Window;
pub const OutputRule = rule.Output;
pub const InputDeviceRule = rule.InputDevice;
pub const LibinputDeviceRule = rule.LibinputDevice;
pub const XkbKeyboardRule = rule.XkbKeyboard;


fn binding_context(comptime @"type": BindingType) type {
    const T, const name = switch (@"type") {
        .key => .{ KeyBindingID, "keysym" },
        .pointer => .{ PointerBindingID, "button" },
    };
    return struct {
        pub fn hash(self: @This(), binding: T) u64 {
            _ = self;
            return std.hash_map.hashString(binding.mode) ^ binding.modifiers ^ @field(binding, name);
        }

        pub fn eql(self: @This(), a: T, b: T) bool {
            _ = self;
            return @field(a, name) == @field(b, name) and a.modifiers == b.modifiers and mem.eql(u8, a.mode, b.mode);
        }
    };
}


env: []const struct { []const u8, []const u8 },

working_directory: union(enum) {
    none,
    home,
    custom: []const u8,
},

startup_cmds: []const []const []const u8,

xcursor_theme: union(enum) {
    none,
    theme: struct {
        name: []const u8,
        size: u32,
    },
},

background: union(enum) {
    none,
    color: u32,
},

bar: struct {
    show_default: bool,
    position: enum {
        top,
        bottom,
    },
    font: []const u8,
    color: struct {
        normal: struct {
            fg: u32,
            bg: u32,
        },
        select: struct {
            fg: u32,
            bg: u32,
        },
    },
    status: union(enum) {
        text: []const u8,
        stdin,
        fifo: []const u8,
    },
    click: meta.enum_struct(
        kwm.BarArea,
        meta.enum_struct(
            kwm.Button,
            union(enum) {
                none,
                action: kwm.BindingAction
            },
        ),
    ),
},

sloppy_focus: bool,

cursor_warp: enum {
    none,
    on_output_changed,
    on_focus_changed,
},

remember_floating_geometry: bool,

auto_swallow: bool,

default_attach_mode: meta.enum_struct(kwm.Layout.Type, kwm.WindowAttachMode),

default_window_decoration: kwm.WindowDecoration,

border: struct {
    width: i32,
    color: struct {
        focus: u32,
        unfocus: u32,
    }
},

tags: []const []const u8,

default_layout: kwm.Layout.Type,
layout: kwm.Layout,
layout_tag: struct {
    tile: meta.enum_struct(kwm.Layout.Tile.MasterLocation, []const u8),
    grid: meta.enum_struct(kwm.Layout.Grid.Direction, []const u8),
    monocle: []const u8,
    deck: meta.enum_struct(kwm.Layout.Deck.MasterLocation, []const u8),
    scroller: []const u8,
    float: []const u8,
},

bindings: struct {
    repeat_info: kwm.KeyboardRepeatInfo,
    mode_tag: []const struct { []const u8, []const u8 },
    key: []const struct {
        mode: []const u8 = default_mode,
        keysym: []const u8,
        modifiers: river.SeatV1.Modifiers,
        event: ?kwm.XkbBindingEvent,
    },
    pointer: []const struct {
        mode: []const u8 = default_mode,
        button: kwm.Button,
        modifiers: river.SeatV1.Modifiers,
        event: ?kwm.PointerBindingEvent,
    }
},

window_rules: []const rule.Window,
output_rules: []const rule.Output,
input_device_rules: []const rule.InputDevice,
libinput_device_rules: []const rule.LibinputDevice,
xkb_keyboard_rules: []const rule.XkbKeyboard,


pub fn init(al: *const mem.Allocator, config_path: []const u8) void {
    log.debug("config init", .{});

    allocator = al.*;
    path = config_path;

    user_config = try_load_user_config();
    refresh_config();
}


pub inline fn deinit() void {
    log.debug("config deinit", .{});

    if (user_config) |cfg| {
        log.debug("free user config", .{});

        key_binding_list.deinit(allocator);
        pointer_binding_list.deinit(allocator);
        meta.zon_free(allocator, cfg);
    }
}


pub fn reload() meta.field_mask(Self) {
    log.debug("reload user config", .{});

    var mask: meta.field_mask(Self) = .{};
    var new_cfg = try_load_user_config();
    if (new_cfg) |*cfg| {
        defer meta.zon_free(allocator, cfg.*);
        const struct_info = @typeInfo(Self).@"struct";
        if (user_config) |*old_cfg| {
            inline for (struct_info.fields) |field| {
                if (!meta.deep_equal(
                    @FieldType(@TypeOf(cfg.*), field.name),
                    &@field(old_cfg.*, field.name),
                    &@field(cfg.*, field.name),
                )) {
                    @field(mask, field.name) = true;
                    mem.swap(
                        @FieldType(@TypeOf(cfg.*), field.name),
                        &@field(old_cfg.*, field.name),
                        &@field(cfg.*, field.name),
                    );
                }
            }
        } else {
            inline for (struct_info.fields) |field| {
                @field(mask, field.name) = true;
            }
        }

        // if modified, refresh config
        blk: {
            inline for (struct_info.fields) |field| {
                if (@field(mask, field.name)) {
                    refresh_config();
                    break :blk;
                }
            }
        }
    }
    return mask;
}


fn try_load_user_config() ?meta.make_fields_optional(Self) {
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

    const stat = file.stat() catch |err| {
        log.err("stat file `{s}` failed: {}", .{ path, err });
        return null;
    };
    const buffer = allocator.alloc(u8, stat.size+1) catch |err| {
        log.err("alloc {} byte failed: {}", .{ stat.size+1, err });
        return null;
    };
    defer allocator.free(buffer);

    _ = file.readAll(buffer) catch return null;
    buffer[stat.size] = 0;

    @setEvalBranchQuota(20000);
    return zon.parse.fromSlice(
        meta.make_fields_optional(Self),
        allocator,
        buffer[0..stat.size:0],
        null,
        .{.ignore_unknown_fields = true},
    ) catch |err| {
        log.err("load user config failed: {}", .{ err });
        return null;
    };
}


fn refresh_config() void {
    log.debug("refresh config", .{});

    if (user_config) |cfg| {
        config = meta.override(default_config, cfg);

        if (cfg.bindings) |bindings| {
            inline for(&[_]BindingType { .key, .pointer }) |t| {
                const T, const name, const list = switch (comptime t) {
                    .key => .{ KeyBindingID, "keysym", &key_binding_list },
                    .pointer => .{ PointerBindingID, "button", &pointer_binding_list },
                };
                var set: std.HashMap(
                    T,
                    void,
                    binding_context(t),
                    std.hash_map.default_max_load_percentage,
                ) = .init(allocator);
                defer set.deinit();

                if (@field(bindings, @tagName(t))) |arr| {
                    if (@field(default_config.bindings, @tagName(t)).len > 0) {
                        list.clearRetainingCapacity();
                        for (arr) |binding| {
                            var id: T = undefined;
                            id.mode = binding.mode;
                            id.modifiers = @bitCast(binding.modifiers);
                            @field(id, name) = switch (comptime t) {
                                .key => keysym_from_name(@field(binding, name)) orelse continue,
                                .pointer => @intFromEnum(@field(binding, name)),
                            };
                            if (set.contains(id)) continue;

                            list.append(allocator, binding) catch continue;
                            set.put(id, {}) catch continue;
                        }
                        for (@field(default_config.bindings, @tagName(t))) |binding| {
                            var id: T = undefined;
                            id.mode = binding.mode;
                            id.modifiers = @bitCast(binding.modifiers);
                            @field(id, name) = switch (comptime t) {
                                .key => keysym_from_name(@field(binding, name)) orelse continue,
                                .pointer => @intFromEnum(@field(binding, name)),
                            };
                            if (set.contains(id)) continue;

                            list.append(allocator, binding) catch continue;
                            set.put(id, {}) catch continue;
                        }
                        @field(config.?.bindings, @tagName(t)) = list.items;
                    }
                }
            }
        }
        log.debug("config: {any}", .{ config.? });
    }
}


pub inline fn get() *Self {
    if (config == null) {
        config = default_config;
    }
    return &config.?;
}


pub fn get_mode_tag(self: *const Self, mode: []const u8) ?[]const u8 {
    for (self.bindings.mode_tag) |pair| {
        const m, const t = pair;
        if (mem.eql(u8, m, mode)) return t;
    }
    return null;
}


// https://codeberg.org/river/river-classic/src/commit/f0908e2d117ede7114fa85c65622b055c565c250/river/command/map.zig#L254
pub fn keysym_from_name(name: []const u8) ?u32 {
    const n = allocator.dupeZ(u8, name) catch |err| {
        log.err("dupeZ failed while call keysym_from_name: {}", .{ err });
        return null;
    };
    defer allocator.free(n);

    const keysym = Keysym.fromName(n, .case_insensitive);
    if (keysym == .NoSymbol) {
        log.err("invalid keysym `{s}`", .{ name });
        return null;
    }

    if (@intFromEnum(keysym) == Keysym.XF86Screensaver) {
        if (mem.eql(u8, name, "XF86Screensaver")) {
            //
        } else if (mem.eql(u8, name, "XF86ScreenSaver")) {
            return Keysym.XF86ScreenSaver;
        } else {
            log.err("ambiguous keysym name '{s}'", .{ name });
            return null;
        }
    }

    return @intFromEnum(keysym);
}
