// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const Self = @This();

const std = @import("std");
const log = std.log.scoped(.grid);

const Context = @import("../context.zig");
const Output = @import("../output.zig");
const Window = @import("../window.zig");

pub const Direction = enum {
    horizontal,
    vertical,
};

const ctx = Context.get();


outer_gap: i32,
inner_gap: i32,
direction: Direction,


pub fn arrange(self: *const Self, output: *Output) !void {
    log.debug("<{*}> arrange windows in output {*}", .{ self, output });

    var windows: std.ArrayList(*Window) = .empty;
    defer windows.deinit(ctx.gpa);
    {
        var it = ctx.windows.safeIterator(.forward);
        while (it.next()) |window| {
            if (
                !window.is_visible_in(output)
                or window.floating
            ) continue;
            try windows.append(ctx.gpa, window);
        }
    }

    if (windows.items.len == 0) return;

    const col_num: i32 = @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(windows.items.len)))));
    const row_num: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(windows.items.len)) / @as(f32, @floatFromInt(col_num))));
    const available_width, const available_height = blk: {
        const width = @max(0, output.exclusive_width() - 2*self.outer_gap);
        const height = @max(0, output.exclusive_height() - 2*self.outer_gap);
        break :blk switch (self.direction) {
            .horizontal => .{ width, height },
            .vertical => .{ height, width },
        };
    };

    const width = @divFloor(available_width, col_num);
    const width_remain = @mod(available_width, col_num);
    const height = @divFloor(available_height, row_num);
    const height_remain = @mod(height, row_num);

    const space_width = (row_num*col_num - @as(i32, @intCast(windows.items.len))) * width;
    const last_row_pad = @divFloor(space_width, 2) + @mod(space_width, 2);
    for (0.., windows.items) |i, window| {
        const row: i32 = @divFloor(@as(i32, @intCast(i)), col_num);
        const col: i32 = @as(i32, @intCast(i)) - row*col_num;

        const x = col * width + (if (col > 0) width_remain else 0) + if (row == row_num-1) last_row_pad else 0;
        const y = row * height + if (row > 0) self.inner_gap+height_remain else 0;
        const w = width - (if (col < col_num-1) self.inner_gap else 0) + if (col == 0) width_remain else 0;
        const h = height - (if (row > 0) self.inner_gap else 0) + if (row == 0) height_remain else 0;

        switch (self.direction) {
            .horizontal => {
                window.unbound_move(x+self.outer_gap, y+self.outer_gap);
                window.unbound_resize(w, h);
            },
            .vertical => {
                window.unbound_move(y+self.outer_gap, x+self.outer_gap);
                window.unbound_resize(h, w);
            },
        }
    }
}
