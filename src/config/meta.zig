const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const Type = std.builtin.Type;

const constants = @import("constants.zig");


pub fn add_default(comptime T: type, comptime object: T) type {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            const names = info.field_names;
            const len = names.len;
            var types: [len]type = undefined;
            var attrs: [len]Type.Struct.FieldAttributes = undefined;

            for (0.., info.field_names, info.field_types, info.field_attrs) |i, name, @"type", attr| {
                const new_T = add_default(@"type", @field(object, name));
                const default: new_T = switch (@typeInfo(new_T)) {
                    .@"struct" => .{},
                    .optional => |optional_info| switch (@typeInfo(optional_info.child)) {
                        .@"struct" => if (@field(object, name)) |_| .{} else null,
                        else => @field(object, name),
                    },
                    else => @field(object, name),
                };

                types[i] = new_T;
                attrs[i] = attr;
                attrs[i].default_value_ptr = @ptrCast(&default);
            }

            return @Struct(info.layout, info.backing_integer, names, &types, &attrs);
        },
        .optional => |info| return
            if (object) |obj| ?add_default(info.child, obj)
            else T,
        else => return T,
    }
}


pub fn enum_struct(comptime E: type, comptime T: type) type {
    const info = @typeInfo(E).@"enum";

    const names = info.field_names;
    const len = names.len;
    var types: [len]type = undefined;
    var attrs: [len]Type.Struct.FieldAttributes = undefined;
    for (0..len) |i| {
        types[i] = T;
        attrs[i] = Type.Struct.FieldAttributes {
            .@"comptime" = false,
            .@"align" = @alignOf(T),
            .default_value_ptr = switch (@typeInfo(T)) {
                .optional => blk: {
                    const default_value: T = null;
                    break :blk &default_value;
                },
                else => null,
            },
        };
    }

    const S = @Struct(.auto, null, names, &types, &attrs);

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

    return @Struct(
        .auto,
        null,
        &(.{ "getter" } ++ names.*),
        &(.{ Getter } ++ types),
        &(.{
            Type.Struct.FieldAttributes {
                .@"comptime" = false,
                .@"align" = @alignOf(T),
                .default_value_ptr = &Getter.instance
            }
        } ++ attrs)
    );
}


pub fn make_optional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => T,
        .@"struct" => ?make_fields_optional(T),
        else => ?T,
    };
}


pub fn make_fields_optional(comptime T: type) type {
    const info = @typeInfo(T).@"struct";

    const names = info.field_names;
    const len = names.len;
    var types: [len]type = undefined;
    var attrs: [len]Type.Struct.FieldAttributes = undefined;
    for (0.., info.field_types) |i, @"type"| {
        const new_T = make_optional(@"type");
        const default_value: new_T = null;
        types[i] = new_T;
        attrs[i] = Type.Struct.FieldAttributes {
            .@"comptime" = false,
            .@"align" = @alignOf(new_T),
            .default_value_ptr = &default_value,
        };
    }

    return @Struct(.auto, null, names, &types, &attrs);
}


pub fn field_mask(comptime T: type) type {
    const info = @typeInfo(T).@"struct";

    const names = info.field_names;
    const len = names.len;
    var attrs: [len]Type.Struct.FieldAttributes = undefined;
    for (0..len) |i| {
        const default_value = false;
        attrs[i] = Type.Struct.FieldAttributes {
            .@"comptime" = false,
            .@"align" = @alignOf(bool),
            .default_value_ptr = &default_value,
        };
    }

    return @Struct(.auto, null, names, &@splat(bool), &attrs);
}


pub fn override(base: anytype, new: anytype) @TypeOf(base) {
    const T = @TypeOf(base);
    var result: T = undefined;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, @"type"| {
        const new_field = @field(new, name);
        const base_field = @field(base, name);
        @field(result, name) =
            if (new_field == null) base_field
            else switch (@typeInfo(@"type")) {
                .@"struct" => override(base_field, new_field.?),
                else => new_field.?,
            };
    }
    return result;
}


pub fn deep_equal(comptime T: type, a: *const T, b: *const T) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            inline for (info.field_names, info.field_types) |name, @"type"| {
                if (!deep_equal(
                    @"type",
                    @ptrCast(&@field(a, name)),
                    @ptrCast(&@field(b, name)),
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

                inline for (info.field_names, info.field_types) |name, @"type"| {
                    if (@field(T, name) == tag_a) {
                        break :blk deep_equal(
                            @"type",
                            &@field(a.*, name),
                            &@field(b.*, name),
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
