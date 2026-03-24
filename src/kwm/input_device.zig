const Self = @This();

const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.input_device);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Config = @import("config");
const Context = @import("context.zig");

const utils = @import("utils.zig");

pub const RepeatInfo = struct {
    rate: i32,
    delay: i32,
};


link: wl.list.Link = undefined,

rwm_input_device: *river.InputDeviceV1,

new: bool = true,
name: ?[]const u8 = null,
type: river.InputDeviceV1.Type = undefined,


pub fn create(rwm_input_device: *river.InputDeviceV1) !*Self {
    const input_device = try utils.allocator.create(Self);
    errdefer utils.allocator.destroy(input_device);

    log.debug("<{*}> created", .{ input_device });

    input_device.* = .{
        .rwm_input_device = rwm_input_device,
    };
    input_device.link.init();

    rwm_input_device.setListener(*Self, rwm_input_device_listener, input_device);

    return input_device;
}


pub fn destroy(self: *Self) void {
    log.debug("<{*}> destroyed", .{ self });

    if (self.name) |name| {
        utils.allocator.free(name);
    }

    self.link.remove();
    self.rwm_input_device.destroy();

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

    for (config.input_device_rules) |rule| {
        if (rule.match(self.name, context.hostname)) {
            self.apply_rule(&rule);
            break;
        }
    }
}


fn apply_rule(self: *Self, rule: *const Config.InputDeviceRule) void {
    switch (self.type) {
        .keyboard => {
            if (rule.repeat_info) |repeat_info| {
                log.debug("<{*}> set repeat info: (rate: {}, delay: {})", .{ self, repeat_info.rate, repeat_info.delay});

                self.rwm_input_device.setRepeatInfo(repeat_info.rate, repeat_info.delay);
            }
        },
        .pointer => {
            if (rule.scroll_factor) |scroll_factor| {
                log.debug("<{*}> set scroll factor: {}", .{ self, scroll_factor });

                self.rwm_input_device.setScrollFactor(.fromDouble(scroll_factor));
            }
        },
        else => {}
    }
}


fn set_name(self: *Self, name: []const u8) void {
    if (self.name) |name_| {
        utils.allocator.free(name_);
        self.name = null;
    }
    self.name = utils.allocator.dupe(u8, name) catch null;
}


fn rwm_input_device_listener(rwm_input_device: *river.InputDeviceV1, event: river.InputDeviceV1.Event, input_device: *Self) void {
    std.debug.assert(rwm_input_device == input_device.rwm_input_device);

    switch (event) {
        .type => |data| {
            log.debug("<{*}> type: {s}", .{ input_device, @tagName(data.type) });

            input_device.type = data.type;
        },
        .name => |data| {
            log.debug("<{*}> name: {s}", .{ input_device, data.name });

            input_device.set_name(mem.span(data.name));
        },
        .removed => {
            log.debug("<{*}> removed", .{ input_device });

            input_device.destroy();
        }
    }
}
