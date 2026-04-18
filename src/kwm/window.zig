const Self = @This();

const build_options = @import("build_options");
const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.window);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Config = @import("config");

const utils = @import("utils.zig");
const types = @import("types.zig");
const Seat = @import("seat.zig");
const Output = @import("output.zig");
const Context = @import("context.zig");
const CustomBorder = @import("custom_border.zig");

pub const Decoration = enum {
    csd,
    ssd,
};

pub const Edge = enum {
    top,
    bottom,
    left,
    right,
};

const Event = union(enum) {
    init,
    fullscreen: ?*Output,
    unfullscreen,
    minimize,
    maximize: bool,
    move: ?*Seat,
    resize: ?*Seat,
};


link: wl.list.Link = undefined,
flink: wl.list.Link = undefined,

rwm_window: *river.WindowV1,
rwm_window_node: *river.NodeV1,

output: ?*Output = null,
former_output: ?[]const u8 = null,

unhandled_events: std.ArrayList(Event) = undefined,

layer_managed: bool = false,
floating_changed: bool = true,
fullscreen: union(enum) {
    none,
    window,
    output: *Output,
} = .none,
maximize: bool = false,
floating: bool = false,
sticky: bool = false,
hidden: bool = false,
clip_state: enum {
    unknow,
    normal,
    cliped,
} = .unknow,
geometry_undefined: bool = false,

tag: u32 = 1,
pid: i32 = 0,
app_id: ?[]const u8 = null,
title: ?[]const u8 = null,
parent: ?*Self = null,
decoration: ?Decoration = null,
decoration_hint: river.WindowV1.DecorationHint = .no_preference,

is_terminal: bool = false,
swallowing: ?*Self = null,
swallowed_by: ?*Self = null,
disable_swallow: bool = false,
swallowing_border: ?CustomBorder = null,

x: i32 = 0,
y: i32 = 0,
width: i32 = 0,
height: i32 = 0,
min_width: i32 = 1,
min_height: i32 = 1,
scroller_mfact: f32 = undefined,
scroller_x: ?union(enum) {
    x: i32,
    center,
} = null,
floating_geometry: ?struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
} = null,
operator: union(enum) {
    none,
    move: struct {
        start_x: i32,
        start_y: i32,
        seat: *Seat,
    },
    resize: struct {
        start_width: i32,
        start_height: i32,
        seat: *Seat,
    },
} = .none,


pub fn create(rwm_window: *river.WindowV1, output: ?*Output) !*Self {
    const window = try utils.allocator.create(Self);
    errdefer utils.allocator.destroy(window);

    defer log.debug("<{*}> created", .{ window });

    const config = Config.get();

    const rwm_window_node = try rwm_window.getNode();
    errdefer rwm_window_node.destroy();

    window.* = .{
        .rwm_window = rwm_window,
        .rwm_window_node = rwm_window_node,
        .unhandled_events = try .initCapacity(utils.allocator, 2),
        .scroller_mfact = (if (output) |o| o.layout else config.layout).scroller.mfact,
    };
    window.link.init();
    window.flink.init();
    if (output) |o| {
        window.set_tag(o.tag);
        window.set_output(o, false);
    }
    try window.unhandled_events.append(utils.allocator, .init);

    rwm_window.setListener(*Self, rwm_window_listener, window);

    return window;
}


pub fn destroy(self: *Self) void {
    defer log.debug("<{*}> destroyed", .{ self });

    const context = Context.get();

    {
        var it = context.seats.safeIterator(.forward);
        while (it.next()) |seat| {
            switch (seat.previous_focused) {
                .window => |window| if (self == window) {
                    seat.previous_focused = if (self.output) |output| .{ .output = output } else .none;
                },
                else => {}
            }

            if (seat.window_below_pointer.window == self) {
                seat.window_below_pointer = .{};
            }
        }
    }

    self.set_former_output(null);

    if (self.is_terminal) {
        context.unregister_terminal(self);
    }
    self.unswallow();

    if (comptime build_options.bar_enabled) {
        if (self.output) |output| output.bar.damage(.tags);
    }

    self.link.remove();
    self.flink.remove();
    self.rwm_window.destroy();
    self.rwm_window_node.destroy();
    self.set_appid(null);
    self.set_title(null);
    self.unhandled_events.deinit(utils.allocator);

    utils.allocator.destroy(self);
}


pub fn set_output(self: *Self, output: ?*Output, clear_former: bool) void {
    log.debug("<{*}> set output to {*}", .{ self, output });

    if (self.output != output) {
        if (comptime build_options.bar_enabled) {
            if (self.output) |o| o.bar.damage(.tags);
        }

        self.output = output;

        // reset floating_geometry
        // window's output had changed, restore its geometry may cause error
        self.floating_geometry = null;

        if (comptime build_options.bar_enabled) {
            if (self.output) |o| o.bar.damage(.tags);
        }
    }

    if (clear_former) self.set_former_output(null);
}


pub fn set_former_output(self: *Self, output: ?[]const u8) void {
    log.debug("<{*}> set former output to `{s}`", .{ self, output orelse "" });

    if (self.former_output) |name| {
        utils.allocator.free(name);
        self.former_output = null;
    }

    if (output) |name| {
        self.former_output = utils.allocator.dupe(u8, name) catch |err| {
            log.err("dupe {s} failed: {}", .{ name, err });
            return;
        };
    }
}


pub fn set_tag(self: *Self, tag: u32) void {
    if (tag == 0) return;

    log.debug("<{*}> set tag: {b}", .{ self, tag });

    self.tag = tag;

    if (comptime build_options.bar_enabled) {
        if (self.output) |output| output.bar.damage(.tags);
    }
}


pub fn toggle_tag(self: *Self, mask: u32) void {
    if (self.tag ^ mask == 0) return;

    log.debug("<{*}> toggle tag: {b}", .{ self, mask });

    self.tag ^= mask;

    if (comptime build_options.bar_enabled) {
        if (self.output) |output| output.bar.damage(.tags);
    }
}


pub fn place(self: *Self, pos: types.PlacePosition) void {
    switch (pos) {
        .top => self.rwm_window_node.placeTop(),
        .bottom => self.rwm_window_node.placeBottom(),
        .above => |node| self.rwm_window_node.placeAbove(node),
        .below => |node| self.rwm_window_node.placeBelow(node),
    }
}


pub fn move(self: *Self, x: ?i32, y: ?i32) void {
    defer log.debug("<{*}> move to (x: {}, y: {})", .{ self, self.x, self.y });

    const config = Config.get();

    self.x = @max(
        config.border.width,
        @min(
            x orelse self.x,
            self.output.?.exclusive_width()-self.width-config.border.width
        )
    );
    self.y = @max(
        config.border.width,
        @min(
            y orelse self.y,
            self.output.?.exclusive_height()-self.height-config.border.width
        )
    );
}


pub fn unbound_move(self: *Self, x: ?i32, y: ?i32) void {
    defer log.debug("<{*}> unbound move to (x: {}, y: {})", .{ self, self.x, self.y });

    if (x) |new_x| self.x = new_x;
    if (y) |new_y| self.y = new_y;
}


pub fn snap_to(
    self: *Self,
    edge: Edge
) void {
    var new_x: ?i32 = null;
    var new_y: ?i32 = null;

    switch (edge) {
        .top => new_y = 0,
        .bottom => new_y = self.output.?.exclusive_height(),
        .left => new_x = 0,
        .right => new_x = self.output.?.exclusive_width(),
    }

    self.move(new_x, new_y);
}


pub fn resize(self: *Self, width: ?i32, height: ?i32) void {
    defer log.debug(
        "<{*}> set dimensions to (width: {}, height: {})",
        .{ self, self.width, self.height },
    );

    const config = Config.get();

    self.width = @min(
        self.output.?.exclusive_width()-self.x-config.border.width,
        @max(
            width orelse self.width,
            self.min_width,
        )
    );
    self.height = @min(
        self.output.?.exclusive_height()-self.y-config.border.width,
        @max(
            height orelse self.height,
            self.min_height,
        )
    );

    if (self.swallowing_border) |*border| {
        border.damage();
    }
}


pub fn unbound_resize(self: *Self, width: ?i32, height: ?i32) void {
    defer log.debug(
        "<{*}> unbound set dimensions to (width: {}, height: {})",
        .{ self, self.width, self.height },
    );

    if (width) |new_width| self.width = new_width;
    if (height) |new_height| self.height = new_height;

    if (self.swallowing_border) |*border| {
        border.damage();
    }
}


pub inline fn prepare_close(self: *Self) void {
    log.debug("<{*}> prepare to close", .{ self });

    self.rwm_window.close();
}


pub fn prepare_move(self: *Self, seat: ?*Seat) void {
    log.debug("<{*}> prepare to move, seat: {*}", .{ self, seat });

    self.append_event(.{ .move = seat });
}


pub fn prepare_resize(self: *Self, seat: ?*Seat) void {
    log.debug("<{*}> prepare to resize, seat: {*}", .{ self, seat });

    self.append_event(.{ .resize = seat });
}


pub fn prepare_fullscreen(self: *Self, output: ?*Output) void {
    if (output) |target_output| {
        log.debug("<{*}> prepare to fullscreen on {*}", .{ self, target_output });
    } else {
        log.debug("<{*}> prepare to fullscreen on window", .{ self });
    }


    self.append_event(.{ .fullscreen = output });
}


pub fn prepare_unfullscreen(self: *Self) void {
    log.debug("<{*}> prepare unfullscreen", .{ self });

    self.append_event(.unfullscreen);
}


pub fn prepare_minimize(self: *Self) void {
    log.debug("<{*}> prepare minimize", .{ self });

    self.append_event(.minimize);
}


pub fn set_border(self: *Self, width: i32, rgb: u32) void {
    log.debug("<{*}> set border: (width: {}, color: 0x{x})", .{ self, width, rgb });

    const color = utils.rgba(rgb);
    self.rwm_window.setBorders(
        .{
            .top = true,
            .bottom = true,
            .left = true,
            .right = true,
        },
        width,
        color.r,
        color.g,
        color.b,
        color.a,
    );
}


pub fn ensure_floating(self: *Self) void {
    if (self.output) |output| {
        if (output.current_layout() == .float) return;
    }
    self.toggle_floating(true);
}


pub fn toggle_floating(self: *Self, flag: ?bool) void {
    self.floating =
        if (flag) |floating| (if (self.floating != floating) floating else return)
        else !self.floating;
    self.layer_managed = false;
    self.floating_changed = true;

    log.debug("<{*}> toggle floating: {}", .{ self, self.floating });

    if (comptime build_options.bar_enabled) {
        if (self.output) |output| {
            output.bar.damage(.title);
        }
    }

    const config = Config.get();

    if (!config.remember_floating_geometry) return;

    if (self.floating) {
        if (self.floating_geometry) |geometry| {
            self.unbound_move(geometry.x, geometry.y);
            self.unbound_resize(geometry.width, geometry.height);
        }
    } else {
        self.floating_geometry = .{
            .x = self.x,
            .y = self.y,
            .width = self.width,
            .height = self.height,
        };
    }
}


pub fn toggle_maximize(self: *Self, flag: ?bool) void {
    self.maximize =
        if (flag) |maximize| (if (self.maximize != maximize) maximize else return)
        else !self.maximize;

    log.debug("<{*}> toggle maximize: {}", .{ self, self.maximize });

    self.append_event(.{ .maximize = self.maximize });

    if (self.swallowing_border) |*border| {
        border.damage();
    }
}


pub fn toggle_sticky(self: *Self) void {
    log.debug("<{*}> toggle sticky: {}", .{ self, !self.sticky });

    self.sticky = !self.sticky;

    if (comptime build_options.bar_enabled) {
        if (self.output) |output| output.bar.damage(.title);
    }
}


pub fn is_visible(self: *Self) bool {
    if (self.output) |output| {
        return (
            self.sticky or
            (self.tag & output.tag) != 0
        ) and self.swallowed_by == null;
    }
    return false;
}


pub fn is_visible_in(self: *Self, output: *Output) bool {
    if (self.output == null) return false;

    if (self.output.? != output) return false;

    return (
        self.sticky or
        (self.tag & output.tag) != 0
        ) and self.swallowed_by == null;
}


pub fn toggle_swallow(self: *Self) void {
    log.debug("<{*}> toggle swallow", .{ self });

    if (self.swallowing != null) {
        self.unswallow();
    } else {
        self.try_swallow();
    }
}


pub fn handle_events(self: *Self) void {
    defer self.unhandled_events.clearRetainingCapacity();

    const config = Config.get();

    for (self.unhandled_events.items) |event| {
        log.debug("<{*}> handle event: {s}", .{ self, @tagName(event) });

        switch (event) {
            .init => {
                log.debug("<{*}> managing new window", .{ self });

                self.rwm_window.setCapabilities(.{
                    .window_menu = false,
                    .maximize = true,
                    .fullscreen = true,
                    .minimize = config.minimize != .disabled,
                });

                if (self.parent != null) {
                    self.toggle_floating(true);
                }

                self.apply_rules();

                switch (self.decoration_hint) {
                    .only_supports_csd => self.decoration = .csd,
                    .prefers_csd => self.decoration = self.decoration orelse .csd,
                    .prefers_ssd => self.decoration = self.decoration orelse .ssd,
                    else => {}
                }

                switch (self.decoration orelse config.default_window_decoration) {
                    .csd => self.rwm_window.useCsd(),
                    .ssd => self.rwm_window.useSsd(),
                }

                if (self.floating or self.output == null or self.output.?.current_layout() == .float) {
                    self.geometry_undefined = true;
                }

                const context = Context.get();

                if (self.is_terminal) {
                    context.register_terminal(self);
                }

                if (config.auto_swallow) {
                    self.try_swallow();
                }
            },
            .fullscreen => |data| {
                log.debug("<{*}> managing fullscreen: {*}", .{ self, data });

                var fullscreen_output: ?*Output = null;

                switch (self.fullscreen) {
                    .none => {
                        self.rwm_window.informFullscreen();
                        if (data) |output| {
                            fullscreen_output = output;
                        } else {
                            log.debug("<{*}> fullscreen on window", .{ self });

                            self.fullscreen = .window;
                        }
                    },
                    .window => {
                        if (data) |output| {
                            fullscreen_output = output;
                        }
                    },
                    .output => |original_output| {
                        if (data) |output| {
                            if (output != original_output) {
                                log.debug("<{*}> fullscreen move from {*} to {*}", .{ self, original_output, output });

                                fullscreen_output = output;
                                self.rwm_window.exitFullscreen();
                            }
                        }
                    }
                }

                if (fullscreen_output) |output| {
                    log.debug("<{*}> fullscreen on {*}", .{ self, output });

                    self.rwm_window.fullscreen(output.rwm_output);
                    self.fullscreen = .{ .output = output };
                }
            },
            .unfullscreen => {
                log.debug("<{*}> managing unfullscreen", .{ self });

                switch (self.fullscreen) {
                    .none => {
                        log.warn("<{*}> unfullscreen while window is not fullscreen", .{ self });
                    },
                    .window => {
                        self.rwm_window.informNotFullscreen();
                    },
                    .output => {
                        self.rwm_window.informNotFullscreen();
                        self.rwm_window.exitFullscreen();
                    }
                }
                self.fullscreen = .none;
            },
            .minimize => {
                log.debug("<{*}> managing minimize", .{ self });

                switch (config.minimize) {
                    .disabled => {},
                    .send_to_tag => |tag| {
                        self.set_tag(tag);
                    }
                }
            },
            .maximize => |flag| {
                log.debug("<{*}> managing maximize: {}", .{ self, flag });

                if (flag) {
                    self.rwm_window.informMaximized();
                } else {
                    self.rwm_window.informUnmaximized();
                }
                self.maximize = flag;
            },
            .move => |data| {
                log.debug("<{*}> managing move, seat: {*}", .{ self, data });

                if (data) |seat| {
                    seat.op_start();
                    self.operator = .{
                        .move = .{
                            .start_x = self.x,
                            .start_y = self.y,
                            .seat = seat,
                        },
                    };
                } else {
                    switch (self.operator) {
                        .move => |op_data| {
                            op_data.seat.op_end();
                        },
                        else => unreachable,
                    }
                    self.operator = .none;
                }
            },
            .resize => |data| {
                log.debug("<{*}> managing resize, seat: {*}", .{ self, data });

                if (data) |seat| {
                    seat.op_start();
                    self.operator = .{
                        .resize = .{
                            .start_width = self.width,
                            .start_height = self.height,
                            .seat = seat,
                        },
                    };
                } else {
                    switch (self.operator) {
                        .resize => |op_data| {
                            op_data.seat.op_end();
                        },
                        else => unreachable,
                    }
                    self.operator = .none;
                }
            },
        }
    }

    if (self.floating_changed) {
        self.floating_changed = false;
        if (self.floating) {
            self.rwm_window.setTiled(.{});
        } else {
            self.rwm_window.setTiled(.{
                .top = true,
                .bottom = true,
                .left = true,
                .right = true,
            });
        }
    }
}


pub fn apply_rules(self: *Self) void {
    log.debug("<{*}> apply rules", .{ self });

    const config = Config.get();

    for (config.window_rules) |rule| {
        if (rule.match(self.app_id, self.title)) {
            self.apply_rule(&rule);
            break;
        }
    }
}


pub fn manage(self: *Self) void {
    log.debug("<{*}> managing, propose dimensions: (width: {}, height: {})", .{ self, self.width, self.height });

    const width, const height = blk: {
        const config = Config.get();

        var width = self.width;
        var height = self.height;
        if (self.maximize) {
            if (self.output) |output| {

                width = output.exclusive_width() - 2*config.border.width;
                height = output.exclusive_height() - 2*config.border.width;
            }
        }
        if (self.swallowing_border != null) {
            height -= 2 * config.border.width;
            width -= 2 * config.border.width;
        }

        break :blk .{ width, height };
    };

    self.rwm_window.proposeDimensions(width, height);
}


pub fn render(self: *Self) void {
    defer self.hidden = false;

    const config = Config.get();

    if (
        self.hidden
        or self.output == null
        or self.geometry_undefined
        or self.x - config.border.width >= self.output.?.width
        or self.x + self.width + config.border.width <= 0
        or self.y - config.border.width >= self.output.?.height
        or self.y + self.height + config.border.width <= 0
    ) {
        if (!self.hidden and !self.geometry_undefined)
            log.debug("<{*}> out of range, hide", .{ self });
        if (self.geometry_undefined)
            log.debug("<{*}> geometry undefined, hidden", .{ self });
        if (self.output == null)
            log.debug("<{*}> has no output, hide", .{ self });
        self.rwm_window.hide();
        return;
    }

    var offset_x: i32 = 0;
    var offset_y: i32 = 0;
    const output_x = self.output.?.exclusive_x();
    const output_y = self.output.?.exclusive_y();

    if (self.swallowing_border) |*border| {
        border.render(config.border.color.swallowing);
        offset_x += config.border.width;
        offset_y += config.border.width;
    }

    if (self.maximize) {
        log.debug("<{*}> rendering maximize", .{ self });
        offset_x += config.border.width;
        offset_y += config.border.width;
        self.rwm_window_node.setPosition(output_x + offset_x, output_y + offset_y);
        self.rwm_window.show();
        return;
    }

    log.debug("<{*}> rendering to (x: {}, y: {})", .{ self, self.x, self.y });

    self.rwm_window_node.setPosition(
        output_x + self.x + offset_x,
        output_y + self.y + offset_y
    );

    var left = self.x - config.border.width;
    var right = self.x + self.width + config.border.width;
    var top = self.y - config.border.width;
    var bottom = self.y + self.height + config.border.width;
    if (
        left < 0
        or top < 0
        or right > self.output.?.width
        or bottom > self.output.?.height
    ) {
        left = @max(left, 0);
        right = @min(right, self.output.?.width);
        top = @max(top, 0);
        bottom = @min(bottom, self.output.?.height);
        self.rwm_window.setClipBox(left-self.x-offset_x, top-self.y-offset_y, right-left, bottom-top);
        self.clip_state = .cliped;
    } else if (self.clip_state != .normal){
        self.rwm_window.setClipBox(0, 0, 0, 0);
        self.clip_state = .normal;
    }

    self.rwm_window.show();
}


pub fn hide(self: *Self) void {
    log.debug("<{*}> hide", .{ self });

    self.hidden = true;
}


fn set_appid(self: *Self, app_id: ?[]const u8) void {
    if (self.app_id) |appid| {
        utils.allocator.free(appid);
        self.app_id = null;
    }
    if (app_id) |appid| {
        self.app_id = utils.allocator.dupe(u8, appid) catch return;
    }
}


fn set_title(self: *Self, title: ?[]const u8) void {
    if (self.title) |tt| {
        utils.allocator.free(tt);
        self.title = null;
    }
    if (title) |tt| {
        self.title = utils.allocator.dupe(u8, tt) catch return;
    }
}


fn center(self: *Self) void {
    self.x = @divFloor(self.output.?.exclusive_width()-self.width, 2);
    self.y = @divFloor(self.output.?.exclusive_height()-self.height, 2);
}


fn append_event(self: *Self, event: Event) void {
    log.debug("<{*}> append event: {s}", .{ self, @tagName(event) });

    self.unhandled_events.append(utils.allocator, event) catch |err| {
        log.err("<{*}> append event {s} failed: {}", .{ self, @tagName(event), err });
        return;
    };
}


fn try_swallow(self: *Self) void {
    log.debug("<{*}> try swallow", .{ self });

    const context = Context.get();
    if (!self.disable_swallow and self.pid != 0) {
        var pid = self.pid;
        var ppid: i32 = undefined;
        while (true) {
            ppid = utils.parent_pid(pid);
            if (ppid == 0 or ppid == 1) break;

            if (context.find_terminal(ppid)) |term| {
                self.swallow(term);
                break;
            }

            pid = ppid;
        }
    }

}


fn swallow(self: *Self, window: *Self) void {
    if (self == window) return;

    if (self.swallowing != null or window.swallowed_by != null) return;

    if (!window.is_visible()) return;

    log.debug("<{*}> swallowing {*}", .{ self, window });

    self.swallowing = window;

    self.toggle_floating(window.floating);
    self.tag = window.tag;
    self.x = window.x;
    self.y = window.y;
    self.width = window.width;
    self.height = window.height;
    self.scroller_x = window.scroller_x;

    self.link.remove();
    window.link.insert(&self.link);
    self.flink.remove();
    window.flink.insert(&self.flink);

    window.output = self.output;
    window.swallowed_by = self;
    switch (window.fullscreen) {
        .none, .window => {},
        .output => {
            window.prepare_unfullscreen();
        }
    }

    self.swallowing_border = undefined;
    self.swallowing_border.?.init(self) catch |err| {
        self.swallowing_border = null;
        log.err("<{*}> init custom decoration failed: {}", .{ self, err });
        return;
    };
}


fn unswallow(self: *Self) void {
    if (self.swallowing) |window| {
        defer self.swallowing = null;

        log.debug("<{*}> unswallowing {*}", .{ self, window });

        window.swallowed_by = null;
        window.output = self.output;
        window.tag = self.tag;

        window.link.remove();
        self.link.insert(&window.link);
        window.flink.remove();
        self.flink.insert(&window.flink);
    }

    if (self.swallowing_border) |*border| {
        border.deinit();
        self.swallowing_border = null;
    }
}


fn apply_rule(self: *Self, rule: *const Config.WindowRule) void {
    const context = Context.get();

    if (rule.tag) |tag| self.set_tag(tag);
    if (rule.output) |output_pattern| {
        {
            var it = context.outputs.safeIterator(.forward);
            while (it.next()) |output| {
                if (output_pattern.is_match(output.name)) {
                    self.set_output(output, true);
                    break;
                }
            }
        }
    }
    if (rule.floating) |floating| self.toggle_floating(floating);
    if (rule.dimension) |dimension| self.resize(dimension.width, dimension.height);
    if (rule.decoration) |decoration| self.decoration = decoration;
    if (rule.is_terminal) |is_terminal| self.is_terminal = is_terminal;
    if (rule.disable_swallow) |disable_swallow| self.disable_swallow = disable_swallow;
    if (rule.scroller_mfact) |scroller_mfact| self.scroller_mfact = scroller_mfact;
    if (rule.attach_mode) |mode| {
        self.link.remove(); self.link.init();
        self.flink.remove(); self.flink.init();
        context.attach_window(self, mode);
        context.focus(self, true);
    }
}


fn rwm_window_listener(rwm_window: *river.WindowV1, event: river.WindowV1.Event, window: *Self) void {
    std.debug.assert(rwm_window == window.rwm_window);

    switch (event) {
        .app_id => |data| {
            const app_id = data.app_id orelse return;

            log.debug("<{*}> app_id: {s}", .{ window, app_id });

            window.set_appid(mem.span(app_id));
        },
        .title => |data| {
            const title = data.title orelse return;

            log.debug("<{*}> title: {s}", .{ window, title });

            window.set_title(mem.span(title));
        },
        .closed => {
            log.debug("<{*}> closed", .{ window });

            window.destroy();
        },
        .decoration_hint => |data| {
            log.debug("<{*}> decoration hint: {s}", .{ window, @tagName(data.hint) });

            window.decoration_hint = data.hint;
        },
        .dimensions => |data| {
            log.debug("<{*}> dimensions: ({}, {})", .{ window, data.width, data.height });

            if (
                window.geometry_undefined
                or (window.floating and window.fullscreen != .output and !window.maximize)
            ) {
                if (window.output == null) {
                    window.unbound_resize(data.width, data.height);
                } else {
                    window.move(null, null);
                    window.resize(data.width, data.height);
                }
                if (window.geometry_undefined) {
                    window.geometry_undefined = false;
                    window.center();
                }
            }
        },
        .dimensions_hint => |data| {
            log.debug(
                "<{*}> dimensions hint: (-width/+width: {}/{}, -height/+height: {}/{})",
                .{ window, data.min_width, data.max_width, data.min_height, data.max_height },
            );

            window.min_width = @max(window.min_width, data.min_width);
            window.min_height = @max(window.min_height, data.min_height);

            // make small fixed-zise child windows to be floating, for
            // software doesn't use xdg_toplevel.set_parent
            const is_fixed = data.max_width > 0 and data.max_height > 0 and
                             data.max_width == data.min_width and
                             data.max_height == data.min_height;
            const is_small = data.max_width > 0 and data.max_height > 0 and
                             data.max_width < 600 and data.max_height < 400;

            if ((is_fixed or is_small) and !window.floating) {
                log.debug("<{*}> auto-floating fixed/small window ({}x{}-{}x{})",
                    .{ window, data.min_width, data.min_height, data.max_width, data.max_height });

                window.toggle_floating(true);
                window.unbound_resize(0, 0);
                window.geometry_undefined = true;
            }
        },
        .fullscreen_requested => |data| {
            var output: ?*Output = undefined;
            if (data.output) |rwm_output| {
                output = @ptrCast(@alignCast(river.OutputV1.getUserData(rwm_output)));
            } else {
                output = window.output;
            }

            log.debug("<{*}> fullscreen requested: {*}", .{ window, output });

            window.prepare_fullscreen(output);
        },
        .exit_fullscreen_requested => {
            log.debug("<{*}> exit fullscreen requested", .{ window });

            window.prepare_unfullscreen();
        },
        .maximize_requested => {
            log.debug("<{*}> maximize requested", .{ window });

            window.toggle_maximize(true);
        },
        .unmaximize_requested => {
            log.debug("<{*}> unmaximize requested", .{ window });

            window.toggle_maximize(false);
        },
        .minimize_requested => {
            log.debug("<{*}> minimize requested", .{ window });

            window.prepare_minimize();
        },
        .parent => |data| {
            const parent_rwm_window = data.parent orelse return;
            const parent_window: *Self = @ptrCast(@alignCast(
                river.WindowV1.getUserData(parent_rwm_window),
            ));

            log.debug("<{*}> parent: {*} (of {*})", .{ window, parent_rwm_window, parent_window });

            window.parent = parent_window;
        },
        .pointer_move_requested => |data| {
            log.debug("<{*}> pointer move requested: {*}", .{ window, data.seat });

            if (!window.floating and (window.output != null and window.output.?.current_layout() != .float)) return;

            if (data.seat) |rwm_seat| {
                const seat: *Seat = @ptrCast(
                    @alignCast(river.SeatV1.getUserData(rwm_seat))
                );
                window.prepare_move(seat);
            }

        },
        .pointer_resize_requested => |data| {
            log.debug("<{*}> pointer resize requested: {*}", .{ window, data.seat });

            if (!window.floating and (window.output != null and window.output.?.current_layout() != .float)) return;

            if (data.seat) |rwm_seat| {
                const seat: *Seat = @ptrCast(
                    @alignCast(river.SeatV1.getUserData(rwm_seat))
                );
                window.prepare_resize(seat);
            }
        },
        .show_window_menu_requested => |data| {
            log.debug("<{*}> show window menu requested: (x: {}, y: {})", .{ window, data.x, data.y });
        },
        .unreliable_pid => |data| {
            log.debug("<{*}> unreliable pid: {}", .{ window, data.unreliable_pid });

            window.pid = data.unreliable_pid;
        },
        .presentation_hint => |data| {
            log.debug("<{*}> presentation_hint: {s}", .{ window, @tagName(data.hint) });
        },
        .identifier => |data| {
            log.debug("<{*}> identifier: {s}", .{ window, data.identifier });
        }
    }
}
