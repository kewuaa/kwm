const Self = @This();

const build_options = @import("build_options");
const std = @import("std");
const mem = std.mem;
const math = std.math;
const log = std.log.scoped(.output);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const river = wayland.client.river;

const config = @import("config");

const utils = @import("utils.zig");
const Layout = @import("layout.zig");
const Context = @import("context.zig");
const Window = @import("window.zig");
const types = @import("types.zig");

pub const State = struct {
    layouts: [32]Layout,

    tag: u32 = 1,
    main_tag: u32 = 1,
    prev_tag: u32 = 1,
    prev_main_tag: u32 = 1,
    layout_tag: [32]Layout.Type,
    prev_layout_tag: [32]Layout.Type,
};

const ctx = Context.get();


link: wl.list.Link = undefined,

wl_output: ?*wl.Output = null,
rwm_output: *river.OutputV1,
rwm_layer_shell_output: ?*river.LayerShellOutputV1,

layouts: [32]Layout,

tag: u32 = 1,
main_tag: u32 = 1,
prev_tag: u32 = 1,
prev_main_tag: u32 = 1,
layout_tag: [32]Layout.Type,
prev_layout_tag: [32]Layout.Type,

name: ?[]const u8 = null,
x: i32 = undefined,
y: i32 = undefined,
width: i32 = undefined,
height: i32 = undefined,

background: if (build_options.background_enabled) @import("background.zig") else void = undefined,
bar: if (build_options.bar_enabled) @import("bar.zig") else void = undefined,


pub fn create(
    rwm_output: *river.OutputV1,
    rwm_layer_shell_output: ?*river.LayerShellOutputV1,
) !*Self {
    const output = try ctx.gpa.create(Self);
    errdefer ctx.gpa.destroy(output);

    defer log.debug("<{*}> created", .{ output });

    output.* = .{
        .rwm_output = rwm_output,
        .rwm_layer_shell_output = rwm_layer_shell_output,
        .layouts = .{ ctx.cfg.layout } ** 32,
        .layout_tag = .{ ctx.cfg.default_layout } ** 32,
        .prev_layout_tag = .{ ctx.cfg.default_layout } ** 32,
    };
    output.link.init();

    if (comptime build_options.background_enabled) {
        try output.background.init(output);
    }

    if (comptime build_options.bar_enabled) {
        try output.bar.init(output);
    }

    rwm_output.setListener(*Self, rwm_output_listener, output);

    if (rwm_layer_shell_output) |layer_shell_output| {
        layer_shell_output.setListener(*Self, rwm_layer_shell_output_listener, output);
    }

    return output;
}


pub fn destroy(self: *Self) void {
    defer log.debug("<{*}> destroyed", .{ self });

    {
        var it = ctx.seats.safeIterator(.forward);
        while (it.next()) |seat| {
            switch (seat.previous_focused) {
                .output => |output| if (self == output) {
                    seat.previous_focused = .none;
                },
                else => {}
            }
        }
    }

    self.set_name(null);

    self.link.remove();
    self.rwm_output.destroy();
    if (self.wl_output) |wl_output| wl_output.destroy();

    if (self.rwm_layer_shell_output) |rwm_layer_shell_output| {
        rwm_layer_shell_output.destroy();
    }

    if (comptime build_options.background_enabled) self.background.deinit();

    if (comptime build_options.bar_enabled) self.bar.deinit();

    ctx.gpa.destroy(self);
}


pub fn get_state(self: *const Self) State {
    var state: State = undefined;
    inline for (@typeInfo(State).@"struct".fields) |field| {
        @field(state, field.name) = @field(self, field.name);
    }
    return state;
}


pub fn sync_state(self: *Self, state: *const State) void {
    inline for (@typeInfo(State).@"struct".fields) |field| {
        @field(self, field.name) = @field(state, field.name);
    }
}


const State = struct {
    layout: Layout,

    tag: u32 = 1,
    main_tag: u32 = 1,
    prev_tag: u32 = 1,
    prev_main_tag: u32 = 1,
    layout_tag: [32]Layout.Type,
    prev_layout_tag: [32]Layout.Type,
};
pub fn get_state(self: *Self) State {
    var state: State = undefined;
    inline for (@typeInfo(State).@"struct".fields) |field_info| {
        @field(state, field_info.name) = @field(self, field_info.name);
    }
    return state;
}
pub fn sync_state(self: *Self, state: *const State) void {
    inline for (@typeInfo(State).@"struct".fields) |field_info| {
        @field(self, field_info.name) = @field(state, field_info.name);
    }
}


pub fn apply_rules(self: *Self) void {
    log.debug("<{*}> apply rules", .{ self });

    for (ctx.cfg.output_rules) |rule| {
        if (rule.match(self.name)) {
            self.apply_rule(&rule);
            break;
        }
    }
}


pub inline fn exclusive_x(self: *Self) i32 {
    return self.x;
}


pub inline fn exclusive_y(self: *Self) i32 {
    return
        if (comptime build_options.bar_enabled)
            if (ctx.cfg.bar.position == .bottom or self.bar.hidden) self.y
            else self.y + self.bar.height(true)
        else self.y;
}


pub inline fn exclusive_width(self: *Self) i32 {
    return self.width;
}


pub inline fn exclusive_height(self: *Self) i32 {
    return
        if (comptime build_options.bar_enabled)
            if (self.bar.hidden) self.height
            else self.height - self.bar.height(true)
        else self.height;
}


pub fn fullscreen_window(self: *Self) ?*Window {
    {
        var it = ctx.windows.safeIterator(.forward);
        while (it.next()) |window| {
            if (!window.is_visible_in(self)) continue;

            switch (window.fullscreen) {
                .output => |output| {
                    if (output == self) {
                        return window;
                    }
                },
                else => {}
            }
        }
    }

    return null;
}


pub fn master_window(self: *Self) ?*Window {
    {
        var it = ctx.windows.safeIterator(.forward);
        while (it.next()) |window| {
            if (window.is_visible_in(self) and !window.floating) {
                return window;
            }
        }
    }

    return null;
}


pub fn set_presentation(self: *Self, mode: river.OutputV1.PresentationMode) void {
    log.debug("<{*}> set presentation mode to {s}", .{ self, @tagName(mode) });

    self.rwm_output.setPresentationMode(mode);
}


pub fn set_tag(self: *Self, tag: u32) void {
    if (tag == 0 or self.tag == tag) return;

    log.debug("<{*}> set tag: {b}", .{ self, tag });

    self.prev_tag = self.tag;
    self.prev_main_tag = self.main_tag;

    self.tag = tag;
    if (self.main_tag & tag == 0) {
        // use the lowest bit 1 as new main tag
        self.main_tag = tag ^ (tag & (tag-1));

        log.debug("<{*}> update main tag to {b}", .{ self, self.main_tag });
    }

    if (comptime build_options.bar_enabled) self.bar.damage(.tags);
}


pub fn switch_to_previous_tag(self: *Self) void {
    const prev_main_tag = self.prev_main_tag;

    self.set_tag(self.prev_tag);
    log.debug("<{*}> switch to previous tag", .{ self });

    self.main_tag = prev_main_tag;
    log.debug("<{*}> switch to previous main tag", .{ self });
}


pub fn occupied_tags(self: *const Self) u32 {
    var mask: u32 = 0;
    {
        var it = ctx.windows.safeIterator(.forward);
        while (it.next()) |window| {
            if (window.output == self and window.swallowed_by == null) mask |= window.tag;
        }
    }
    return mask;
}


pub fn toggle_tag(self: *Self, mask: u32) void {
    if (self.tag ^ mask == 0) return;

    log.debug("<{*}> toggle tag: (tag: {b}, mask: {b})", .{ self, self.tag, mask });

    self.tag ^= mask;
    // if there is only one bit 1, set it as new main tag
    if (self.tag & (self.tag-1) == 0) {
        log.debug("<{*}> update main tag to {b}", .{ self, self.tag });

        self.main_tag = self.tag;
    }

    if (comptime build_options.bar_enabled) self.bar.damage(.tags);
}


pub fn current_layout(self: *Self) union(Layout.Type) {
    tile: *Layout.Tile,
    grid: *Layout.Grid,
    monocle: *Layout.Monocle,
    deck: *Layout.Deck,
    scroller: *Layout.Scroller,
    centered_master: *Layout.CenteredMaster,
    float,
} {
    std.debug.assert(self.main_tag != 0 and self.main_tag & (self.main_tag-1) == 0);

    const i = @ctz(self.main_tag);
    return switch (self.layout_tag[i]) {
        .float => .float,
        inline else => |t| @unionInit(
            @TypeOf(self.current_layout()),
            @tagName(t),
            &@field(self.layouts[i], @tagName(t))
        ),
    };
}


pub inline fn scroller_mfact(self: *const Self) f32 {
    std.debug.assert(self.main_tag != 0 and self.main_tag & (self.main_tag-1) == 0);

    const i = @ctz(self.main_tag);
    return self.layouts[i].scroller.mfact;
}


pub fn set_current_layout(self: *Self, layout_t: Layout.Type) void {
    std.debug.assert(self.main_tag != 0 and self.main_tag & (self.main_tag-1) == 0);

    const i = @ctz(self.main_tag);
    if (self.layout_tag[i] == layout_t) return;

    log.debug("<{*}>(tag: {b}) set layout to {s}", .{ self, self.main_tag, @tagName(layout_t) });

    self.prev_layout_tag[i] = self.layout_tag[i];
    self.layout_tag[i] = layout_t;

    if (comptime build_options.bar_enabled) self.bar.damage(.layout);
}


pub fn switch_to_previous_layout(self: *Self) void {
    log.debug("<{*}> tag {b} switch to previous layout", .{ self, self.main_tag });

    const i = @ctz(self.main_tag);
    self.set_current_layout(self.prev_layout_tag[i]);
}


pub fn manage(self: *Self) void {
    switch (self.current_layout()) {
        .float => {},
        inline else => |layout| layout.arrange(self) catch |err| {
            log.err("<{*}> arrange windows with {*} failed: {}", .{ self, &layout, err });
            return;
        },
    }

    log.debug("<{*}> managed", .{ self });
}


fn apply_rule(self: *Self, rule: *const config.OutputRule) void {
    if (rule.presentation_mode) |mode| self.set_presentation(mode);
    if (rule.layout) |layout| for (&self.layouts) |*l| {
        l.* = config.meta.override(l.*, layout);
    };
    if (rule.default_layout) |default_layout| {
        self.layout_tag = .{ default_layout } ** 32;
        self.prev_layout_tag = .{ default_layout } ** 32;
    }
}


fn set_name(self: *Self, name: ?[]const u8) void {
    if (self.name) |name_| {
        ctx.gpa.free(name_);
        self.name = null;
    }

    if (name) |name_| {
        self.name = ctx.gpa.dupe(u8, name_) catch null;
    }
}


fn rwm_output_listener(rwm_output: *river.OutputV1, event: river.OutputV1.Event, output: *Self) void {
    std.debug.assert(rwm_output == output.rwm_output);

    switch (event) {
        .dimensions => |data| {
            log.debug("<{*}> new dimensions: (width: {}, height: {})", .{ output, data.width, data.height });

            output.width = data.width;
            output.height = data.height;

            if (comptime build_options.background_enabled) output.background.damage();
            if (comptime build_options.bar_enabled) output.bar.damage(.all);
        },
        .position => |data| {
            log.debug("<{*}> new position: (x: {}, y: {})", .{ output, data.x, data.y });

            output.x = data.x;
            output.y = data.y;

            if (comptime build_options.background_enabled) output.background.damage();
            if (comptime build_options.bar_enabled) output.bar.damage(.all);
        },
        .removed => {
            log.debug("<{*}> removed, name: {s}", .{ output, output.name orelse "" });

            ctx.prepare_remove_output(output);

            output.destroy();
        },
        .wl_output => |data| {
            log.debug("<{*}> wl_output: {}", .{ output, data.name });

            const wl_output = ctx.wl_registry.bind(data.name, wl.Output, 4) catch return;
            output.wl_output = wl_output;
            wl_output.setListener(*Self, wl_output_listener, output);
        },
    }
}


fn rwm_layer_shell_output_listener(
    rwm_layer_shell_output: *river.LayerShellOutputV1,
    event: river.LayerShellOutputV1.Event,
    output: *Self,
) void {
    std.debug.assert(rwm_layer_shell_output == output.rwm_layer_shell_output.?);

    switch (event) {
        .non_exclusive_area => |data| {
            log.debug(
                "<{*}> non exclusive area: (width: {}, height: {}, x: {}, y: {})",
                .{ output, data.width, data.height, data.x, data.y },
            );

            output.width = data.width;
            output.height = data.height;
            output.x = data.x;
            output.y = data.y;

            if (comptime build_options.bar_enabled) {
                output.bar.damage(.all);
            }
        },
    }
}


fn wl_output_listener(wl_output: *wl.Output, event: wl.Output.Event, output: *Self) void {
    std.debug.assert(wl_output == output.wl_output.?);

    switch (event) {
        .geometry => |data| {
            log.debug(
                "<{*}> geometry: (x: {}, y: {}, physical_width: {}, physical_height: {}, subpixel: {s}, make: {s}, model: {s}, transform: {s})",
                .{ output, data.x, data.y, data.physical_width, data.physical_height, @tagName(data.subpixel), data.make, data.model, @tagName(data.transform) },
            );
        },
        .mode => |data| {
            log.debug(
                "<{*}> mode: (flags: (current: {}, preferred: {}), width: {}, height: {}, refresh: {})",
                .{ output, data.flags.current, data.flags.preferred, data.width, data.height, data.refresh },
            );
        },
        .scale => |data| {
            log.debug("<{*}> scale: {}", .{ output, data.factor });
        },
        .name => |data| {
            log.debug("<{*}> name: {s}", .{ output, data.name });

            const name = mem.span(data.name);
            output.set_name(name);

            if (ctx.output_states.fetchRemove(name)) |kv| {
                log.debug("<{*}> restore state: {any}", .{ output, kv.value });
                output.sync_state(kv.value);
                ctx.gpa.free(kv.key);
                ctx.gpa.destroy(kv.value);

                ctx.rwm.manageDirty();
            }

            {
                var it = ctx.windows.safeIterator(.forward);
                while (it.next()) |window| {
                    if (window.former_output) |former| {
                        if (mem.eql(u8, former, name)) {
                            log.debug("{*} former output match `{s}`", .{ window, name });
                            window.set_output(output, true);
                        }
                    }
                }
            }
        },
        .description => |data| {
            log.debug("<{*}> description: {s}", .{ output, data.description });
        },
        .done => {
            log.debug("<{*}> done", .{ output });

            output.apply_rules();
        }
    }
}
