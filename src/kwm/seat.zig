const Self = @This();

const build_options = @import("build_options");
const std = @import("std");
const fmt = std.fmt;
const mem = std.mem;
const log = std.log.scoped(.seat);

const xkbcommon = @import("xkbcommon");
const Keysym = xkbcommon.Keysym;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Config = @import("config");

const utils = @import("utils.zig");
const types = @import("types.zig");
const binding = @import("binding.zig");
const Output = @import("output.zig");
const Window = @import("window.zig");
const Context = @import("context.zig");
const ShellSurface = @import("shell_surface.zig");


link: wl.list.Link = undefined,

wl_seat: ?*wl.Seat = null,
wl_pointer: ?*wl.Pointer = null,
rwm_seat: *river.SeatV1,
rwm_layer_shell_seat: *river.LayerShellSeatV1,
rwm_xkb_binding_seat: *river.XkbBindingsSeatV1,

mode_buffer: [16]u8 = undefined,
mode: ?[]const u8 = null,
chorded: struct {
    state: enum {
        entering,
        enabled,
        exiting,
        disabled,
    } = .disabled,
    quit_mode: enum {
        once_pressed,
        once_bound_pressed,
        once_unbound_pressed,
    },
} = .{ .state = .disabled, .quit_mode = .once_pressed },
button: types.Button = undefined,
focus_exclusive: bool = false,
previous_focused: union(enum) {
    none,
    window: *Window,
    output: *Output,
} = .none,
pointer_position: struct {
    x: i32, y: i32,
} = undefined,
window_below_pointer: ?*Window = null,
unhandled_actions: std.ArrayList(binding.Action) = undefined,
xkb_bindings: std.StringHashMap(std.ArrayList(*binding.XkbBinding)) = undefined,
pointer_bindings: std.StringHashMap(std.ArrayList(*binding.PointerBinding)) = undefined,


pub fn create(rwm_seat: *river.SeatV1) !*Self {
    const seat = try utils.allocator.create(Self);
    errdefer utils.allocator.destroy(seat);

    defer log.debug("<{*}> created", .{ seat });

    const context = Context.get();

    const rwm_layer_shell_seat = try context.rwm_layer_shell.getSeat(rwm_seat);
    errdefer rwm_layer_shell_seat.destroy();
    const rwm_xkb_binding_seat = try context.rwm_xkb_bindings.getSeat(rwm_seat);

    seat.* = .{
        .rwm_seat = rwm_seat,
        .rwm_layer_shell_seat = rwm_layer_shell_seat,
        .rwm_xkb_binding_seat = rwm_xkb_binding_seat,
        .unhandled_actions = try .initCapacity(utils.allocator, 2),
        .xkb_bindings = .init(utils.allocator),
        .pointer_bindings = .init(utils.allocator),
    };
    seat.link.init();

    seat.refresh_xursor_theme();
    seat.create_bindings();

    rwm_seat.setListener(*Self, rwm_seat_listener, seat);
    rwm_layer_shell_seat.setListener(*Self, rwm_layer_shell_seat_listener, seat);
    rwm_xkb_binding_seat.setListener(*Self, rwm_xkb_binding_seat_listener, seat);

    return seat;
}


pub fn destroy(self: *Self) void {
    defer log.debug("<{*}> destroyed", .{ self });

    self.link.remove();
    if (self.wl_seat) |wl_seat| wl_seat.destroy();
    if (self.wl_pointer) |wl_pointer| wl_pointer.destroy();
    self.rwm_seat.destroy();
    self.rwm_layer_shell_seat.destroy();

    self.clear_bindings();
    self.xkb_bindings.deinit();
    self.pointer_bindings.deinit();

    self.unhandled_actions.deinit(utils.allocator);

    utils.allocator.destroy(self);
}


pub fn toggle_bindings(self: *Self, mode: []const u8, flag: bool) void {
    log.debug("<{*}> toggle binding: (mode: {s}, flag: {})", .{ self, mode, flag });

    if (self.xkb_bindings.get(mode)) |list| {
        for (list.items) |xkb_binding| {
            if (flag) {
                xkb_binding.enable();
            } else {
                xkb_binding.disable();
            }
        }
    }

    if (self.pointer_bindings.get(mode)) |list| {
        for (list.items) |pointer_binding| {
            if (flag) {
                pointer_binding.enable();
            } else {
                pointer_binding.disable();
            }
        }
    }
}


pub inline fn op_start(self: *Self) void {
    log.debug("<{*}> op begin", .{ self });

    self.rwm_seat.opStartPointer();
}


pub inline fn op_end(self: *Self) void {
    log.debug("<{*}> op end", .{ self });

    self.rwm_seat.opEnd();
}


pub fn manage(self: *Self) void {
    defer log.debug("<{*}> managed", .{ self });

    self.handle_actions();

    const context = Context.get();

    if (self.chorded.state != .enabled) {
        if (self.chorded.state == .exiting) {
            log.debug("<{*}> exiting chorded", .{ self });

            // restore mode
            self.toggle_bindings(context.mode, false);
            context.switch_mode(self.mode.?);

            // reset self.mode, sync with context.mode later
            self.mode = null;

            self.chorded.state = .disabled;
        }

        if (self.mode == null or !mem.eql(u8, self.mode.?, context.mode)) {
            self.toggle_bindings(context.mode, true);
            if (self.mode) |mode| self.toggle_bindings(mode, false);

            if (self.chorded.state == .entering) {
                log.debug("<{*}> entering chorded", .{ self });

                self.chorded.state = .enabled;
            } else {
                self.mode = fmt.bufPrint(&self.mode_buffer, "{s}", .{ context.mode }) catch unreachable;
            }
        }
    }

    if (self.chorded.state == .enabled){
        self.rwm_xkb_binding_seat.ensureNextKeyEaten();
    }
}


pub fn try_focus(self: *Self) void {
    log.debug("<{*}> try focus", .{ self });

    if (self.focus_exclusive) return;

    const config = Config.get();
    const context = Context.get();

    if (context.focused_window()) |window| {
        defer self.previous_focused = .{ .window = window };

        switch (config.cursor_wrap) {
            .none => {},
            .on_output_changed => blk: {
                switch (self.previous_focused) {
                    .none => {},
                    .window => |w| if (w.output == window.output) break :blk,
                    .output => |o| if (o == window.output) break :blk,
                }

                if (window.output) |output| {
                    self.wrap_cursor(.{ .output = output });
                }
            },
            .on_focus_changed => blk: {
                switch (self.previous_focused) {
                    .none, .output => {},
                    .window => |w| if (w == window) break :blk,
                }

                self.wrap_cursor(.{ .window = window });
            }
        }

        self.rwm_seat.focusWindow(window.rwm_window);
    } else {
        if (context.current_output) |output| {
            defer self.previous_focused = .{ .output = output };

            if (config.cursor_wrap != .none) blk: {
                switch (self.previous_focused) {
                    .none => {},
                    .window => |w| if (w.output == output) break :blk,
                    .output => |o| if (o == output) break :blk,
                }

                self.wrap_cursor(.{ .output = output });
            }
        } else {
            self.previous_focused = .none;
        }

        self.rwm_seat.clearFocus();
    }
}


pub fn append_action(self: *Self, action: binding.Action) void {
    log.debug("<{*}> append action: {s}", .{ self, @tagName(action) });

    self.unhandled_actions.append(utils.allocator, action) catch |err| {
        log.err("<{*}> append action failed: {}", .{ self, err });
        return;
    };
}


pub fn refresh_xursor_theme(self: *Self) void {
    log.debug("<{*}> refresh xcursor theme", .{ self });

    const config = Config.get();

    if (config.xcursor_theme) |xcursor_theme| {
        log.debug("<{*}> set xcursor theme: (name: {s}, size: {})", .{ self, xcursor_theme.name, xcursor_theme.size });

        const name = utils.allocator.dupeZ(u8, xcursor_theme.name) catch |err| {
            log.err("<{*}> dupeZ failed while set xcursor theme: {}", .{ self, err });
            return;
        };
        defer utils.allocator.free(name);

        self.rwm_seat.setXcursorTheme(name, xcursor_theme.size);
    }
}


pub fn create_bindings(self: *Self) void {
    log.debug("<{*}> create bindings", .{ self });

    const config = Config.get();

    for (config.bindings.key) |key_binding| {
        if (!self.xkb_bindings.contains(key_binding.mode)) {
            self.xkb_bindings.put(key_binding.mode, .empty) catch |err| {
                log.err("<{*}> put a new xkb binding list failed: {}", .{ self, err });
                continue;
            };
        }
        const list = self.xkb_bindings.getPtr(key_binding.mode).?;

        list.append(
            utils.allocator,
            binding.XkbBinding.create(
                self,
                keysym_from_name(key_binding.keysym) orelse {
                    log.warn("ambiguous keysym name '{s}'", .{ key_binding.keysym });
                    continue;
                },
                key_binding.modifiers,
                key_binding.event,
            ) catch |err| {
                log.err("<{*}> create xkb binding failed: {}", .{ self, err });
                continue;
            },
        ) catch |err| {
            log.err("<{*}> append xkb binding failed: {}", .{ self, err });
            continue;
        };

        log.debug(
            "<{*}> append key binding: (mode: {s}, keysym: {s}, modifiers: (shift: {}, ctrl: {}, mod1: {}, mod3: {}, mod4: {}, mod5: {}), event: {any})",
            .{
                self,
                key_binding.mode,
                key_binding.keysym,
                key_binding.modifiers.shift,
                key_binding.modifiers.ctrl,
                key_binding.modifiers.mod1,
                key_binding.modifiers.mod3,
                key_binding.modifiers.mod4,
                key_binding.modifiers.mod5,
                key_binding.event,
            },
        );
    }

    for (config.bindings.pointer) |pointer_binding| {
        if (!self.pointer_bindings.contains(pointer_binding.mode)) {
            self.pointer_bindings.put(pointer_binding.mode, .empty) catch |err| {
                log.err("<{*}> put a new pointer binding list failed: {}", .{ self, err });
                continue;
            };
        }
        const list = self.pointer_bindings.getPtr(pointer_binding.mode).?;

        list.append(
            utils.allocator,
            binding.PointerBinding.create(
                self,
                @intFromEnum(pointer_binding.button),
                pointer_binding.modifiers,
                pointer_binding.event,
            ) catch |err| {
                log.err("<{*}> create pointer binding failed: {}", .{ self, err });
                continue;
            },
        ) catch |err| {
            log.err("<{*}> append pointer binding failed: {}", .{ self, err });
            continue;
        };

        log.debug(
            "<{*}> append pointer binding: (mode: {s}, button: {s}, modifiers: (shift: {}, ctrl: {}, mod1: {}, mod3: {}, mod4: {}, mod5: {}), event: {any})",
            .{
                self,
                pointer_binding.mode,
                @tagName(pointer_binding.button),
                pointer_binding.modifiers.shift,
                pointer_binding.modifiers.ctrl,
                pointer_binding.modifiers.mod1,
                pointer_binding.modifiers.mod3,
                pointer_binding.modifiers.mod4,
                pointer_binding.modifiers.mod5,
                pointer_binding.event,
            },
        );
    }
}


pub fn clear_bindings(self: *Self) void {
    log.debug("<{*}> clear bindings", .{ self });

    {
        var it = self.xkb_bindings.iterator();
        while (it.next()) |pair| {
            for (pair.value_ptr.items) |xkb_binding| {
                xkb_binding.destroy();
            }
            pair.value_ptr.deinit(utils.allocator);
        }
        self.xkb_bindings.clearRetainingCapacity();
    }

    {
        var it = self.pointer_bindings.iterator();
        while (it.next()) |pair| {
            for (pair.value_ptr.items) |pointer_binding| {
                pointer_binding.destroy();
            }
            pair.value_ptr.deinit(utils.allocator);
        }
        self.pointer_bindings.clearRetainingCapacity();
    }
}


fn wrap_cursor(self: *Self, dest: union(enum) { window: *Window, output: *Output }) void {
    switch (dest) {
        .window => |window| log.debug("<{*}> wrap cursor to {*}", .{ self, window }),
        .output => |output| log.debug("<{*}> wrap cursor to {*}", .{ self, output }),
    }

    const x, const y = switch (dest) {
        .window => |window| blk: {
            if (window.output) |output| {
                const x = window.x + @divFloor(window.width, 2);
                const y = window.y + @divFloor(window.height, 2);
                break :blk .{
                    output.exclusive_x() + @max(0, @min(output.exclusive_width(), x)),
                    output.exclusive_y() + @max(0, @min(output.exclusive_height(), y)),
                };
            } else return;
        },
        .output => |output| .{
            output.exclusive_x() + @divFloor(output.exclusive_width(), 2),
            output.exclusive_y() + @divFloor(output.exclusive_height(), 2),
        },
    };
    self.rwm_seat.pointerWarp(x, y);
}


fn handle_actions(self: *Self) void {
    defer self.unhandled_actions.clearRetainingCapacity();

    const config = Config.get();
    const context = Context.get();

    var i: usize = 0;
    while (i < self.unhandled_actions.items.len) : (i += 1) {
        const action = self.unhandled_actions.items[i];

        switch (action) {
            .quit => |data| {
                context.quit(data.exit_session);
            },
            .close => {
                if (context.focused_window()) |window| {
                    window.prepare_close();
                }
            },
            .spawn => |data| {
                _ = context.spawn(data.argv);
            },
            .spawn_shell => |data| {
                _ = context.spawn_shell(data.cmd);
            },
            .move => |data| {
                if (context.focused_window()) |window| {
                    window.ensure_floating();
                    switch (data.step) {
                        .horizontal => |offset| window.move(window.x+offset, null),
                        .vertical => |offset| window.move(null, window.y+offset),
                    }
                }
            },
            .resize => |data| {
                if (context.focused_window()) |window| {
                    window.ensure_floating();
                    switch (data.step) {
                        .horizontal => |offset| {
                            window.move(window.x-@divFloor(offset, 2), null);
                            window.resize(window.width+offset, null);
                        },
                        .vertical => |offset| {
                            window.move(null, window.y-@divFloor(offset, 2));
                            window.resize(null, window.height+offset);
                        }
                    }
                }
            },
            .pointer_move => {
                if (self.window_below_pointer) |window| {
                    self.window_interaction(window);
                    window.prepare_move(self);
                }
            },
            .pointer_resize => {
                if (self.window_below_pointer) |window| {
                    self.window_interaction(window);
                    window.prepare_resize(self);
                }
            },
            .snap => |data| {
                if (context.focused_window()) |window| {
                    window.ensure_floating();
                    window.snap_to(data.edge);
                }
            },
            .switch_mode => |data| {
                if (mem.eql(u8, data.mode, context.mode)) continue;

                context.switch_mode(data.mode);

                if (data.auto_quit != .disabled) {
                    switch (self.chorded.state) {
                        .entering => log.warn("<{*}> try repeatly entering chorded", .{ self }),
                        .enabled => log.warn("<{*}> try recursively entering chorded", .{ self }),
                        .exiting => unreachable,
                        .disabled => {
                            self.chorded.state = .entering;
                            self.chorded.quit_mode = switch (data.auto_quit) {
                                .disabled => unreachable,
                                .once_pressed => .once_pressed,
                                .once_bound_pressed => .once_bound_pressed,
                                .once_unbound_pressed => .once_unbound_pressed,
                            };
                        }
                    }
                }
            },
            .focus_iter => |data| {
                context.focus_iter(data.direction, data.skip_floating);
            },
            .focus_output_iter => |data| {
                context.focus_output_iter(data.direction);
            },
            .send_to_output => |data| {
                if (context.focused_window()) |window| {
                    context.send_to_output(window, data.direction);
                }
            },
            .swap => |data| {
                context.swap(data.direction);
            },
            .toggle_fullscreen => |data| {
                context.toggle_fullscreen(data.in_window);
            },
            .set_output_tag => |data| {
                if (context.current_output) |output| {
                    output.set_tag(data.tag);
                }
            },
            .set_window_tag => |data| {
                if (context.focused_window()) |window| {
                    window.set_tag(data.tag);
                }
            },
            .toggle_output_tag => |data| {
                if (context.current_output) |output| {
                    output.toggle_tag(data.mask);
                }
            },
            .toggle_window_tag => |data| {
                if (context.focused_window()) |window| {
                    window.toggle_tag(data.mask);
                }
            },
            .switch_to_previous_tag => {
                if (context.current_output) |output| {
                    output.switch_to_previous_tag();
                }
            },
            .shift_tag => |data| {
                if (context.current_output) |output| {
                    output.shift_tag(data.direction);
                }
            },
            .toggle_floating => {
                if (context.focused_window()) |window| {
                    window.toggle_floating();
                }
            },
            .toggle_sticky => {
                if (context.focused_window()) |window| {
                    window.toggle_sticky();
                }
            },
            .toggle_swallow => {
                if (context.focused_window()) |window| {
                    window.toggle_swallow();
                }
            },
            .zoom => |data| {
                if (context.focused_window()) |window| {
                    if (window.floating) continue;

                    if (window.output) |output| {
                        switch (output.current_layout()) {
                            .tile, .deck => {
                                if (!data.swap) {
                                    context.focus(window);
                                    context.shift_to_head(window);
                                    continue;
                                }

                                var master = output.master_window() orelse continue;
                                var new_master = if (window != master) window
                                    else context.focused_before(window, true) orelse continue;

                                // ensure the old master immediately behind the new master in focus_stack
                                context.focus(master);
                                context.focus(new_master);

                                // swap old master with new master
                                master.link.swapWith(&new_master.link);
                            },
                            .scroller => window.scroller_x = .center,
                            else => {}
                        }
                    }
                }
            },
            .focus_master_return => {
                if (context.focused_window()) |window| {
                    if (window.floating) continue;
                    if (window.output) |output| {
                        switch (output.current_layout()) {
                            .tile, .deck => {
                                const master = output.master_window() orelse continue;
                                context.focus(
                                    if (window != master) master
                                    else context.focused_before(window, true) orelse continue,
                                );
                            },
                            else => {}
                        }
                    }
                }
            },
            .switch_layout => |data| {
                if (context.current_output) |output| {
                    output.set_current_layout(data.layout);
                    self.previous_focused = .none;
                }
            },
            .switch_to_previous_layout => {
                if (context.current_output) |output| {
                    output.switch_to_previous_layout();
                }
            },
            .toggle_bar => {
                if (comptime build_options.bar_enabled) {
                    if (context.current_output) |output| {
                        output.bar.toggle();
                    }
                } else {
                    log.warn("`toggle_bar` while bar disabled", .{});
                }
            },

            .modify_nmaster => |data| {
                if (context.current_output) |output| {
                    if (output.current_layout() == .tile) {
                        switch (data.change) {
                            .increase => config.layout.tile.nmaster += 1,
                            .decrease => config.layout.tile.nmaster = @max(1, config.layout.tile.nmaster-1),
                        }
                    }
                }
            },
            .modify_mfact => |data| {
                if (context.current_output) |output| {
                    switch (output.current_layout()) {
                        .tile => config.layout.tile.mfact = @min(1, @max(0, config.layout.tile.mfact+data.step)),
                        .scroller => if (context.focus_top_in(output, false)) |window| {
                            window.scroller_mfact = @min(1, @max(0, window.scroller_mfact+data.step));
                        },
                        else => {},
                    }
                }
            },
            .modify_gap => |data| {
                if (context.current_output) |output| {
                    switch (output.current_layout()) {
                        .tile => config.layout.tile.inner_gap = @max(config.border.width*2, config.layout.tile.inner_gap+data.step),
                        .grid => config.layout.grid.inner_gap = @max(config.border.width*2, config.layout.grid.inner_gap+data.step),
                        .monocle => config.layout.monocle.gap = @max(config.border.width*2, config.layout.monocle.gap+data.step),
                        .deck => config.layout.deck.inner_gap = @max(config.border.width*2, config.layout.deck.inner_gap+data.step),
                        .scroller => config.layout.scroller.inner_gap = @max(config.border.width*2, config.layout.scroller.inner_gap+data.step),
                        .float => {},
                    }
                }
            },
            .modify_master_location => |data| {
                if (context.current_output) |output| {
                    switch (output.current_layout()) {
                        .tile => config.layout.tile.master_location = data.location,
                        .deck => config.layout.deck.master_location = data.location,
                        else => {},
                    }
                }
            },
            .toggle_grid_direction => {
                if (context.current_output) |output| {
                    if (output.current_layout() == .grid) {
                        config.layout.grid.direction = switch (config.layout.grid.direction) {
                            .horizontal => .vertical,
                            .vertical => .horizontal,
                        };
                    }
                }
            },
            .toggle_auto_swallow => {
                config.auto_swallow = !config.auto_swallow;
            },

            .reload_config => {
                context.reload_config();
            },

            .group => |group| {
                for (group.actions) |nested_action| {
                    self.append_action(nested_action);
                }
            },
        }
    }
}


fn window_interaction(self: *Self, window: *Window) void {
    log.debug("<{*}> interaction with window {*}", .{ self, window });

    const context = Context.get();

    // avoid cursor wrapping
    self.previous_focused = .{ .window = window };

    context.focus(window);
}


fn rwm_seat_listener(rwm_seat: *river.SeatV1, event: river.SeatV1.Event, seat: *Self) void {
    std.debug.assert(rwm_seat == seat.rwm_seat);

    const config = Config.get();
    const context = Context.get();

    switch (event) {
        .op_delta => |data| {
            log.debug("<{*}> op delta: (dx: {}, dy: {})", .{ seat, data.dx, data.dy });

            const window = context.focused_window().?;
            switch (window.operator) {
                .none => unreachable,
                .move => |op_data| {
                    if (op_data.seat == seat) {
                        window.move(
                            op_data.start_x+data.dx,
                            op_data.start_y+data.dy,
                        );
                    }
                },
                .resize => |op_data| {
                    if (op_data.seat == seat) {
                        window.resize(
                            op_data.start_width+data.dx,
                            op_data.start_height+data.dy,
                        );
                    }
                }
            }
        },
        .op_release => {
            log.debug("<{*}> op release", .{ seat });

            if (context.focused_window()) |window| {
                switch (window.operator) {
                    .none => {},
                    .move => |data| {
                        if (data.seat == seat) {
                            window.prepare_move(null);
                        }
                    },
                    .resize => |data| {
                        if (data.seat == seat) {
                            window.prepare_resize(null);
                        }
                    }
                }
            } else {
                log.debug("no window focused", .{});
            }
        },
        .pointer_enter => |data| {
            log.debug("<{*}> pointer enter: {*}", .{ seat, data.window });

            const rwm_window = data.window orelse return;

            const window: *Window = @ptrCast(
                @alignCast(river.WindowV1.getUserData(rwm_window))
            );

            std.debug.assert(seat.window_below_pointer == null);

            seat.window_below_pointer = window;

            if (config.sloppy_focus) {
                // avoid cursor wrapping
                seat.previous_focused = .{ .window = window };

                context.focus(window);
            }
        },
        .pointer_leave => {
            log.debug("<{*}> pointer leave", .{ seat });

            std.debug.assert(seat.window_below_pointer != null);

            seat.window_below_pointer = null;
        },
        .pointer_position => |data| {
            log.debug("<{*}> pointer position: (x: {}, y: {})", .{ seat, data.x, data.y });

            seat.pointer_position.x = data.x;
            seat.pointer_position.y = data.y;
        },
        .removed => {
            log.debug("<{*}> removed", .{ seat });

            context.prepare_remove_seat(seat);

            seat.destroy();
        },
        .shell_surface_interaction => |data| {
            log.debug("<{*}> shell surface interaction: {*}", .{ seat, data.shell_surface });

            const shell_surface: *ShellSurface = @ptrCast(
                @alignCast((data.shell_surface orelse return).getUserData())
            );

            log.debug("<{*}> interaction with {*}", .{ seat, shell_surface });

            switch (shell_surface.type) {
                .bar => |bar| if (comptime build_options.bar_enabled) {
                    log.debug("<{*}> interaction with {*}", .{ seat, bar });

                    // avoid cursor wrapping
                    seat.previous_focused = .{ .output = bar.output };

                    context.set_current_output(bar.output);

                    bar.handle_click(seat);
                } else unreachable,
            }
        },
        .window_interaction => |data| {
            log.debug("<{*}> window interaction: {*}", .{ seat, data.window });

            const window: *Window = @ptrCast(
                @alignCast(river.WindowV1.getUserData(data.window.?))
            );

            seat.window_interaction(window);
        },
        .wl_seat => |data| {
            log.debug("<{*}> wl_seat: {}", .{ seat, data.name });

            const wl_seat = context.wl_registry.bind(data.name, wl.Seat, 7) catch return;
            seat.wl_seat = wl_seat;
            wl_seat.setListener(*Self, wl_seat_listener, seat);
        },
    }
}


fn rwm_layer_shell_seat_listener(rwm_layer_shell_seat: *river.LayerShellSeatV1, event: river.LayerShellSeatV1.Event, seat: *Self) void {
    std.debug.assert(rwm_layer_shell_seat == seat.rwm_layer_shell_seat);

    switch (event) {
        .focus_exclusive => {
            log.debug("<{*}> focus exclusive", .{ seat });

            seat.focus_exclusive = true;
        },
        .focus_non_exclusive => {
            log.debug("<{*}> focus non exclusive", .{ seat });
        },
        .focus_none => {
            log.debug("<{*}> focus none", .{ seat });

            seat.focus_exclusive = false;
        }
    }
}


fn rwm_xkb_binding_seat_listener(rwm_xkb_binding_seat: *river.XkbBindingsSeatV1, event: river.XkbBindingsSeatV1.Event, seat: *Self) void {
    std.debug.assert(rwm_xkb_binding_seat == seat.rwm_xkb_binding_seat);

    switch (event) {
        .ate_unbound_key => {
            log.debug("<{*}> ate_unbound_key", .{ seat });

            std.debug.assert(seat.chorded.state == .enabled);

            switch (seat.chorded.quit_mode) {
                .once_pressed, .once_unbound_pressed => seat.chorded.state = .exiting,
                .once_bound_pressed => {}
            }
        }
    }
}


fn wl_seat_listener(wl_seat: *wl.Seat, event: wl.Seat.Event, seat: *Self) void {
    std.debug.assert(wl_seat == seat.wl_seat);

    switch (event) {
        .name => |data| {
            log.debug("<{*}> name: {s}", .{ seat, data.name });
        },
        .capabilities => |data| {
            if (data.capabilities.pointer) {
                const wl_pointer = wl_seat.getPointer() catch return;
                seat.wl_pointer = wl_pointer;
                wl_pointer.setListener(*Self, wl_pointer_listener, seat);
            }
        }
    }
}


fn wl_pointer_listener(wl_pointer: *wl.Pointer, event: wl.Pointer.Event, seat: *Self) void {
    std.debug.assert(wl_pointer == seat.wl_pointer);

    switch (event) {
        .button => |data| {
            log.debug("<{*}> button: {}, state: {s}", .{ seat, data.button, @tagName(data.state) });

            seat.button = @enumFromInt(data.button);
        },
        else => {}
    }
}


// https://codeberg.org/river/river-classic/src/commit/f0908e2d117ede7114fa85c65622b055c565c250/river/command/map.zig#L254
fn keysym_from_name(name: []const u8) ?u32 {
    const n = utils.allocator.dupeZ(u8, name) catch |err| {
        log.err("dupeZ failed while call keysym_from_name: {}", .{ err });
        return null;
    };
    defer utils.allocator.free(n);

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
