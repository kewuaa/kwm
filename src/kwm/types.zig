const build_options = @import("build_options");
const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;

pub const RiverInputs = if (build_options.kwim_enabled) struct {
    input_manager: ?*river.InputManagerV1 = null,
    libinput_config: ?*river.LibinputConfigV1 = null,
    xkb_config: ?*river.XkbConfigV1 = null,

    pub fn destroy(self: *const @This()) void {
        if (self.input_manager) |rwm_input_manager| rwm_input_manager.destroy();
        if (self.libinput_config) |rwm_libinput_config| rwm_libinput_config.destroy();
        if (self.xkb_config) |rwm_xkb_config| rwm_xkb_config.destroy();
    }
} else struct {};

pub const Button = enum(u32) {
    none = 0,
    left = 0x110,
    right = 0x111,
    middle = 0x112,
    side = 0x113,
    extra = 0x114,
    forward = 0x115,
    back = 0x116,
    task = 0x117,
};

pub const Direction = enum {
    forward,
    reverse,
};

pub const PlacePosition = union(enum) {
    top,
    bottom,
    above: *river.NodeV1,
    below: *river.NodeV1,
};

pub const BarArea = enum {
    tags,
    mode,
    layout,
    title,
    status,
};

pub const LayoutMasterLocation = enum {
    left,
    right,
    top,
    bottom,
};

pub const WindowAttachMode = enum {
    top,
    bottom,
    stack_top,
    above_focused,
    below_focused,
};

pub const WindowIterSkip = enum {
    none,
    floating,
    nonfloating,
};
