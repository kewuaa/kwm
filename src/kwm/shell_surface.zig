// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const Self = @This();

const build_options = @import("build_options");
const std = @import("std");
const log = std.log.scoped(.shell_surface);

const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

const utils = @import("utils.zig");
const types = @import("types.zig");
const Context = @import("context.zig");

const Type = union(enum) {
    layer_marker,
    background: if (build_options.background_enabled) *@import("background.zig") else void,
    bar: if (build_options.bar_enabled) *@import("bar.zig") else void,
};

const ctx = Context.get();


rwm_shell_surface: *river.ShellSurfaceV1,
rwm_shell_surface_node: *river.NodeV1,

type: Type,


pub fn init(self: *Self, wl_surface: *wl.Surface, @"type": Type) !void {
    log.debug("<{*}> init", .{ self });

    const rwm_shell_surface = try ctx.rwm.getShellSurface(wl_surface);
    errdefer rwm_shell_surface.destroy();

    const rwm_shell_surface_node = try rwm_shell_surface.getNode();
    errdefer rwm_shell_surface_node.destroy();

    self.* = .{
        .rwm_shell_surface = rwm_shell_surface,
        .rwm_shell_surface_node = rwm_shell_surface_node,
        .type = @"type",
    };

    utils.set_user_data(river.ShellSurfaceV1, rwm_shell_surface, *Self, self);
}


pub fn deinit(self: *Self) void {
    log.debug("<{*}> deinit", .{ self });

    self.rwm_shell_surface.destroy();
    self.rwm_shell_surface_node.destroy();
}


pub inline fn sync_next_commit(self: *Self) void {
    self.rwm_shell_surface.syncNextCommit();
}


pub fn set_position(self: *Self, x: i32, y: i32) void {
    log.debug("<{*}> set position (x: {}, y: {})", .{ self, x, y });

    self.rwm_shell_surface_node.setPosition(x, y);
}


pub fn place(self: *Self, pos: types.PlacePosition) void {
    switch (pos) {
        .top => self.rwm_shell_surface_node.placeTop(),
        .bottom => self.rwm_shell_surface_node.placeBottom(),
        .above => |node| self.rwm_shell_surface_node.placeAbove(node),
        .below => |node| self.rwm_shell_surface_node.placeBelow(node),
    }
}
