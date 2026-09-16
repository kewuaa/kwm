// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const Self = @This();

const std = @import("std");
const log = std.log.scoped(.output_rule);

const wayland = @import("wayland");
const river = wayland.client.river;

const kwm = @import("kwm");

const meta = @import("../meta.zig");
const Pattern = @import("pattern.zig");


name: ?Pattern = null,

presentation_mode: ?river.OutputV1.PresentationMode = null,
default_layout: ?kwm.Layout.Type = null,
layout: ?meta.make_fields_optional(kwm.Layout) = null,


pub fn match(self: *const Self, name: ?[]const u8) bool {
    if (self.name) |pattern| {
        log.debug("try match name: `{s}` with {*}({*}: `{s}`)", .{ name orelse "null", self, &pattern, pattern.str });

        if (!pattern.is_match(name)) return false;
    }
    return true;
}
