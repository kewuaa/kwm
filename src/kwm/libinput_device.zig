const Self = @This();

const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.libinput_device);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const Config = @import("config");
const Context = @import("context.zig");

const utils = @import("utils.zig");
const types = @import("types.zig");

const InputDevice = @import("input_device.zig");


link: wl.list.Link = undefined,

rwm_libinput_device: *river.LibinputDeviceV1,

input_device: ?*InputDevice = null,

new: bool = true,

send_events_support: river.LibinputDeviceV1.SendEventsModes = mem.zeroes(river.LibinputDeviceV1.SendEventsModes),
send_events_current: river.LibinputDeviceV1.SendEventsModes = undefined,

tap_support: i32 = 0,
tap_current: river.LibinputDeviceV1.TapState = undefined,
drag_current: river.LibinputDeviceV1.DragState = undefined,
drag_lock_current: river.LibinputDeviceV1.DragLockState = undefined,
tap_button_map_current: river.LibinputDeviceV1.TapButtonMap = undefined,

three_finger_drag_support: i32 = 0,
three_finger_drag_current: river.LibinputDeviceV1.ThreeFingerDragState = undefined,

calibration_matrix_support: bool = false,
calibration_matrix_current: [6]f32 = undefined,

accel_profiles_support: river.LibinputDeviceV1.AccelProfiles = mem.zeroes(river.LibinputDeviceV1.AccelProfiles),
accel_profile_current: river.LibinputDeviceV1.AccelProfile = undefined,
accel_speed_current: f64 = undefined,

natural_scroll_support: bool = false,
natural_scroll_current: river.LibinputDeviceV1.NaturalScrollState = undefined,

left_handed_support: bool = false,
left_handed_current: river.LibinputDeviceV1.LeftHandedState = undefined,

click_method_support: river.LibinputDeviceV1.ClickMethods = mem.zeroes(river.LibinputDeviceV1.ClickMethods),
click_method_current: river.LibinputDeviceV1.ClickMethod = undefined,
clickfinger_button_map_current: river.LibinputDeviceV1.ClickfingerButtonMap = undefined,

middle_emulation_support: bool = false,
middle_emulation_current: river.LibinputDeviceV1.MiddleEmulationState = undefined,

scroll_method_support: river.LibinputDeviceV1.ScrollMethods = mem.zeroes(river.LibinputDeviceV1.ScrollMethods),
scroll_method_current: river.LibinputDeviceV1.ScrollMethod = undefined,
scroll_button_current: types.Button = undefined,
scroll_button_lock_current: river.LibinputDeviceV1.ScrollButtonLockState = undefined,

dwt_support: bool = false,
dwt_current: river.LibinputDeviceV1.DwtState = undefined,

dwtp_support: bool = false,
dwtp_current: river.LibinputDeviceV1.DwtpState = undefined,

rotation_support: bool = false,
rotation_current: u32 = undefined,


pub fn create(rwm_libinput_device: *river.LibinputDeviceV1) !*Self {
    const libinput_device = try utils.allocator.create(Self);
    errdefer utils.allocator.destroy(libinput_device);

    log.debug("<{*}> created", .{ libinput_device });

    libinput_device.* = .{
        .rwm_libinput_device = rwm_libinput_device,
    };
    libinput_device.link.init();

    rwm_libinput_device.setListener(*Self, rwm_libinput_device_listener, libinput_device);

    return libinput_device;
}


pub fn destroy(self: *Self) void {
    log.debug("<{*}> destroyed", .{ self });

    self.link.remove();
    self.rwm_libinput_device.destroy();

    utils.allocator.destroy(self);
}


pub fn manage(self: *Self) void {
    log.debug("<{*}> manage", .{ self });

    if (self.new) {
        self.new = false;

        self.apply_rules();
    }
}


pub fn apply_rules(self: *Self) void {
    log.debug("<{*}> apply rules", .{ self });

    const config = Config.get();
    const context = Context.get();

    for (config.libinput_device_rules) |rule| {
        if (rule.match((self.input_device orelse return).name, context.hostname)) {
            self.apply_rule(&rule);
            break;
        }
    }
}


fn apply_rule(self: *Self, rule: *const Config.LibinputDeviceRule) void {
    var bits: u32 = undefined;

    bits = @bitCast(self.send_events_support);
    if (bits != 0) {
        if (rule.send_events_modes) |mode| {
            const modes: river.LibinputDeviceV1.SendEventsModes = @bitCast(@as(u32, @intCast(@intFromEnum(mode))));

            if (mode == .enabled or @as(u32, @bitCast(modes)) & bits != 0) {
                if (modes != self.send_events_current) self.set_send_events(modes);
            }
        }
    }

    if (self.tap_support != 0) {
        if (rule.tap) |state| {
            if (self.tap_current != state) self.set_tap(state);
        }

        if (rule.drag) |state| {
            if (self.drag_current != state) self.set_drag(state);
        }

        if (rule.drag_lock) |state| {
            if (self.drag_lock_current != state) self.set_drag_lock(state);
        }

        if (rule.tap_button_map) |button_map| {
            if (self.tap_button_map_current != button_map) self.set_tap_button_map(button_map);
        }
    }

    if (self.three_finger_drag_support >= 3) {
        if (rule.three_finger_drag) |state| blk: {
            if (state == .enabled_4fg and self.three_finger_drag_support < 4) break :blk;
            if (self.three_finger_drag_current != state) self.set_three_finger_drag(state);
        }
    }

    if (self.calibration_matrix_support) {
        if (rule.calibration_matrix) |matrix| blk: {
            for (0..6) |i| {
                if (@abs(self.calibration_matrix_current[i]-matrix[i]) > 1e-6) {
                    self.set_calibration_matrix(&matrix);
                    break :blk;
                }
            }
        }
    }

    bits = @bitCast(self.accel_profiles_support);
    if (bits != 0) {
        if (rule.accel_profile) |profile| {
            if (profile == .none or @as(u32, @intCast(@intFromEnum(profile))) & bits != 0) {
                if (self.accel_profile_current != profile) self.set_accel_profile(profile);
            }
        }

        if (rule.accel_speed) |speed| {
            if (@abs(speed) > 1) {
                log.err("accel_speed must between [-1, 1], but found: {}", .{ speed });
            } else {
                if (@abs(self.accel_speed_current-speed) > 1e-6) self.set_accel_speed(speed);
            }
        }
    }


    if (self.natural_scroll_support) {
        if (rule.natural_scroll) |state| {
            if (self.natural_scroll_current != state) self.set_natural_scroll(state);
        }
    }

    if (self.left_handed_support) {
        if (rule.left_handed) |state| {
            if (self.left_handed_current != state) self.set_left_handed(state);
        }
    }

    bits = @bitCast(self.click_method_support);
    if (bits != 0) {
        if (rule.click_method) |method| {
            if (method == .none or @as(u32, @intCast(@intFromEnum(method))) & bits != 0) {
                if (self.click_method_current != method) self.set_click_method(method);
            }
        }

        if (self.click_method_support.clickfinger) {
            if (rule.clickfinger_button_map) |button_map| {
                if (self.clickfinger_button_map_current != button_map) self.set_clickfinger_button_map(button_map);
            }
        }
    }

    if (self.middle_emulation_support) {
        if (rule.middle_button_emulation) |state| {
            if (self.middle_emulation_current != state) self.set_middle_emulation(state);
        }
    }

    bits = @bitCast(self.scroll_method_support);
    if (bits != 0) {
        if (rule.scroll_method) |method| {
            if (method == .no_scroll or @as(u32, @intCast(@intFromEnum(method))) & bits != 0) {
                if (self.scroll_method_current != method) self.set_scroll_method(method);
            }
        }

        if (self.scroll_method_support.on_button_down) {
            if (rule.scroll_button) |button| {
                if (self.scroll_button_current != button) self.set_scroll_button(@intFromEnum(button));
            }

            if (rule.scroll_button_lock) |state| {
                if (self.scroll_button_lock_current != state) self.set_scroll_button_lock(state);
            }
        }
    }

    if (self.dwt_support) {
        if (rule.disable_while_typing) |state| {
            if (self.dwt_current != state) self.set_dwt(state);
        }
    }

    if (self.dwtp_support) {
        if (rule.disable_while_trackpointing) |state| {
            if (self.dwtp_current != state) self.set_dwtp(state);
        }
    }

    if (self.rotation_support) {
        if (rule.rotation_angle) |angle| {
            if (self.rotation_current != angle) self.set_rotation(angle);
        }
    }
}


fn set_tap(self: *Self, state: river.LibinputDeviceV1.TapState) void {
    log.debug("<{*}> set tap state to {s}", .{ self, @tagName(state) });

    const result = self.rwm_libinput_device.setTap(state) catch |err| {
        log.err("{*} set tap state to {s} failed: {}", .{ self, @tagName(state), err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_drag(self: *Self, state: river.LibinputDeviceV1.DragState) void {
    log.debug("<{*}> set drag state to {s}", .{ self, @tagName(state) });

    const result = self.rwm_libinput_device.setDrag(state) catch |err| {
        log.err("{*} set drag state to {s} failed: {}", .{ self, @tagName(state), err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_drag_lock(self: *Self, state: river.LibinputDeviceV1.DragLockState) void {
    log.debug("<{*}> set drag lock state to {s}", .{ self, @tagName(state) });

    const result = self.rwm_libinput_device.setDragLock(state) catch |err| {
        log.err("{*} set drag lock state to {s} failed: {}", .{ self, @tagName(state), err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_three_finger_drag(self: *Self, state: river.LibinputDeviceV1.ThreeFingerDragState) void {
    log.debug("<{*}> set three finger drag state to {s}", .{ self, @tagName(state) });

    const result = self.rwm_libinput_device.setThreeFingerDrag(state) catch |err| {
        log.err("{*} set three finger drag state to {s} failed: {}", .{ self, @tagName(state), err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_tap_button_map(self: *Self, button_map: river.LibinputDeviceV1.TapButtonMap) void {
    log.debug("<{*}> set tap button map to {s}", .{ self, @tagName(button_map) });

    const result = self.rwm_libinput_device.setTapButtonMap(button_map) catch |err| {
        log.err("{*} set tap button map to {s} failed: {}", .{ self, @tagName(button_map), err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_natural_scroll(self: *Self, state: river.LibinputDeviceV1.NaturalScrollState) void {
    log.debug("<{*}> set natural scroll state to {s}", .{ self, @tagName(state) });

    const result = self.rwm_libinput_device.setNaturalScroll(state) catch |err| {
        log.err("{*} set natural scroll state to {s} failed: {}", .{ self, @tagName(state), err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_dwt(self: *Self, state: river.LibinputDeviceV1.DwtState) void {
    log.debug("<{*}> set dwt state to {s}", .{ self, @tagName(state) });

    const result = self.rwm_libinput_device.setDwt(state) catch |err| {
        log.err("{*} set dwt state to {s} failed: {}", .{ self, @tagName(state), err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_dwtp(self: *Self, state: river.LibinputDeviceV1.DwtpState) void {
    log.debug("<{*}> set dwtp state to {s}", .{ self, @tagName(state) });

    const result = self.rwm_libinput_device.setDwtp(state) catch |err| {
        log.err("{*} set dwtp state to {s} failed: {}", .{ self, @tagName(state), err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_left_handed(self: *Self, state: river.LibinputDeviceV1.LeftHandedState) void {
    log.debug("<{*}> set left handed state to {s}", .{ self, @tagName(state) });

    const result = self.rwm_libinput_device.setLeftHanded(state) catch |err| {
        log.err("{*} set left handed state to {s} failed: {}", .{ self, @tagName(state), err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_middle_emulation(self: *Self, state: river.LibinputDeviceV1.MiddleEmulationState) void {
    log.debug("<{*}> set middle emulation state to {s}", .{ self, @tagName(state) });

    const result = self.rwm_libinput_device.setMiddleEmulation(state) catch |err| {
        log.err("{*} set middle emulation state to {s} failed: {}", .{ self, @tagName(state), err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_scroll_method(self: *Self, method: river.LibinputDeviceV1.ScrollMethod) void {
    log.debug("<{*}> set scroll method to {s}", .{ self, @tagName(method) });

    const result = self.rwm_libinput_device.setScrollMethod(method) catch |err| {
        log.err("{*} set scroll method to {s} failed: {}", .{ self, @tagName(method), err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_scroll_button(self: *Self, button: u32) void {
    log.debug("<{*}> set scroll button to {}", .{ self, button });

    const result = self.rwm_libinput_device.setScrollButton(button) catch |err| {
        log.err("{*} set scroll button to {} failed: {}", .{ self, button, err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_scroll_button_lock(self: *Self, state: river.LibinputDeviceV1.ScrollButtonLockState) void {
    log.debug("<{*}> set scroll button lock state to {s}", .{ self, @tagName(state) });

    const result = self.rwm_libinput_device.setScrollButtonLock(state) catch |err| {
        log.err("{*} set scroll button lock state to {s} failed: {}", .{ self, @tagName(state), err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_click_method(self: *Self, method: river.LibinputDeviceV1.ClickMethod) void {
    log.debug("<{*}> set click method to {s}", .{ self, @tagName(method) });

    const result = self.rwm_libinput_device.setClickMethod(method) catch |err| {
        log.err("{*} set click method to {s} failed: {}", .{ self, @tagName(method), err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_clickfinger_button_map(self: *Self, button_map: river.LibinputDeviceV1.ClickfingerButtonMap) void {
    log.debug("<{*}> set clickfinger button map to {s}", .{ self, @tagName(button_map) });

    const result = self.rwm_libinput_device.setClickfingerButtonMap(button_map) catch |err| {
        log.err("{*} set clickfinger button map to {s} failed: {}", .{ self, @tagName(button_map), err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_send_events(self: *Self, modes: river.LibinputDeviceV1.SendEventsModes) void {
    log.debug("<{*}> set send events modes to (disabled: {}, disabled_on_external_mouse: {})", .{ self, modes.disabled, modes.disabled_on_external_mouse });

    const result = self.rwm_libinput_device.setSendEvents(modes) catch |err| {
        log.err("{*} set send events to (disabled: {}, disabled_on_external_mouse: {}) failed: {}", .{ self, modes.disabled, modes.disabled_on_external_mouse, err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_accel_profile(self: *Self, profile: river.LibinputDeviceV1.AccelProfile) void {
    log.debug("<{*}> set accel profile to {s}", .{ self, @tagName(profile) });

    const result = self.rwm_libinput_device.setAccelProfile(profile) catch |err| {
        log.err("{*} set accel profile to {s} failed: {}", .{ self, @tagName(profile), err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_accel_speed(self: *Self, speed: f64) void {
    log.debug("<{*}> set accel speed to {}", .{ self, speed });

    var buffer: [1]f64 = undefined;
    var list: std.ArrayList(f64) = .initBuffer(&buffer);
    list.appendBounded(speed) catch unreachable;

    var arr = wl.Array.fromArrayList(f64, list);
    const result = self.rwm_libinput_device.setAccelSpeed(&arr) catch |err| {
        log.err("{*} set accel speed to {} failed: {}", .{ self, speed, err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_calibration_matrix(self: *Self, matrix: *const [6]f32) void {
    log.debug("<{*}> set calibration matrix to {any}", .{ self, matrix.* });

    var buffer: [6]f32 = undefined;
    var list: std.ArrayList(f32) = .initBuffer(&buffer);
    for (0..buffer.len) |i| {
        list.appendBounded(matrix[i]) catch unreachable;
    }

    var arr = wl.Array.fromArrayList(f32, list);
    const result = self.rwm_libinput_device.setCalibrationMatrix(&arr) catch |err| {
        log.err("{*} set calibration matrix to {any} failed: {}", .{ self, matrix.*, err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn set_rotation(self: *Self, angle: u32) void {
    log.debug("<{*}> set rotation angle to {}", .{ self, angle });

    const result = self.rwm_libinput_device.setRotation(angle) catch |err| {
        log.err("{*} set rotation angle to {} failed: {}", .{ self, angle, err });
        return;
    };

    result.setListener(*Self, rwm_libinput_result_listener, self);
}


fn rwm_libinput_device_listener(rwm_libinput_device: *river.LibinputDeviceV1, event: river.LibinputDeviceV1.Event, libinput_device: *Self) void {
    std.debug.assert(rwm_libinput_device == libinput_device.rwm_libinput_device);

    switch (event) {
        .input_device => |data| {
            log.debug("<{*}> input_device: {*}", .{ libinput_device, data.device });

            const rwm_input_device = data.device orelse return;
            const input_device: *InputDevice = @ptrCast(@alignCast(rwm_input_device.getUserData()));

            log.debug("<{*}> input_device, name: {s}", .{ libinput_device, input_device.name orelse "" });

            libinput_device.input_device = input_device;
        },


        .send_events_support => |data| {
            log.debug("<{*}> send_events_support, modes: (disabled: {}, disabled_on_external_mouse: {})", .{ libinput_device, data.modes.disabled, data.modes.disabled_on_external_mouse });

            libinput_device.send_events_support = data.modes;
        },
        .send_events_default => |data| {
            log.debug("<{*}> send_events_default, mode: (disabled: {}, disabled_on_external_mouse: {})", .{ libinput_device, data.mode.disabled, data.mode.disabled_on_external_mouse });
        },
        .send_events_current => |data| {
            log.debug("<{*}> send_events_current, mode: (disabled: {}, disabled_on_external_mouse: {})", .{ libinput_device, data.mode.disabled, data.mode.disabled_on_external_mouse });

            libinput_device.send_events_current = data.mode;
        },

        .tap_support => |data| {
            log.debug("<{*}> tap_support, finger_count: {}", .{ libinput_device, data.finger_count });

            libinput_device.tap_support = data.finger_count;
        },
        .tap_default => |data| {
            log.debug("<{*}> tap_default, state: {s}", .{ libinput_device, @tagName(data.state) });
        },
        .tap_current => |data| {
            log.debug("<{*}> tap_current, state: {s}", .{ libinput_device, @tagName(data.state) });

            libinput_device.tap_current = data.state;
        },
        .drag_default => |data| {
            log.debug("<{*}> drag_default, state: {s}", .{ libinput_device, @tagName(data.state) });
        },
        .drag_current => |data| {
            log.debug("<{*}> drag_current, state: {s}", .{ libinput_device, @tagName(data.state) });

            libinput_device.drag_current = data.state;
        },
        .drag_lock_default => |data| {
            log.debug("<{*}> drag_lock_default, state: {s}", .{ libinput_device, @tagName(data.state) });
        },
        .drag_lock_current => |data| {
            log.debug("<{*}> drag_lock_current, state: {s}", .{ libinput_device, @tagName(data.state) });

            libinput_device.drag_lock_current = data.state;
        },
        .tap_button_map_default => |data| {
            log.debug("<{*}> tap_button_map_default, button_map: {s}", .{ libinput_device, @tagName(data.button_map) });
        },
        .tap_button_map_current => |data| {
            log.debug("<{*}> tap_button_map_current, button_map: {s}", .{ libinput_device, @tagName(data.button_map) });

            libinput_device.tap_button_map_current = data.button_map;
        },


        .three_finger_drag_support => |data| {
            log.debug("<{*}> three_finger_drag_support, finger_count: {}", .{ libinput_device, data.finger_count });

            libinput_device.three_finger_drag_support = data.finger_count;
        },
        .three_finger_drag_default => |data| {
            log.debug("<{*}> three_finger_drag_default, state: {s}", .{ libinput_device, @tagName(data.state) });
        },
        .three_finger_drag_current => |data| {
            log.debug("<{*}> three_finger_drag_current, state: {s}", .{ libinput_device, @tagName(data.state) });

            libinput_device.three_finger_drag_current = data.state;
        },


        .calibration_matrix_support => |data| {
            log.debug("<{*}> calibration_matrix_support, supported: {}", .{ libinput_device, data.supported });

            libinput_device.calibration_matrix_support = data.supported != 0;
        },
        .calibration_matrix_default => |data| {
            log.debug("<{*}> calibration_matrix_default, matrix: {any}", .{ libinput_device, data.matrix.slice(f32) });
        },
        .calibration_matrix_current => |data| {
            log.debug("<{*}> calibration_matrix_current, matrix: {any}", .{ libinput_device, data.matrix.slice(f32) });

            for (0.., data.matrix.slice(f32)) |i, v| {
                libinput_device.calibration_matrix_current[i] = v;
            }
        },


        .accel_profiles_support => |data| {
            log.debug("<{*}> accel_profiles_support, profiles: (flat: {}, adaptive: {}, custom: {})", .{ libinput_device, data.profiles.flat, data.profiles.adaptive, data.profiles.custom });

            libinput_device.accel_profiles_support = data.profiles;
        },
        .accel_profile_default => |data| {
            log.debug("<{*}> accel_profile_default, profile: {s}", .{ libinput_device, @tagName(data.profile) });
        },
        .accel_profile_current => |data| {
            log.debug("<{*}> accel_profile_current, profile: {s}", .{ libinput_device, @tagName(data.profile) });

            libinput_device.accel_profile_current = data.profile;
        },
        .accel_speed_default => |data| {
            log.debug("<{*}> accel_speed_default, speed: {any}", .{ libinput_device, data.speed.slice(f64) });
        },
        .accel_speed_current => |data| {
            log.debug("<{*}> accel_speed_current, speed: {any}", .{ libinput_device, data.speed.slice(f64) });

            libinput_device.accel_speed_current = data.speed.slice(f64)[0];
        },


        .natural_scroll_support => |data| {
            log.debug("<{*}> natural_scroll_support, suppported: {}", .{ libinput_device, data.supported });

            libinput_device.natural_scroll_support = data.supported != 0;
        },
        .natural_scroll_default => |data| {
            log.debug("<{*}> natural_scroll_default, state: {s}", .{ libinput_device, @tagName(data.state) });
        },
        .natural_scroll_current => |data| {
            log.debug("<{*}> natural_scroll_current, state: {s}", .{ libinput_device, @tagName(data.state) });

            libinput_device.natural_scroll_current = data.state;
        },


        .left_handed_support => |data| {
            log.debug("<{*}> left_handed_support, supported: {}", .{ libinput_device, data.supported });

            libinput_device.left_handed_support = data.supported != 0;
        },
        .left_handed_default => |data| {
            log.debug("<{*}> left_handed_default, state: {s}", .{ libinput_device, @tagName(data.state) });
        },
        .left_handed_current => |data| {
            log.debug("<{*}> left_handed_current, state: {s}", .{ libinput_device, @tagName(data.state) });

            libinput_device.left_handed_current = data.state;
        },


        .click_method_support => |data| {
            log.debug("<{*}> click_method_support, methods: (button_areas: {}, clickfinger: {})", .{ libinput_device, data.methods.button_areas, data.methods.clickfinger });

            libinput_device.click_method_support = data.methods;
        },
        .click_method_default => |data| {
            log.debug("<{*}> click_method_default, method: {s}", .{ libinput_device, @tagName(data.method) });
        },
        .click_method_current => |data| {
            log.debug("<{*}> click_method_current, method: {s}", .{ libinput_device, @tagName(data.method) });

            libinput_device.click_method_current = data.method;
        },
        .clickfinger_button_map_default => |data| {
            log.debug("<{*}> clickfinger_button_map_default, button_map: {s}", .{ libinput_device, @tagName(data.button_map) });
        },
        .clickfinger_button_map_current => |data| {
            log.debug("<{*}> clickfinger_button_map_current, button_map: {s}", .{ libinput_device, @tagName(data.button_map) });

            libinput_device.clickfinger_button_map_current = data.button_map;
        },


        .middle_emulation_support => |data| {
            log.debug("<{*}> middle_emulation_support, supported: {}", .{ libinput_device, data.supported });

            libinput_device.middle_emulation_support = data.supported != 0;
        },
        .middle_emulation_default => |data| {
            log.debug("<{*}> middle_emulation_default, state: {s}", .{ libinput_device, @tagName(data.state) });
        },
        .middle_emulation_current => |data| {
            log.debug("<{*}> middle_emulation_current, state: {s}", .{ libinput_device, @tagName(data.state) });

            libinput_device.middle_emulation_current = data.state;
        },


        .scroll_method_support => |data| {
            log.debug(
                "<{*}> scroll_method_support, methods: (two_finger: {}, edge: {}, on_button_down: {})",
                .{ libinput_device, data.methods.two_finger, data.methods.edge, data.methods.on_button_down },
            );

            libinput_device.scroll_method_support = data.methods;
        },
        .scroll_method_default => |data| {
            log.debug("<{*}> scroll_method_default, method: {s}", .{ libinput_device, @tagName(data.method) });
        },
        .scroll_method_current => |data| {
            log.debug("<{*}> scroll_method_current, method: {s}", .{ libinput_device, @tagName(data.method) });

            libinput_device.scroll_method_current = data.method;
        },
        .scroll_button_default => |data| {
            log.debug("<{*}> scroll_button_default, button: {}", .{ libinput_device, data.button });
        },
        .scroll_button_current => |data| {
            log.debug("<{*}> scroll_button_current, button: {}", .{ libinput_device, data.button });

            libinput_device.scroll_button_current = @enumFromInt(data.button);
        },
        .scroll_button_lock_default => |data| {
            log.debug("<{*}> scroll_button_lock_default, state: {s}", .{ libinput_device, @tagName(data.state) });
        },
        .scroll_button_lock_current => |data| {
            log.debug("<{*}> scroll_button_lock_current, state: {s}", .{ libinput_device, @tagName(data.state) });

            libinput_device.scroll_button_lock_current = data.state;
        },


        .dwt_support => |data| {
            log.debug("<{*}> dwt_support, suppported: {}", .{ libinput_device, data.supported });

            libinput_device.dwt_support = data.supported != 0;
        },
        .dwt_default => |data| {
            log.debug("<{*}> dwt_default, state: {s}", .{ libinput_device, @tagName(data.state) });
        },
        .dwt_current => |data| {
            log.debug("<{*}> dwt_current, state: {s}", .{ libinput_device, @tagName(data.state) });

            libinput_device.dwt_current = data.state;
        },


        .dwtp_support => |data| {
            log.debug("<{*}> dwtp_support, suppported: {}", .{ libinput_device, data.supported });

            libinput_device.dwt_support = data.supported != 0;
        },
        .dwtp_default => |data| {
            log.debug("<{*}> dwtp_default, state: {s}", .{ libinput_device, @tagName(data.state) });
        },
        .dwtp_current => |data| {
            log.debug("<{*}> dwtp_current, state: {s}", .{ libinput_device, @tagName(data.state) });

            libinput_device.dwtp_current = data.state;
        },


        .rotation_support => |data| {
            log.debug("<{*}> rotation_support, supported: {}", .{ libinput_device, data.supported });

            libinput_device.rotation_support = data.supported != 0;
        },
        .rotation_default => |data| {
            log.debug("<{*}> rotation_default, angle: {}", .{ libinput_device, data.angle });
        },
        .rotation_current => |data| {
            log.debug("<{*}> rotation_current, angle: {}", .{ libinput_device, data.angle });

            libinput_device.rotation_current = data.angle;
        },


        .removed => {
            log.debug("<{*}> removed", .{ libinput_device });

            libinput_device.destroy();
        },
    }
}


fn rwm_libinput_result_listener(rwm_libinput_result: *river.LibinputResultV1, event: river.LibinputResultV1.Event, rwm_libinput_device: *Self) void {
    _ = rwm_libinput_device;

    log.debug("<{*}> configuration result: {s}", .{ rwm_libinput_result, @tagName(event) });

    rwm_libinput_result.destroy();
}
