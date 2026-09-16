// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const Self = @This();

const std = @import("std");
const log = std.log.scoped(.pointer_binding);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const binding = @import("../binding.zig");
const Seat = @import("../seat.zig");
const Context = @import("../context.zig");

pub const Event = struct {
    pressed: ?binding.Action = null,
    released: ?binding.Action = null,
};

const ctx = Context.get();


rwm_pointer_binding: *river.PointerBindingV1,

seat: *Seat,
event: Event,


pub fn create(
    seat: *Seat,
    button: u32,
    modifiers: river.SeatV1.Modifiers,
    event: Event,
) !*Self {
    const pointer_binding = try ctx.gpa.create(Self);
    errdefer ctx.gpa.destroy(pointer_binding);

    defer log.debug("<{*}> created", .{ pointer_binding });

    const rwm_pointer_binding = try seat.rwm_seat.getPointerBinding(button, modifiers);

    pointer_binding.* = .{
        .rwm_pointer_binding = rwm_pointer_binding,
        .seat = seat,
        .event = event,
    };

    rwm_pointer_binding.setListener(*Self, rwm_pointer_binding_listener, pointer_binding);

    return pointer_binding;
}


pub fn destroy(self: *Self) void {
    defer log.debug("<{*}> destroyed", .{ self });

    self.rwm_pointer_binding.destroy();

    ctx.gpa.destroy(self);
}


pub inline fn enable(self: *Self) void {
    defer log.debug("<{*}> enabled", .{ self });

    self.rwm_pointer_binding.enable();
}


pub inline fn disable(self: *Self) void {
    defer log.debug("<{*}> disabled", .{ self });

    self.rwm_pointer_binding.disable();
}


fn rwm_pointer_binding_listener(rwm_pointer_binding: *river.PointerBindingV1, event: river.PointerBindingV1.Event, pointer_binding: *Self) void {
    std.debug.assert(rwm_pointer_binding == pointer_binding.rwm_pointer_binding);

    log.debug("<{*}> {s}", .{ pointer_binding, @tagName(event) });

    pointer_binding.seat.append_action(switch (event) {
        .pressed => pointer_binding.event.pressed orelse return,
        .released => pointer_binding.event.released orelse return,
    });
}
