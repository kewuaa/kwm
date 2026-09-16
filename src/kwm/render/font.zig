// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const Self = @This();

const std = @import("std");
const fmt = std.fmt;
const unicode = std.unicode;
const log = std.log.scoped(.font);

const fcft = @import("fcft");
const pixman = @import("pixman");

const render_utils = @import("utils.zig");
const Buffer = @import("buffer.zig");
const Context = @import("../context.zig");

const ctx = Context.get();


font: *fcft.Font,


pub fn init(self: *Self, font_name: []const u8, scale: u32) !void {
    log.debug("<{*}> init, font: {s}, scale: {}", .{ self, font_name, scale });

    const fcft_font = try load_font(font_name, scale);
    errdefer fcft_font.destroy();

    self.* = .{
        .font = fcft_font,
    };
}


pub fn deinit(self: *Self) void {
    log.debug("<{*}> deinit", .{ self });

    self.font.destroy();
}


pub inline fn height(self: *const Self) c_int {
    return self.font.height;
}


pub inline fn rasterize_text_run(self: *const Self, text: []const u32) ?*const fcft.TextRun {
    return self.font.rasterizeTextRunUtf32(text, .default) catch |err| {
        log.err("<{*}> rasterize text run failed: {}", .{ self, err });
        return null;
    };
}


pub fn reload(self: *Self, font_name: []const u8, scale: u32) void {
    log.debug("<{*}> reloading", .{ self });

    var new_font: Self = undefined;
    new_font.init(font_name, scale) catch |err| {
        log.err("<{*}> reload (font: {s}, scale: {}) failed: {}", .{ self, font_name, scale, err });
        return;
    };

    self.deinit();
    self.* = new_font;
}


pub fn render_text(
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


pub fn render_str(
    self: *const Self,
    buffer: *Buffer,
    str: []const u8,
    c: *const pixman.Color,
    x: i32,
    y: i32,
) i16 {
    const utf8 = render_utils.to_utf8(ctx.gpa, str) catch return 0;
    defer ctx.gpa.free(utf8);

    const text = self.rasterize_text_run(utf8) orelse return 0;
    defer text.destroy();

    return self.render_text(buffer, text, c, x, y);
}


fn load_font(font_name: []const u8, scale: u32) !*fcft.Font {
    const backup_font = "monospace:size=10";
    const name = try ctx.gpa.dupeZ(u8, font_name);
    defer ctx.gpa.free(name);
    var fonts = [_][*:0]const u8 { name.ptr, backup_font };

    var buffer: [12]u8 = undefined;
    const attr = try fmt.bufPrintZ(&buffer, "dpi={}", .{ @divFloor(scale*96, 120) });

    return fcft.Font.fromName(&fonts, @ptrCast(attr)) catch |err| {
        log.err("load font `{s}` and backup font `{s}` with attr: {s} failed: {}", .{ font_name, backup_font, attr, err });
        return err;
    };
}
