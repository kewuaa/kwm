// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const Self = @This();

const std = @import("std");
const log = std.log.scoped(.background);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const river = wayland.client.river;

const utils = @import("utils.zig");
const Context = @import("context.zig");
const Output = @import("output.zig");
const ShellSurface = @import("shell_surface.zig");

const ctx = Context.get();


wl_surface: *wl.Surface,
wp_viewport: *wp.Viewport,
shell_surface: ShellSurface = undefined,

output: *Output,

damaged: bool = true,


pub fn init(self: *Self, output: *Output) !void {
    log.debug("<{*}> init", .{ self });

    const wl_surface = try ctx.wl_compositor.createSurface();
    errdefer wl_surface.destroy();

    const wp_viewport = try ctx.wp_viewporter.getViewport(wl_surface);
    errdefer wp_viewport.destroy();

    self.* = .{
        .wl_surface = wl_surface,
        .wp_viewport = wp_viewport,
        .output = output,
    };

    try self.shell_surface.init(wl_surface, .{ .background = self });
    errdefer self.shell_surface.deinit();
}


pub fn deinit(self: *Self) void {
    log.debug("<{*}> deinit", .{ self });

    self.shell_surface.deinit();
    self.wp_viewport.destroy();
    self.wl_surface.destroy();
}


pub fn damage(self: *Self) void {
    log.debug("<{*}> damaged", .{ self });

    self.damaged = true;
}


pub fn render(self: *Self) void {
    if (!self.damaged) return;
    defer self.damaged = false;

    log.debug("<{*}> rendering", .{ self });

    self.shell_surface.sync_next_commit();
    self.shell_surface.place(.bottom);
    self.shell_surface.set_position(self.output.x, self.output.y);

    const buffer = (
        if (ctx.cfg.background) |color| blk: {
            const rgba = utils.rgba(color);
            break :blk ctx.wp_single_pixel_buffer_manager.createU32RgbaBuffer(
                rgba.r,
                rgba.g,
                rgba.b,
                rgba.a,
            );
        } else ctx.wp_single_pixel_buffer_manager.createU32RgbaBuffer(0, 0, 0, 0)
    ) catch |err| {
        log.err("<{*}> create buffer failed: {}", .{ self, err });
        return;
    };
    defer buffer.destroy();

    self.wl_surface.attach(buffer, 0, 0);
    self.wl_surface.damageBuffer(0, 0, self.output.width, self.output.height);
    self.wp_viewport.setDestination(self.output.width, self.output.height);
    self.wl_surface.commit();
}
