const Self = @This();

const build_options = @import("build_options");
const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const unicode = std.unicode;
const log = std.log.scoped(.bar);

const wayland = @import("wayland");
const wp = wayland.client.wp;
const wl = wayland.client.wl;
const river = wayland.client.river;
const pixman = @import("pixman");
const fcft = @import("fcft");
const mvzr = @import("mvzr");

const utils = @import("utils.zig");
const types = @import("types.zig");
const render_ = @import("render.zig");
const binding = @import("binding.zig");
const Context = @import("context.zig");
const Seat = @import("seat.zig");
const Output = @import("output.zig");
const ShellSurface = @import("shell_surface.zig");

const ctx = Context.get();
const color_pattern = mvzr.compile("\\^#([0-9a-zA-Z]{8}|!)").?;
pub var status_buffer = [1]u8 { 0 } ** 256;

font: render_.Font = undefined,

wl_surface: *wl.Surface = undefined,
shell_surface: ShellSurface = undefined,
wp_viewport: *wp.Viewport = undefined,
wp_fractional_scale: *wp.FractionalScaleV1 = undefined,
static_component: render_.Component = undefined,
dynamic_component: render_.Component = undefined,

output: *Output,

scale: u32,
static_component_damaged: bool = true,
dynamic_component_damaged: bool = true,
background_damaged: bool = true,
hidden: bool,

dynamic_splits_buffer: [@typeInfo(types.BarArea).@"enum".fields.len-2]i32 = undefined,
static_splits: std.ArrayList(i32) = .empty,
dynamic_splits: std.ArrayList(i32) = undefined,


pub fn init(self: *Self, output: *Output) !void {
    log.debug("<{*}> init", .{ self });

    const scale = 120;

    self.* = .{
        .output = output,
        .scale = scale,
        .hidden = !ctx.cfg.bar.show_default,
    };

    try self.font.init(ctx.cfg.bar.font, scale);
    errdefer self.font.deinit();

    self.dynamic_splits = .initBuffer(&self.dynamic_splits_buffer);

    if (!self.hidden) {
        try self.show();
    }
}


pub fn deinit(self: *Self) void {
    log.debug("<{*}> deinit", .{ self });

    if (!self.hidden) {
        self.hidden = true;
        self.hide();
    }
    self.font.deinit();

    self.static_splits.deinit(ctx.gpa);
}


pub inline fn reload_font(self: *Self) void {
    log.debug("<{*}> reload font", .{ self });

    self.font.reload(ctx.cfg.bar.font, self.scale);
}


pub inline fn height(self: *const Self, logical: bool) i32 {
    return if (logical) utils.physics2logical(
        i32,
        self.font.height(),
        self.scale,
    ) else self.font.height();
}


pub fn handle_click(self: *Self, seat: *Seat) void {
    log.debug("<{*}> handle click by {*}", .{ self, seat });

    const pointer_x = seat.pointer_position.x;
    const pointer_y = seat.pointer_position.y;

    // ensure in range
    if (pointer_x < self.output.x or pointer_x > self.output.x + self.output.width) {
        return;
    }
    switch (ctx.cfg.bar.position) {
        .top => {
            if (pointer_y < self.output.y or pointer_y > self.output.y + self.height(true)) {
                return;
            }
        },
        .bottom => {
            if (pointer_y < self.output.y + self.output.height - self.height(true)
                or pointer_y > self.output.y + self.output.height) {
                return;
            }
        }
    }

    var action: ?binding.Action = null;
    defer if (action) |a| {
        seat.append_action(a);
    };

    var x = utils.logical2physics(i32, pointer_x - self.output.x, self.scale);
    if (ctx.cfg.bar.tags) |area| {
        if (x <= self.static_component_width()) {
            for (0.., self.static_splits.items) |i, split| {
                if (x <= split) {
                    const tag = @as(u32, @intCast(1)) << @as(u5, @intCast(i));
                    const callback_action = area.click.getter.get(seat.button) orelse return;
                    action = switch (callback_action) {
                        .set_window_tag => .{ .set_window_tag = .{ .tag = .{ .tag = tag } } },
                        .toggle_window_tag => .{ .toggle_window_tag = .{ .mask = tag } },
                        .set_output_tag => .{ .set_output_tag = .{ .tag = .{ .tag = tag } } },
                        .toggle_output_tag => .{ .toggle_output_tag = .{ .mask = tag } },
                        else => callback_action,
                    };
                    break;
                }
            }
            return;
        }
    }

    x -= self.static_component_width();
    inline for (0.., &[_]types.BarArea { .mode, .layout, .title }) |i, area_type| {
        if (ctx.cfg.bar.get(area_type)) |area| {
            if (x <= self.dynamic_splits.items[i]) {
                action = area.click.getter.get(seat.button) orelse return;
                return;
            }
        }
    }

    if (ctx.cfg.bar.status) |area| {
        if (x > self.dynamic_splits.getLast()) {
            action = area.click.getter.get(seat.button) orelse return;
        }
    }
}


pub fn toggle(self: *Self) void {
    log.debug("<{*}> toggle: {}", .{ self, !self.hidden });

    self.hidden = !self.hidden;
    if (self.hidden) {
        self.hide();
    } else {
        self.show() catch |err| {
            self.hidden = true;
            log.err("<{*}> failed to show: {}", .{ self, err });
            return;
        };
    }
}


pub fn damage(self: *Self, @"type": enum { all, tags, dynamic, layout, mode, title, status }) void {
    log.debug("<{*}> damage {s}", .{ self, @tagName(@"type") });

    switch (@"type") {
        .all => {
            self.background_damaged = true;
        },
        .tags => {
            self.static_component_damaged = true;
            self.dynamic_component_damaged = true;
        },
        else => self.dynamic_component_damaged = true,
    }
}


pub fn render(self: *Self) void {
    if (self.hidden) return;

    log.debug("<{*}> rendering", .{ self });

    if (self.static_component_damaged or self.background_damaged) {
        defer self.static_component_damaged = false;

        self.render_static_component();
    }

    if (self.dynamic_component_damaged or self.background_damaged) {
        defer self.dynamic_component_damaged = false;

        self.render_dynamic_component();
    }

    if (self.background_damaged) {
        defer self.background_damaged = false;

        self.render_background();
    }
}


inline fn static_component_width(self: *Self) i32 {
    return self.static_splits.getLastOrNull() orelse 0;
}


inline fn get_pad(self: *const Self) u16 {
    return @intCast(self.font.height());
}


fn render_background(self: *Self) void {
    log.debug("<{*}> rendering background", .{ self });

    const h = self.height(false);
    const logical_h = self.height(true);

    self.shell_surface.sync_next_commit();
    if (comptime build_options.background_enabled) {
        self.shell_surface.place(.{ .above = self.output.background.shell_surface.rwm_shell_surface_node });
    } else {
        self.shell_surface.place(.bottom);
    }
    self.shell_surface.set_position(self.output.x, self.output.y + switch (ctx.cfg.bar.position) {
        .top => 0,
        .bottom => self.output.height - logical_h,
    });

    const buffer = (
        if (ctx.cfg.bar.empty()) blk: {
            const rgba = utils.rgba(ctx.cfg.bar.scheme.normal.bg);
            break :blk ctx.wp_single_pixel_buffer_manager.createU32RgbaBuffer(
                rgba.r,
                rgba.g,
                rgba.b,
                rgba.a
            );
        }
        else ctx.wp_single_pixel_buffer_manager.createU32RgbaBuffer(0, 0, 0, 0)
    ) catch |err| {
        log.err("<{*}> create buffer failed: {}", .{ self, err });
        return;
    };
    defer buffer.destroy();

    self.static_component.manage(0, 0);
    self.dynamic_component.manage(
        utils.physics2logical(i32, self.static_component_width(), self.scale),
        0,
    );

    self.wl_surface.attach(buffer, 0, 0);
    self.wl_surface.damageBuffer(
        0, 0,
        utils.logical2physics(i32, self.output.width, self.scale), h,
    );
    self.wp_viewport.setDestination(self.output.width, logical_h);
    self.wl_surface.commit();
}


fn draw_box(
    self: *const Self,
    buffer: *render_.Buffer,
    inner: bool,
    pos: enum { top, bottom },
    c: *const pixman.Color,
    x: i16,
    y: i16,
) void {
    const h: u16 = @intCast(self.height(false));
    const box_size: u16 = @intCast(@divFloor(h, 6) + 2);
    const box_offset: i16 = @intCast(@divFloor(h, 9));
    var box = [_]pixman.Rectangle16 {
        .{
            .x = x + box_offset,
            .y = switch (pos) {
                .top => y + 1,
                .bottom => @intCast(h - box_size - 1),
            },
            .width = box_size,
            .height = box_size,
        }
    };
    if (inner) {
        box[0].x += 1;
        box[0].y += 1;
        box[0].width -= 2;
        box[0].height -= 2;
    }
    _ = pixman.Image.fillRectangles(
        .src,
        buffer.image,
        c,
        1,
        &box,
    );
}


fn render_static_component(self: *Self) void {
    log.debug("<{*}> rendering static component", .{ self });

    self.static_splits.clearRetainingCapacity();

    const area = ctx.cfg.bar.tags orelse {
        self.static_splits.append(ctx.gpa, 0) catch |err| {
            log.err("<{*}> append failed: {}", .{ self, err });
        };
        return;
    };

    self.static_splits.ensureTotalCapacity(ctx.gpa, area.tags.len) catch |err| {
        log.err("<{*}> ensure static_splits total capacity to {} failed: {}", .{ self, area.tags.len, err });
        return;
    };

    var texts: std.ArrayList(*const fcft.TextRun) = .empty;
    texts.ensureTotalCapacity(ctx.gpa, area.tags.len) catch |err| {
        log.err("<{*}> initCapacity for texts while render_static_component failed: {}", .{ self, err });
        return;
    };
    defer texts.deinit(ctx.gpa);

    for (area.tags) |label| {
        const utf8 = render_.utils.to_utf8(ctx.gpa, label) catch |err| {
            log.warn("<{*}> to_utf8 failed: {}", .{ self, err });
            return;
        };
        defer ctx.gpa.free(utf8);

        texts.appendBounded(
            self.font.rasterize_text_run(utf8) orelse return
        ) catch unreachable;
    }

    defer {
        for (texts.items) |text| {
            text.destroy();
        }
    }

    const pad = self.get_pad();
    const w: u16 = blk: {
        var width: u16 = 0;
        for (texts.items) |text| {
            width += @intCast(render_.utils.text_width(text)+pad);
            self.static_splits.appendBounded(@intCast(width)) catch unreachable;
        }
        break :blk width;
    };
    const h: u16 = @intCast(self.height(false));

    const buffer = self.next_buffer(.static, w, h) orelse return;

    const windows_tag: u32 = self.output.occupied_tags();
    const urgent_tag: u32 = self.output.urgent_tags();
    const focused_window = ctx.focused_window();

    const scheme = ctx.cfg.bar.get_scheme(.tags);
    const select_fg = render_.utils.color(scheme.select.fg);
    const select_bg = render_.utils.color(scheme.select.bg);
    const normal_fg = render_.utils.color(scheme.normal.fg);
    const normal_bg = render_.utils.color(scheme.normal.bg);
    // solarized yellow warning colors unless configured
    const urgent_scheme: @TypeOf(scheme.normal) = scheme.urgent orelse .{ .fg = 0x002b36ff, .bg = 0xb58900ff };
    const urgent_fg = render_.utils.color(urgent_scheme.fg);
    const urgent_bg = render_.utils.color(urgent_scheme.bg);

    const bg_rect = [_]pixman.Rectangle16 {
        .{
            .x = 0,
            .y = 0,
            .width = w,
            .height = h,
        },
    };
    _ = pixman.Image.fillRectangles(.src, buffer.image, &normal_bg, 1, &bg_rect);

    var x: i16 = 0;
    const y: i16 = 0;
    for (0.., texts.items) |i, text| {
        const tag: u32 = @as(u32, @intCast(1)) << @as(u5, @intCast(i));

        const is_focused = self.output.tag & tag != 0;
        // urgency outranks focus: an urgent tag stays loud until visited
        const is_urgent = urgent_tag & tag != 0;

        const fg = if (is_urgent) &urgent_fg else if (is_focused) &select_fg else &normal_fg;
        const bg = if (is_urgent) &urgent_bg else if (is_focused) &select_bg else &normal_bg;

        const tag_width: u16 = @intCast(render_.utils.text_width(text)+pad);
        defer x += @intCast(tag_width);

        if (is_focused or is_urgent) {
            const tag_rect = [_]pixman.Rectangle16 {
                .{
                    .x = x,
                    .y = y,
                    .width = tag_width,
                    .height = h,
                }
            };
            _ = pixman.Image.fillRectangles(
                .src,
                buffer.image,
                bg,
                1,
                &tag_rect,
            );
        }

        if (windows_tag & tag != 0) {
            self.draw_box(
                buffer,
                false,
                .top,
                fg,
                x,
                y,
            );

            if (focused_window == null or focused_window.?.tag & tag == 0) {
                self.draw_box(
                    buffer,
                    true,
                    .top,
                    bg,
                    x,
                    y,
                );
            }
        }

        _ = self.font.render_text(
            buffer,
            text,
            fg,
            x+@as(i16, @intCast(@divFloor(pad, 2))),
            y,
        );
    }

    self.static_component.render(buffer, self.scale);
}


fn render_dynamic_component(self: *Self) void {
    log.debug("<{*}> rendering dynamic component", .{ self });

    self.dynamic_splits.clearRetainingCapacity();

    const pad = self.get_pad();
    const w: u16 = @intCast(
        utils.logical2physics(i32, self.output.width, self.scale)-self.static_component_width()
    );
    const h: u16 = @intCast(self.height(false));

    const buffer = self.next_buffer(.dynamic, w, h) orelse return;

    var bg_rect = [_]pixman.Rectangle16 {
        .{
            .x = 0,
            .y = 0,
            .width = w,
            .height = h,
        },
    };

    var x: i16 = 0;
    const y: i16 = 0;

    if (ctx.cfg.bar.mode) |area| draw_mode: {
        const tag = area.tag(ctx.mode) orelse ctx.mode;
        if (tag.len == 0) break :draw_mode;

        const color = ctx.cfg.bar.get_scheme(.{ .mode = ctx.mode }).normal;
        const fg = render_.utils.color(color.fg);
        const bg = render_.utils.color(color.bg);

        _ = pixman.Image.fillRectangles(.src, buffer.image, &bg, 1, &bg_rect);

        x += self.font.render_str(
            buffer,
            tag,
            &fg,
            x+@as(i16, @intCast(@divFloor(pad, 2))),
            y,
        ) + @as(i16, @intCast(pad));
    }
    self.dynamic_splits.appendBounded(x) catch unreachable;

    bg_rect[0].x = x;
    bg_rect[0].width = w - @as(u16, @intCast(x));

    if (ctx.cfg.bar.layout) |area| draw_layout: {
        var layout_tag_buffer: [32]u8 = undefined;
        const layout_tag = blk: {
            const tag = switch (self.output.current_layout()) {
                .tile => |tile| area.tags.tile.getter.get(tile.master_location),
                .grid => |grid| area.tags.grid.getter.get(grid.direction),
                .monocle => area.tags.monocle,
                .deck => |deck| area.tags.deck.getter.get(deck.master_location),
                .scroller => area.tags.scroller,
                .centered_master => |centered_master| area.tags.centered_master.getter.get(centered_master.direction),
                .float => area.tags.float,
            };
            const left = mem.indexOf(u8, tag, "{{") orelse break :blk tag;
            const right = mem.lastIndexOf(u8, tag, "}}") orelse break :blk tag;

            if (left < right) {
                var num: usize = 0;
                var it = ctx.windows.safeIterator(.forward);
                while (it.next()) |window| {
                    if (window.is_visible_in(self.output) and !window.floating) {
                        num += 1;
                    }
                }

                var buf: [8]u8 = undefined;
                const str =
                    if (right-left == 2 or num > 0) fmt.bufPrint(&buf, "{}", .{ num }) catch break :blk tag
                    else tag[left+2..right];

                const n = mem.replace(
                    u8,
                    tag,
                    tag[left..right+2],
                    str,
                    &layout_tag_buffer,
                );
                break :blk layout_tag_buffer[0..tag.len + str.len*n - (right-left+2)*n];
            } else break :blk tag;
        };
        if (layout_tag.len == 0) break :draw_layout;

        const color = ctx.cfg.bar.get_scheme(.{ .layout = self.output.current_layout() }).normal;
        const fg = render_.utils.color(color.fg);
        const bg = render_.utils.color(color.bg);

        _ = pixman.Image.fillRectangles(.src, buffer.image, &bg, 1, &bg_rect);

        x += self.font.render_str(
            buffer,
            layout_tag,
            &fg,
            x+@as(i16, @intCast(@divFloor(pad, 2))),
            y,
        ) + @as(i16, @intCast(pad));
    }
    self.dynamic_splits.appendBounded(x) catch unreachable;

    bg_rect[0].x = x;
    bg_rect[0].width = w - @as(u16, @intCast(x));

    const title_start = x;
    if (ctx.cfg.bar.title) |_| draw_title: {
        const scheme = ctx.cfg.bar.get_scheme(.title);
        const normal_fg = render_.utils.color(scheme.normal.fg);
        const normal_bg = render_.utils.color(scheme.normal.bg);
        const select_fg = render_.utils.color(scheme.select.fg);
        const select_bg = render_.utils.color(scheme.select.bg);

        const top = ctx.focus_top_in(self.output, false);
        if (top == null) {
            _ = pixman.Image.fillRectangles(
                .src,
                buffer.image,
                &normal_bg,
                1,
                &bg_rect
            );
            break :draw_title;
        }

        const window = top.?;
        var fg: *const pixman.Color = undefined;
        var bg: *const pixman.Color = undefined;
        if (self.output == ctx.current_output) {
            fg = &select_fg;
            bg = &select_bg;
        } else {
            fg = &normal_fg;
            bg = &normal_bg;
        }
        _ = pixman.Image.fillRectangles(.src, buffer.image, bg, 1, &bg_rect);

        if (window.sticky) {
            self.draw_box(buffer, false, .top, fg, x, y);
        }

        if (window.floating) {
            self.draw_box(
                buffer,
                false,
                if (window.sticky) .bottom else .top,
                fg,
                x,
                y,
            );

            self.draw_box(
                buffer,
                true,
                if (window.sticky) .bottom else .top,
                bg,
                x,
                y,
            );
        }

        x += self.font.render_str(
            buffer,
            window.title orelse "???",
            fg,
            x+@as(i16, @intCast(@divFloor(pad, 2))),
            y,
        ) + @as(i16, @intCast(pad));
    } else {
        const bg = render_.utils.color(ctx.cfg.bar.scheme.normal.bg);
        _ = pixman.Image.fillRectangles(
            .src,
            buffer.image,
            &bg,
            1,
            &bg_rect
        );
    }
    self.dynamic_splits.appendBounded(@intCast(w)) catch unreachable;

    if (ctx.cfg.bar.status) |area| draw_status: {
        const status_text: []const u8 = mem.trimEnd(
            u8,
            switch (area.data) {
                .text => |text| text,
                else => mem.span(@as([*:0]const u8, @ptrCast(&status_buffer))),
            },
            "\n ",
        );
        if (status_text.len == 0) break :draw_status;

        const color = ctx.cfg.bar.get_scheme(.status).normal;
        const fg = render_.utils.color(color.fg);
        const bg = render_.utils.color(color.bg);

        status_block: {
            var texts: std.ArrayList(struct { pixman.Color, *const fcft.TextRun }) = .empty;
            defer {
                for (texts.items) |item| {
                    item[1].destroy();
                }
                texts.deinit(ctx.gpa);
            }

            var i: usize = 0;
            var c = fg;
            var it = color_pattern.iterator(status_text);
            var match = it.next();
            while (i < status_text.len) {
                if (match == null or i < match.?.start) {
                    const end = if (match) |m| m.start else status_text.len;
                    defer i = end;

                    const utf8 = render_.utils.to_utf8(ctx.gpa, status_text[i..end]) catch |err| {
                        log.warn("<{*}> to_utf8 failed: {}", .{ self, err });
                        break :status_block;
                    };
                    defer ctx.gpa.free(utf8);

                    texts.append(
                        ctx.gpa,
                        .{
                            c,
                            self.font.rasterize_text_run(utf8) orelse break :status_block
                        },
                    ) catch |err| {
                        log.err("<{*}> append failed: {}", .{ self, err });
                        break :status_block;
                    };
                } else if (i == match.?.start) blk: {
                    defer {
                        i += match.?.slice.len;
                        match = it.next();
                    }

                    if (match.?.slice.len == 3) {
                        c = fg;
                    } else {
                        const hex = match.?.slice[2..];
                        c = render_.utils.color(fmt.parseInt(u32, hex, 16) catch |err| {
                            log.err("parseInt failed: {}", .{ err });
                            break :blk;
                        });
                    }
                } else unreachable;
            }

            var width: u32 = 0;
            for (texts.items) |item| {
                _, const text = item;
                width += render_.utils.text_width(text);
            }
            x = @max(
                title_start,
                @as(i16, @intCast(w -| @as(u16, @intCast(width)) -| pad))
            );

            self.dynamic_splits.items[self.dynamic_splits.items.len-1] = x;

            bg_rect[0].x = x;
            bg_rect[0].width = w - @as(u16, @intCast(x));
            _ = pixman.Image.fillRectangles(.src, buffer.image, &bg, 1, &bg_rect);

            x += @as(i16, @intCast(@divFloor(pad, 2)));
            for (texts.items) |item| {
                const cc, const text = item;
                x += self.font.render_text(buffer, text, &cc, x, y);
            }
        }
    }

    self.dynamic_component.render(buffer, self.scale);
}


fn show(self: *Self) !void {
    std.debug.assert(!self.hidden);

    log.debug("<{*}> show", .{ self });

    const wl_surface = try ctx.wl_compositor.createSurface();
    errdefer wl_surface.destroy();

    try self.shell_surface.init(wl_surface, .{ .bar = self });
    errdefer self.shell_surface.deinit();

    const wp_viewport = try ctx.wp_viewporter.getViewport(wl_surface);
    errdefer wp_viewport.destroy();

    const wp_fractional_scale = try ctx.wp_fractional_scale_manager.getFractionalScale(wl_surface);
    errdefer wp_fractional_scale.destroy();

    try self.static_component.init(wl_surface);
    errdefer self.static_component.deinit();

    try self.dynamic_component.init(wl_surface);
    errdefer self.dynamic_component.deinit();

    self.wl_surface = wl_surface;
    self.wp_viewport = wp_viewport;
    self.wp_fractional_scale = wp_fractional_scale;
    wp_fractional_scale.setListener(*Self, wp_fractional_scale_listener, self);
    self.damage(.all);

    if (ctx.cfg.bar.status) |area| {
        if (area.data != .text and !ctx.is_listening_status()) {
            ctx.start_listening_status();
        }
    }
}


fn hide(self: *Self) void {
    std.debug.assert(self.hidden);

    log.debug("<{*}> hide", .{ self });

    self.static_component.deinit();
    self.static_component = undefined;

    self.dynamic_component.deinit();
    self.dynamic_component = undefined;

    self.wp_viewport.destroy();
    self.wp_viewport = undefined;

    self.wp_fractional_scale.destroy();
    self.wp_fractional_scale = undefined;

    self.shell_surface.deinit();
    self.shell_surface = undefined;

    self.wl_surface.destroy();
    self.wl_surface = undefined;
}


fn wp_fractional_scale_listener(wp_fractional_scale: *wp.FractionalScaleV1, event: wp.FractionalScaleV1.Event, bar: *Self) void {
    std.debug.assert(wp_fractional_scale == bar.wp_fractional_scale);

    switch (event) {
        .preferred_scale => |data| {
            log.debug("<{*}> preferred_scale: {}", .{ bar, data.scale });

            if (data.scale != bar.scale) {
                bar.scale = data.scale;
                bar.reload_font();
                bar.damage(.all);
            }
        }
    }
}


fn next_buffer(self: *Self, @"type": enum { static, dynamic }, width: i32, height_: i32) ?*render_.Buffer {
    log.debug("<{*}> get buffer for {s}", .{ self, @tagName(@"type") });

    const component =  &switch (@"type") {
        .static => self.static_component,
        .dynamic => self.dynamic_component,
    };
    const buffer = component.next_buffer() orelse {
        log.warn("<{*}> next_buffer return null", .{ self });
        return null;
    };
    buffer.init(width, height_) catch |err| {
        log.err("<{*}> init buffer for {s} rendering failed: {}", .{ self, @tagName(@"type"), err });
        return null;
    };
    return buffer;
}
