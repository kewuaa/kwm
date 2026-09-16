// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const Self = @This();

const std = @import("std");
const mem = std.mem;
const time = std.time;
const log = std.log.scoped(.key_repeat);

const posix = @import("posix");

const binding = @import("binding.zig");
const Context = @import("context.zig");

const ctx = Context.get();


action: binding.Action = undefined,
xkb_binding: ?*binding.XkbBinding = null,

timer_fd: posix.fd_t,


pub fn init(self: *Self) !void {
    log.debug("<{*}> init", .{ self });

    const timer_fd = try posix.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
    errdefer posix.close(timer_fd);

    self.* = .{
        .timer_fd = timer_fd,
    };
}


pub fn deinit(self: *Self) void {
    log.debug("<{*}> deinit", .{ self });

    posix.close(self.timer_fd);
}


pub fn prepare_repeat(self: *Self, xkb_binding: *binding.XkbBinding, action: binding.Action) void {
    if (self.is_repeating()) return;

    log.debug("<{*}> start repeating {*}, action: {s}", .{ self, xkb_binding, @tagName(action) });

    const repeat_info = &ctx.cfg.bindings.repeat_info;

    const itimerspec: posix.system.itimerspec = .{
        .it_value = .{ .sec = 0, .nsec = repeat_info.delay*time.ns_per_ms },
        .it_interval = .{ .sec = 0, .nsec = @divFloor(time.ns_per_s, repeat_info.rate) },
    };
    posix.timerfd_settime(self.timer_fd, .{ .ABSTIME = false }, &itimerspec, null) catch |err| {
        log.err("<{*}> call timerfd_settime of timer_fd failed: {}", .{ self, err });
        return;
    };

    self.xkb_binding = xkb_binding;
    self.action = action;
}


pub fn repeat(self: *Self, count: u64) void {
    if (!self.is_repeating()) return;

    log.debug("<{*}> repeat, count: {}", .{ self, count });

    for (0..count) |_| {
        self.xkb_binding.?.seat.append_action(self.action);
    }

    ctx.rwm.manageDirty();
}


pub fn stop(self: *Self, xkb_binding: *binding.XkbBinding) void {
    if (!self.is_repeating()) return;

    if (xkb_binding != self.xkb_binding.?) return;

    log.debug("<{*}> stop repeating {*}", .{ self, self.xkb_binding.? });

    self.reset_timer() catch |err| {
        log.err("<{*}> reset timer failed: {}", .{ self, err });
    };

    self.xkb_binding = null;
    self.action = undefined;
}


pub inline fn is_repeating(self: *const Self) bool {
    return self.xkb_binding != null;
}


fn reset_timer(self: *Self) !void {
    log.debug("<{*}> reset timer", .{ self });

    const itimerspec = mem.zeroes(posix.system.itimerspec);
    try posix.timerfd_settime(self.timer_fd, .{ .ABSTIME = false }, &itimerspec, null);
}
