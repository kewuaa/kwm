// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const Self = @This();

const std = @import("std");
const log = std.log.scoped(.custom_border);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const river = wayland.client.river;

const utils = @import("utils.zig");
const Context = @import("context.zig");
const Window = @import("window.zig");
const SolidColorComponent = @import("render/solid_color_component.zig");

const ctx = Context.get();


wl_surface: *wl.Surface,
wp_viewport: *wp.Viewport,

rwm_decoration: *river.DecorationV1,

top: SolidColorComponent = undefined,
bottom: SolidColorComponent = undefined,
left: SolidColorComponent = undefined,
right: SolidColorComponent = undefined,

window: *Window,

damaged: bool = true,


pub fn init(self: *Self, window: *Window) !void {
    log.debug("<{*}> init", .{ self });

    const wl_surface = try ctx.wl_compositor.createSurface();
    errdefer wl_surface.destroy();

    const wp_viewport = try ctx.wp_viewporter.getViewport(wl_surface);
    errdefer wp_viewport.destroy();

    const rwm_decoration = try window.rwm_window.getDecorationBelow(wl_surface);
    errdefer rwm_decoration.destroy();

    self.* = .{
        .wl_surface = wl_surface,
        .wp_viewport = wp_viewport,
        .rwm_decoration = rwm_decoration,
        .window = window,
    };

    try self.top.init(wl_surface);
    errdefer self.top.deinit();

    try self.bottom.init(wl_surface);
    errdefer self.bottom.deinit();

    try self.left.init(wl_surface);
    errdefer self.left.deinit();

    try self.right.init(wl_surface);
    errdefer self.right.deinit();
}


pub fn deinit(self: *Self) void {
    log.debug("<{*}> deinit", .{ self });

    self.top.deinit();
    self.bottom.deinit();
    self.left.deinit();
    self.right.deinit();
    self.rwm_decoration.destroy();
    self.wp_viewport.destroy();
    self.wl_surface.destroy();
}


pub inline fn damage(self: *Self) void {
    log.debug("<{*}> damage", .{ self });

    self.damaged = true;
}


pub fn render(self: *Self, color: u32) void {
    if (!self.damaged) return;
    self.damaged = false;

    log.debug("<{*}> rendering", .{ self });

    const width, const height = blk: {
        if (self.window.maximize) {
            if (self.window.output) |output| {
                break :blk .{
                    output.exclusive_width(),
                    output.exclusive_height(),
                };
            }
            return;
        }
        break :blk
            if (self.window.managed_by_layout()) .{
                self.window.width + 2*ctx.cfg.border.width,
                self.window.height + 2*ctx.cfg.border.width,
            }
            else .{
                self.window.width + 4*ctx.cfg.border.width,
                self.window.height + 4*ctx.cfg.border.width,
            };
    };

    self.rwm_decoration.setOffset(-2*ctx.cfg.border.width, -2*ctx.cfg.border.width);
    self.rwm_decoration.syncNextCommit();

    const buffer = ctx.wp_single_pixel_buffer_manager.createU32RgbaBuffer(0, 0, 0, 0) catch |err| {
        log.err("<{*}> create buffer failed: {}", .{ self, err });
        return;
    };
    defer buffer.destroy();

    self.wl_surface.attach(buffer, 0, 0);
    self.wl_surface.damage(0, 0, width, height);
    self.wp_viewport.setDestination(width, height);

    self.top.render(0, 0, width, ctx.cfg.border.width, color);
    self.bottom.render(0, height-ctx.cfg.border.width, width, ctx.cfg.border.width, color);
    self.left.render(0, 0, ctx.cfg.border.width, height, color);
    self.right.render(width-ctx.cfg.border.width, 0, ctx.cfg.border.width, height, color);

    self.wl_surface.commit();
}
