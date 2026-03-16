const Self = @This();

const std = @import("std");
const log = std.log.scoped(.monocle);

const Context = @import("../context.zig");
const Output = @import("../output.zig");


gap: i32,


pub fn arrange(self: *const Self, output: *Output) void {
    log.debug("<{*}> arrange windows in output {*}", .{ self, output });

    const context = Context.get();

    const focus_top = context.focus_top_in(output, true, false) orelse return;
    const available_width = output.exclusive_width() - 2*self.gap;
    const available_height = output.exclusive_height() - 2*self.gap;
    {
        var it = context.windows.safeIterator(.forward);
        while (it.next()) |window| {
            if (!window.is_visible_in(output) or window.floating) continue;
            if (window != focus_top) window.hide();
            window.unbound_move(self.gap, self.gap);
            window.unbound_resize(available_width, available_height);
        }
    }
}
