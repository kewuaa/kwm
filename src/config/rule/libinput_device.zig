const Self = @This();

const std = @import("std");
const log = std.log.scoped(.libinput_device_rule);

const wayland = @import("wayland");
const river = wayland.client.river;

const kwm = @import("kwm");

const Pattern = @import("pattern.zig");


name: ?Pattern = null,

send_events_modes: ?river.LibinputDeviceV1.SendEventsModes.Enum = null,
tap: ?river.LibinputDeviceV1.TapState = null,
drag: ?river.LibinputDeviceV1.DragState = null,
drag_lock: ?river.LibinputDeviceV1.DragLockState = null,
tap_button_map: ?river.LibinputDeviceV1.TapButtonMap = null,
three_finger_drag: ?river.LibinputDeviceV1.ThreeFingerDragState = null,
calibration_matrix: ?[6]f32 = null,
accel_profile: ?river.LibinputDeviceV1.AccelProfile = null,
accel_speed: ?f64 = null,
natural_scroll: ?river.LibinputDeviceV1.NaturalScrollState = null,
left_handed: ?river.LibinputDeviceV1.LeftHandedState = null,
click_method: ?river.LibinputDeviceV1.ClickMethod = null,
clickfinger_button_map: ?river.LibinputDeviceV1.ClickfingerButtonMap = null,
middle_button_emulation: ?river.LibinputDeviceV1.MiddleEmulationState = null,
scroll_method: ?river.LibinputDeviceV1.ScrollMethod = null,
scroll_button: ?kwm.Button = null,
scroll_button_lock: ?river.LibinputDeviceV1.ScrollButtonLockState = null,
disable_while_typing: ?river.LibinputDeviceV1.DwtState = null,
disable_while_trackpointing: ?river.LibinputDeviceV1.DwtpState = null,
rotation_angle: ?u32 = null,
host: ?Pattern = null,


pub fn match(self: *const Self, name: ?[]const u8, hostname: ?[]const u8) bool {
    if (self.host) |host| {
        if (!host.is_match(hostname)) {
            return false;
        }
    }

    if (self.name) |pattern| {
        log.debug("try match name: `{s}` with {*}({*}: `{s}`)", .{ name orelse "null", self, &pattern, pattern.str });

        if (!pattern.is_match(name)) return false;
    }
    return true;
}
