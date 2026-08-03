const Self = @This();

const std = @import("std");
const log = std.log.scoped(.xkb_binding);

const wayland = @import("wayland");
const river = wayland.client.river;

const utils = @import("../utils.zig");
const binding = @import("../binding.zig");
const Seat = @import("../seat.zig");
const Context = @import("../context.zig");

pub const Event = union(enum) {
    repeat: binding.Action,
    click: struct {
        pressed: ?binding.Action = null,
        released: ?binding.Action = null,
    },
};

const ctx = Context.get();


rwm_xkb_binding: *river.XkbBindingV1,

seat: *Seat,
event: Event,


pub fn create(
    seat: *Seat,
    keysym: u32,
    modifiers: river.SeatV1.Modifiers,
    event: Event,
) !*Self {
    const xkb_binding = try ctx.gpa.create(Self);
    errdefer ctx.gpa.destroy(xkb_binding);

    defer log.debug("<{*}> created", .{ xkb_binding });

    const rwm_xkb_binding = try ctx.rwm_xkb_bindings.getXkbBinding(seat.rwm_seat, keysym, modifiers);

    xkb_binding.* = .{
        .rwm_xkb_binding = rwm_xkb_binding,
        .seat = seat,
        .event = event
    };

    rwm_xkb_binding.setListener(*Self, rwm_xkb_binding_listener, xkb_binding);

    return xkb_binding;
}


pub fn destroy(self: *Self) void {
    defer log.debug("<{*}> destroyed", .{ self });

    self.rwm_xkb_binding.destroy();

    ctx.gpa.destroy(self);
}


pub inline fn enable(self: *Self) void {
    defer log.debug("<{*}> enabled", .{ self });

    self.rwm_xkb_binding.enable();
}


pub inline fn disable(self: *Self) void {
    defer log.debug("<{*}> disabled", .{ self });

    self.rwm_xkb_binding.disable();
}


fn rwm_xkb_binding_listener(rwm_xkb_binding: *river.XkbBindingV1, event: river.XkbBindingV1.Event, xkb_binding: *Self) void {
    std.debug.assert(rwm_xkb_binding == xkb_binding.rwm_xkb_binding);

    log.debug("<{*}> {s}", .{ xkb_binding, @tagName(event) });

    // exiting chorded
    switch (xkb_binding.seat.chorded.state) {
        .entering => unreachable,
        .enabled => if (event == .pressed) {
            switch (xkb_binding.seat.chorded.quit_mode) {
                .once_pressed, .once_bound_pressed => xkb_binding.seat.chorded.state = .exiting,
                .once_unbound_pressed => {}
            }
        },
        .exiting => if (event == .pressed) unreachable,
        .disabled => {}
    }

    switch (xkb_binding.event) {
        .click => |data| blk: {
            xkb_binding.seat.append_action(switch (event) {
                .pressed => data.pressed orelse break :blk,
                .released => data.released orelse break :blk,
                .stop_repeat => break :blk,
            });
        },
        .repeat => |action| {
            if (ctx.key_repeat) |*key_repeat| {
                switch (event) {
                    .pressed => {
                        key_repeat.prepare_repeat(xkb_binding, action);
                    },
                    .stop_repeat, .released => key_repeat.stop(xkb_binding),
                }
            }

            if (event == .pressed) {
                xkb_binding.seat.append_action(action);
            }
        },
    }
}
