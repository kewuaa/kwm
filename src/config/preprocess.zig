// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const posix = std.posix;
const process = std.process;
const log = std.log.scoped(.preprocess);

const mvzr = @import("mvzr");

const State = union(enum) {
    normal,
    @"if",
    @"else",
    elif,
};
const Target = struct {
    hostname: []const u8,
};


pub fn preprocess(
    ctx: struct {
        gpa: mem.Allocator,
        io: Io,
        env: *const process.Environ.Map,
    },
    path: []const u8
) !std.ArrayList(u8) {
    const cwd = Io.Dir.cwd();
    const file = try cwd.openFile(ctx.io, path, .{ .mode = .read_only });
    defer file.close(ctx.io);
    var dir = blk: {
        const abs_path = try cwd.realPathFileAlloc(ctx.io, path, ctx.gpa);
        defer ctx.gpa.free(abs_path);
        break :blk cwd.openDir(
            ctx.io,
            Io.Dir.path.dirname(abs_path) orelse break :blk cwd,
            .{},
        ) catch cwd;
    };
    defer dir.close(ctx.io);

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(ctx.gpa);

    var reader_buffer: [1024]u8 = undefined;
    var reader = file.reader(ctx.io, &reader_buffer);
    const f = &reader.interface;

    var hostname_buffer: [posix.HOST_NAME_MAX]u8 = undefined;
    const target: Target = .{
        .hostname = try posix.gethostname(&hostname_buffer),
    };

    const if_pattern = mvzr.compile(
        \\//\s*@if\s*\(.+\)
        \\
    ).?;
    const elif_pattern = mvzr.compile(
        \\//\s*@elif\s*\(.+\)
        \\
    ).?;
    const else_pattern = mvzr.compile(
        \\//\s*@else
        \\
    ).?;
    const end_pattern = mvzr.compile(
        \\//\s*@endif
        \\
    ).?;
    const include_pattern = mvzr.compile(
        \\//\s*@include\(.+\)
        \\
    ).?;
    var save = true;
    var matched = false;
    var state: State = .normal;
    while (f.takeDelimiterInclusive('\n')) |line| {
        switch (state) {
            .normal => {
                if (if_pattern.isMatch(line)) {
                    matched = try match(ctx.env, line, &target);
                    save = matched;
                    state = .@"if";
                    continue;
                }
            },
            .@"if", .elif => {
                if (end_pattern.isMatch(line)) {
                    save = true;
                    matched = false;
                    state = .normal;
                    continue;
                } else if (else_pattern.isMatch(line)) {
                    save = !matched;
                    state = .@"else";
                    continue;
                } else if (elif_pattern.isMatch(line)) {
                    if (matched) {
                        save = false;
                    } else {
                        matched = try match(ctx.env, line, &target);
                        save = matched;
                    }
                    state = .elif;
                    continue;
                }
            },
            .@"else" => {
                if (end_pattern.isMatch(line)) {
                    save = true;
                    matched = false;
                    state = .normal;
                    continue;
                }
            },
        }

        if (save) {
            if (include_pattern.isMatch(line)) {
                const begin = mem.indexOf(u8, line, "(") orelse continue;
                const contents = try dir.readFileAlloc(ctx.io, line[begin+1..line.len-2], ctx.gpa, .unlimited);
                defer ctx.gpa.free(contents);

                try result.appendSlice(ctx.gpa, contents);
            } else try result.appendSlice(ctx.gpa, line);
        }
    } else |err| if (err != error.EndOfStream) return err;

    try result.append(ctx.gpa, 0);
    return result;
}


fn match(env: *const process.Environ.Map, line: []const u8, target: *const Target) !bool {
    var found_condition = false;
    inline for (@typeInfo(Target).@"struct".fields) |field_info| {
        if (parse(line, field_info.name++"=")) |str| {
            found_condition = true;

            const pattern = mvzr.compile(str) orelse return error.CompileFailed;

            log.debug(field_info.name++": try match {s} with {s}", .{ @field(target, field_info.name), str });

            if (!pattern.isMatch(@field(target, field_info.name))) return false;
        }
    }
    if (parse(line, "env_contains:")) |str| {
        found_condition = true;

        log.debug("finding environment variable {s}", .{ str });
        if (env.get(str) == null) return false;
    }
    if (parse(line, "env:")) |str| blk: {
        found_condition = true;

        var it = mem.splitAny(u8, str, "=");
        const key = mem.trim(u8, it.next() orelse break :blk, " ");
        const value = mem.trim(u8, it.next() orelse break :blk, " ");
        log.debug("matching environment variable {s}={s}", .{ key, value });
        if (env.get(key)) |v| {
            if (mem.eql(u8, v, value)) break :blk;
        }
        return false;
    }
    return found_condition;
}


fn parse(line: []const u8, name: []const u8) ?[]const u8 {
    var i = mem.indexOf(u8, line, name) orelse return null;
    i += name.len;
    const end = line.len - 2;

    while (i < end and line[i] == ' ') : (i += 1) {}
    const start = i;

    while (i < end and line[i] != ',') : (i += 1) {}
    return line[start..i];
}
