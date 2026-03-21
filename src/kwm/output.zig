const Self = @This();

const build_options = @import("build_options");
const std = @import("std");
const mem = std.mem;
const math = std.math;
const log = std.log.scoped(.output);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Config = @import("config");

const utils = @import("utils.zig");
const layout = @import("layout.zig");
const Context = @import("context.zig");
const Window = @import("window.zig");
const types = @import("types.zig");


link: wl.list.Link = undefined,

wl_output: ?*wl.Output = null,
rwm_output: *river.OutputV1,
rwm_layer_shell_output: ?*river.LayerShellOutputV1,

tag: u32 = 1,
main_tag: u32 = 1,
prev_tag: u32 = 1,
prev_main_tag: u32 = 1,
layout_tag: [32]layout.Type,
prev_layout_tag: [32]layout.Type,

name: ?[]const u8 = null,
x: i32 = undefined,
y: i32 = undefined,
width: i32 = undefined,
height: i32 = undefined,

bar: if (build_options.bar_enabled) @import("bar.zig") else void = undefined,


pub fn create(
    rwm_output: *river.OutputV1,
    rwm_layer_shell_output: ?*river.LayerShellOutputV1,
) !*Self {
    const output = try utils.allocator.create(Self);
    errdefer utils.allocator.destroy(output);

    defer log.debug("<{*}> created", .{ output });

    const config = Config.get();

    output.* = .{
        .rwm_output = rwm_output,
        .rwm_layer_shell_output = rwm_layer_shell_output,
        .layout_tag = .{ config.layout.default } ** 32,
        .prev_layout_tag = .{ config.layout.default } ** 32,
    };
    output.link.init();

    if (comptime build_options.bar_enabled) {
        try output.bar.init(output);
    }

    rwm_output.setListener(*Self, rwm_output_listener, output);

    if (rwm_layer_shell_output) |layer_shell_output| {
        layer_shell_output.setListener(*Self, rwm_layer_shell_output_listener, output);
    }

    return output;
}


pub fn destroy(self: *Self) void {
    defer log.debug("<{*}> destroyed", .{ self });

    const context = Context.get();

    {
        var it = context.seats.safeIterator(.forward);
        while (it.next()) |seat| {
            switch (seat.previous_focused) {
                .output => |output| if (self == output) {
                    seat.previous_focused = .none;
                },
                else => {}
            }
        }
    }

    self.set_name(null);

    self.link.remove();
    self.rwm_output.destroy();
    if (self.wl_output) |wl_output| wl_output.destroy();

    if (self.rwm_layer_shell_output) |rwm_layer_shell_output| {
        rwm_layer_shell_output.destroy();
    }

    if (comptime build_options.bar_enabled) self.bar.deinit();

    utils.allocator.destroy(self);
}


pub inline fn exclusive_x(self: *Self) i32 {
    return self.x;
}


pub inline fn exclusive_y(self: *Self) i32 {
    const config = Config.get();

    return
        if (comptime build_options.bar_enabled)
            if (config.bar.position == .bottom or self.bar.hidden) self.y
            else self.y + self.bar.height(true)
        else self.y;
}


pub inline fn exclusive_width(self: *Self) i32 {
    return self.width;
}


pub inline fn exclusive_height(self: *Self) i32 {
    return
        if (comptime build_options.bar_enabled)
            if (self.bar.hidden) self.height
            else self.height - self.bar.height(true)
        else self.height;
}


pub fn fullscreen_window(self: *Self) ?*Window {
    const context = Context.get();

    {
        var it = context.windows.safeIterator(.forward);
        while (it.next()) |window| {
            if (!window.is_visible_in(self)) continue;

            switch (window.fullscreen) {
                .output => |output| {
                    if (output == self) {
                        return window;
                    }
                },
                else => {}
            }
        }
    }

    return null;
}


pub fn master_window(self: *Self) ?*Window {
    const context = Context.get();

    {
        var it = context.windows.safeIterator(.forward);
        while (it.next()) |window| {
            if (window.is_visible_in(self) and !window.floating) {
                return window;
            }
        }
    }

    return null;
}


pub fn set_tag(self: *Self, tag: u32) void {
    if (tag == 0 or self.tag == tag) return;

    log.debug("<{*}> set tag: {b}", .{ self, tag });

    self.prev_tag = self.tag;
    self.prev_main_tag = self.main_tag;

    self.tag = tag;
    if (self.main_tag & tag == 0) {
        // use the lowest bit 1 as new main tag
        self.main_tag = tag ^ (tag & (tag-1));

        log.debug("<{*}> update main tag to {b}", .{ self, self.main_tag });
    }

    if (comptime build_options.bar_enabled) self.bar.damage(.tags);
}


pub fn switch_to_previous_tag(self: *Self) void {
    log.debug("<{*}> switch to previous tag", .{ self });

    mem.swap(u32, &self.tag, &self.prev_tag);
    mem.swap(u32, &self.main_tag, &self.prev_main_tag);

    if (comptime build_options.bar_enabled) self.bar.damage(.tags);
}


fn get_occupied_tags(self: *Self) u32 {
    const context = Context.get();
    var occupied_tags: u32 = 0;
    var it = context.windows.safeIterator(.forward);
    while (it.next()) |window| {
        if (window.output == self) occupied_tags |= window.tag;
    }
    return occupied_tags;
}


pub fn switch_to_unoccupied_tag(self: *Self) void {
    const config = Config.get();
    const total_tags = config.tags.len;

    log.debug("<{*}> switch to unoccupied tag", .{ self });

    const occupied_tags = self.get_occupied_tags();
    const all_occupied = std.math.pow(u64, 2, total_tags) - 1;
    if (occupied_tags == 0 or occupied_tags == all_occupied) return;
    const trailing_zeroes = @ctz(~occupied_tags);
    var new_tag: u32 = 1;
    for (0..trailing_zeroes) |_| {
        new_tag <<= 1;
    }
    self.set_tag(new_tag);
    if (comptime build_options.bar_enabled) self.bar.damage(.tags);
}


pub fn shift_tag(self: *Self, direction: types.Direction) void {
    const config = Config.get();
    const total_tags = config.tags.len;

    log.debug("<{*}> shift tag: {}", .{ self, direction });

    const current_tags = self.tag;
    if (current_tags == 0) {
        log.warn("<{*}> no tags selected", .{ self });
        return;
    }

    const occupied_tags: u32 = self.get_occupied_tags();

    if (occupied_tags == 0) {
        var new_tags = current_tags;
        if (direction == .forward) {
            new_tags = (new_tags << 1) | (new_tags >> @as(u5, @intCast(total_tags - 1)));
        } else {
            new_tags = (new_tags >> 1) | (new_tags << @as(u5, @intCast(total_tags - 1)));
        }
        new_tags &= (@as(u32, 1) << @as(u5, @intCast(total_tags))) - 1;
        if (new_tags != 0) self.set_tag(new_tags);
        return;
    }

    var new_tags: u32 = 0;
    var tag_mask: u32 = 1;

    for (0..total_tags) |i| {
        if (current_tags & tag_mask != 0) {
            var found = false;
            var test_index = i;

            for (0..total_tags) |_| {
                test_index = if (direction == .forward)
                    (test_index + 1) % total_tags
                else if (test_index == 0)
                    total_tags - 1
                else
                    test_index - 1;

                const test_mask = @as(u32, 1) << @as(u5, @intCast(test_index));
                if (occupied_tags & test_mask != 0) {
                    new_tags |= test_mask;
                    found = true;
                    break;
                }
            }

            if (!found and (occupied_tags & tag_mask != 0)) new_tags |= tag_mask;
        }
        tag_mask <<= 1;
    }

    if (new_tags != 0) self.set_tag(new_tags)
    else log.warn("<{*}> no valid tags found after shifting", .{ self });
}


pub fn toggle_tag(self: *Self, mask: u32) void {
    if (self.tag ^ mask == 0) return;

    log.debug("<{*}> toggle tag: (tag: {b}, mask: {b})", .{ self, self.tag, mask });

    self.tag ^= mask;
    // if there is only one bit 1, set it as new main tag
    if (self.tag & (self.tag-1) == 0) {
        log.debug("<{*}> update main tag to {b}", .{ self, self.tag });

        self.main_tag = self.tag;
    }

    if (comptime build_options.bar_enabled) self.bar.damage(.tags);
}


pub fn current_layout(self: *Self) layout.Type {
    std.debug.assert(self.main_tag != 0 and self.main_tag & (self.main_tag-1) == 0);

    return self.layout_tag[@ctz(self.main_tag)];
}


pub fn set_current_layout(self: *Self, layout_t: layout.Type) void {
    std.debug.assert(self.main_tag != 0 and self.main_tag & (self.main_tag-1) == 0);

    const i = @ctz(self.main_tag);
    if (self.layout_tag[i] == layout_t) return;

    log.debug("<{*}>(tag: {b}) set layout to {s}", .{ self, self.main_tag, @tagName(layout_t) });

    self.prev_layout_tag[i] = self.layout_tag[i];
    self.layout_tag[i] = layout_t;

    if (comptime build_options.bar_enabled) self.bar.damage(.layout);
}


pub fn switch_to_previous_layout(self: *Self) void {
    log.debug("<{*}> tag {b} switch to previous layout", .{ self, self.main_tag });

    const i = @ctz(self.main_tag);
    mem.swap(layout.Type, &self.layout_tag[i], &self.prev_layout_tag[i]);

    if (comptime build_options.bar_enabled) self.bar.damage(.layout);
}


pub fn manage(self: *Self) void {
    layout.arrange(self.current_layout(), self);

    log.debug("<{*}> managed", .{ self });
}


fn set_name(self: *Self, name: ?[]const u8) void {
    if (self.name) |name_| {
        utils.allocator.free(name_);
        self.name = null;
    }

    if (name) |name_| {
        self.name = utils.allocator.dupe(u8, name_) catch null;
    }
}


fn rwm_output_listener(rwm_output: *river.OutputV1, event: river.OutputV1.Event, output: *Self) void {
    std.debug.assert(rwm_output == output.rwm_output);

    switch (event) {
        .dimensions => |data| {
            log.debug("<{*}> new dimensions: (width: {}, height: {})", .{ output, data.width, data.height });

            output.width = data.width;
            output.height = data.height;
        },
        .position => |data| {
            log.debug("<{*}> new position: (x: {}, y: {})", .{ output, data.x, data.y });

            output.x = data.x;
            output.y = data.y;
        },
        .removed => {
            log.debug("<{*}> removed, name: {s}", .{ output, output.name orelse "" });

            const context = Context.get();

            context.prepare_remove_output(output);

            output.destroy();
        },
        .wl_output => |data| {
            log.debug("<{*}> wl_output: {}", .{ output, data.name });

            const context = Context.get();
            const wl_output = context.wl_registry.bind(data.name, wl.Output, 4) catch return;
            output.wl_output = wl_output;
            wl_output.setListener(*Self, wl_output_listener, output);
        },
    }
}


fn rwm_layer_shell_output_listener(
    rwm_layer_shell_output: *river.LayerShellOutputV1,
    event: river.LayerShellOutputV1.Event,
    output: *Self,
) void {
    std.debug.assert(rwm_layer_shell_output == output.rwm_layer_shell_output.?);

    switch (event) {
        .non_exclusive_area => |data| {
            log.debug(
                "<{*}> non exclusive area: (width: {}, height: {}, x: {}, y: {})",
                .{ output, data.width, data.height, data.x, data.y },
            );

            output.width = data.width;
            output.height = data.height;
            output.x = data.x;
            output.y = data.y;
        },
    }
}


fn wl_output_listener(wl_output: *wl.Output, event: wl.Output.Event, output: *Self) void {
    std.debug.assert(wl_output == output.wl_output.?);

    const context = Context.get();
    switch (event) {
        .geometry => |data| {
            log.debug(
                "<{*}> geometry: (x: {}, y: {}, physical_width: {}, physical_height: {}, subpixel: {s}, make: {s}, model: {s}, transform: {s})",
                .{ output, data.x, data.y, data.physical_width, data.physical_height, @tagName(data.subpixel), data.make, data.model, @tagName(data.transform) },
            );
        },
        .mode => |data| {
            log.debug(
                "<{*}> mode: (flags: (current: {}, preferred: {}), width: {}, height: {}, refresh: {})",
                .{ output, data.flags.current, data.flags.preferred, data.width, data.height, data.refresh },
            );
        },
        .scale => |data| {
            log.debug("<{*}> scale: {}", .{ output, data.factor });
        },
        .name => |data| {
            log.debug("<{*}> name: {s}", .{ output, data.name });

            const name = mem.span(data.name);
            output.set_name(name);

            {
                var it = context.windows.safeIterator(.forward);
                while (it.next()) |window| {
                    if (window.former_output) |former| {
                        if (mem.eql(u8, former, name)) {
                            log.debug("{*} former output match `{s}`", .{ window, name });
                            window.set_output(output, true);
                        }
                    }
                }
            }
        },
        .description => |data| {
            log.debug("<{*}> description: {s}", .{ output, data.description });
        },
        .done => {
            log.debug("<{*}> done", .{ output });
        }
    }
}
