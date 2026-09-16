// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const Self = @This();

const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.pattern);

const mvzr = @import("mvzr");

str: []const u8,
regex: bool = false,
match_null: bool = false,

pub fn is_match(self: *const Self, haystack: ?[]const u8) bool {
    if (haystack == null) {
        log.debug("<{*}> matched null", .{ self });
        return self.match_null;
    }

    const matched = blk: {
        if (self.regex) {
            const pattern = mvzr.compile(self.str) orelse return false;
            break :blk pattern.isMatch(haystack.?);
        } else {
            break :blk mem.eql(u8, self.str, haystack.?);
        }
    };

    if (matched) {
        log.debug("<{*}> matched `{s}`", .{ self, haystack.? });
    }

    return matched;
}
