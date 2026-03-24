const Self = @This();

const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const posix = std.posix;
const linux = std.os.linux;
const log = std.log.scoped(.xkb_keyboard);

const xkbcommon = @import("xkbcommon");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Config = @import("config");

const utils = @import("utils.zig");
const Context = @import("context.zig");

const InputDevice = @import("input_device.zig");

pub const NumlockState = enum {
    enabled,
    disabled,
};
pub const CapslockState = enum {
    enabled,
    disabled,
};
pub const Layout = union(enum) {
    index: u32,
    name: []const u8,
};
pub const Keymap = union(enum) {
    file: struct {
        path: []const u8,
        format: river.XkbConfigV1.KeymapFormat,
    },
    options: struct {
        rules: ?[]const u8 = null,
        model: ?[]const u8 = null,
        layout: ?[]const u8 = null,
        variant: ?[]const u8 = null,
        options: ?[]const u8 = null,
    },

    pub fn eql_with(self: *const @This(), other: *const @This()) bool {
        const self_tag = meta.activeTag(self.*);
        const other_tag = meta.activeTag(other.*);
        if (self_tag != other_tag) return false;
        switch (self.*) {
            .file => |*self_file| {
                const other_file = &other.file;
                if (!mem.eql(u8, self_file.path, other_file.path)) return false;
                if (self_file.format != other_file.format) return false;
            },
            .options => |*self_options| {
                const other_options = &other.options;
                inline for (&[_][]const u8 { "rules", "model", "layout", "variant", "options" }) |name| {
                    const a = @field(self_options, name);
                    const b = @field(other_options, name);
                    if (a != null or b != null) {
                        if (a == null or b == null) return false;
                        if (!mem.eql(u8, a.?, b.?)) return false;
                    }
                }
            }
        }
        return true;
    }
};


link: wl.list.Link = undefined,

rwm_xkb_keyboard: *river.XkbKeyboardV1,

input_device: ?*InputDevice = null,

new: bool = true,
numlock: NumlockState = undefined,
capslock: CapslockState = undefined,
layout: struct {
    index: u32 = 0,
    name: ?[]const u8 = null,
} = .{},
keymap: ?Keymap = null,


pub fn create(rwm_xkb_keyboard: *river.XkbKeyboardV1) !*Self {
    const xkb_keyboard = try utils.allocator.create(Self);
    errdefer utils.allocator.destroy(xkb_keyboard);

    log.debug("<{*}> created", .{ xkb_keyboard });

    xkb_keyboard.* = .{
        .rwm_xkb_keyboard = rwm_xkb_keyboard,
    };
    xkb_keyboard.link.init();

    rwm_xkb_keyboard.setListener(*Self, rwm_xkb_keyboard_listener, xkb_keyboard);

    return xkb_keyboard;
}


pub fn destroy(self: *Self) void {
    log.debug("<{*}> destroyed", .{ self });

    if (self.layout.name) |name| {
        utils.allocator.free(name);
        self.layout.name = null;
    }

    self.link.remove();
    self.rwm_xkb_keyboard.destroy();

    utils.allocator.destroy(self);
}


pub fn manage(self: *Self) void {
    log.debug("<{*}> manage", .{ self });

    if (self.new) {
        self.new = false;

        self.apply_rules();
    }
}


pub fn apply_rules(self: *Self) void {
    log.debug("<{*}> apply rules", .{ self });

    const config = Config.get();
    const context = Context.get();

    for (config.xkb_keyboard_rules) |rule| {
        if (rule.match((self.input_device orelse return).name, context.hostname)) {
            self.apply_rule(&rule);
            break;
        }
    }
}


fn apply_rule(self: *Self, rule: *const Config.XkbKeyboardRule) void {
    if (rule.numlock) |state| {
        if (self.numlock != state) self.set_numlock(state);
    }

    if (rule.capslock) |state| {
        if (self.capslock != state) self.set_capslock(state);
    }

    var keymap_updated = false;
    if (rule.keymap) |keymap| blk: {
        if (self.keymap != null and self.keymap.?.eql_with(&keymap)) break :blk;

        self.set_keymap(&keymap) catch |err| {
            log.err("<{*}> set keymap failed: {}", .{ self, err });
            break :blk;
        };

        keymap_updated = true;

        if (self.layout.name) |name| utils.allocator.free(name);
        self.layout = .{};
    }

    if (rule.layout) |layout| {
        if (keymap_updated or switch (layout) {
            .index => |index| index != self.layout.index,
            .name => |name| if (self.layout.name) |layout_name| !mem.eql(u8, layout_name, name) else true,
        }) self.set_layout(layout);
    }
}


fn set_numlock(self: *Self, state: NumlockState) void {
    log.debug("<{*}> set numlock: {s}", .{ self, @tagName(state) });

    switch (state) {
        .enabled => self.rwm_xkb_keyboard.numlockEnable(),
        .disabled => self.rwm_xkb_keyboard.numlockDisable(),
    }
}


fn set_capslock(self: *Self, state: CapslockState) void {
    log.debug("<{*}> set capslock: {s}", .{ self, @tagName(state) });

    switch (state) {
        .enabled => self.rwm_xkb_keyboard.capslockEnable(),
        .disabled => self.rwm_xkb_keyboard.capslockDisable(),
    }
}


fn set_layout(self: *Self, layout: Layout) void {
    switch (layout) {
        .index => |index| {
            log.debug("<{*}> set keyboard layout to {}", .{ self, index });

            self.rwm_xkb_keyboard.setLayoutByIndex(@intCast(index));
        },
        .name => |name| {
            log.debug("<{*}> set keyboard layout to {s}", .{ self, name });

            const n = utils.allocator.dupeZ(u8, name) catch |err| {
                log.err("<{*}> dupeZ failed while set layout by name: {}", .{ self, err });
                return;
            };
            defer utils.allocator.free(n);
            self.rwm_xkb_keyboard.setLayoutByName(n);
        }
    }
}


fn set_keymap(self: *Self, keymap: *const Keymap) !void {
    const context = Context.get();

    if (context.rwm_xkb_config) |rwm_xkb_config| {
        const rwm_xkb_keymap = switch (keymap.*) {
            .file => |file| blk: {
                log.debug("<{*}> set keymap to `{s}` with format {s}", .{ self, file.path, @tagName(file.format) });

                const fd = try posix.open(file.path, .{ .ACCMODE = .RDWR }, 0);
                defer posix.close(fd);

                break :blk try rwm_xkb_config.createKeymap(fd, file.format);
            },
            .options => |map| blk: {
                log.debug(
                    "<{*}> set keymap to (rules: {s}, model: {s}, layout: {s}, variant: {s}, options: {s})",
                    .{
                        self,
                        map.rules orelse "null",
                        map.model orelse "null",
                        map.layout orelse "null",
                        map.variant orelse "null",
                        map.options orelse "null",
                    },
                );

                const xkb_context = xkbcommon.Context.new(.no_flags) orelse return error.XkbContextNewFailed;
                defer xkb_context.unref();

                const xkb_keymap_rules = if (map.rules) |rules| try utils.allocator.dupeZ(u8, rules) else null;
                const xkb_keymap_model = if (map.model) |model| try utils.allocator.dupeZ(u8, model) else null;
                const xkb_keymap_layout = if (map.layout) |layout| try utils.allocator.dupeZ(u8, layout) else null;
                const xkb_keymap_variant = if (map.variant) |variant| try utils.allocator.dupeZ(u8, variant) else null;
                const xkb_keymap_options = if (map.options) |options| try utils.allocator.dupeZ(u8, options) else null;
                defer {
                    if (xkb_keymap_rules) |rules| utils.allocator.free(rules);
                    if (xkb_keymap_model) |model| utils.allocator.free(model);
                    if (xkb_keymap_layout) |layout| utils.allocator.free(layout);
                    if (xkb_keymap_variant) |variant| utils.allocator.free(variant);
                    if (xkb_keymap_options) |options| utils.allocator.free(options);
                }

                const xkb_rule_names = xkbcommon.RuleNames {
                    .rules = if (xkb_keymap_rules) |rules| rules.ptr else null,
                    .model = if (xkb_keymap_model) |model| model.ptr else null,
                    .layout = if (xkb_keymap_layout) |layout| layout.ptr else null,
                    .variant = if (xkb_keymap_variant) |variant| variant.ptr else null,
                    .options = if (xkb_keymap_options) |options| options.ptr else null,
                };

                const xkb_keymap = xkbcommon.Keymap.newFromNames(
                    xkb_context,
                    &xkb_rule_names,
                    .no_flags,
                ) orelse return error.XkbKeymapNewFailed;
                defer xkb_keymap.unref();

                const fd = try posix.memfd_create("kwm-keymap-file", linux.MFD.CLOEXEC);
                defer posix.close(fd);

                const xkb_keymap_str: ?[*:0]const u8 = @ptrCast(xkb_keymap.getAsString(.text_v1));
                _ = try posix.write(fd, mem.span(xkb_keymap_str orelse return error.GetXkbKeymapStringFailed));

                break :blk try rwm_xkb_config.createKeymap(fd, .text_v1);
            }
        };
        defer rwm_xkb_keymap.destroy();

        self.keymap = keymap.*;
        self.rwm_xkb_keyboard.setKeymap(rwm_xkb_keymap);
    } else return error.MissingRiverXkbConfig;
}


fn rwm_xkb_keyboard_listener(rwm_xkb_keyboard: *river.XkbKeyboardV1, event: river.XkbKeyboardV1.Event, xkb_keyboard: *Self) void {
    std.debug.assert(rwm_xkb_keyboard == xkb_keyboard.rwm_xkb_keyboard);

    switch (event) {
        .input_device => |data| {
            log.debug("<{*}> input_device: {*}", .{ xkb_keyboard, data.device });

            const rwm_input_device = data.device orelse return;
            const input_device: *InputDevice = @ptrCast(@alignCast(rwm_input_device.getUserData()));

            log.debug("<{*}> input_device, name: {s}", .{ xkb_keyboard, input_device.name orelse "" });

            xkb_keyboard.input_device = input_device;
        },
        .layout => |data| {
            log.debug("<{*}> layout, index: {}, name: {s}", .{ xkb_keyboard, data.index, data.name orelse "" });

            if (xkb_keyboard.layout.name) |name| {
                utils.allocator.free(name);
                xkb_keyboard.layout.name = null;
            }

            xkb_keyboard.layout.index = data.index;
            if (data.name) |name| {
                xkb_keyboard.layout.name = utils.allocator.dupe(u8, mem.span(name)) catch null;
            }
        },
        .capslock_enabled => {
            log.debug("<{*}> capslock_enabled", .{ xkb_keyboard });

            xkb_keyboard.capslock = .enabled;
        },
        .capslock_disabled => {
            log.debug("<{*}> capslock_disabled", .{ xkb_keyboard });

            xkb_keyboard.capslock = .disabled;
        },
        .numlock_enabled => {
            log.debug("<{*}> numlock_enabled", .{ xkb_keyboard });

            xkb_keyboard.numlock = .enabled;
        },
        .numlock_disabled => {
            log.debug("<{*}> numlock_disabled", .{ xkb_keyboard });

            xkb_keyboard.numlock = .disabled;
        },
        .removed => {
            log.debug("<{*}> removed", .{ xkb_keyboard });

            xkb_keyboard.destroy();
        }
    }
}
