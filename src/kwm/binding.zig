const std = @import("std");
const math = std.math;

const utils = @import("utils.zig");
const types = @import("types.zig");
const layout = @import("layout.zig");
const Window = @import("window.zig");
const Output = @import("output.zig");
const Context = @import("context.zig");
pub const XkbBinding = @import("binding/xkb_binding.zig");
pub const PointerBinding = @import("binding/pointer_binding.zig");

const SetStep = union(enum) {
    set: f32,
    step: f32,
};
const MoveResizeStep = union(enum) {
    horizontal: i32,
    vertical: i32,
};
const Tag = union(enum) {
    tag: u32,
    direction: types.Direction,
    occupied: types.Direction,
    unoccupied: types.Direction,

    pub fn of(self: *const @This(), base: union(enum) { output: *const Output, window: *const Window }) u32 {
        const output, const base_tag = switch (base) {
            .output => |o| .{ o, o.tag },
            .window => |w| .{ w.output orelse return 0, w.tag },
        };
        return
            if (ctx.cfg.bar.tags) |area|
                switch (self.*) {
                    .tag => |tag| tag,
                    .direction => |direction| utils.shift_tag(
                        base_tag,
                        ((@as(u32, 1) << @as(u5, @intCast(area.tags.len))) - 1),
                        area.tags.len,
                        direction,
                    ),
                    .occupied => |direction| utils.shift_tag(
                        base_tag,
                        output.occupied_tags(),
                        area.tags.len,
                        direction,
                    ),
                    .unoccupied => |direction| utils.shift_tag(
                        base_tag,
                        ~output.occupied_tags() & ((@as(u32, 1) << @as(u5, @intCast(area.tags.len))) - 1),
                        area.tags.len,
                        direction,
                    ),
                }
            else
                switch (self.*) {
                    .tag => |tag| tag,
                    inline else => |direction|
                        switch (direction) {
                            .forward => math.rotl(u32, base_tag, 1),
                            .reverse => math.rotr(u32, base_tag, 1),
                        }
                };
    }
};


pub const Action = union(enum) {
    quit: struct {
        exit_session: bool,
        hook: ?[]const[]const u8 = null
    },
    close,
    spawn: struct {
        argv: []const []const u8,
    },
    spawn_shell: struct {
        cmd: []const u8,
    },
    focus_iter: struct {
        direction: types.Direction,
        skip: types.WindowIterSkip = .none,
    },
    focus_output_iter: struct {
        direction: types.Direction,
    },
    send_to_output: struct {
        direction: types.Direction,
    },
    swap: struct {
        direction: types.Direction,
    },
    move: struct {
        step: MoveResizeStep,
    },
    resize: struct {
        step: MoveResizeStep,
    },
    pointer_move,
    pointer_resize,
    snap: struct {
        edge: Window.Edge,
    },
    switch_mode: struct {
        mode: []const u8,
        auto_quit: enum {
            disabled,
            once_pressed,
            once_bound_pressed,
            once_unbound_pressed,
        } = .disabled,
    },
    toggle_maximize,
    toggle_fullscreen: struct {
        in_window: bool = false,
    },
    rotate_outputs: struct { direction: types.Direction },
    set_output_tag: struct { tag: Tag },
    set_window_tag: struct { tag: Tag, focus_follow: bool = false },
    toggle_output_tag: struct { mask: u32 },
    toggle_window_tag: struct { mask: u32 },
    switch_to_previous_tag,
    toggle_floating,
    toggle_sticky,
    toggle_swallow,
    zoom: struct { swap: bool },
    focus_master_return,
    switch_layout: struct { layout: layout.Type },
    switch_to_previous_layout,
    toggle_bar,

    modify_nmaster: struct { change: enum { increase, decrease } },
    modify_mfact: struct { change: SetStep },
    modify_gap: struct { step: i32 },
    modify_master_location: struct { location: types.LayoutMasterLocation },
    toggle_grid_direction,
    toggle_centered_master_direction,
    toggle_auto_swallow,

    reload_config,

    group: struct {
        actions: []const Action,
    },
};

const ctx = Context.get();
