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

const types = @import("types.zig");
const Config = @import("config");

const utils = @import("utils.zig");
const binding = @import("binding.zig");
const Context = @import("context.zig");
const Seat = @import("seat.zig");
const Output = @import("output.zig");
const ShellSurface = @import("shell_surface.zig");
const Buffer = @import("bar/buffer.zig");
const Component = @import("bar/component.zig");

const color_pattern = mvzr.compile("\\^#([0-9a-zA-Z]{8}|!)").?;
pub var status_buffer = [1]u8 { 0 } ** 256;

font: *fcft.Font,

wl_surface: *wl.Surface = undefined,
shell_surface: ShellSurface = undefined,
wp_viewport: *wp.Viewport = undefined,
wp_fractional_scale: *wp.FractionalScaleV1 = undefined,
static_component: Component = undefined,
dynamic_component: Component = undefined,

output: *Output,

scale: u32,
background_damaged: bool = true,
hidden: bool,

dynamic_splits_buffer: [@typeInfo(types.BarArea).@"enum".fields.len-2]i32 = undefined,
static_splits: std.ArrayList(i32) = .empty,
dynamic_splits: std.ArrayList(i32) = undefined,


pub fn init(self: *Self, output: *Output) !void {
    log.debug("<{*}> init", .{ self });

    const config = Config.get();

    const scale = 120;
    const font = load_font(scale) catch unreachable;
    errdefer font.destroy();

    self.* = .{
        .font = font,
        .output = output,
        .scale = scale,
        .hidden = !config.bar.show_default,
    };

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
    self.font.destroy();

    self.static_splits.deinit(utils.allocator);
}


pub fn reload_font(self: *Self) void {
    log.debug("<{*}> reload font", .{ self });

    const font = load_font(self.scale) catch return;
    self.font.destroy();
    self.font = font;
}


pub inline fn height(self: *const Self, logical: bool) i32 {
    return if (logical) utils.physics2logical(
        i32,
        self.font.height,
        self.scale,
    ) else self.font.height;
}


pub fn handle_click(self: *Self, seat: *Seat) void {
    log.debug("<{*}> handle click by {*}", .{ self, seat });

    const config = Config.get();

    const pointer_x = seat.pointer_position.x;
    const pointer_y = seat.pointer_position.y;

    // ensure in range
    if (pointer_x < self.output.x or pointer_x > self.output.x + self.output.width) {
        return;
    }
    switch (config.bar.position) {
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
    if (x <= self.static_component_width()) {
        for (0.., self.static_splits.items) |i, split| {
            if (x <= split) {
                const tag = @as(u32, @intCast(1)) << @as(u5, @intCast(i));
                const callback_action = switch (config.bar.click.getter.get(.tags).getter.get(seat.button)) {
                    .none => return,
                    .action => |a| a,
                };
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

    x -= self.static_component_width();
    for (&[_]types.BarArea { .mode, .layout, .title }, self.dynamic_splits.items) |area, split| {
        if (x <= split) {
            action = switch (config.bar.click.getter.get(area).getter.get(seat.button)) {
                .none => return,
                .action => |a| a,
            };
            return;
        }
    }

    action = switch (config.bar.click.getter.get(.status).getter.get(seat.button)) {
        .none => return,
        .action => |a| a,
    };
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
            self.static_component.damaged = true;
            self.dynamic_component.damaged = true;
        },
        else => self.dynamic_component.damaged = true,
    }
}


pub fn render(self: *Self) void {
    if (self.hidden) return;

    log.debug("<{*}> rendering", .{ self });

    if (self.static_component.damaged or self.background_damaged) {
        defer self.static_component.damaged = false;

        self.render_static_component();
    }

    if (self.dynamic_component.damaged or self.background_damaged) {
        defer self.dynamic_component.damaged = false;

        self.render_dynamic_component();
    }

    if (self.background_damaged) {
        defer self.background_damaged = false;

        self.render_background();
    }
}


inline fn static_component_width(self: *Self) i32 {
    const config = Config.get();

    std.debug.assert(self.static_splits.items.len == config.tags.len);

    return self.static_splits.getLast();
}


inline fn get_pad(self: *const Self) u16 {
    return @intCast(self.font.height);
}


fn render_background(self: *Self) void {
    log.debug("<{*}> rendering background", .{ self });

    const config = Config.get();
    const context = Context.get();
    const h = self.height(false);
    const logical_h = self.height(true);

    self.shell_surface.sync_next_commit();
    if (comptime build_options.background_enabled) {
        self.shell_surface.place(.{ .above = self.output.background.shell_surface.rwm_shell_surface_node });
    } else {
        self.shell_surface.place(.bottom);
    }
    self.shell_surface.set_position(self.output.x, self.output.y + switch (config.bar.position) {
        .top => 0,
        .bottom => self.output.height - logical_h,
    });

    const rgba = utils.rgba(config.bar_normal_bg orelse config.bar.color.normal.bg);
    const buffer = context.wp_single_pixel_buffer_manager.createU32RgbaBuffer(rgba.r, rgba.g, rgba.b, rgba.a) catch |err| {
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


fn render_text(
    self: *const Self,
    buffer: *Buffer,
    text: *const fcft.TextRun,
    c: *const pixman.Color,
    x: i32,
    y: i32,
) i16 {
    const image = pixman.Image.createSolidFill(c) orelse {
        log.err("createSolidFill failed", .{});
        return 0;
    };
    defer _ = image.unref();

    var offset: i32 = 0;
    for (0..text.count) |i| {
        const glyph = text.glyphs[i];
        offset += @intCast(glyph.x);
        pixman.Image.composite32(
            .over,
            image,
            glyph.pix,
            buffer.image,
            0,
            0,
            0,
            0,
            x + offset,
            y + self.font.ascent - glyph.y,
            glyph.width,
            glyph.height,
        );
        offset += @intCast(glyph.advance.x - glyph.x);
        if (offset >= buffer.width) break;
    }
    return @intCast(offset);
}


fn render_str(
    self: *const Self,
    buffer: *Buffer,
    str: []const u8,
    c: *const pixman.Color,
    x: i32,
    y: i32,
) i16 {
    if (to_utf8(str)) |utf8| {
        defer utils.allocator.free(utf8);

        const text = self.font.rasterizeTextRunUtf32(utf8, .default) catch |err| {
            log.err("createU32RgbaBuffer failed: {}", .{ err });
            return 0;
        };
        defer text.destroy();

        return self.render_text(buffer, text, c, x, y);
    } return 0;
}


fn draw_box(
    self: *const Self,
    buffer: *Buffer,
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

    const config = Config.get();
    const context = Context.get();
    self.static_splits.clearRetainingCapacity();
    self.static_splits.ensureTotalCapacity(utils.allocator, config.tags.len) catch |err| {
        log.err("<{*}> ensure static_splits total capacity to {} failed: {}", .{ self, config.tags.len, err });
        return;
    };

    var texts: std.ArrayList(*const fcft.TextRun) = .empty;
    texts.ensureTotalCapacity(utils.allocator, config.tags.len) catch |err| {
        log.err("<{*}> initCapacity for texts while render_static_component failed: {}", .{ self, err });
        return;
    };
    defer texts.deinit(utils.allocator);

    for (config.tags) |label| {
        if (to_utf8(label)) |utf8| {
            texts.appendBounded(
                self.font.rasterizeTextRunUtf32(utf8, .default) catch |err| {
                    log.err("rasterizeTextRunUtf32 failed: {}", .{ err });
                    return;
                }
            ) catch unreachable;
            utils.allocator.free(utf8);
        } else {
            log.warn("to_utf8 failed", .{});
            return;
        }
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
            width += @intCast(text_width(text)+pad);
            self.static_splits.appendBounded(@intCast(width)) catch unreachable;
        }
        break :blk width;
    };
    const h: u16 = @intCast(self.height(false));

    const buffer = self.next_buffer(.static, w, h) orelse return;

    var windows_tag: u32 = 0;
    {
        var it = context.windows.safeIterator(.forward);
        while (it.next()) |window| {
            if (window.output == self.output) {
                windows_tag |= window.tag;
            }
        }
    }
    const focused_window = context.focused_window();

    const select_fg = color(config.bar_select_fg orelse config.bar.color.select.fg);
    const select_bg = color(config.bar_select_bg orelse config.bar.color.select.bg);
    const normal_fg = color(config.bar_normal_fg orelse config.bar.color.normal.fg);
    const transparent = mem.zeroes(pixman.Color);

    const bg_rect = [_]pixman.Rectangle16 {
        .{
            .x = 0,
            .y = 0,
            .width = w,
            .height = h,
        },
    };
    _ = pixman.Image.fillRectangles(.src, buffer.image, &transparent, 1, &bg_rect);

    var x: i16 = 0;
    const y: i16 = 0;
    for (0.., texts.items) |i, text| {
        const tag: u32 = @as(u32, @intCast(1)) << @as(u5, @intCast(i));

        const is_focused = self.output.tag & tag != 0;

        const tag_width: u16 = @intCast(text_width(text)+pad); 
        defer x += @intCast(tag_width);

        if (is_focused) {
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
                &select_bg,
                1,
                &tag_rect,
            );
        }

        if (windows_tag & tag != 0) {
            self.draw_box(
                buffer,
                false,
                .top,
                if (is_focused) &transparent else &select_bg,
                x,
                y,
            );

            if (focused_window == null or focused_window.?.tag & tag == 0) {
                self.draw_box(
                    buffer,
                    true,
                    .top,
                    if (is_focused) &select_bg else &transparent,
                    x,
                    y,
                );
            }
        }

        _ = self.render_text(
            buffer,
            text,
            if (is_focused) &select_fg else &normal_fg,
            x+@as(i16, @intCast(@divFloor(pad, 2))),
            y,
        );
    }

    self.static_component.render(buffer, self.scale);
}


fn render_dynamic_component(self: *Self) void {
    log.debug("<{*}> rendering dynamic component", .{ self });

    const config = Config.get();
    const context = Context.get();
    self.dynamic_splits.clearRetainingCapacity();

    const normal_fg = color(config.bar_normal_fg orelse config.bar.color.normal.fg);
    const select_bg = color(config.bar_select_bg orelse config.bar.color.select.bg);
    const select_fg = color(config.bar_select_fg orelse config.bar.color.select.fg);
    const transparent = mem.zeroes(pixman.Color);

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
    _ = pixman.Image.fillRectangles(.src, buffer.image, &select_bg, 1, &bg_rect);


    var x: i16 = 0;
    const y: i16 = 0;

    const mode_tag = config.get_mode_tag(context.mode) orelse context.mode;
    if (mode_tag.len > 0) {
        x += self.render_str(
            buffer,
            mode_tag,
            &select_fg,
            x+@as(i16, @intCast(@divFloor(pad, 2))),
            y,
        ) + @as(i16, @intCast(pad));
    }
    self.dynamic_splits.appendBounded(x) catch unreachable;

    bg_rect[0].x = x;
    bg_rect[0].width = w - @as(u16, @intCast(x));
    _ = pixman.Image.fillRectangles(.src, buffer.image, &transparent, 1, &bg_rect);

    var layout_tag_buffer: [32]u8 = undefined;
    const layout_tag = blk: {
        const tag = switch (self.output.current_layout()) {
            .tile => config.layout_tag.tile.getter.get(self.output.layout.tile.master_location),
            .grid => config.layout_tag.grid.getter.get(self.output.layout.grid.direction),
            .monocle => config.layout_tag.monocle,
            .deck => config.layout_tag.deck.getter.get(self.output.layout.deck.master_location),
            .scroller => config.layout_tag.scroller,
            .float => config.layout_tag.float,
        };
        const left = mem.indexOf(u8, tag, "{{") orelse break :blk tag;
        const right = mem.lastIndexOf(u8, tag, "}}") orelse break :blk tag;

        if (left < right) {
            var num: usize = 0;
            var it = context.windows.safeIterator(.forward);
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
    x += self.render_str(
        buffer,
        layout_tag,
        &normal_fg,
        x+@as(i16, @intCast(@divFloor(pad, 2))),
        y,
    ) + @as(i16, @intCast(pad));
    self.dynamic_splits.appendBounded(x) catch unreachable;

    const title_start = x;
    if (context.focus_top_in(self.output, false)) |window| {
        if (self.output == context.current_output) {
            bg_rect[0].x = x;
            bg_rect[0].width = w - @as(u16, @intCast(x));
            _ = pixman.Image.fillRectangles(.src, buffer.image, &select_bg, 1, &bg_rect);
        }

        if (window.sticky) {
            self.draw_box(buffer, false, .top, &select_fg, x, y);
        }

        if (window.floating) {
            self.draw_box(
                buffer,
                false,
                if (window.sticky) .bottom else .top,
                &select_fg,
                x,
                y,
            );

            self.draw_box(
                buffer,
                true,
                if (window.sticky) .bottom else .top,
                &select_bg,
                x,
                y,
            );
        }

        if (window.title) |title| {
            x += self.render_str(
                buffer,
                title,
                &select_fg,
                x+@as(i16, @intCast(@divFloor(pad, 2))),
                y,
            ) + @as(i16, @intCast(pad));
        }
    }

    self.dynamic_splits.appendBounded(@intCast(w)) catch unreachable;
    const status_text: []const u8 = mem.trimEnd(
        u8,
        switch (config.bar.status) {
            .text => |text| text,
            else => mem.span(@as([*:0]const u8, @ptrCast(&status_buffer))),
        },
        "\n ",
    );
    if (status_text.len > 0) status_block: {
        var texts: std.ArrayList(struct { pixman.Color, *const fcft.TextRun }) = .empty;
        defer {
            for (texts.items) |item| {
                item[1].destroy();
            }
            texts.deinit(utils.allocator);
        }

        var i: usize = 0;
        var fg = normal_fg;
        var it = color_pattern.iterator(status_text);
        var match = it.next();
        while (i < status_text.len) {
            if (match == null or i < match.?.start) {
                const end = if (match) |m| m.start else status_text.len;
                defer i = end;

                if (to_utf8(status_text[i..end])) |utf8| {
                    defer utils.allocator.free(utf8);

                    texts.append(
                        utils.allocator,
                        .{
                            fg,
                            self.font.rasterizeTextRunUtf32(
                                utf8,
                                .default,
                            ) catch |err| {
                                log.err("rasterizeTextRunUtf32 failed: {}", .{ err });
                                break :status_block;
                            },
                        },
                    ) catch |err| {
                        log.err("append failed: {}", .{ err });
                        break :status_block;
                    };
                } else {
                    log.warn("to_utf8 failed", .{});
                    break :status_block;
                }
            } else if (i == match.?.start) blk: {
                defer {
                    i += match.?.slice.len;
                    match = it.next();
                }

                if (match.?.slice.len == 3) {
                    fg = normal_fg;
                } else {
                    const hex = match.?.slice[2..];
                    fg = color(fmt.parseInt(u32, hex, 16) catch |err| {
                        log.err("parseInt failed: {}", .{ err });
                        break :blk;
                    });
                }
            } else unreachable;
        }

        var width: u32 = 0;
        for (texts.items) |item| {
            _, const text = item;
            width += text_width(text);
        }
        x = @max(
            title_start,
            @as(i16, @intCast(w -| @as(u16, @intCast(width)) -| pad))
        );

        self.dynamic_splits.items[self.dynamic_splits.items.len-1] = x;

        bg_rect[0].x = x;
        bg_rect[0].width = w - @as(u16, @intCast(x));
        _ = pixman.Image.fillRectangles(.src, buffer.image, &transparent, 1, &bg_rect);

        x += @as(i16, @intCast(@divFloor(pad, 2)));
        for (texts.items) |item| {
            const c, const text = item;
            x += self.render_text(buffer, text, &c, x, y);
        }
    }

    self.dynamic_component.render(buffer, self.scale);
}


fn show(self: *Self) !void {
    std.debug.assert(!self.hidden);

    log.debug("<{*}> show", .{ self });

    const config = Config.get();
    const context = Context.get();

    const wl_surface = try context.wl_compositor.createSurface();
    errdefer wl_surface.destroy();

    try self.shell_surface.init(wl_surface, .{ .bar = self });
    errdefer self.shell_surface.deinit();

    const wp_viewport = try context.wp_viewporter.getViewport(wl_surface);
    errdefer wp_viewport.destroy();

    const wp_fractional_scale = try context.wp_fractional_scale_manager.getFractionalScale(wl_surface);
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

    if (config.bar.status != .text and !context.is_listening_status()) {
        context.start_listening_status();
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


fn next_buffer(self: *Self, @"type": enum { static, dynamic }, width: i32, height_: i32) ?*Buffer {
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


fn load_font(scale: u32) !*fcft.Font {
    const config = Config.get();

    var buffer: [12]u8 = undefined;
    const backup_font = "monospace:size=10";
    var fonts = [_][*:0]const u8 { @ptrCast(config.bar.font.ptr), backup_font };
    const attr = try fmt.bufPrint(&buffer, "dpi={}", .{ @divFloor(scale*96, 120) });
    const font = fcft.Font.fromName(&fonts, @ptrCast(attr)) catch |err| {
        log.err("load font `{s}` and backup font `{s}` with attr: {s} failed: {}", .{ config.bar.font, backup_font, attr, err });
        return err;
    };
    return font;
}


fn color(rgba: u32) pixman.Color {
    const c = utils.rgba(rgba);
    return .{
        .red = @truncate(c.r << 8),
        .green = @truncate(c.g << 8),
        .blue = @truncate(c.b << 8),
        .alpha = @truncate(c.a << 8),
    };
}


fn to_utf8(bytes: []const u8) ?[]u32 {
    const utf8 = unicode.Utf8View.init(bytes) catch return null;
    var iter = utf8.iterator();

    var runes = std.ArrayList(u32).initCapacity(utils.allocator, bytes.len) catch return null;
    var i: usize = 0;
    while (iter.nextCodepoint()) |rune| : (i += 1) {
        runes.appendAssumeCapacity(rune);
    }

    return runes.toOwnedSlice(utils.allocator) catch null;
}


fn text_width(text: *const fcft.TextRun) u32 {
    var width: u32 = 0;
    for (0..text.count) |i| {
        width += @intCast(text.glyphs[i].advance.x);
    }
    return width;
}

fn str_width(font: *fcft.Font, str: []const u8) ?u32 {
    if (to_utf8(str)) |utf8| {
        defer utils.allocator.free(utf8);

        const text = font.rasterizeTextRunUtf32(utf8, .default) catch |err| {
            log.err("rasterizeTextRunUtf32 failed: {}", .{ err });
            return null;
        };
        defer text.destroy();

        return text_width(text);
    }
    return null;
}
