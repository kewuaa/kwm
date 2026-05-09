const std = @import("std");
const mem = std.mem;
const meta = std.meta;

const constants = @import("constants.zig");


pub fn add_default(comptime T: type, comptime object: T) type {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var new_info = info;
            var new_fields: [info.fields.len]std.builtin.Type.StructField = undefined;
            for (&new_fields, info.fields) |*new_field, field| {
                const new_T = add_default(field.type, @field(object, field.name));
                const default: new_T =
                    if (@typeInfo(new_T) == .@"struct") .{}
                    else @field(object, field.name);

                new_field.* = field;
                new_field.type = new_T;
                new_field.default_value_ptr = @ptrCast(&default);
            }
            new_info.fields = &new_fields;
            new_info.decls = &.{};
            return @Type(.{ .@"struct" = new_info });
        },
        else => return T,
    }
}


pub fn enum_struct(comptime E: type, comptime T: type) type {
    const info = @typeInfo(E);
    if (info != .@"enum") @compileError("E is needed to be a enum");

    var fields: [info.@"enum".fields.len]std.builtin.Type.StructField = undefined;
    for (0.., info.@"enum".fields) |i, field| {
        fields[i] = std.builtin.Type.StructField {
            .name = field.name,
            .type = T,
            .is_comptime = false,
            .default_value_ptr = switch (@typeInfo(T)) {
                .optional => blk: {
                    const default_value: T = null;
                    break :blk &default_value;
                },
                else => null,
            },
            .alignment = @alignOf(T),
        };
    }

    const S = @Type(
        .{
            .@"struct" = .{
                .layout = .auto,
                .is_tuple = false,
                .fields = &fields,
                .decls = &.{},
            },
        }
    );

    const Getter = struct {
        pub const instance: @This() = .{};
        pub fn get(self: *const @This(), e: E) T {
            return switch (e) {
                inline else => |v| @field(
                    @as(*const S, @ptrCast(@alignCast(self))),
                    @tagName(v)
                ),
            };
        }
    };

    return @Type(
        .{
            .@"struct" = .{
                .layout = .auto,
                .is_tuple = false,
                .fields = &([_]std.builtin.Type.StructField {.{
                    .name = "getter",
                    .type = Getter,
                    .default_value_ptr = &Getter.instance,
                    .is_comptime = false,
                    .alignment = @alignOf(T),
                }} ++ fields),
                .decls = &.{},
            },
        }
    );
}


pub fn make_optional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => T,
        .@"struct" => @Type(.{ .optional = .{ .child = make_fields_optional(T) } }),
        else => @Type(.{ .optional = .{ .child = T } }),
    };
}


pub fn make_fields_optional(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("T is needed to be a struct");

    var fields: [info.@"struct".fields.len]std.builtin.Type.StructField = undefined;
    for (0.., info.@"struct".fields) |i, field| {
        const new_T = make_optional(field.type);
        const default_value: new_T = null;
        fields[i] = std.builtin.Type.StructField {
            .name = field.name,
            .type = new_T,
            .default_value_ptr = &default_value,
            .is_comptime = false,
            .alignment = @alignOf(new_T),
        };
    }

    return @Type(
        .{
            .@"struct" = .{
                .layout = .auto,
                .is_tuple = false,
                .fields = &fields,
                .decls = &.{},
            },
        }
    );
}


pub fn field_mask(comptime T: type) type {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("T is needed to be a struct");

    var fields: [info.@"struct".fields.len]std.builtin.Type.StructField = undefined;
    for (0.., info.@"struct".fields) |i, field| {
        const default_value = false;
        fields[i] = std.builtin.Type.StructField {
            .name = field.name,
            .type = bool,
            .default_value_ptr = &default_value,
            .is_comptime = false,
            .alignment = @alignOf(bool),
        };
    }

    return @Type(
        .{
            .@"struct" = .{
                .layout = .auto,
                .is_tuple = false,
                .fields = &fields,
                .decls = &.{},
            },
        }
    );
}


pub fn override(base: anytype, new: anytype) @TypeOf(base) {
    const T = @TypeOf(base);
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field_info| {
        const new_field = @field(new, field_info.name);
        const base_field = @field(base, field_info.name);
        @field(result, field_info.name) =
            if (new_field == null) base_field
            else switch (@typeInfo(field_info.type)) {
                .@"struct" => override(base_field, new_field.?),
                else => new_field.?,
            };
    }
    return result;
}


pub fn deep_equal(comptime T: type, a: *const T, b: *const T) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (!deep_equal(
                    field.type,
                    @ptrCast(&@field(a, field.name)),
                    @ptrCast(&@field(b, field.name)),
                )) {
                    break :blk false;
                }
            }
            break :blk true;
        },
        .array => |info| blk: {
            if (a.len != b.len) break :blk false;

            for (a.*, b.*) |elem_a, elem_b| {
                if (!deep_equal(info.child, &elem_a, &elem_b)) {
                    break :blk false;
                }
            }

            break :blk true;
        },
        .pointer => |info| switch (info.size) {
            .slice => blk: {
                if (a.len != b.len) break :blk false;

                for (a.*, b.*) |elem_a, elem_b| {
                    if (!deep_equal(info.child, &elem_a, &elem_b)) {
                        break :blk false;
                    }
                }

                break :blk true;
            },
            else => unreachable,
        },
        .@"union" => |info| blk: {
            if (info.tag_type != null) {
                const tag_a = meta.activeTag(a.*);
                const tag_b = meta.activeTag(b.*);

                if (tag_a != tag_b) break :blk false;

                inline for (info.fields) |field| {
                    if (@field(T, field.name) == tag_a) {
                        break :blk deep_equal(
                            field.type,
                            &@field(a.*, field.name),
                            &@field(b.*, field.name),
                        );
                    }
                }
                unreachable;
            } else unreachable;
        },
        .optional => |info|
            if (a.* == null and b.* == null) true
            else if (a.* == null or b.* == null) false
            else deep_equal(info.child, &a.*.?, &b.*.?),
        .float => @abs(a.*-b.*) < 1e-9,
        .int, .bool, .@"enum" => a.* == b.*,
        .void => true,
        else => unreachable,
    };
}


pub fn zon_free(gpa: mem.Allocator, value: anytype, default: ?*const @TypeOf(value)) void {
    const Value = @TypeOf(value);
    const info = @typeInfo(Value);

    switch (info) {
        .bool, .int, .float, .@"enum" => {},
        .pointer => |pointer| {
            switch (pointer.size) {
                .one => {
                    if (default) |ptr| {
                        if (value == ptr.*) return;
                    }

                    zon_free(gpa, value.*, null);
                    gpa.destroy(value);
                },
                .slice => {
                    if (default) |ptr| {
                        if (value.ptr == ptr.ptr) return;
                    }

                    for (value) |item| {
                        zon_free(gpa, item, null);
                    }
                    gpa.free(value);
                },
                .many, .c => comptime unreachable,
            }
        },
        .array => for (0.., value) |i, item| {
            zon_free(
                gpa,
                item,
                if (default) |ptr| &ptr.*[i] else null
            );
        },
        .@"struct" => |@"struct"| inline for (@"struct".fields) |field| {
            zon_free(
                gpa,
                @field(value, field.name),
                if (default) |ptr|
                    @ptrCast(@alignCast(&@field(ptr.*, field.name)))
                else
                    if (field.default_value_ptr) |ptr| @ptrCast(@alignCast(ptr))
                    else null
            );
        },
        .@"union" => |@"union"| if (@"union".tag_type == null) {
            if (comptime requiresAllocator(Value)) unreachable;
        } else switch (value) {
            inline else => |_, tag| {
                zon_free(
                    gpa,
                    @field(value, @tagName(tag)),
                    if (default) |ptr| (
                        if (meta.activeTag(ptr.*) == tag)
                            &@field(ptr.*, @tagName(tag))
                        else null
                    )
                    else null
                );
            },
        },
        .optional => if (value) |some| {
            zon_free(
                gpa,
                some,
                if (default) |ptr| (
                    if (ptr.* != null) &ptr.*.?
                    else null
                )
                else null
            );
        },
        .vector => |vector| for (0..vector.len) |i|
            zon_free(
                gpa,
                value[i],
                if (default) |ptr| &ptr.*[i] else null
            ),
        .void => {},
        else => comptime unreachable,
    }
}

fn requiresAllocator(T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => true,
        .array => |array| return array.len > 0 and requiresAllocator(array.child),
        .@"struct" => |@"struct"| inline for (@"struct".fields) |field| {
            if (requiresAllocator(field.type)) {
                break true;
            }
        } else false,
        .@"union" => |@"union"| inline for (@"union".fields) |field| {
            if (requiresAllocator(field.type)) {
                break true;
            }
        } else false,
        .optional => |optional| requiresAllocator(optional.child),
        .vector => |vector| return vector.len > 0 and requiresAllocator(vector.child),
        else => false,
    };
}
