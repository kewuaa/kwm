const Self = @This();

const build_options = @import("build_options");
const std = @import("std");
const fs = std.fs;
const fmt = std.fmt;
const mem = std.mem;
const log = std.log.scoped(.seat);

const xkbcommon = @import("xkbcommon");
const Keysym = xkbcommon.Keysym;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const river = wayland.client.river;

const config = @import("config");

const types = @import("types.zig");
const binding = @import("binding.zig");
const Output = @import("output.zig");
const Window = @import("window.zig");
const Context = @import("context.zig");
const ShellSurface = @import("shell_surface.zig");

const ctx = Context.get();


link: wl.list.Link = undefined,

wl_seat: ?*wl.Seat = null,
wl_pointer: ?*wl.Pointer = null,
cursor_shape_device: ?*wp.CursorShapeDeviceV1 = null,
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
    x: i32 = 0,
    y: i32 = 0,
    new: bool = false,
} = .{},
window_below_pointer: struct {
    window: ?*Window = null,
    new: bool = false,
} = .{},
has_pointer_interaction: bool = false,
unhandled_actions: std.ArrayList(binding.Action) = undefined,
xkb_bindings: std.StringHashMap(std.ArrayList(*binding.XkbBinding)) = undefined,
pointer_bindings: std.StringHashMap(std.ArrayList(*binding.PointerBinding)) = undefined,


pub fn create(rwm_seat: *river.SeatV1) !*Self {
    const seat = try ctx.gpa.create(Self);
    errdefer ctx.gpa.destroy(seat);

    defer log.debug("<{*}> created", .{ seat });

    const rwm_layer_shell_seat = try ctx.rwm_layer_shell.getSeat(rwm_seat);
    errdefer rwm_layer_shell_seat.destroy();
    const rwm_xkb_binding_seat = try ctx.rwm_xkb_bindings.getSeat(rwm_seat);

    seat.* = .{
        .rwm_seat = rwm_seat,
        .rwm_layer_shell_seat = rwm_layer_shell_seat,
        .rwm_xkb_binding_seat = rwm_xkb_binding_seat,
        .unhandled_actions = try .initCapacity(ctx.gpa, 2),
        .xkb_bindings = .init(ctx.gpa),
        .pointer_bindings = .init(ctx.gpa),
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
    if (self.cursor_shape_device) |cursor_shape_device| cursor_shape_device.destroy();
    self.rwm_seat.destroy();
    self.rwm_layer_shell_seat.destroy();

    self.clear_bindings();
    self.xkb_bindings.deinit();
    self.pointer_bindings.deinit();

    self.unhandled_actions.deinit(ctx.gpa);

    ctx.gpa.destroy(self);
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


pub fn op_start(self: *Self, @"type": union(enum) { move, resize: Window.ResizeDirection }) void {
    log.debug("<{*}> op begin", .{ self });

    if (self.cursor_shape_device) |cursor_shape_device| {
        cursor_shape_device.setShape(0, switch (@"type") {
            .move => .move,
            .resize => |direction|
                if (direction.horizontal == null)
                    switch (direction.vertical.?) {
                        .forward => .s_resize,
                        .reverse => .n_resize,
                    }
                else if (direction.vertical == null)
                    switch (direction.horizontal.?) {
                        .forward => .e_resize,
                        .reverse => .w_resize,
                    }
                else
                    switch (direction.vertical.?) {
                        .forward => switch (direction.horizontal.?) {
                            .forward => .se_resize,
                            .reverse => .sw_resize,
                        },
                        .reverse => switch (direction.horizontal.?) {
                            .forward => .ne_resize,
                            .reverse => .nw_resize,
                        },
                    }
        });
    }

    self.rwm_seat.opStartPointer();
}


pub fn op_end(self: *Self) void {
    log.debug("<{*}> op end", .{ self });

    if (self.cursor_shape_device) |cursor_shape_device| {
        cursor_shape_device.setShape(0, .default);
    }

    self.rwm_seat.opEnd();
}


pub fn manage(self: *Self) void {
    defer log.debug("<{*}> managed", .{ self });

    defer self.pointer_position.new = false;

    // TODO: https://codeberg.org/river/river/issues/1317
    // if ctx.cfg.sloppy_focus is true, once pointer activity, check window_below_pointer.new,
    // if true, focus the window below pointer and reset window_below_pointer.new to false
    if (ctx.cfg.sloppy_focus and self.window_below_pointer.new and self.pointer_position.new) {
        defer self.window_below_pointer.new = false;

        const window = self.window_below_pointer.window.?;

        ctx.focus(window, window.managed_by_layout());
    }

    self.handle_actions();

    if (self.chorded.state != .enabled) {
        if (self.chorded.state == .exiting) {
            log.debug("<{*}> exiting chorded", .{ self });

            // restore mode
            self.toggle_bindings(ctx.mode, false);
            ctx.switch_mode(self.mode.?);

            // reset self.mode, sync with context.mode later
            self.mode = null;

            self.chorded.state = .disabled;
        }

        if (self.mode == null or !mem.eql(u8, self.mode.?, ctx.mode)) {
            self.toggle_bindings(ctx.mode, true);
            if (self.mode) |mode| self.toggle_bindings(mode, false);

            if (self.chorded.state == .entering) {
                log.debug("<{*}> entering chorded", .{ self });

                self.chorded.state = .enabled;
            } else {
                self.mode = fmt.bufPrint(&self.mode_buffer, "{s}", .{ ctx.mode }) catch unreachable;
            }
        }
    }

    if (self.chorded.state == .enabled and self.chorded.quit_mode != .once_bound_pressed){
        self.rwm_xkb_binding_seat.ensureNextKeyEaten();
    }
}


pub fn try_focus(self: *Self) void {
    log.debug("<{*}> try focus", .{ self });

    if (self.focus_exclusive) return;

    defer self.has_pointer_interaction = false;

    if (ctx.focused_window()) |window| focus_window: {
        if (window.geometry_undefined) break :focus_window;

        defer self.previous_focused = .{ .window = window };

        if (!self.has_pointer_interaction) switch (ctx.cfg.cursor_warp) {
            .none => {},
            .on_output_changed => blk: {
                switch (self.previous_focused) {
                    .none => {},
                    .window => |w| if (w.output == window.output) break :blk,
                    .output => |o| if (o == window.output) break :blk,
                }

                if (window.output) |output| {
                    self.warp_cursor(.{ .output = output });
                }
            },
            .on_focus_changed => blk: {
                switch (self.previous_focused) {
                    .none, .output => {},
                    .window => |w| if (w == window) break :blk,
                }

                self.warp_cursor(.{ .window = window });
            }
        };

        // if there are any window fullscreen on output, focus it first
        const fullscreen_window =
            if (window.output) |output|
                output.fullscreen_window()
            else null;
        self.rwm_seat.focusWindow((fullscreen_window orelse window).rwm_window);
    } else {
        if (ctx.current_output) |output| {
            defer self.previous_focused = .{ .output = output };

            if (!self.has_pointer_interaction and ctx.cfg.cursor_warp != .none) blk: {
                switch (self.previous_focused) {
                    .none => {},
                    .window => |w| if (w.output == output) break :blk,
                    .output => |o| if (o == output) break :blk,
                }

                self.warp_cursor(.{ .output = output });
            }
        } else {
            self.previous_focused = .none;
        }

        self.rwm_seat.clearFocus();
    }
}


pub fn append_action(self: *Self, action: binding.Action) void {
    log.debug("<{*}> append action: {s}", .{ self, @tagName(action) });

    self.unhandled_actions.append(ctx.gpa, action) catch |err| {
        log.err("<{*}> append action failed: {}", .{ self, err });
        return;
    };
}


pub fn refresh_xursor_theme(self: *Self) void {
    log.debug("<{*}> refresh xcursor theme", .{ self });

    if (ctx.cfg.xcursor_theme) |xcursor_theme| {
        log.debug(
            "<{*}> set xcursor theme: (name: {s}, size: {})",
            .{ self, xcursor_theme.name, xcursor_theme.size }
        );

        self.rwm_seat.setXcursorTheme(xcursor_theme.name, xcursor_theme.size);
    }
}


pub fn create_bindings(self: *Self) void {
    log.debug("<{*}> create bindings", .{ self });

    for (ctx.cfg.bindings.key) |key_binding| {
        const mode = key_binding.mode orelse config.default_mode;
        if (!self.xkb_bindings.contains(mode)) {
            self.xkb_bindings.put(mode, .empty) catch |err| {
                log.err("<{*}> put a new xkb binding list failed: {}", .{ self, err });
                continue;
            };
        }
        const list = self.xkb_bindings.getPtr(mode).?;

        list.append(
            ctx.gpa,
            binding.XkbBinding.create(
                self,
                keysym_from_name(key_binding.keysym) orelse {
                    log.warn("ambiguous keysym name '{s}'", .{ key_binding.keysym });
                    continue;
                },
                to_river_modifiers(key_binding.modifiers),
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
                mode,
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

    for (ctx.cfg.bindings.pointer) |pointer_binding| {
        const mode = pointer_binding.mode orelse config.default_mode;
        if (!self.pointer_bindings.contains(mode)) {
            self.pointer_bindings.put(mode, .empty) catch |err| {
                log.err("<{*}> put a new pointer binding list failed: {}", .{ self, err });
                continue;
            };
        }
        const list = self.pointer_bindings.getPtr(mode).?;

        list.append(
            ctx.gpa,
            binding.PointerBinding.create(
                self,
                @intFromEnum(pointer_binding.button),
                to_river_modifiers(pointer_binding.modifiers),
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
                mode,
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
            pair.value_ptr.deinit(ctx.gpa);
        }
        self.xkb_bindings.clearRetainingCapacity();
    }

    {
        var it = self.pointer_bindings.iterator();
        while (it.next()) |pair| {
            for (pair.value_ptr.items) |pointer_binding| {
                pointer_binding.destroy();
            }
            pair.value_ptr.deinit(ctx.gpa);
        }
        self.pointer_bindings.clearRetainingCapacity();
    }
}


fn warp_cursor(self: *Self, dest: union(enum) { window: *Window, output: *Output }) void {
    switch (dest) {
        .window => |window| log.debug("<{*}> warp cursor to {*}", .{ self, window }),
        .output => |output| log.debug("<{*}> warp cursor to {*}", .{ self, output }),
    }

    const x, const y = switch (dest) {
        .window => |window| blk: {
            if (window.output) |output| {
                const x = window.x + @divFloor(window.width, 2);
                const y = window.y + @divFloor(window.height, 2);
                const abs_x = output.exclusive_x() + @max(0, @min(output.exclusive_width(), x));
                const abs_y = output.exclusive_y() + @max(0, @min(output.exclusive_height(), y));
                const pointer_x = self.pointer_position.x;
                const pointer_y = self.pointer_position.y;
                // if pointer already within the window, skip
                if (
                    @abs(pointer_x - abs_x) < @divFloor(window.width, 2) + ctx.cfg.border.width + 1
                    and
                    @abs(pointer_y - abs_y) < @divFloor(window.height, 2) + ctx.cfg.border.width + 1
                ) {
                    return;
                }
                break :blk .{ abs_x, abs_y };
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

    var i: usize = 0;
    while (i < self.unhandled_actions.items.len) : (i += 1) {
        const action = self.unhandled_actions.items[i];

        switch (action) {
            .quit => |data| {
                if (data.hook) |argv| ctx.register_quit_hook(argv, data.exit_session)
                else ctx.quit(data.exit_session);
            },
            .close => {
                if (ctx.focused_window()) |window| {
                    window.prepare_close();
                }
            },
            .spawn => |data| {
                ctx.spawn(data.argv);
            },
            .spawn_shell => |data| {
                ctx.spawn_shell(data.cmd);
            },
            .move => |data| {
                if (ctx.focused_window()) |window| {
                    window.ensure_floating();
                    switch (data.step) {
                        .horizontal => |offset| window.move(window.x+offset, null),
                        .vertical => |offset| window.move(null, window.y+offset),
                    }
                }
            },
            .resize => |data| {
                if (ctx.focused_window()) |window| {
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
                if (self.window_below_pointer.window) |window| {
                    self.window_interaction(window);
                    window.ensure_floating();
                    window.prepare_move(.{ .start = .{ .seat = self } });
                }
            },
            .pointer_resize => {
                if (self.window_below_pointer.window) |window| {
                    self.window_interaction(window);
                    window.ensure_floating();
                    window.prepare_resize(.{
                        .start = .{
                            .seat = self,
                            .direction = .{
                                .horizontal = .forward,
                                .vertical = .forward
                            }
                        }
                    });
                }
            },
            .snap => |data| {
                if (ctx.focused_window()) |window| {
                    window.ensure_floating();
                    window.snap_to(data.edge);
                }
            },
            .switch_mode => |data| {
                if (data.auto_quit != .disabled) {
                    self.chorded.state = switch (self.chorded.state) {
                        .entering => {
                            log.warn("<{*}> try repeatly entering chorded", .{ self });
                            continue;
                        },
                        .enabled => {
                            log.warn("<{*}> try recursively entering chorded", .{ self });
                            continue;
                        },
                        .exiting => blk: {
                            if (!mem.eql(u8, data.mode, ctx.mode)) {
                                self.toggle_bindings(ctx.mode, false);
                                self.toggle_bindings(data.mode, true);
                            }
                            break :blk .enabled;
                        },
                        .disabled => .entering,
                    };
                    self.chorded.quit_mode = switch (data.auto_quit) {
                        .disabled => unreachable,
                        inline else => |mode| @field(
                            @TypeOf(self.chorded.quit_mode),
                            @tagName(mode)
                        ),
                    };

                    ctx.switch_mode(data.mode);
                } else if (self.chorded.state == .disabled) {
                    ctx.switch_mode(data.mode);
                } else {
                    self.mode = fmt.bufPrint(&self.mode_buffer, "{s}", .{ data.mode }) catch unreachable;
                }
            },
            .focus_iter => |data| {
                ctx.focus_iter(data.direction, data.skip);
            },
            .focus_output_iter => |data| {
                ctx.focus_output_iter(data.direction);
            },
            .send_to_output => |data| {
                if (ctx.focused_window()) |window| {
                    ctx.send_to_output(window, data.direction);
                }
            },
            .swap => |data| {
                ctx.swap(data.direction);
            },
            .toggle_maximize => {
                if (ctx.focused_window()) |window| {
                    window.toggle_maximize(null);
                }
            },
            .toggle_fullscreen => |data| {
                ctx.toggle_fullscreen(data.in_window);
            },
            .rotate_outputs => |data| {
                context.rotate_outputs(data.direction);
            },
            .set_output_tag => |data| {
                if (ctx.current_output) |output| {
                    output.set_tag(data.tag.of(.{ .output = output }));
                }
            },
            .set_window_tag => |data| {
                if (ctx.focused_window()) |window| {
                    const new_tag = data.tag.of(.{ .window = window });
                    window.set_tag(new_tag);
                    if (data.focus_follow) {
                        if (window.output) |output| {
                            output.set_tag(new_tag);
                        }
                    }
                }
            },
            .toggle_output_tag => |data| {
                if (ctx.current_output) |output| {
                    output.toggle_tag(data.mask);
                }
            },
            .toggle_window_tag => |data| {
                if (ctx.focused_window()) |window| {
                    window.toggle_tag(data.mask);
                }
            },
            .switch_to_previous_tag => {
                if (ctx.current_output) |output| {
                    output.switch_to_previous_tag();
                }
            },
            .toggle_floating => {
                if (ctx.focused_window()) |window| {
                    window.toggle_floating(null);
                }
            },
            .toggle_sticky => {
                if (ctx.focused_window()) |window| {
                    window.toggle_sticky();
                }
            },
            .toggle_swallow => {
                if (ctx.focused_window()) |window| {
                    window.toggle_swallow();
                }
            },
            .zoom => |data| {
                if (ctx.focused_window()) |window| {
                    if (window.floating) continue;

                    if (window.output) |output| {
                        switch (output.current_layout()) {
                            .tile, .deck, .centered_master => {
                                if (!data.swap) {
                                    ctx.focus(window, true);
                                    ctx.shift_to_head(window);
                                    continue;
                                }

                                var master = output.master_window() orelse continue;
                                var new_master = if (window != master) window
                                    else ctx.focused_before(window, true) orelse continue;

                                // ensure the old master immediately behind the new master in focus_stack
                                ctx.focus(master, true);
                                ctx.focus(new_master, true);

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
                if (ctx.focused_window()) |window| {
                    if (window.floating) continue;
                    if (window.output) |output| {
                        switch (output.current_layout()) {
                            .tile, .deck, .centered_master => {
                                const master = output.master_window() orelse continue;
                                ctx.focus(
                                    if (window != master) master
                                    else ctx.focused_before(window, true) orelse continue,
                                    true,
                                );
                            },
                            else => {}
                        }
                    }
                }
            },
            .switch_layout => |data| {
                if (ctx.current_output) |output| {
                    output.set_current_layout(data.layout);
                }
            },
            .switch_to_previous_layout => {
                if (ctx.current_output) |output| {
                    output.switch_to_previous_layout();
                }
            },
            .toggle_bar => {
                if (comptime build_options.bar_enabled) {
                    if (ctx.current_output) |output| {
                        output.bar.toggle();
                    }
                } else {
                    log.warn("`toggle_bar` while bar disabled", .{});
                }
            },

            .modify_nmaster => |data| {
                if (ctx.current_output) |output| {
                    switch (output.current_layout()) {
                        .tile => |tile| switch (data.change) {
                            .increase => tile.nmaster += 1,
                            .decrease => tile.nmaster = @max(1, tile.nmaster-1),
                        },
                        .deck => |deck| switch (data.change) {
                            .increase => deck.nmaster += 1,
                            .decrease => deck.nmaster = @max(1, deck.nmaster-1),
                        },
                        .centered_master => |centered_master| switch (data.change) {
                            .increase => centered_master.nmaster += 1,
                            .decrease => centered_master.nmaster = @max(1, centered_master.nmaster-1),
                        },
                        else => {}
                    }
                }
            },
            .modify_mfact => |data| {
                if (ctx.current_output) |output| {
                    switch (output.current_layout()) {
                        .tile => |tile| {
                            const mfact = switch (data.change) {
                                .set => |mfact| mfact,
                                .step => |step| tile.mfact + step,
                            };
                            tile.mfact = @min(1, @max(0, mfact));
                        },
                        .deck => |deck| {
                            const mfact = switch (data.change) {
                                .set => |mfact| mfact,
                                .step => |step| deck.mfact + step,
                            };
                            deck.mfact = @min(1, @max(0, mfact));
                        },
                        .scroller => {
                            if (ctx.focus_top_in(output, false)) |window| {
                                const mfact = switch (data.change) {
                                    .set => |mfact| mfact,
                                    .step => |step| window.scroller_mfact + step,
                                };
                                window.scroller_mfact = @min(1, @max(0, mfact));
                            }
                        },
                        .centered_master => |centered_master| {
                            const mfact = switch (data.change) {
                                .set => |mfact| mfact,
                                .step => |step| centered_master.mfact + step,
                            };
                            centered_master.mfact = @min(1, @max(0, mfact));
                        },
                        else => {},
                    }
                }
            },
            .modify_gap => |data| {
                if (ctx.current_output) |output| {
                    switch (output.current_layout()) {
                        .tile => |tile| tile.inner_gap = @max(ctx.cfg.border.width*2, tile.inner_gap+data.step),
                        .grid => |grid| grid.inner_gap = @max(ctx.cfg.border.width*2, grid.inner_gap+data.step),
                        .monocle => |monocle| monocle.gap = @max(ctx.cfg.border.width*2, monocle.gap+data.step),
                        .deck => |deck| deck.inner_gap = @max(ctx.cfg.border.width*2, deck.inner_gap+data.step),
                        .scroller => |scroller| scroller.inner_gap = @max(ctx.cfg.border.width*2, scroller.inner_gap+data.step),
                        .centered_master => |centered_master| centered_master.inner_gap = @max(ctx.cfg.border.width*2, centered_master.inner_gap+data.step),
                        .float => {},
                    }
                }
            },
            .modify_master_location => |data| {
                if (ctx.current_output) |output| blk: {
                    switch (output.current_layout()) {
                        .tile => |tile| tile.master_location = data.location,
                        .deck => |deck| deck.master_location = data.location,
                        else => break :blk,
                    }
                    if (comptime build_options.bar_enabled) {
                        output.bar.damage(.layout);
                    }
                }
            },
            .toggle_grid_direction => {
                if (ctx.current_output) |output| {
                    switch (output.current_layout()) {
                        .grid => |grid| {
                            grid.direction = switch (grid.direction) {
                                .horizontal => .vertical,
                                .vertical => .horizontal,
                            };
                            if (comptime build_options.bar_enabled) {
                                output.bar.damage(.layout);
                            }
                        },
                        else => {}
                    }
                }
            },
            .toggle_centered_master_direction => {
                if (ctx.current_output) |output| {
                    switch (output.current_layout()) {
                        .centered_master => |centered_master| {
                            centered_master.direction = switch (centered_master.direction) {
                                .horizontal => .vertical,
                                .vertical => .horizontal,
                            };
                            if (comptime build_options.bar_enabled) {
                                output.bar.damage(.layout);
                            }
                        },
                        else => {}
                    }
                }
            },
            .toggle_auto_swallow => {
                ctx.cfg.auto_swallow = !ctx.cfg.auto_swallow;
            },

            .reload_config => {
                ctx.reload_config();
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

    ctx.focus(window, true);
    self.has_pointer_interaction = true;
}


fn shell_surface_interaction(self: *Self, shell_surface: *ShellSurface) void {
    log.debug("<{*}> interaction with shell surface: {*}", .{ self, shell_surface });

    switch (shell_surface.type) {
        .layer_marker => unreachable,
        .bar => |bar| if (comptime build_options.bar_enabled) {
            log.debug("<{*}> interaction with {*}", .{ self, bar });

            ctx.set_current_output(bar.output);

            bar.handle_click(self);
        } else unreachable,
        .background => |background| if (comptime build_options.background_enabled) {
            log.debug("<{*}> interaction with {*}", .{ self, background });

            ctx.set_current_output(background.output);
        } else unreachable,
    }

    self.has_pointer_interaction = true;
}


fn rwm_seat_listener(rwm_seat: *river.SeatV1, event: river.SeatV1.Event, seat: *Self) void {
    std.debug.assert(rwm_seat == seat.rwm_seat);

    switch (event) {
        .op_delta => |data| {
            log.debug("<{*}> op delta: (dx: {}, dy: {})", .{ seat, data.dx, data.dy });

            const window = ctx.focused_window().?;
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
                        const new_x =
                            if (op_data.direction.horizontal) |direction|
                                switch (direction) {
                                    .forward => null,
                                    .reverse => op_data.start_x + data.dx,
                                }
                            else null;
                        const new_y =
                            if (op_data.direction.vertical) |direction|
                                switch (direction) {
                                    .forward => null,
                                    .reverse => op_data.start_y + data.dy,
                                }
                            else null;
                        window.move(new_x, new_y);

                        const new_width =
                            if (op_data.direction.horizontal) |direction|
                                op_data.start_width + switch (direction) {
                                    .forward => data.dx,
                                    .reverse => -data.dx,
                                }
                            else null;
                        const new_height =
                            if (op_data.direction.vertical) |direction|
                                op_data.start_height + switch (direction) {
                                    .forward => data.dy,
                                    .reverse => -data.dy,
                                }
                            else null;
                        window.resize(new_width, new_height);
                    }
                }
            }
        },
        .op_release => {
            log.debug("<{*}> op release", .{ seat });

            if (ctx.focused_window()) |window| {
                switch (window.operator) {
                    .none => {},
                    .move => |data| {
                        if (data.seat == seat) {
                            window.prepare_move(.stop);
                        }
                    },
                    .resize => |data| {
                        if (data.seat == seat) {
                            window.prepare_resize(.stop);
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

            seat.window_below_pointer = .{
                .window = window,
                .new = true,
            };
        },
        .pointer_leave => {
            log.debug("<{*}> pointer leave", .{ seat });

            seat.window_below_pointer = .{};
        },
        .pointer_position => |data| {
            log.debug("<{*}> pointer position: (x: {}, y: {})", .{ seat, data.x, data.y });

            const new = seat.pointer_position.x != data.x or seat.pointer_position.y != data.y;
            seat.pointer_position = .{
                .x = data.x,
                .y = data.y,
                .new = new,
            };
        },
        .removed => {
            log.debug("<{*}> removed", .{ seat });

            ctx.prepare_remove_seat(seat);

            seat.destroy();
        },
        .shell_surface_interaction => |data| {
            log.debug("<{*}> shell surface interaction: {*}", .{ seat, data.shell_surface });

            const shell_surface: *ShellSurface = @ptrCast(
                @alignCast((data.shell_surface orelse return).getUserData())
            );

            seat.shell_surface_interaction(shell_surface);

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

            const wl_seat = ctx.wl_registry.bind(data.name, wl.Seat, 7) catch return;
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
            log.debug(
                "<{*}> wl_seat {*}, capabilities: (pointer: {}, keyboard: {}, touch: {})",
                .{
                    seat,
                    wl_seat,
                    data.capabilities.pointer,
                    data.capabilities.keyboard,
                    data.capabilities.touch,
                },
            );

            if (seat.wl_pointer) |wl_pointer| {
                wl_pointer.destroy();
                seat.wl_pointer = null;
            }
            if (data.capabilities.pointer) {
                const wl_pointer = wl_seat.getPointer() catch return;
                wl_pointer.setListener(*Self, wl_pointer_listener, seat);
                seat.wl_pointer = wl_pointer;
                seat.cursor_shape_device = ctx.wp_cursor_shape_manager.getPointer(wl_pointer) catch null;
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
        .enter => |data| {
            log.debug("<{*}> enter: (surface: {*}, x: {}, y: {})", .{ seat, data.surface, data.surface_x.toInt(), data.surface_y.toInt() });

            if (seat.cursor_shape_device) |cursor_shape_device| {
                cursor_shape_device.setShape(0, .default);
            }
        },
        else => {}
    }
}


fn to_river_modifiers(modifiers: config.Modifiers) river.SeatV1.Modifiers {
    var mods: river.SeatV1.Modifiers = .{};
    inline for (@typeInfo(config.Modifiers).@"struct".fields) |field| {
        @field(mods, field.name) = @field(modifiers, field.name);
    }
    return mods;
}


// https://codeberg.org/river/river-classic/src/commit/f0908e2d117ede7114fa85c65622b055c565c250/river/command/map.zig#L254
fn keysym_from_name(name: []const u8) ?u32 {
    const n = ctx.gpa.dupeZ(u8, name) catch |err| {
        log.err("dupeZ failed while call keysym_from_name: {}", .{ err });
        return null;
    };
    defer ctx.gpa.free(n);

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
