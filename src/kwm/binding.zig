const types = @import("types.zig");
const layout = @import("layout.zig");
const Context = @import("context.zig");
const Window = @import("window.zig");

pub const XkbBinding = @import("binding/xkb_binding.zig");
pub const PointerBinding = @import("binding/pointer_binding.zig");

const MoveResizeStep = union(enum) {
    horizontal: i32,
    vertical: i32,
};


pub const Action = union(enum) {
    quit: struct { exit_session: bool },
    close,
    spawn: struct {
        argv: []const []const u8,
    },
    spawn_shell: struct {
        cmd: []const u8,
    },
    focus_iter: struct {
        direction: types.Direction,
        skip_floating: bool = false,
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
    toggle_fullscreen: struct {
        in_window: bool = false,
    },
    set_output_tag: struct { tag: u32 },
    set_window_tag: struct { tag: u32 },
    toggle_output_tag: struct { mask: u32 },
    toggle_window_tag: struct { mask: u32 },
    switch_to_previous_tag,
    shift_tag: struct { direction: types.Direction },
    toggle_floating,
    toggle_sticky,
    toggle_swallow,
    zoom: struct { swap: bool },
    focus_master_return,
    switch_layout: struct { layout: layout.Type },
    switch_to_previous_layout,
    toggle_bar,

    modify_nmaster: struct { change: enum { increase, decrease } },
    modify_mfact: struct { step: f32 },
    modify_gap: struct { step: i32 },
    modify_master_location: struct { location: types.LayoutMasterLocation },
    toggle_grid_direction,
    toggle_auto_swallow,

    reload_config,

    group: struct {
        actions: []const Action,
    },
};
