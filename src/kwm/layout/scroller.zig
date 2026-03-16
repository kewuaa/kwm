const Self = @This();

const std = @import("std");
const log = std.log.scoped(.scroller);

const Context = @import("../context.zig");
const Output = @import("../output.zig");
const Window = @import("../window.zig");


outer_gap: i32,
inner_gap: i32,
mfact: f32,


pub fn arrange(self: *const Self, output: *Output) void {
    log.debug("<{*}> arrange windows in output {*}", .{ self, output });

    const context = Context.get();

    const focus_top = context.focus_top_in(output, true, false) orelse return;

    const available_width = output.exclusive_width();
    const available_height = output.exclusive_height();

    const master_width: i32 = @intFromFloat(
        @as(f32, @floatFromInt(available_width)) * focus_top.scroller_mfact
    );
    const height = available_height - 2*self.outer_gap;
    var master_x: i32 = undefined;
    const y = self.outer_gap;

    if (focus_top.scroller_x) |scroller_x| blk: {
        switch (scroller_x) {
            .x => |x| {
                var link = &focus_top.link;
                while (link.prev.? != &context.windows.link) {
                    defer link = link.prev.?;
                    const window: *Window = @fieldParentPtr("link", link.prev.?);
                    if (window.is_visible_in(output) and !window.floating) {
                        const left = self.outer_gap;
                        const right = output.width - self.outer_gap - master_width;
                        if (x < left) {
                            master_x = left;
                        } else if (x > right) {
                            master_x = right;
                        } else master_x = x;
                        break :blk;
                    }
                }
                master_x = self.outer_gap;
            },
            .center => master_x = @divFloor(output.width-focus_top.width, 2),
        }
    } else {
        master_x = self.outer_gap;
    }
    if (focus_top.scroller_x != null and focus_top.scroller_x.? == .x) {
        focus_top.scroller_x = .{ .x = master_x };
    }

    focus_top.unbound_move(master_x, y);
    focus_top.unbound_resize(master_width, height);

    {
        var link = &focus_top.link;
        var x = master_x;
        while (link.prev.? != &context.windows.link) {
            defer link = link.prev.?;
            const window: *Window = @fieldParentPtr("link", link.prev.?);
            if (!window.is_visible_in(output) or window.floating) continue;

            x -= self.inner_gap;

            const width: i32 = @intFromFloat(
                @as(f32, @floatFromInt(available_width)) * window.scroller_mfact
            );

            x -= width;
            window.scroller_x = .{ .x = x };
            window.unbound_move(x, y);
            window.unbound_resize(width, height);
        }
    }

    {
        var link = &focus_top.link;
        var x = master_x + master_width;
        while (link.next.? != &context.windows.link) {
            defer link = link.next.?;
            const window: *Window = @fieldParentPtr("link", link.next.?);
            if (!window.is_visible_in(output) or window.floating) continue;

            x += self.inner_gap;

            const width: i32 = @intFromFloat(
                @as(f32, @floatFromInt(available_width)) * window.scroller_mfact
            );

            window.scroller_x = .{ .x = x };
            window.unbound_move(x, y);
            window.unbound_resize(width, height);
            x += width;
        }
    }
}
