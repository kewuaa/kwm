const Self = @This();

const std = @import("std");
const log = std.log.scoped(.input_device_rule);

const kwm = @import("kwm");

const Pattern = @import("pattern.zig");

name: ?Pattern = null,

repeat_info: ?kwm.KeyboardRepeatInfo = null,
scroll_factor: ?f64 = null,
host: ?Pattern = null,


pub fn match(self: *const Self, name: ?[]const u8, hostname: ?[]const u8) bool {
    if (self.host) |host| {
        if (!host.is_match(hostname)) {
            return false;
        }
    }

    if (self.name) |pattern| {
        log.debug("try match name: `{s}` with {*}({*}: `{s}`)", .{ name orelse "null", self, &pattern, pattern.str });

        if (!pattern.is_match(name)) return false;
    }
    return true;
}
