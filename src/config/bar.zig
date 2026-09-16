// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const Self = @This();

const std = @import("std");
const mem = std.mem;

const kwm = @import("kwm");

const meta = @import("meta.zig");

const Color = struct {
    fg: u32,
    bg: u32,
};
const Scheme = struct {
    normal: Color,
    select: Color,
};
const BarArea = union(kwm.BarArea) {
    tags,
    mode: ?[]const u8,
    layout: ?kwm.Layout.Type,
    title,
    status,
};


show_default: bool,

position: enum {
    top,
    bottom,
},

font: []const u8,

scheme: Scheme,

tags: ?struct {
    tags: []const []const u8,
    click: meta.enum_struct(
        kwm.Button,
        ?kwm.BindingAction
    ),
},

mode: ?struct {
    tags: []const struct { []const u8, []const u8 },
    click: meta.enum_struct(
        kwm.Button,
        ?kwm.BindingAction
    ),

    pub fn tag(self: *const @This(), mode: []const u8) ?[]const u8 {
        for (self.tags) |pair| {
            const m, const t = pair;
            if (mem.eql(u8, m, mode)) return t;
        }
        return null;
    }
},

layout: ?struct {
    tags: struct {
        tile: meta.enum_struct(kwm.Layout.Tile.MasterLocation, []const u8),
        grid: meta.enum_struct(kwm.Layout.Grid.Direction, []const u8),
        monocle: []const u8,
        deck: meta.enum_struct(kwm.Layout.Deck.MasterLocation, []const u8),
        scroller: []const u8,
        centered_master: meta.enum_struct(kwm.Layout.CenteredMaster.Direction, []const u8),
        float: []const u8,
    },
    click: meta.enum_struct(
        kwm.Button,
        ?kwm.BindingAction
    ),
},

title: ?struct {
    click: meta.enum_struct(
        kwm.Button,
        ?kwm.BindingAction
    ),
},

status: ?struct {
    data: union(enum) {
        text: []const u8,
        stdin,
        fifo: []const u8,
    },
    click: meta.enum_struct(
        kwm.Button,
        ?kwm.BindingAction
    ),
},

override_colors: []const struct {
    area: BarArea,
    scheme: meta.make_fields_optional(Scheme),

    fn is_match(self: *const @This(), area: BarArea) bool {
        if (std.meta.activeTag(self.area) != std.meta.activeTag(area)) return false;

        return switch (area) {
            .mode => |mode|
                if (self.area.mode) |m| mem.eql(u8, mode.?, m)
                else true,
            .layout => |layout|
                if (self.area.layout) |l| layout.? == l
                else true,
            else => true,
        };
    }
},


pub fn get(self: *const Self, comptime area: kwm.BarArea) @FieldType(Self, @tagName(area)) {
    return @field(self, @tagName(area));
}


pub fn get_scheme(
    self: *const Self,
    area: BarArea,
) Scheme {
    for (self.override_colors) |item| {
        if (!item.is_match(area)) continue;

        return meta.override(self.scheme, item.scheme);
    }

    return self.scheme;
}


pub fn empty(self: *const Self) bool {
    inline for (@typeInfo(kwm.BarArea).@"enum".fields) |field| {
        if (@field(self, field.name) != null) return false;
    }
    return true;
}
