// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const Self = @This();

const std = @import("std");
const log = std.log.scoped(.component);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;

const utils = @import("../utils.zig");
const Context = @import("../context.zig");
const Buffer = @import("buffer.zig");

const ctx = Context.get();


wl_surface: *wl.Surface,
wl_subsurface: *wl.Subsurface,
wp_viewport: *wp.Viewport,
buffers: [2]Buffer = undefined,


pub fn init(self: *Self, parent: *wl.Surface) !void {
    log.debug("<{*}> init", .{ self });

    const wl_surface = try ctx.wl_compositor.createSurface();
    errdefer wl_surface.destroy();

    const wl_subsurface = try ctx.wl_subcompositor.getSubsurface(wl_surface, parent);
    errdefer wl_subsurface.destroy();

    const wp_viewport = try ctx.wp_viewporter.getViewport(wl_surface);
    errdefer wp_viewport.destroy();

    self.* = .{
        .wl_surface = wl_surface,
        .wl_subsurface = wl_subsurface,
        .wp_viewport = wp_viewport,
        .buffers = .{ .{}, .{} },
    };

    wl_subsurface.setDesync();
}


pub fn deinit(self: *Self) void {
    log.debug("<{*}> deinit", .{ self });

    self.wp_viewport.destroy();
    self.wl_subsurface.destroy();
    self.wl_surface.destroy();
    self.buffers[0].deinit();
    self.buffers[1].deinit();
}


pub fn manage(self: *Self, x: i32, y: i32) void {
    log.debug("<{*}> manage (x: {}, y: {})", .{ self, x, y });

    self.wl_subsurface.setPosition(x, y);
}


pub fn render(self: *Self, buffer: *Buffer, scale: u32) void {
    log.debug("<{*}> rendering", .{ self });

    self.wl_surface.attach(buffer.wl_buffer, 0, 0);
    self.wl_surface.damageBuffer(0, 0, buffer.width, buffer.height);
    self.wp_viewport.setDestination(
        utils.physics2logical(i32, buffer.width, scale),
        utils.physics2logical(i32, buffer.height, scale),
    );
    self.wl_surface.commit();
}


pub fn next_buffer(self: *Self) ?*Buffer {
    for (0..2) |i| {
        if (!self.buffers[i].busy) {
            self.buffers[i].occupy();
            return &self.buffers[i];
        }
    }
    return null;
}
