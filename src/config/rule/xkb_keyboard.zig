const Self = @This();

const std = @import("std");
const log = std.log.scoped(.xkb_keyboard_rule);

const kwm = @import("kwm");

const Pattern = @import("pattern.zig");


name: ?Pattern = null,

numlock: ?kwm.KeyboardNumlockState = null,
capslock: ?kwm.KeyboardCapslockState = null,
layout: ?kwm.KeyboardLayout = null,
keymap: ?kwm.Keymap = null,
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
