// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const process = std.process;

const preprocess = @import("config/preprocess.zig");


pub fn main(init: process.Init) !void {
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var args = init.minimal.args.iterate();
    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "-i")) {
            input = args.next();
        } else if (mem.eql(u8, arg, "-o")) {
            output = args.next();
        }
    }

    const output_file = try Io.Dir.createFileAbsolute(init.io, output orelse return error.MissingOutput, .{});
    defer output_file.close(init.io);

    var buffer = try preprocess.preprocess(
        .{ .gpa = init.gpa, .io = init.io, .env = init.environ_map },
        input orelse return error.MissingInput
    );
    defer buffer.deinit(init.gpa);

    var output_buffer: [4096]u8 = undefined;
    var output_writer = output_file.writer(init.io, &output_buffer);
    const writer = &output_writer.interface;
    try writer.writeAll(buffer.items[0..buffer.items.len-1:0]);
    try writer.flush();
}
