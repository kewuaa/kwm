// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const Self = @This();

const std = @import("std");
const log = std.log.scoped(.centered_master);

const config = @import("config");

const types = @import("../types.zig");
const Context = @import("../context.zig");
const Output = @import("../output.zig");
const Window = @import("../window.zig");

pub const Direction = enum {
    horizontal,
    vertical,
};

const ctx = Context.get();

nmaster: i32,
mfact: f32,
inner_gap: i32,
outer_gap: i32,
direction: Direction,


pub fn arrange(self: *const Self, output: *Output) !void {
    log.debug("<{*}> arrange windows in output {*}", .{ self, output });

    const context = Context.get();

    var windows: std.ArrayList(*Window) = .empty;
    defer windows.deinit(ctx.gpa);
    {
        var it = context.windows.safeIterator(.forward);
        while (it.next()) |window| {
            if (
                !window.is_visible_in(output)
                or window.floating
            ) continue;
            try windows.append(ctx.gpa, window);
        }
    }

    if (windows.items.len == 0) return;

    const usable_width, const usable_height = blk: {
        const width = @max(0, output.exclusive_width() - 2*self.outer_gap);
        const height = @max(0, output.exclusive_height() - 2*self.outer_gap);
        break :blk switch (self.direction) {
            .horizontal => .{ width, height },
            .vertical => .{ height, width },
        };
    };

    const window_num: i32 = @intCast(windows.items.len);
    const nmaster = @min(window_num, self.nmaster);
    const nstack = window_num - self.nmaster;
    const n_left_stack: i32 = if (nstack <= 0) 0 else if (nstack == 1) 1 else @divFloor(nstack, 2);
    const n_right_stack: i32 = if (nstack <= 0) 0 else nstack - n_left_stack;

    const half_gap = @divFloor(self.inner_gap, 2);

    var master_width: i32 = undefined;
    var master_height: i32 = undefined;
    var master_remain: i32 = undefined;
    var left_stack_width: i32 = undefined;
    var left_height: i32 = undefined;
    var left_remain: i32 = undefined;
    var right_stack_width: i32 = undefined;
    var right_height: i32 = undefined;
    var right_remain: i32 = undefined;

    if (nstack > 0) {
        master_width = @intFromFloat(self.mfact * @as(f32, @floatFromInt(usable_width)));
        const remaining = usable_width - master_width;
        left_stack_width = if (n_left_stack > 0) @divFloor(remaining, 2) else 0;
        right_stack_width = if (n_right_stack > 0) remaining - left_stack_width else 0;
        master_width = usable_width - left_stack_width - right_stack_width;
    } else {
        master_width = usable_width;
        left_stack_width = 0;
        right_stack_width = 0;
    }

    master_height = @divFloor(usable_height, nmaster);
    master_remain = @mod(usable_height, nmaster);

    if (n_left_stack > 0) {
        left_height = @divFloor(usable_height, n_left_stack);
        left_remain = @mod(usable_height, n_left_stack);
    }

    if (n_right_stack > 0) {
        right_height = @divFloor(usable_height, n_right_stack);
        right_remain = @mod(usable_height, n_right_stack);
    }

    for (0.., windows.items) |i, window| {
        const idx: i32 = @intCast(i);
        var x: i32 = undefined;
        var y: i32 = undefined;
        var w: i32 = undefined;
        var h: i32 = undefined;

        if (i < nmaster) {
            x = left_stack_width + (if (n_left_stack > 0) half_gap else 0);
            y = (idx * master_height) + if (i > 0) master_remain + self.inner_gap else 0;
            w = master_width - (if (n_left_stack > 0) half_gap else 0) - (if (n_right_stack > 0) half_gap else 0);
            h = (master_height + if (i == 0) master_remain else 0) - if (i > 0) self.inner_gap else 0;
        } else if (i < nmaster + n_right_stack) {
            const ri = idx - nmaster;
            x = left_stack_width + master_width + half_gap;
            y = (ri * right_height) + if (ri > 0) right_remain + self.inner_gap else 0;
            w = right_stack_width - half_gap;
            h = (right_height + if (ri == 0) right_remain else 0) - if (ri > 0) self.inner_gap else 0;
        } else {
            const li = idx - nmaster - n_right_stack;
            x = 0;
            y = (li * left_height) + if (li > 0) left_remain + self.inner_gap else 0;
            w = left_stack_width - half_gap;
            h = (left_height + if (li == 0) left_remain else 0) - if (li > 0) self.inner_gap else 0;
        }

        w = @max(0, w);
        h = @max(0, h);

        switch (self.direction) {
            .horizontal => {
                window.unbound_move(x + self.outer_gap, y + self.outer_gap);
                window.unbound_resize(w, h);
            },
            .vertical => {
                window.unbound_move(y + self.outer_gap, x + self.outer_gap);
                window.unbound_resize(h, w);
            },
        }
    }
}
