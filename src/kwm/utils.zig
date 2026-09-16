// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Io = std.Io;
const fmt = std.fmt;
const mem = std.mem;
const process = std.process;

const mvzr = @import("mvzr");
const wayland = @import("wayland");
const wl = wayland.client.wl;

const types = @import("types.zig");

const env_pattern = mvzr.compile("\\$\\{.*\\}").?;


pub inline fn logical2physics(T: type, logical: T, scale: u32) T {
    return @intCast(@divFloor(
        logical*@as(T, @intCast(scale)),
        120
    ));
}


pub inline fn physics2logical(T: type, physics: T, scale: u32) T {
    return @intCast(@divFloor(
        physics*120,
        @as(T, @intCast(scale))
    ));
}


pub fn cycle_list(
    comptime T: type,
    wrap_around: bool,
    head: *wl.list.Link,
    node: *wl.list.Link,
    tag: @EnumLiteral(),
) ?*T {
    var next_node: ?*wl.list.Link = @field(node, @tagName(tag));
    if (next_node) |link| {
        if (link == head) {
            if (wrap_around) {
                next_node = @field(head, @tagName(tag));
            } else return null;
        }
    }

    return @fieldParentPtr("link", next_node.?);
}


// if shift failed, return 0
pub fn shift_tag(base: u32, mask: u32, len: usize, direction: types.Direction) u32 {
    if (base == 0) return 0;

    if (mask == 0) {
        var new = base << @as(
            u5,
            @intCast(
                switch (direction) {
                    .forward => 1,
                    .reverse => len-1,
                }
            )
        );
        new |= new >> @as(u5, @intCast(len));
        new &= (@as(u32, 1) << @as(u5, @intCast(len))) - 1;
        return new;
    }

    var new: u32 = 0;
    var i: i6, const step: i2 = switch (direction) {
        .forward => .{ 0, 1 },
        .reverse => .{ @intCast(len-1), -1 },
    };
    while (i >= 0 and i < len) : (i += step) {
        if (base & (@as(u32, 1) << @as(u5, @intCast(i))) == 0) continue;

        var j: i6 = @mod(i+step, @as(i6, @intCast(len)));
        while (j != i) : (j = @mod(j+step, @as(i6, @intCast(len)))) {
            const bit = (@as(u32, 1) << @as(u5, @intCast(j)));
            if (mask & bit != 0 and new & bit == 0) {
                new |= bit;
                break;
            }
        }
    }
    return new;
}


pub fn rgba(color: u32) struct { r: u32, g: u32, b: u32, a: u32 } {
    return .{
        .r = @as(u32, (color >> 24) & 0xFF) * (0xFFFF_FFFF / 0xFF),
        .g = @as(u32, (color >> 16) & 0xFF) * (0xFFFF_FFFF / 0xFF),
        .b = @as(u32, (color >> 8) & 0xFF) * (0xFFFF_FFFF / 0xFF),
        .a = @as(u32, (color >> 0) & 0xFF) * (0xFFFF_FFFF / 0xFF),
    };
}


// https://codeberg.org/dwl/dwl-patches/src/branch/main/patches/swallow/swallow.patch
pub fn parent_pid(io: Io, pid: i32) i32 {
    var path_buf: [32]u8 = undefined;
    const path = fmt.bufPrint(
        &path_buf,
        "/proc/{}/stat",
        .{ @as(u32, @intCast(pid)) },
    ) catch return 0;

    var buffer: [256]u8 = undefined;
    const contents = Io.Dir.cwd().readFile(io, path, &buffer) catch return 0;

    var it = mem.splitAny(u8, contents, " ");
    _ = it.next(); // pid
    _ = it.next(); // process name
    _ = it.next(); // process state
    const ppid_str = it.next() orelse return 0;

    return fmt.parseInt(i32, ppid_str, 10) catch return 0;
}


extern fn wl_proxy_set_user_data(proxy: *wl.Proxy, data: ?*anyopaque) void;
pub fn set_user_data(comptime T: type, object: *T, comptime DataT: type, data: DataT) void {
    const proxy: *wl.Proxy = @ptrCast(object);
    wl_proxy_set_user_data(proxy, @ptrFromInt(@intFromPtr(data)));
}


pub fn expand_env_str(
    ctx: struct {
        gpa: mem.Allocator,
        env: *const process.Environ.Map,
    },
    str: []const u8
) !std.ArrayList(u8) {
    var result: std.ArrayList(u8) = .empty;

    var i: usize = 0;
    var it = env_pattern.iterator(str);
    var match = it.next();
    while (i < str.len) {
        var part: []const u8 = undefined;
        if (match == null or i < match.?.start) {
            const end = if (match) |m| m.start else str.len;
            defer i = end;

            part = str[i..end];
        } else if (i == match.?.start) {
            defer {
                i += match.?.slice.len;
                match = it.next();
            }

            part = ctx.env.get(match.?.slice[2..match.?.slice.len-1]) orelse match.?.slice;
        } else unreachable;
        try result.appendSlice(ctx.gpa, part);
    }

    return result;
}
