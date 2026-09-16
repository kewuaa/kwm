// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const Self = @This();

const std = @import("std");
const mem = std.mem;
const linux = std.os.linux;
const log = std.log.scoped(.buffer);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const pixman = @import("pixman");

const posix = @import("posix");

const Context = @import("../context.zig");

const ctx = Context.get();


wl_buffer: *wl.Buffer = undefined,
image: *pixman.Image = undefined,
data: []align(4096) u8 = undefined,

width: i32 = undefined,
height: i32 = undefined,
busy: bool = false,
configured: bool = false,


pub fn init(self: *Self, width: i32, height: i32) !void {
    log.debug("<{*}> init", .{ self });

    if (self.configured) {
        if (self.width == width and self.height == height) {
            log.debug("<{*}> same size, skip", .{ self });
            return;
        }
        self.deinit();
    }

    const stride = width * 4;
    const size = stride * height;

    const fd = try posix.memfd_create("kwm-shm", linux.MFD.CLOEXEC);
    defer posix.close(fd);

    try posix.ftruncate(fd, @intCast(size));

    const data = try posix.mmap(
        null,
        @intCast(size),
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0
    );
    errdefer posix.munmap(data);

    const pool = try ctx.wl_shm.createPool(fd, size);
    defer pool.destroy();

    const wl_buffer = try pool.createBuffer(0, width, height, stride, .argb8888);
    wl_buffer.setListener(*Self, wl_buffer_listener, self);
    errdefer wl_buffer.destroy();

    const image = pixman.Image.createBitsNoClear(.a8r8g8b8, width, height, @ptrCast(data.ptr), stride) orelse return error.CreateImageError;

    self.* = .{
        .wl_buffer = wl_buffer,
        .image = image,
        .width = width,
        .height = height,
        .data = data,
    };

    self.configured = true;
}


pub fn deinit(self: *Self) void {
    log.debug("<{*}> deinit", .{ self });

    if (!self.configured) return;

    self.wl_buffer.destroy();
    _ = self.image.unref();
    posix.munmap((self.data));

    self.configured = false;
}


pub fn occupy(self: *Self) void {
    log.debug("<{*}> occupied", .{ self });

    self.busy = true;
}


fn wl_buffer_listener(wl_buffer: *wl.Buffer, event: wl.Buffer.Event, buffer: *Self) void {
    std.debug.assert(wl_buffer == buffer.wl_buffer);

    switch (event) {
        .release => {
            log.debug("<{*}> release", .{ buffer });

            buffer.busy = false;
        }
    }
}
