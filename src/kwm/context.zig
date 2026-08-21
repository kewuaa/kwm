const Self = @This();

const build_options = @import("build_options");
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const fmt = std.fmt;
const mem = std.mem;
const math = std.math;
const heap = std.heap;
const process = std.process;
const log = std.log.scoped(.context);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const river = wayland.client.river;

const posix = @import("posix");
const config = @import("config");

const utils = @import("utils.zig");
const types = @import("types.zig");
const Seat = @import("seat.zig");
const Output = @import("output.zig");
const Window = @import("window.zig");
const KeyRepeat = @import("key_repeat.zig");
const ShellSurface = @import("shell_surface.zig");

const TimerTask = struct {
    time: Io.Timestamp,
    handler: *const fn(context: *Self) void,

    pub fn compare(context: void, task1: TimerTask, task2: TimerTask) math.Order {
        _ = context;
        return math.order(task1.time.toNanoseconds(), task2.time.toNanoseconds());
    }
};

var ctx: Self = undefined;
var inited: bool = false;
var mode_buffer: [16]u8 = undefined;


gpa: mem.Allocator,
io: Io,
init_env: *const process.Environ,

config_path: []const u8,
cfg: config.Config = undefined,

wl_registry: *wl.Registry,
wl_compositor: *wl.Compositor,
wl_subcompositor: *wl.Subcompositor,
wl_shm: *wl.Shm,
wp_viewporter: *wp.Viewporter,
wp_cursor_shape_manager: *wp.CursorShapeManagerV1,
wp_fractional_scale_manager: *wp.FractionalScaleManagerV1,
wp_single_pixel_buffer_manager: *wp.SinglePixelBufferManagerV1,
rwm: *river.WindowManagerV1,
rwm_xkb_bindings: *river.XkbBindingsV1,
rwm_layer_shell: *river.LayerShellV1,
rwm_inputs: if (build_options.kwim_enabled) types.RiverInputs else void = if (build_options.kwim_enabled) .{} else {},

// seperate layer between floating and nonfloating
wl_surface: *wl.Surface = undefined,
layer_marker: ShellSurface = undefined,

timer_tasks: std.PriorityQueue(TimerTask, void, TimerTask.compare) = .empty,

seats: wl.list.Head(Seat, .link) = undefined,
current_seat: ?*Seat = null,

outputs: wl.list.Head(Output, .link) = undefined,
current_output: ?*Output = null,

window_to_lift: ?*Window = null,
windows: wl.list.Head(Window, .link) = undefined,
focus_stack: wl.list.Head(Window, .flink) = undefined,

key_repeat: ?KeyRepeat,

bar_status_fd: ?posix.fd_t = null,

terminal_windows: std.AutoHashMap(i32, *Window) = undefined,
output_states: std.StringHashMap(*Output.State) = undefined,

mode: []const u8,
running: bool = true,
any_inputs_plugged: bool = false,
env: process.Environ.Map = undefined,
startup_processes: std.ArrayList(process.Child) = .empty,
quit_hook: ?struct {
    pid: i32,
    exit_session: bool,
} = null,


pub inline fn check_init() void {
    if (!inited) @panic("context has not been initialized yet");
}


pub fn init(
    gpa: mem.Allocator,
    io: Io,
    init_env: *const process.Environ,
    config_path: []const u8,
    wl_registry: *wl.Registry,
    wl_compositor: *wl.Compositor,
    wl_subcompositor: *wl.Subcompositor,
    wl_shm: *wl.Shm,
    wp_viewporter: *wp.Viewporter,
    wp_cursor_shape_manager: *wp.CursorShapeManagerV1,
    wp_fractional_scale_manager: *wp.FractionalScaleManagerV1,
    wp_single_pixel_buffer_manager: *wp.SinglePixelBufferManagerV1,
    rwm: *river.WindowManagerV1,
    rwm_xkb_bindings: *river.XkbBindingsV1,
    rwm_layer_shell: *river.LayerShellV1,
    rwm_inputs: types.RiverInputs,
) !void {
    // initialize once
    if (inited) return;

    if (comptime build_options.bar_enabled) {
        _ = @import("fcft").init(.auto, false, .err);
    }

    log.info("init context", .{});

    ctx = .{
        .gpa = gpa,
        .io = io,
        .init_env = init_env,
        .config_path = config_path,
        .wl_registry = wl_registry,
        .wl_compositor = wl_compositor,
        .wl_subcompositor = wl_subcompositor,
        .wl_shm = wl_shm,
        .wp_viewporter = wp_viewporter,
        .wp_cursor_shape_manager = wp_cursor_shape_manager,
        .wp_fractional_scale_manager = wp_fractional_scale_manager,
        .wp_single_pixel_buffer_manager = wp_single_pixel_buffer_manager,
        .rwm = rwm,
        .rwm_xkb_bindings = rwm_xkb_bindings,
        .rwm_layer_shell = rwm_layer_shell,
        .key_repeat = undefined,
        .terminal_windows = .init(gpa),
        .output_states = .init(gpa),
        .mode = fmt.bufPrint(&mode_buffer, "{s}", .{ config.default_mode }) catch return error.ModeNameTooLong,
    };

    const wl_surface = try wl_compositor.createSurface();
    errdefer wl_surface.destroy();
    const wl_region = try wl_compositor.createRegion();
    defer wl_region.destroy();
    wl_surface.setInputRegion(wl_region);
    wl_surface.setOpaqueRegion(null);
    try ctx.layer_marker.init(wl_surface, .layer_marker);
    ctx.wl_surface = wl_surface;
    wl_surface.commit();

    ctx.seats.init();
    ctx.outputs.init();
    ctx.windows.init();
    ctx.focus_stack.init();
    ctx.key_repeat.?.init() catch {
        ctx.key_repeat = null;
    };

    ctx.load_config();
    ctx.init_env_map();
    ctx.run_startup_cmds();

    rwm.setListener(*Self, rwm_listener, &ctx);
    if (comptime build_options.kwim_enabled) {
        ctx.rwm_inputs = rwm_inputs;

        if (ctx.rwm_inputs.input_manager) |input_manager| {
            input_manager.setListener(*Self, rwm_input_manager_listener, &ctx);
        }
        if (ctx.rwm_inputs.libinput_config) |libinput_config| {
            libinput_config.setListener(*Self, rwm_libinput_config_listener, &ctx);
        }
        if (ctx.rwm_inputs.xkb_config) |xkb_config| {
            xkb_config.setListener(*Self, rwm_xkb_config_listener, &ctx);
        }
    }

    inited = true;
}


pub fn deinit() void {
    std.debug.assert(inited);
    defer inited = false;

    log.info("deinit context", .{});

    if (comptime build_options.bar_enabled) {
        @import("fcft").fini();
    }

    ctx.wl_registry.destroy();
    ctx.wl_compositor.destroy();
    ctx.wl_subcompositor.destroy();
    ctx.wl_shm.destroy();
    ctx.wp_viewporter.destroy();
    ctx.wp_cursor_shape_manager.destroy();
    ctx.wp_fractional_scale_manager.destroy();
    ctx.wp_single_pixel_buffer_manager.destroy();
    ctx.rwm.destroy();
    ctx.rwm_xkb_bindings.destroy();
    ctx.rwm_layer_shell.destroy();
    ctx.layer_marker.deinit();
    ctx.wl_surface.destroy();
    if (comptime build_options.kwim_enabled) {
        ctx.rwm_inputs.destroy();
    }

    ctx.timer_tasks.deinit(ctx.gpa);

    // first destroy windows for it's destroy function may depends on others
    {
        var it = ctx.windows.safeIterator(.forward);
        while (it.next()) |window| {
            window.destroy();
        }
        ctx.windows.init();
        ctx.focus_stack.init();
    }

    {
        var it = ctx.seats.safeIterator(.forward);
        while (it.next()) |seat| {
            seat.destroy();
        }
        ctx.seats.init();
    }
    ctx.current_seat = null;

    {
        var it = ctx.outputs.safeIterator(.forward);
        while (it.next()) |output| {
            output.destroy();
        }
        ctx.outputs.init();
    }
    ctx.current_output = null;

    if (ctx.key_repeat) |*key_repeat| key_repeat.deinit();

    if (ctx.is_listening_status()) {
        ctx.stop_listening_status();
    }

    ctx.terminal_windows.deinit();

    {
        var it = ctx.output_states.iterator();
        while (it.next()) |kv| {
            ctx.gpa.free(kv.key_ptr.*);
            ctx.gpa.destroy(kv.value_ptr.*);
        }
    }
    ctx.output_states.deinit();

    ctx.env.deinit();

    ctx.kill_startup_process();
    ctx.startup_processes.deinit(ctx.gpa);

    config.free(ctx.gpa, ctx.cfg);
}


pub inline fn get() *Self {
    return &ctx;
}


pub fn run_later(self: *Self, delay: Io.Duration, handler: *const fn(*Self) void) void {
    log.debug("run {*} {}ms later", .{ handler, delay.toMilliseconds() });

    const now = Io.Timestamp.now(self.io, .awake);
    const time = now.addDuration(delay);
    self.timer_tasks.push(self.gpa, .{ .time = time, .handler = handler }) catch |err| {
        log.err("push failed: {}", .{ err });
        return;
    };
}


pub fn run_timer_tasks(self: *Self) void {
    log.debug("run timer tasks", .{});

    while (self.timer_tasks.peek()) |*task| {
        const now = std.Io.Timestamp.now(self.io, .awake);
        if (now.toMilliseconds() >= task.time.toMilliseconds()) {
            log.debug("run {*}", .{ task.handler });
            task.handler(self);
        } else break;
        _ = self.timer_tasks.pop();
    }
}


pub fn reload_config(self: *Self) void {
    log.debug("reloading config", .{});

    const mask = config.reload(
        .{ .gpa = self.gpa, .io = self.io, .env = &self.env },
        &self.cfg,
        self.config_path
    ) catch |err| {
        log.err("reload configuration failed: {}", .{ err });
        return;
    };

    log.debug("mask: {any}", .{ mask });

    if (mask.env) {
        self.env.deinit();
        self.init_env_map();
    }

    // if (mask.startup_cmds) {
    //     self.kill_startup_process();
    //     self.run_startup_cmds();
    // }

    if (mask.xcursor_theme or mask.bindings) {
        var it = self.seats.safeIterator(.forward);
        while (it.next()) |seat| {
            if (mask.xcursor_theme) {
                seat.refresh_xursor_theme();
            }
            if (mask.bindings) {
                seat.clear_bindings();
                seat.create_bindings();
                seat.mode = null;
            }
        }
    }

    if (mask.window_rules) {
        var it = self.windows.safeIterator(.forward);
        while (it.next()) |window| {
            window.apply_rules();
        }
    }

    if (mask.output_rules) {
        var it = self.outputs.safeIterator(.forward);
        while (it.next()) |output| {
            output.apply_rules();
        }
    }

    if (comptime build_options.background_enabled) {
        if (mask.background) {
            {
                var it = self.outputs.safeIterator(.forward);
                while (it.next()) |output| {
                    output.background.damage();
                }
            }
        }
    }

    if (comptime build_options.bar_enabled) {
        if (mask.bar) {
            self.stop_listening_status();

            var it = self.outputs.safeIterator(.forward);
            while (it.next()) |output| {
                if (mask.bar) {
                    output.bar.reload_font();
                }
                output.bar.damage(.all);
            }
        }
    }
}


pub fn start_listening_status(self: *Self) void {
    self.stop_listening_status();

    self.bar_status_fd = if (self.cfg.bar.status) |area|
        switch (area.data) {
            .text => null,
            .stdin => blk: {
                var flags = posix.fcntl(posix.STDIN_FILENO, posix.F.GETFL, 0) catch |err| {
                    log.err("get fd flags failed: {}", .{ err });
                    break :blk null;
                };
                flags |= 1 << @bitOffsetOf(posix.O, "NONBLOCK");

                _ = posix.fcntl(posix.STDIN_FILENO, posix.F.SETFL, flags) catch |err| {
                    log.err("set stdin fd NONBLOCK failed: {}", .{ err });
                    break :blk null;
                };

                break :blk posix.STDIN_FILENO;
            },
            .fifo => |fifo| try_open_fifo(fifo) catch |err| blk: {
                log.warn("open fifo `{s}` failed: {}", .{ fifo, err });
                break :blk null;
            },
        }
        else null;
}


pub fn stop_listening_status(self: *Self) void {
    if (self.cfg.bar.status) |area| {
        switch (area.data) {
            .text => {},
            .stdin => self.bar_status_fd = null,
            .fifo => if (self.bar_status_fd) |fd| {
                log.debug("close fd {}", .{ fd });
                posix.close(fd);
                self.bar_status_fd = null;
            }
        }
    }
}


pub inline fn is_listening_status(self: *Self) bool {
    return self.bar_status_fd != null;
}


pub fn update_bar_status(self: *Self) void {
    if (comptime build_options.bar_enabled) {
        if (self.bar_status_fd) |fd| {
            log.debug("update status", .{});

            const dest_buf = &@import("bar.zig").status_buffer;
            const nbytes = posix.read(fd, dest_buf) catch |err| {
                switch (err) {
                    error.WouldBlock => log.debug("no data in fd {}", .{ fd }),
                    else => log.err("read data from fd {} failed: {}", .{ fd, err }),
                }
                return;
            };

            log.debug("read {} bytes data from fd {}", .{ nbytes, fd });

            if (nbytes > 0) {
                if (nbytes < dest_buf.len) {
                    dest_buf[nbytes] = 0;
                }

                var show_bar_num: u8 = 0;
                var it = self.outputs.safeIterator(.forward);
                while (it.next()) |output| {
                    output.bar.damage(.status);

                    if (!output.bar.hidden) {
                        show_bar_num += 1;
                    }
                }

                if (show_bar_num > 0) self.rwm.manageDirty();
            } else {
                self.stop_listening_status();
            }
        } else {
            log.warn("call `update_bar_status` while bar_status_fd is null", .{});
        }
    } else unreachable;
}


pub fn handle_signal(self: *Self, sig: posix.SIG) void {
    switch (sig) {
        .INT, .TERM, .QUIT => self.quit(false),
        .KILL => self.quit(true),
        .CHLD => {
            while (true) {
                const res = posix.waitpid(-1, posix.W.NOHANG) catch |err| {
                    log.warn("wait failed: {}", .{ err });
                    break;
                };
                if (res.pid <= 0) break;
                log.debug("wait pid {}", .{ res.pid });

                if (self.quit_hook) |hook| if (res.pid == hook.pid) {
                    self.quit_hook = null;
                    if (res.status == 0) {
                        self.quit(hook.exit_session);
                    }
                };
            }
        },
        else => {}
    }
}


pub fn register_quit_hook(self: *Self, argv: []const []const u8, exit_session: bool) void {
    log.debug("register quit hook", .{});

    if (self.quit_hook == null) {
        const child = self.spawn_child(argv) catch |err| {
            log.err("spawn quit hook failed: {}", .{ err });
            return;
        };
        self.quit_hook = .{
            .pid = child.id orelse {
                log.err("null child id", .{});
                return;
            },
            .exit_session = exit_session
        };
    } else log.warn("repeatly register quit hook", .{});
}


pub fn quit(self: *Self, exit_session: bool) void {
    if (exit_session) {
        log.debug("exit session", .{});

        self.rwm.exitSession();
    } else {
        log.debug("quit kwm", .{});

        self.running = false;
    }
}


pub fn focus(self: *Self, window: *Window, lift: bool) void {
    log.debug("<{*}> focus window: {*}", .{ self, window });

    self.set_current_output(window.output);
    if (lift) self.window_to_lift = window;

    if (self.focused_window()) |w| {
        // unmaximize window if focus changed
        if (w != window and w.maximize) {
            w.toggle_maximize(false);
        }
    }

    if (comptime build_options.bar_enabled) {
        if (window.output) |output| {
            output.bar.damage(.tags);
        }
    }

    window.flink.remove();
    self.focus_stack.prepend(window);
}


pub fn focused_window(self: *Self) ?*Window {
    if (self.current_output) |output| {
        var it = self.focus_stack.safeIterator(.forward);
        while (it.next()) |window| {
            if (window.is_visible_in(output)) {
                return window;
            }
        }
    }
    return null;
}


pub fn focus_iter(self: *Self, direction: types.Direction, skip: types.WindowIterSkip) void {
    log.debug("focus iter: {s}", .{ @tagName(direction) });

    if (self.focused_window()) |window| {
        const wrap_around = !self.cfg.disable_wrap_around_for_scroller or window.output.?.current_layout() != .scroller;

        var win = window;
        while (true) {
            const new_window = switch (direction) {
                inline else => |d| utils.cycle_list(
                    Window,
                    wrap_around,
                    &self.windows.link,
                    &win.link,
                    switch (comptime d) {
                        .forward => .next,
                        .reverse => .prev,
                    },
                ),
            } orelse break;
            defer win = new_window;
            if (new_window == window) break;
            if (new_window.is_visible_in(window.output.?)) {
                switch (skip) {
                    .none => {},
                    .floating => if (new_window.floating) continue,
                    .nonfloating => if (!new_window.floating) continue,
                }

                self.focus(new_window, true);
                break;
            }
        }
    }
}


pub fn focus_top_in(self: *Self, output: *Output, skip_floating: bool) ?*Window {
    var it = self.focus_stack.safeIterator(.forward);
    while (it.next()) |window| {
        if (window.is_visible_in(output)) {
            if (skip_floating and window.floating) continue;
            return window;
        }
    }
    return null;
}


pub fn focused_before(self: *Self, window: *Window, skip_floating: bool) ?*Window {
    if (window.output) |output| {
        var flink = &window.flink;
        while (flink.next.? != &self.focus_stack.link) {
            defer flink = flink.next.?;
            const w: *Window = @fieldParentPtr("flink", flink.next.?);
            if (w.is_visible_in(output)) {
                if (skip_floating and w.floating) continue;
                return w;
            }
        }
    }
    return null;
}


pub fn focus_output_iter(self: *Self, direction: types.Direction) void {
    log.debug("focus output iter: {s}", .{ @tagName(direction) });

    if (self.current_output) |output| {
        const new_output = switch (direction) {
            inline else => |d| utils.cycle_list(
                Output,
                true,
                &self.outputs.link,
                &output.link,
                switch (comptime d) {
                    .forward => .next,
                    .reverse => .prev,
                },
            ).?
        };
        if (new_output != output) {
            self.set_current_output(new_output);
        }
    }
}


pub fn send_to_output(self: *Self, window: *Window, direction: types.Direction) void {
    log.debug("send {*} to {s} output", .{ window, @tagName(direction) });

    if (window.output) |output| {
        const new_output = switch (direction) {
            inline else => |d| utils.cycle_list(
                Output,
                true,
                &self.outputs.link,
                &output.link,
                switch (comptime d) {
                    .forward => .next,
                    .reverse => .prev,
                },
            ).?
        };
        if (new_output != output) {
            window.set_output(new_output, true);
            switch (window.fullscreen) {
                .output => {
                    window.prepare_fullscreen(new_output);
                },
                else => {}
            }
            window.set_tag(new_output.tag);
        }
    }
}


pub inline fn focus_exclusive(self: *Self) bool {
    return if (self.current_seat) |seat| seat.focus_exclusive else false;
}


pub fn swap(self: *Self, direction: types.Direction) void {
    log.debug("swap window: {s}", .{ @tagName(direction) });

    if (self.focused_window()) |window| {
        if (window.floating) return;
        if (window.fullscreen == .output) return;

        const wrap_around = !self.cfg.disable_wrap_around_for_scroller or window.output.?.current_layout() != .scroller;

        var win = window;
        while (true) {
            const new_window = switch (direction) {
                inline else => |d| utils.cycle_list(
                    Window,
                    wrap_around,
                    &self.windows.link,
                    &win.link,
                    switch (comptime d) {
                        .forward => .next,
                        .reverse => .prev,
                    },
                )
            } orelse break;
            defer win = new_window;
            if (new_window == window) break;
            if (new_window.is_visible_in(window.output.?) and !new_window.floating) {
                window.link.swapWith(&new_window.link);
                self.focus(window, true);
                break;
            }
        }
    }
}


pub fn attach_window(self: *Self, window: *Window, mode: types.WindowAttachMode) void {
    log.debug("attach {*}: {s}", .{ window, @tagName(mode) });

    switch (mode) {
        .top => self.windows.prepend(window),
        .bottom => self.windows.append(window),
        .stack_top => if (self.current_output) |output| {
            const nmaster = switch (output.current_layout()) {
                .tile => |tile| tile.nmaster,
                .deck => |deck| deck.nmaster,
                else => 0,
            };

            if (nmaster == 0) {
                self.windows.prepend(window);
            } else {
                var link: *wl.list.Link = &self.windows.link;
                defer link.insert(&window.link);

                var i: i32 = 0;
                var it = self.windows.safeIterator(.forward);
                while (it.next()) |w| {
                    if (!w.is_visible_in(output) or w.floating) continue;
                    link = &w.link;
                    i += 1;
                    if (i == nmaster) break;
                }
            }
        } else self.windows.prepend(window), // fallback to prepend if no output
        else => if (self.focused_window()) |focused| {
            switch (mode) {
                .above_focused => focused.link.prev.?.insert(&window.link),
                .below_focused => focused.link.insert(&window.link),
                else => unreachable,
            }
        } else self.windows.prepend(window), // fallback to prepend if no focused
    }
}


pub fn prepare_remove_output(self: *Self, output: *Output) void {
    log.debug("prepare to remove output {*}", .{ output });

    // store output state
    if (self.store_output_state(output)) {
        log.debug("store state of output `{s}`", .{ output.name orelse "unknown" });
    } else |err| log.err("store state of output `{s}` failed: {}", .{ output.name orelse "unknown", err });

    if (output == self.current_output) {
        self.promote_new_output();
    }

    const new_output = self.current_output;
    {
        var it = self.windows.iterator(.forward);
        while (it.next()) |window| {
            if (window.output == output) {
                if (window.former_output == null) {
                    window.set_former_output(output.name);
                }
                window.set_output(new_output, false);
            }
            switch (window.fullscreen) {
                .output => |o| if (o == output) window.prepare_unfullscreen(),
                else => {}
            }
        }
    }
}


pub fn prepare_remove_seat(self: *Self, seat: *Seat) void {
    log.debug("prepare to remove seat {*}", .{ seat });

    if (seat == self.current_seat) {
        self.promote_new_seat();
    }
}


pub fn switch_mode(self: *Self, mode: []const u8) void {
    log.debug("switch mode from {s} to {s}", .{ self.mode, mode });

    self.mode = fmt.bufPrint(&mode_buffer, "{s}", .{ mode }) catch @panic("mode name too lone");

    if (comptime build_options.bar_enabled) {
        var it = self.outputs.safeIterator(.forward);
        while (it.next()) |output| {
            output.bar.damage(.mode);
        }
    }
}


pub fn shift_to_head(self: *Self, window: *Window) void {
    log.debug("shift window {*} to head", .{ window });

    window.link.remove();
    self.windows.prepend(window);
}


pub fn toggle_fullscreen(self: *Self, in_window: bool) void {
    if (self.current_output) |output| {
        if (output.fullscreen_window()) |window| {
            window.prepare_unfullscreen();
            self.focus(window, true);
        } else if (self.focused_window()) |window| {
            switch (window.fullscreen) {
                .none => window.prepare_fullscreen(if (in_window) null else window.output.?),
                .window => if (in_window) window.prepare_unfullscreen()
                    else window.prepare_fullscreen(window.output.?),
                .output => {
                    window.prepare_unfullscreen();
                    self.focus(window, true);
                },
            }
        }
    }
}


pub fn register_terminal(self: *Self, window: *Window) void {
    log.debug("register terminal window {*}(pid: {})", .{ window, window.pid });

    self.terminal_windows.put(window.pid, window) catch |err| {
        log.err("put (key: {}, value: {*}) failed: {}", .{ window.pid, window, err });
        return;
    };
}


pub fn unregister_terminal(self: *Self, window: *Window) void {
    log.debug("unregister terminal window {*}(pid: {})", .{ window, window.pid });

    if (!self.terminal_windows.remove(window.pid)) {
        log.debug("remove pid {} failed, not found", .{ window.pid });
    }
}


pub inline fn find_terminal(self: *Self, pid: i32) ?*Window {
    return self.terminal_windows.get(pid);
}


pub fn set_current_output(self: *Self, output: ?*Output) void {
    log.debug("set current output: {*}", .{ output });

    if (comptime build_options.bar_enabled) {
        if (self.current_output) |o| o.bar.damage(.title);
    }

    if (self.current_output != output) {
        self.current_output = output;

        if (output) |o| {
            if (comptime build_options.bar_enabled) o.bar.damage(.title);

            if (o.rwm_layer_shell_output) |rwm_layer_shell_output| {
                rwm_layer_shell_output.setDefault();
            }
        }
    }
}


pub inline fn set_current_seat(self: *Self, seat: ?*Seat) void {
    log.debug("set current seat: {*}", .{ seat });

    self.current_seat = seat;
}


pub fn spawn_child(self: *Self, argv: []const []const u8) !process.Child {
    if (comptime builtin.mode == .Debug) {
        const cmd = try mem.join(self.gpa, " ", argv);
        defer self.gpa.free(cmd);
        log.debug("spawn child process: {s}", .{ cmd });
    }

    return try process.spawn(
        self.io,
        .{
            .argv = argv,
            .environ_map = &self.env,
            .cwd =
                if (
                    switch (self.cfg.working_directory) {
                        .none => null,
                        .home => self.env.get("HOME"),
                        .custom => |dir| dir,
                    }
                ) |path| .{ .path = path }
                else .inherit
        }
    );
}


pub fn spawn(self: *Self, argv: []const []const u8) void {
    if (argv.len == 0) return;

    if (comptime builtin.mode == .Debug) {
        const cmd = mem.join(self.gpa, " ", argv) catch unreachable;
        defer self.gpa.free(cmd);
        log.debug("spawn: `{s}`", .{ cmd });
    }

    var arena_allocator: heap.ArenaAllocator = .init(self.gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const argv_buffer = arena.allocSentinel(?[*:0]const u8, argv.len, null) catch |err| {
        log.err("allocSentinel failed: {}", .{ err });
        return;
    };
    for (0..argv.len) |i| argv_buffer[i] = arena.dupeZ(u8, argv[i]) catch |err| {
        log.err("dupeZ failed: {}", .{ err });
        return;
    };

    const env_block = self.env.createPosixBlock(arena, .{}) catch |err| {
        log.err("createPosixBlock failed: {}", .{ err });
        return;
    };

    const pid1 = posix.fork() catch |err| {
        log.err("fork failed: {}", .{ err });
        return;
    };

    if (pid1 > 0) return;

    _ = posix.setsid() catch unreachable;

    // reset signal mask
    if (
        posix.system.sigprocmask(
            posix.SIG.SETMASK,
            &posix.sigemptyset(),
            null
        ) < 0
    ) unreachable;

    const pid2 = posix.fork() catch posix.exit(1);
    if (pid2 == 0) {
        if (switch (self.cfg.working_directory) {
            .none => null,
            .home => self.env.get("HOME"),
            .custom => |dir| dir,
        }) |dir| {
            posix.chdir(dir) catch posix.exit(1);
        }

        const err = posix.execve(argv_buffer[0].?, argv_buffer, env_block.slice.ptr);
        log.err("execve failed: {}", .{ err });
    }

    posix.exit(0);
}


pub inline fn spawn_shell(self: *Self, cmd: []const u8) void {
    self.spawn(&[_][]const u8 { "sh", "-c", cmd });
}


inline fn store_output_state(self: *Self, output: *const Output) !void {
    if (output.name) |name| {
        const state = try self.gpa.create(Output.State);
        errdefer self.gpa.destroy(state);
        state.* = output.get_state();
        try self.output_states.put(
            try self.gpa.dupe(u8, name),
            state,
        );
    }
}


fn init_env_map(self: *Self) void {
    self.env = self.init_env.createMap(self.gpa) catch |err| blk: {
        log.warn("create environ map failed: {}", .{ err });
        break :blk .init(self.gpa);
    };

    for (self.cfg.env) |pair| {
        const key, const value = pair;
        ctx.env.put(key, value) catch |err| {
            log.warn("put (key: {s}, value: {s}) to env map failed: {}", .{ key, value, err });
        };
    }

    if (self.cfg.xcursor_theme) |xcursor_theme| blk: {
        ctx.env.put("XCURSOR_THEME", xcursor_theme.name) catch |err| {
            log.warn("put XCURSOR_THEME to `{s}` failed: {}", .{ xcursor_theme.name, err });
        };

        var buffer: [8]u8 = undefined;
        const xcursor_size = fmt.bufPrint(&buffer, "{}", .{ xcursor_theme.size }) catch |err| {
            log.warn("bufPrint failed: {}", .{ err });
            break :blk;
        };
        ctx.env.put("XCURSOR_SIZE", xcursor_size) catch |err| {
            log.warn("put XCURSOR_SIZE to `{}` failed: {}", .{ xcursor_theme.size, err });
        };
    }
}


fn load_config(self: *Self) void {
    log.debug("loading configuration", .{});

    var env: process.Environ.Map = self.init_env.createMap(self.gpa) catch |err| blk: {
        log.warn("create environ map failed: {}", .{ err });
        break :blk .init(self.gpa);
    };
    defer env.deinit();

    self.cfg = config.load(
        .{ .gpa = self.gpa, .io = self.io, .env = &env },
        self.config_path
    ) catch |err| blk: {
        log.err("load configuration failed: {}, fallback to default configuration", .{ err });
        break :blk config.default;
    };
}


fn run_startup_cmds(self: *Self) void {
    self.startup_processes.ensureTotalCapacity(self.gpa, self.cfg.startup_cmds.len) catch |err| {
        log.err("initCapacity for startup_processes failed: {}", .{ err });
        return;
    };
    for (self.cfg.startup_cmds) |argv| {
        const child = self.spawn_child(argv) catch |err| {
            log.err("spawn child failed: {}", .{ err });
            continue;
        };
        ctx.startup_processes.appendBounded(child) catch unreachable;
    }
}


fn kill_startup_process(self: *Self) void {
    for (self.startup_processes.items) |*child| {
        log.debug("kill startup process {}", .{ child.id orelse -1 });
        child.kill(self.io);
    }
    self.startup_processes.clearRetainingCapacity();
}


fn promote_new_output(self: *Self) void {
    log.debug("promote new output", .{});

    const former_output = self.current_output.?;
    const current_output = utils.cycle_list(
        Output,
        true,
        &self.outputs.link,
        &former_output.link,
        .prev,
    );

    self.set_current_output(
        if (current_output == former_output) null
        else current_output
    );
}


fn promote_new_seat(self: *Self) void {
    log.debug("promote new seat", .{});

    const former_seat = self.current_seat.?;
    const current_seat = utils.cycle_list(
        Seat,
        true,
        &self.seats.link,
        &former_seat.link,
        .prev,
    );

    self.set_current_seat(
        if (current_seat == former_seat) null
        else current_seat
    );
}


fn prepare_manage(self: *Self) void {
    log.debug("prepare to manage", .{});

    {
        var it = self.seats.safeIterator(.forward);
        while (it.next()) |seat| {
            seat.manage();
        }
    }

    {
        var it = self.windows.safeIterator(.forward);
        while (it.next()) |window| {
            window.handle_events();
        }
    }

    if (self.cfg.single_tagset) single_tagset_blk: {
        const current_output = self.current_output
            orelse break :single_tagset_blk;

        {
            var it = self.outputs.safeIterator(.forward);
            while (it.next()) |output| {
                if (output == current_output) continue;
                if (output.tag & current_output.tag != 0) {
                    output.set_tag(current_output.prev_tag);
                }
            }
        }

        var flag = true;
        var output_it = self.outputs.safeIterator(.forward);
        while (flag) {
            const output = output_it.next() orelse blk: {
                flag = false;
                break :blk current_output;
            };
            var window_it = self.windows.safeIterator(.forward);
            while (window_it.next()) |window| {
                if (window.sticky or window.tag & output.tag != 0) {
                    window.set_output(output, false);
                }
            }
        }
    }
}


fn prepare_render_windows(self: *Self) void {
    const focused = self.focused_window();

    var it = self.windows.safeIterator(.forward);
    while (it.next()) |window| {
        if (!window.is_visible()) {
            window.hide();
        } else {
            window.set_border(
                if (window.fullscreen == .output) 0
                else self.cfg.border.width,
                if (!self.focus_exclusive() and window == focused)
                    self.cfg.border.color.focus
                else self.cfg.border.color.unfocus
            );
        }
    }

    if (focused) |window| {
        // move focus to head of focus_stack
        if (!window.sticky) self.focus(window, false);
    }
}

fn render_windows(self: *Self) void {
    {
        var it = self.windows.safeIterator(.forward);
        while (it.next()) |window| {
            window.render();

            if (!window.layer_managed) {
                window.layer_managed = true;
                if (window.floating) {
                    window.place(.top);
                } else {
                    window.place(.{
                        .below = self.layer_marker.rwm_shell_surface_node,
                    });
                }
            }
        }
    }

    if (self.window_to_lift) |window| {
        self.window_to_lift = null;
        if (window.floating) {
            window.place(.top);
        } else {
            window.place(.{
                .below = self.layer_marker.rwm_shell_surface_node,
            });
        }
    }
}


fn rwm_listener(rwm: *river.WindowManagerV1, event: river.WindowManagerV1.Event, context: *Self) void {
    std.debug.assert(rwm == context.rwm);

    const cache = struct {
        pub var mode: [16] u8 = undefined;
    };

    switch (event) {
        .finished => {
            log.debug("window manager finished", .{});

            context.running = false;
        },
        .unavailable => {
            log.err("another window manager is already running", .{});

            context.running = false;
        },
        .manage_start => {
            log.debug("manage start", .{});

            context.prepare_manage();

            {
                var it = context.outputs.safeIterator(.forward);
                while (it.next()) |output| {
                    if (output.fullscreen_window() != null) {
                        continue;
                    }
                    output.manage();
                }
            }

            {
                var it = context.windows.safeIterator(.forward);
                while (it.next()) |window| {
                    window.manage();
                }
            }

            {
                var it = context.seats.iterator(.forward);
                while (it.next()) |seat| {
                    seat.try_focus();
                }
            }

            rwm.manageFinish();
        },
        .render_start => {
            log.debug("render start", .{});

            context.prepare_render_windows();
            context.render_windows();

            if (comptime build_options.background_enabled) {
                var it = context.outputs.safeIterator(.forward);
                while (it.next()) |output| {
                    output.background.render();
                }
            }

            if (comptime build_options.bar_enabled) {
                var it = context.outputs.safeIterator(.forward);
                while (it.next()) |output| {
                    output.bar.render();
                }
            }

            rwm.renderFinish();
        },
        .window => |data| {
            log.debug("new window {*}", .{ data.id });

            const window = Window.create(data.id, context.current_output) catch |err| {
                log.err("create window failed: {}", .{ err });
                return;
            };

            context.attach_window(
                window,
                context.cfg.default_attach_mode.getter.get(
                    if (context.current_output) |output| output.current_layout()
                    else context.cfg.default_layout,
                ),
            );
            context.focus(window, true);
        },
        .output => |data| {
            log.debug("new output {*}", .{ data.id });

            const rwm_layer_shell_output = context.rwm_layer_shell.getOutput(data.id) catch null;
            const output = Output.create(data.id, rwm_layer_shell_output) catch |err| {
                log.err("create output failed: {}", .{ err });
                return;
            };
            context.outputs.append(output);

            {
                var it = context.windows.safeIterator(.forward);
                while (it.next()) |window| {
                    if (window.output == null) {
                        window.set_output(output, false);
                    }
                }
            }

            if (context.current_output == null) {
                context.set_current_output(output);
            }
        },
        .seat => |data| {
            log.debug("new seat {*}", .{ data.id });

            const seat = Seat.create(data.id) catch |err| {
                log.err("create seat failed: {}", .{ err });
                return;
            };
            context.seats.append(seat);

            if (context.current_seat == null) {
                context.set_current_seat(seat);
            }
        },
        .session_locked => {
            log.debug("session locked", .{});

            _ = fmt.bufPrintZ(&cache.mode, "{s}", .{ context.mode }) catch unreachable;
            context.switch_mode(config.lock_mode);
        },
        .session_unlocked => {
            log.debug("session unlocked", .{});

            context.switch_mode(mem.span(@as([*:0]const u8, @ptrCast(&cache.mode))));
        }
    }
}


fn trigger_hotplug(self: *Self) void {
    log.debug("trigger hotplug", .{});

    if (!self.any_inputs_plugged) {
        self.any_inputs_plugged = true;
        self.run_later(.fromMilliseconds(100), hotplug_inputs);
    }
}


fn hotplug_inputs(self: *Self) void {
    if (self.any_inputs_plugged) {
        self.any_inputs_plugged = false;

        log.debug("hotplug inputs", .{});
        self.spawn(&.{ "kwim" });
    }
}


fn rwm_input_manager_listener(rwm_input_manager: *river.InputManagerV1, event: river.InputManagerV1.Event, context: *Self) void {
    std.debug.assert(rwm_input_manager == context.rwm_inputs.input_manager);

    switch (event) {
        .input_device => |data| {
            log.debug("new input_device {*}", .{ data.id });

            context.trigger_hotplug();

            // The device object must stay alive until its removed event:
            // river_xkb_keyboard_v1.input_device and
            // river_libinput_device_v1.input_device reference it as their
            // first event, and destroying it here races those in-flight
            // events into a fatal unknown-object dispatch error.
            data.id.setListener(*Self, rwm_input_device_listener, context);
        },
        .finished => {
            log.debug("{*} finished", .{ rwm_input_manager });

            rwm_input_manager.destroy();
        }
    }
}


fn rwm_input_device_listener(rwm_input_device: *river.InputDeviceV1, event: river.InputDeviceV1.Event, context: *Self) void {
    _ = context;

    switch (event) {
        .removed => {
            log.debug("input_device {*} removed", .{ rwm_input_device });

            rwm_input_device.destroy();
        },
        .type, .name => {}
    }
}


fn rwm_libinput_config_listener(rwm_libinput_config: *river.LibinputConfigV1, event: river.LibinputConfigV1.Event, context: *Self) void {
    std.debug.assert(rwm_libinput_config == context.rwm_inputs.libinput_config);

    switch (event) {
        .libinput_device => |data| {
            log.debug("new libinput_device {*}", .{ data.id });

            context.trigger_hotplug();
            data.id.destroy();
        },
        .finished => {
            log.debug("{*} finished", .{ rwm_libinput_config });

            rwm_libinput_config.destroy();
        }
    }
}


fn rwm_xkb_config_listener(rwm_xkb_config: *river.XkbConfigV1, event: river.XkbConfigV1.Event, context: *Self) void {
    std.debug.assert(rwm_xkb_config == context.rwm_inputs.xkb_config);

    switch (event) {
        .xkb_keyboard => |data| {
            log.debug("new xkb_keyboard {*}", .{ data.id });

            context.trigger_hotplug();
            data.id.destroy();

        },
        .finished => {
            log.debug("{*} finished", .{ rwm_xkb_config });

            rwm_xkb_config.destroy();
        }
    }
}


fn try_open_fifo(path: []const u8) !posix.fd_t {
    var expanded_path = try utils.expand_env_str(
        .{ .gpa = ctx.gpa, .env = &ctx.env },
        path
    );
    defer expanded_path.deinit(ctx.gpa);

    log.debug("try to open fifo file `{s}`", .{ expanded_path.items });

    const fd = try posix.open(
        expanded_path.items,
        .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true },
        0
    );
    errdefer posix.close(fd);

    const file: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    const stat = try file.stat(ctx.io);

    if (stat.kind != .named_pipe) return error.NotFifo;

    return fd;
}
