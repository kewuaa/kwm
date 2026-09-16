// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const Self = @This();

const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.deck);

const types = @import("../types.zig");
const utils = @import("../utils.zig");
const Context = @import("../context.zig");
const Output = @import("../output.zig");
const Window = @import("../window.zig");

pub const MasterLocation = types.LayoutMasterLocation;

const ctx = Context.get();


nmaster: i32,
mfact: f32,
inner_gap: i32,
outer_gap: i32,
master_location: MasterLocation,


pub fn arrange(self: *const Self, output: *Output) !void {
    log.debug("<{*}> arrange windows in output {*}", .{ self, output });

    var windows = blk: {
        var windows: std.ArrayList(*Window) = .empty;
        errdefer windows.deinit(ctx.gpa);

        {
            var it = ctx.windows.safeIterator(.forward);
            while (windows.items.len < self.nmaster) {
                const window = it.next() orelse break :blk windows;
                if (!window.is_visible_in(output) or window.floating) continue;
                try windows.append(ctx.gpa, window);
            }
        }

        {
            var it = ctx.focus_stack.safeIterator(.forward);
            while (it.next()) |window| {
                const masters = windows.items[0..@intCast(self.nmaster)];
                if (mem.containsAtLeastScalar(*Window, masters, 1, window)) continue;
                if (!window.is_visible_in(output) or window.floating) continue;
                try windows.append(ctx.gpa, window);
            }
        }
        break :blk windows;
    };
    defer windows.deinit(ctx.gpa);

    if (windows.items.len == 0) return;

    const usable_width, const usable_height = blk: {
        const width = @max(0, output.exclusive_width() - 2*self.outer_gap);
        const height = @max(0, output.exclusive_height() - 2*self.outer_gap);
        break :blk switch (self.master_location) {
            .left, .right => .{ width, height },
            .top, .bottom => .{ height, width },
        };
    };

    var master_width: i32 = undefined;
    var master_height: i32 = undefined;
    var master_remain: i32 = undefined;
    var stack_width: i32 = undefined;
    var stack_height: i32 = undefined;

    const window_num: i32 = @intCast(windows.items.len);
    const nmaster = @min(window_num, self.nmaster);
    const nstack = window_num - self.nmaster;
    if (nstack > 0) {
        master_width = @intFromFloat(self.mfact * @as(f32, @floatFromInt(usable_width)));
        master_height = @divFloor(usable_height, nmaster);
        master_remain = @mod(usable_height, nmaster);

        stack_width = usable_width - master_width;
        stack_height = usable_height;
    } else {
        master_width = usable_width;
        master_height = @divFloor(usable_height, nmaster);
        master_remain = @mod(usable_height, nmaster);
    }

    for (0.., windows.items) |i, window| {
        var x: i32 = undefined;
        var y: i32 = undefined;
        var w: i32 = undefined;
        var h: i32 = undefined;
        if (i < nmaster) {
            x = 0;
            y = (@as(i32, @intCast(i)) * master_height) + if (i > 0) master_remain + self.inner_gap else 0;
            w = if (nstack > 0) master_width - @divFloor(self.inner_gap, 2) else master_width;
            h = (master_height + if (i == 0) master_remain else 0) - if (i > 0) self.inner_gap else 0;
        } else if (i == nmaster) {
            x = master_width + @divFloor(self.inner_gap, 2);
            y = 0;
            w = stack_width - @divFloor(self.inner_gap, 2);
            h = stack_height;
        } else window.hide();
        w = @max(0, w);
        h = @max(0, h);

        switch (self.master_location) {
            .left => {
                window.unbound_move(x+self.outer_gap, y+self.outer_gap);
                window.unbound_resize(w, h);
            },
            .right => {
                window.unbound_move(usable_width-x-w+self.outer_gap, y+self.outer_gap);
                window.unbound_resize(w, h);
            },
            .top => {
                window.unbound_move(y+self.outer_gap, x+self.outer_gap);
                window.unbound_resize(h, w);
            },
            .bottom => {
                window.unbound_move(y+self.outer_gap, usable_width-x-w+self.outer_gap);
                window.unbound_resize(h, w);
            }
        }
    }
}
