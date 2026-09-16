// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const Self = @This();

const std = @import("std");
const log = std.log.scoped(.solid_color_component);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;

const utils = @import("../utils.zig");
const Context = @import("../context.zig");

const ctx = Context.get();


wl_surface: *wl.Surface,
wl_subsurface: *wl.Subsurface,
wp_viewport: *wp.Viewport,


pub fn init(self: *Self, parent: *wl.Surface) !void {
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
    };
}

pub fn deinit(self: *Self) void {
    log.debug("<{*}> deinit", .{ self });

    self.wp_viewport.destroy();
    self.wl_subsurface.destroy();
    self.wl_surface.destroy();
}

pub fn render(self: *Self, x: i32, y: i32, width: i32, height: i32, color: u32) void {
    log.debug("<{*}> rendering", .{ self });

    const rgba = utils.rgba(color);
    const wl_buffer = ctx.wp_single_pixel_buffer_manager.createU32RgbaBuffer(
        rgba.r,
        rgba.g,
        rgba.b,
        rgba.a,
    ) catch |err| {
        log.err("<{*}> create buffer failed: {}", .{ self, err });
        return;
    };
    defer wl_buffer.destroy();

    self.wl_subsurface.setPosition(x, y);
    self.wl_surface.attach(wl_buffer, 0, 0);
    self.wl_surface.damage(0, 0, width, height);
    self.wp_viewport.setDestination(width, height);
    self.wl_surface.commit();
}
