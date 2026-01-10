const std = @import("std");
const fmt = std.fmt;

const xkb = @import("xkbcommon");
const Keysym = xkb.Keysym;
const wayland = @import("wayland");
const river = wayland.client.river;

const binding = @import("binding.zig");
const Context = @import("context.zig");
const Rule = @import("rule.zig");
const Window = @import("window.zig");

const Alt: u32 = @intFromEnum(river.SeatV1.Modifiers.Enum.mod1);
const Super: u32 = @intFromEnum(river.SeatV1.Modifiers.Enum.mod4);
const Ctrl: u32 = @intFromEnum(river.SeatV1.Modifiers.Enum.ctrl);
const Shift: u32 = @intFromEnum(river.SeatV1.Modifiers.Enum.shift);
const Button = struct {
    const left = 0x110;
    const right = 0x111;
    const middle = 0x112;
};
const XcursorTheme = struct {
    name: []const u8,
    size: u32,
};
const XkbBinding = struct {
    mode: Mode = .default,
    keysym: u32,
    modifiers: u32,
    event: river.XkbBindingV1.Event = .pressed,
    action: binding.Action,
};
const PointerBinding = struct {
    mode: Mode = .default,
    button: u32,
    modifiers: u32,
    action: binding.Action,
    event: river.PointerBindingV1.Event = .pressed,
};
const BorderColor = struct {
    focus: u32,
    unfocus: u32,
    urgent: u32,
};

const font = "FiraCode Nerd Font";
const font_size = 15;
const menu_font_size = 20;
const norm_fg = 0x828bb8ff;
const norm_bg = 0x1b1d2bd0;
const norm_border = 0x828bb8ff;
const sele_fg = 0x444a73ff;
const sele_bg = 0xc8d3f5d0;
const sele_border = 0xffc777ff;
const menu_options = fmt.comptimePrint(
    "-ci -l 9 -f '{s}, {}' -n {x} -N {x} -m {x} -M {x} -s {x} -S {x}",
    .{ font, menu_font_size, norm_fg, norm_bg, norm_fg, norm_bg, sele_fg, sele_bg },
);
const audio_script = "$HOME/.local/bin/audio";
const bright_script = "$HOME/.local/bin/bright";

pub const env = [_] struct { []const u8, []const u8 } {
    // .{ "key", "value" },
};

pub const working_directory: union(enum) {
    none,
    home,
    custom: []const u8,
} = .home;

pub const startup_cmds = [_][]const []const u8 {
    &[_][]const u8 { "sh", "-c", "$HOME/.local/bin/swaybgd" },
    &[_][]const u8{ "foot", "--server" },
};

pub const xcursor_theme: ?XcursorTheme = null;

pub const repeat_rate = 50;
pub const repeat_delay = 300;
pub const scroll_factor = 1.0;

pub const sloppy_focus = false;

pub const default_window_decoration: Window.Decoration = .ssd;
pub var auto_swallow = true;

pub const Mode = enum {
    lock, // do not delete, compile needed
    default,
    floating,
    passthrough,
};

pub var border_width: i32 = 5;
pub const border_color: BorderColor = .{
    .focus = sele_border,
    .unfocus = norm_border,
    .urgent = 0xff0000ff,
};


pub const default_layout: @import("layout.zig").Type = .scroller;
pub var layout: struct {
    tile: @import("layout/tile.zig"),
    monocle: @import("layout/monocle.zig"),
    scroller: @import("layout/scroller.zig"),
} = .{
    .tile = .{
        .nmaster = 1,
        .mfact = 0.55,
        .inner_gap = 12,
        .outer_gap = 9,
        .master_location = .left,
    },
    .monocle = .{
        .gap = 9,
    },
    .scroller = .{
        .mfact = 0.5,
        .inner_gap = 16,
        .outer_gap = 9,
        .snap_to_left = false,
    }
};

fn modify_nmaster(context: *const Context, arg: *const binding.Arg) void {
    std.debug.assert(arg.* == .i);

    if (context.current_output) |output| {
        switch (output.current_layout()) {
            .tile => layout.tile.nmaster = @max(1, layout.tile.nmaster+arg.i),
            else => {}
        }
    }
}


fn modify_mfact(context: *const Context, arg: *const binding.Arg) void {
    std.debug.assert(arg.* == .f);

    if (context.current_output) |output| {
        switch (output.current_layout()) {
            .tile => layout.tile.mfact = @min(1, @max(0, layout.tile.mfact+arg.f)),
            .scroller => layout.scroller.mfact = @min(1, @max(0, layout.scroller.mfact+arg.f)),
            else => {},
        }
    }
}


fn modify_gap(context: *const Context, arg: *const binding.Arg) void {
    std.debug.assert(arg.* == .i);

    if (context.current_output) |output| {
        switch (output.current_layout()) {
            .tile => layout.tile.inner_gap = @max(border_width*2, layout.tile.inner_gap+arg.i),
            .monocle => layout.monocle.gap = @max(border_width*2, layout.monocle.gap+arg.i),
            .scroller => layout.scroller.inner_gap = @max(border_width*2, layout.scroller.inner_gap+arg.i),
            .float => {},
        }
    }
}


fn modify_master_location(context: *const Context, arg: *const binding.Arg) void {
    std.debug.assert(arg.* == .ui);

    if (context.current_output) |output| {
        switch (output.current_layout()) {
            .tile => {
                layout.tile.master_location = switch (arg.ui) {
                    'l' => .left,
                    'r' => .right,
                    'u' => .top,
                    'd' => .bottom,
                    else => return,
                };
            },
            else => {}
        }
    }
}


fn toggle_scroller_snap_to_left(context: *const Context, arg: *const binding.Arg) void {
    std.debug.assert(arg.* == .none);

    if (context.current_output) |output| {
        switch (output.current_layout()) {
            .scroller => {
                layout.scroller.snap_to_left = !layout.scroller.snap_to_left;
            },
            else => {}
        }
    }
}


fn toggle_auto_swallow(_: *const Context, _: *const binding.Arg) void {
    auto_swallow = !auto_swallow;
}


pub const xkb_bindings = blk: {
    const bindings = [_]XkbBinding {
        // passthrough
        .{
            .keysym = Keysym.Escape,
            .modifiers = Super|Shift,
            .action = .{ .switch_mode = .{ .mode = .passthrough } }
        },
        .{
            .mode = .passthrough,
            .keysym = Keysym.Escape,
            .modifiers = Super|Shift,
            .action = .{ .switch_mode = .{ .mode = .default } }
        },


        // floating
        .{
            .keysym = Keysym.f,
            .modifiers = Super|Ctrl,
            .action = .{ .switch_mode = .{ .mode = .floating } },
        },
        .{
            .mode = .floating,
            .keysym = Keysym.f,
            .modifiers = Super|Ctrl,
            .action = .{ .switch_mode = .{ .mode = .default } },
        },
        .{
            .mode = .floating,
            .keysym = Keysym.l,
            .modifiers = Super,
            .action = .{ .move = .{ .step = .{ .horizontal = 10 } } }
        },
        .{
            .mode = .floating,
            .keysym = Keysym.h,
            .modifiers = Super,
            .action = .{ .move = .{ .step = .{ .horizontal = -10 } } }
        },
        .{
            .mode = .floating,
            .keysym = Keysym.j,
            .modifiers = Super,
            .action = .{ .move = .{ .step = .{ .vertical = 10 } } }
        },
        .{
            .mode = .floating,
            .keysym = Keysym.k,
            .modifiers = Super,
            .action = .{ .move = .{ .step = .{ .vertical = -10 } } }
        },
        .{
            .mode = .floating,
            .keysym = Keysym.l,
            .modifiers = Super|Ctrl,
            .action = .{ .resize = .{ .step = .{ .horizontal = 10 } } }
        },
        .{
            .mode = .floating,
            .keysym = Keysym.h,
            .modifiers = Super|Ctrl,
            .action = .{ .resize = .{ .step = .{ .horizontal = -10 } } }
        },
        .{
            .mode = .floating,
            .keysym = Keysym.j,
            .modifiers = Super|Ctrl,
            .action = .{ .resize = .{ .step = .{ .vertical = 10 } } }
        },
        .{
            .mode = .floating,
            .keysym = Keysym.k,
            .modifiers = Super|Ctrl,
            .action = .{ .resize = .{ .step = .{ .vertical = -10 } } }
        },
        .{
            .mode = .floating,
            .keysym = Keysym.l,
            .modifiers = Super|Shift,
            .action = .{ .snap = .{ .edges = .{ .right = true } } }
        },
        .{
            .mode = .floating,
            .keysym = Keysym.h,
            .modifiers = Super|Shift,
            .action = .{ .snap = .{ .edges = .{ .left = true } } }
        },
        .{
            .mode = .floating,
            .keysym = Keysym.j,
            .modifiers = Super|Shift,
            .action = .{ .snap = .{ .edges = .{ .bottom = true } } }
        },
        .{
            .mode = .floating,
            .keysym = Keysym.k,
            .modifiers = Super|Shift,
            .action = .{ .snap = .{ .edges = .{ .top = true } } }
        },


        // default
        .{
            .keysym = Keysym.q,
            .modifiers = Super|Shift,
            .action = .quit,
        },
        .{
            .keysym = Keysym.c,
            .modifiers = Super|Shift,
            .action = .close,
        },
        .{
            .keysym = Keysym.Return,
            .modifiers = Super,
            .action = .zoom,
        },
        .{
            .keysym = Keysym.l,
            .modifiers = Super,
            .action = .{ .custom_fn = .{ .func = &modify_mfact, .arg = .{ .f = 0.01 } } },
        },
        .{
            .keysym = Keysym.h,
            .modifiers = Super,
            .action = .{ .custom_fn = .{ .func = &modify_mfact, .arg = .{ .f = -0.01 } } },
        },
        .{
            .keysym = Keysym.j,
            .modifiers = Super|Alt,
            .action = .{ .custom_fn = .{ .func = &modify_master_location, .arg = .{ .ui = 'd' } } },
        },
        .{
            .keysym = Keysym.k,
            .modifiers = Super|Alt,
            .action = .{ .custom_fn = .{ .func = &modify_master_location, .arg = .{ .ui = 'u' } } },
        },
        .{
            .keysym = Keysym.l,
            .modifiers = Super|Alt,
            .action = .{ .custom_fn = .{ .func = &modify_master_location, .arg = .{ .ui = 'r' } } },
        },
        .{
            .keysym = Keysym.h,
            .modifiers = Super|Alt,
            .action = .{ .custom_fn = .{ .func = &modify_master_location, .arg = .{ .ui = 'l' } } },
        },
        .{
            .keysym = Keysym.equal,
            .modifiers = Super,
            .action = .{ .custom_fn = .{ .func = &modify_nmaster, .arg = .{ .i = 1 } } },
        },
        .{
            .keysym = Keysym.minus,
            .modifiers = Super,
            .action = .{ .custom_fn = .{ .func = &modify_nmaster, .arg = .{ .i = -1 } } },
        },
        .{
            .keysym = Keysym.equal,
            .modifiers = Super|Alt,
            .action = .{ .custom_fn = .{ .func = &modify_gap, .arg = .{ .i = 1 } } },
        },
        .{
            .keysym = Keysym.minus,
            .modifiers = Super|Alt,
            .action = .{ .custom_fn = .{ .func = &modify_gap, .arg = .{ .i = -1 } } },
        },
        .{
            .keysym = Keysym.j,
            .modifiers = Super,
            .action = .{ .focus_iter = .{ .direction = .forward } },
        },
        .{
            .keysym = Keysym.k,
            .modifiers = Super,
            .action = .{ .focus_iter = .{ .direction = .reverse } },
        },
        .{
            .keysym = Keysym.j,
            .modifiers = Super|Ctrl,
            .action = .{ .focus_iter = .{ .direction = .forward, .skip_floating = true, } },
        },
        .{
            .keysym = Keysym.k,
            .modifiers = Super|Ctrl,
            .action = .{ .focus_iter = .{ .direction = .reverse, .skip_floating = true } },
        },
        .{
            .keysym = Keysym.j,
            .modifiers = Super|Shift,
            .action = .{ .swap = .{ .direction = .forward } },
        },
        .{
            .keysym = Keysym.k,
            .modifiers = Super|Shift,
            .action = .{ .swap = .{ .direction = .reverse } },
        },
        .{
            .keysym = Keysym.period,
            .modifiers = Super,
            .action = .{ .focus_output_iter = .{ .direction = .forward } },
        },
        .{
            .keysym = Keysym.comma,
            .modifiers = Super,
            .action = .{ .focus_output_iter = .{ .direction = .reverse } },
        },
        .{
            .keysym = Keysym.period,
            .modifiers = Super|Shift,
            .action = .{ .send_to_output = .{ .direction = .forward } },
        },
        .{
            .keysym = Keysym.comma,
            .modifiers = Super|Shift,
            .action = .{ .send_to_output = .{ .direction = .reverse } },
        },
        .{
            .keysym = Keysym.m,
            .modifiers = Super|Shift,
            .action = .{ .toggle_fullscreen = .{ .in_window = true } },
        },
        .{
            .keysym = Keysym.f,
            .modifiers = Super|Shift,
            .action = .{ .toggle_fullscreen = .{} },
        },
        .{
            .keysym = Keysym.space,
            .modifiers = Super,
            .action = .toggle_floating,
        },
        .{
            .keysym = Keysym.a,
            .modifiers = Super,
            .action = .toggle_swallow,
        },
        .{
            .keysym = Keysym.a,
            .modifiers = Super|Shift,
            .action = .{ .custom_fn = .{ .func = &toggle_auto_swallow, .arg = .none } }
        },
        .{
            .keysym = Keysym.h,
            .modifiers = Super|Shift,
            .action = .{ .custom_fn = .{ .func = &toggle_scroller_snap_to_left, .arg = .none } },
        },
        .{
            .keysym = Keysym.f,
            .modifiers = Super,
            .action = .{ .switch_layout = .{ .layout = .float } },
        },
        .{
            .keysym = Keysym.t,
            .modifiers = Super,
            .action = .{ .switch_layout = .{ .layout = .tile } },
        },
        .{
            .keysym = Keysym.m,
            .modifiers = Super,
            .action = .{ .switch_layout = .{ .layout = .monocle } },
        },
        .{
            .keysym = Keysym.s,
            .modifiers = Super,
            .action = .{ .switch_layout = .{ .layout = .scroller } },
        },
        .{
            .keysym = Keysym.Tab,
            .modifiers = Super,
            .action = .switch_to_previous_tag,
        },
        .{
            .keysym = Keysym.@"0",
            .modifiers = Super,
            .action = .{ .set_output_tag = .{ .tag = 0xffffffff } }
        },
        .{
            .keysym = Keysym.p,
            .modifiers = Super,
            .action = .{ .spawn_shell = .{ .cmd = fmt.comptimePrint("wmenu-run {s}", .{ menu_options }) } },
        },
        .{
            .keysym = Keysym.Return,
            .modifiers = Super|Shift,
            .action = .{ .spawn = .{ .argv = &[_][]const u8 { "footclient" } } },
        },
        .{
            .keysym = Keysym.e,
            .modifiers = Super,
            .action = .{ .spawn = .{ .argv = &[_][]const u8 { "footclient", "lf" } } },
        },
        .{
            .keysym = Keysym.l,
            .modifiers = Super|Shift,
            .action = .{ .spawn = .{ .argv = &[_][]const u8 { "wayland_lock" } } },
        },
        .{
            .keysym = Keysym.Print,
            .modifiers = 0,
            .action = .{ .spawn_shell = .{ .cmd = "grim -| wl-copy && notify-send 'Screenshot taken'" } },
        },
        .{
            .keysym = Keysym.s,
            .modifiers = Super|Shift,
            .action = .{ .spawn_shell = .{ .cmd = "sleep 0.2; slurp | xargs -I {} grim -g {} -| wl-copy" } },
        },
        .{
            .keysym = Keysym.k,
            .modifiers = Super|Ctrl|Shift,
            .action = .{
                .spawn_shell = .{
                    .cmd = fmt.comptimePrint(
                        "if pgrep -x wshowkeys > /dev/null; then killall wshowkeys; else wshowkeys -b {x} -f {x} -F '{s} 60' -a bottom -m 60; fi",
                        .{ norm_fg, norm_bg, font }
                    ),
                },
            },
        },
        .{
            .keysym = Keysym.v,
            .modifiers = Super,
            .action = .{
                .spawn_shell = .{
                    .cmd = fmt.comptimePrint(
                        "cliphist list | wmenu {s} | {{ read -r selection; [ -n \"$selection\" ] && echo \"$selection\" | cliphist decode | wl-copy; }}",
                        .{ menu_options },
                    ),
                },
            },
        },
        .{
            .keysym = Keysym.v,
            .modifiers = Super|Shift,
            .action = .{
                .spawn_shell = .{
                    .cmd = fmt.comptimePrint(
                        "cliphist list | wmenu {s} | cliphist delete",
                        .{ menu_options },
                    ),
                },
            },
        },
        .{
            .keysym = Keysym.Caps_Lock,
            .modifiers = 0,
            .action = .{
                .spawn_shell = .{ .cmd = "sleep 0.2; $HOME/.local/bin/capslock" },
            },
        },
        .{
            .keysym = Keysym.XF86AudioRaiseVolume,
            .modifiers = 0,
            .action = .{
                .spawn_shell = .{ .cmd = fmt.comptimePrint("{s} sink --plus", .{ audio_script }) },
            },
        },
        .{
            .keysym = Keysym.XF86AudioLowerVolume,
            .modifiers = 0,
            .action = .{
                .spawn_shell = .{ .cmd = fmt.comptimePrint("{s} sink --minus", .{ audio_script }) },
            },
        },
        .{
            .keysym = Keysym.XF86AudioMute,
            .modifiers = 0,
            .action = .{
                .spawn_shell = .{ .cmd = fmt.comptimePrint("{s} sink --mute", .{ audio_script }) },
            },
        },
        .{
            .keysym = Keysym.XF86AudioRaiseVolume,
            .modifiers = Super,
            .action = .{
                .spawn_shell = .{ .cmd = fmt.comptimePrint("{s} source --plus", .{ audio_script }) },
            },
        },
        .{
            .keysym = Keysym.XF86AudioLowerVolume,
            .modifiers = Super,
            .action = .{
                .spawn_shell = .{ .cmd = fmt.comptimePrint("{s} source --minus", .{ audio_script }) },
            },
        },
        .{
            .keysym = Keysym.XF86AudioMute,
            .modifiers = Super,
            .action = .{
                .spawn_shell = .{ .cmd = fmt.comptimePrint("{s} source --mute", .{ audio_script }) },
            },
        },
        .{
            .keysym = Keysym.XF86MonBrightnessUp,
            .modifiers = 0,
            .action = .{
                .spawn_shell = .{ .cmd = fmt.comptimePrint("{s} --plus", .{ bright_script }) },
            },
        },
        .{
            .keysym = Keysym.XF86MonBrightnessDown,
            .modifiers = 0,
            .action = .{
                .spawn_shell = .{ .cmd = fmt.comptimePrint("{s} --minus", .{ bright_script }) },
            },
        },
    };

    const tag_num = 9;
    var tag_binddings: [tag_num*4]XkbBinding = undefined;
    for (0..tag_num) |i| {
        tag_binddings[i*4] = .{
            .keysym = Keysym.@"1"+i,
            .modifiers = Super,
            .action = .{ .set_output_tag = .{ .tag = 1 << i } },
        };
        tag_binddings[i*4+1] = .{
            .keysym = Keysym.@"1"+i,
            .modifiers = Super|Shift,
            .action = .{ .set_window_tag = .{ .tag = 1 << i } },
        };
        tag_binddings[i*4+2] = .{
            .keysym = Keysym.@"1"+i,
            .modifiers = Super|Ctrl,
            .action = .{ .toggle_output_tag = .{ .mask = 1 << i } },
        };
        tag_binddings[i*4+3] = .{
            .keysym = Keysym.@"1"+i,
            .modifiers = Super|Ctrl|Shift,
            .action = .{ .toggle_window_tag = .{ .mask = 1 << i } },
        };
    }

    break :blk bindings ++ tag_binddings;
};

pub const pointer_bindings = [_]PointerBinding {
    .{
        .button = Button.left,
        .modifiers = Super,
        .action = .pointer_move,
    },
    .{
        .button = Button.right,
        .modifiers = Super,
        .action = .pointer_resize,
    },
};


fn empty_appid_or_title(_: *const Rule, window: *const Window) bool {
    return window.app_id == null or window.app_id.?.len == 0 or window.title == null or window.title.?.len == 0;
}
pub const rules = [_]Rule {
    //  support regex by: https://github.com/mnemnion/mvzr
    // .{
    //     // match part
    //     .app_id = .{ .str = "pattern" } or .app_id = .compile("regex pattern"),
    //     .title = .{ .str = "pattern" } or .title = .compile("regex pattern"),
    //
    //     // apply part
    //     .tag = 1,
    //     .floating = true,
    //     .decoration = .csd or .ssd
    //     .is_terminal = true,
    //     .disable_swallow = true,
    //     .scroller_mfact = 0.5
    // },
    .{ .alter_match_fn = &empty_appid_or_title, .floating = true },
    .{ .app_id = .{ .str = "zenity" }, .floating = true },
    .{ .app_id = .{ .str = "DesktopEditors" }, .floating = true },
    .{ .app_id = .{ .str = "xdg-desktop-portal-gtk" }, .floating = true },
    .{ .app_id = .{ .str = "chromium" }, .tag = 1 << 1, .scroller_mfact = 0.9 },
    .{ .app_id = .{ .str = "QQ" }, .tag = 1 << 2, .floating = true },
    .{ .app_id = .{ .str = "wemeetapp" }, .tag = 1 << 2, .floating = true },
    .{ .app_id = .{ .str = "wechat" }, .tag = 1 << 2, .floating = true },
    .{ .app_id = .{ .str = "virt-manager" }, .floating = true },
    .{ .app_id = .{ .str = "Zotero" }, .floating = true },
    .{ .app_id = .{ .str = "stalonetray" }, .floating = true },
    .{ .app_id = .{ .str = "lazarus" }, .floating = true },
    .{ .app_id = .{ .str = "ONLYOFFICE" }, .floating = true },
    .{ .app_id = .{ .str = "foot" }, .is_terminal = true, .scroller_mfact = 0.8 },
    .{ .app_id = .{ .str = "footclient" }, .is_terminal = true, .scroller_mfact = 0.8 },
};

// libinput config
fn InputConfig(comptime T: type) type {
    return struct {
        value: T,
        pattern: ?Rule.Pattern = null,
    };
}
pub const tap: InputConfig(river.LibinputDeviceV1.TapState)                                 = .{ .value = .enabled };
pub const drag: InputConfig(river.LibinputDeviceV1.DragState)                               = .{ .value = .enabled };
pub const drag_lock: InputConfig(river.LibinputDeviceV1.DragLockState)                      = .{ .value = .disabled };
pub const three_finger_drag: InputConfig(river.LibinputDeviceV1.ThreeFingerDragState)       = .{ .value = .disabled };
pub const tap_button_map: InputConfig(river.LibinputDeviceV1.TapButtonMap)                  = .{ .value = .lrm };
pub const natural_scroll: InputConfig(river.LibinputDeviceV1.NaturalScrollState)            = .{ .value = .enabled, .pattern = .compile(".*[tT]ouchpad") };
pub const disable_while_typing: InputConfig(river.LibinputDeviceV1.DwtState)                = .{ .value = .enabled };
pub const disable_while_trackpointing: InputConfig(river.LibinputDeviceV1.DwtpState)        = .{ .value = .enabled };
pub const left_handed: InputConfig(river.LibinputDeviceV1.LeftHandedState)                  = .{ .value = .disabled };
pub const middle_button_emulation: InputConfig(river.LibinputDeviceV1.MiddleEmulationState) = .{ .value = .disabled };
pub const scroll_method: InputConfig(river.LibinputDeviceV1.ScrollMethod)                   = .{ .value = .two_finger };
pub const scroll_button: InputConfig(u32)                                                   = .{ .value = Button.middle };
pub const scroll_button_lock: InputConfig(river.LibinputDeviceV1.ScrollButtonLockState)     = .{ .value = .disabled };
pub const click_method: InputConfig(river.LibinputDeviceV1.ClickMethod)                     = .{ .value = .button_areas };
pub const clickfinger_button_map: InputConfig(river.LibinputDeviceV1.ClickfingerButtonMap)  = .{ .value = .lrm };
pub const send_events_modes: InputConfig(river.LibinputDeviceV1.SendEventsModes.Enum)       = .{ .value = .enabled };
pub const accel_profile: InputConfig(river.LibinputDeviceV1.AccelProfile)                   = .{ .value = .adaptive };
pub const accel_speed: InputConfig(f64)                                                     = .{ .value = 0.0 };
pub const calibration_matrix: InputConfig(?[6]f32)                                          = .{ .value = null };
pub const rotation_angle: InputConfig(u32)                                                  = .{ .value = 0 };
