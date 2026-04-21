const Self = @This();

const build_options = @import("build_options");
const builtins = @import("builtin");
const std = @import("std");
const fs = std.fs;
const fmt = std.fmt;
const mem = std.mem;
const posix = std.posix;
const linux = std.os.linux;
const process = std.process;
const log = std.log.scoped(.context);

const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const river = wayland.client.river;

const Config = @import("config");

const utils = @import("utils.zig");
const types = @import("types.zig");
const Seat = @import("seat.zig");
const Output = @import("output.zig");
const Window = @import("window.zig");
const KeyRepeat = @import("key_repeat.zig");
const ShellSurface = @import("shell_surface.zig");

var ctx: ?Self = null;
var mode_buffer: [16]u8 = undefined;


wl_registry: *wl.Registry,
wl_compositor: *wl.Compositor,
wl_subcompositor: *wl.Subcompositor,
wl_shm: *wl.Shm,
wp_viewporter: *wp.Viewporter,
wp_fractional_scale_manager: *wp.FractionalScaleManagerV1,
wp_single_pixel_buffer_manager: *wp.SinglePixelBufferManagerV1,
rwm: *river.WindowManagerV1,
rwm_xkb_bindings: *river.XkbBindingsV1,
rwm_layer_shell: *river.LayerShellV1,

// seperate layer between floating and nonfloating
wl_surface: *wl.Surface = undefined,
layer_marker: ShellSurface = undefined,

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
output_states: std.StringHashMap(Output.State) = undefined,

mode: []const u8,
running: bool = true,
env: process.EnvMap = undefined,
startup_processes: std.ArrayList(?process.Child) = .empty,


pub fn init(
    wl_registry: *wl.Registry,
    wl_compositor: *wl.Compositor,
    wl_subcompositor: *wl.Subcompositor,
    wl_shm: *wl.Shm,
    wp_viewporter: *wp.Viewporter,
    wp_fractional_scale_manager: *wp.FractionalScaleManagerV1,
    wp_single_pixel_buffer_manager: *wp.SinglePixelBufferManagerV1,
    rwm: *river.WindowManagerV1,
    rwm_xkb_bindings: *river.XkbBindingsV1,
    rwm_layer_shell: *river.LayerShellV1,
) !void {
    // initialize once
    if (ctx != null) return;

    if (comptime build_options.bar_enabled) {
        _ = @import("fcft").init(.auto, false, .err);
    }

    log.info("init context", .{});

    ctx = .{
        .wl_registry = wl_registry,
        .wl_compositor = wl_compositor,
        .wl_subcompositor = wl_subcompositor,
        .wl_shm = wl_shm,
        .wp_viewporter = wp_viewporter,
        .wp_fractional_scale_manager = wp_fractional_scale_manager,
        .wp_single_pixel_buffer_manager = wp_single_pixel_buffer_manager,
        .rwm = rwm,
        .rwm_xkb_bindings = rwm_xkb_bindings,
        .rwm_layer_shell = rwm_layer_shell,
        .key_repeat = undefined,
        .terminal_windows = .init(utils.allocator),
        .output_states = .init(utils.allocator),
        .mode = fmt.bufPrint(&mode_buffer, "{s}", .{ Config.default_mode }) catch return error.ModeNameTooLong,
    };

    const wl_surface = try wl_compositor.createSurface();
    errdefer wl_surface.destroy();
    const wl_region = try wl_compositor.createRegion();
    defer wl_region.destroy();
    wl_surface.setInputRegion(wl_region);
    wl_surface.setOpaqueRegion(null);
    try ctx.?.layer_marker.init(wl_surface, .layer_marker);
    ctx.?.wl_surface = wl_surface;
    wl_surface.commit();

    ctx.?.seats.init();
    ctx.?.outputs.init();
    ctx.?.windows.init();
    ctx.?.focus_stack.init();
    ctx.?.key_repeat.?.init() catch {
        ctx.?.key_repeat = null;
    };

    ctx.?.init_env_map();
    ctx.?.run_startup_cmds();

    rwm.setListener(*Self, rwm_listener, &ctx.?);
}


pub fn deinit() void {
    std.debug.assert(ctx != null);

    log.info("deinit context", .{});

    if (comptime build_options.bar_enabled) {
        @import("fcft").fini();
    }

    defer ctx = null;

    ctx.?.wl_registry.destroy();
    ctx.?.wl_compositor.destroy();
    ctx.?.wl_subcompositor.destroy();
    ctx.?.wl_shm.destroy();
    ctx.?.wp_viewporter.destroy();
    ctx.?.wp_fractional_scale_manager.destroy();
    ctx.?.wp_single_pixel_buffer_manager.destroy();
    ctx.?.rwm.destroy();
    ctx.?.rwm_xkb_bindings.destroy();
    ctx.?.rwm_layer_shell.destroy();
    ctx.?.layer_marker.deinit();
    ctx.?.wl_surface.destroy();

    // first destroy windows for it's destroy function may depends on others
    {
        var it = ctx.?.windows.safeIterator(.forward);
        while (it.next()) |window| {
            window.destroy();
        }
        ctx.?.windows.init();
        ctx.?.focus_stack.init();
    }

    {
        var it = ctx.?.seats.safeIterator(.forward);
        while (it.next()) |seat| {
            seat.destroy();
        }
        ctx.?.seats.init();
    }
    ctx.?.current_seat = null;

    {
        var it = ctx.?.outputs.safeIterator(.forward);
        while (it.next()) |output| {
            output.destroy();
        }
        ctx.?.outputs.init();
    }
    ctx.?.current_output = null;

    if (ctx.?.key_repeat) |*key_repeat| key_repeat.deinit();

    if (ctx.?.is_listening_status()) {
        ctx.?.stop_listening_status();
    }

    ctx.?.terminal_windows.deinit();

    {
        var it = ctx.?.output_states.iterator();
        while (it.next()) |kv| {
            utils.allocator.free(kv.key_ptr.*);
        }
    }
    ctx.?.output_states.deinit();

    ctx.?.env.deinit();

    ctx.?.kill_startup_process();
    ctx.?.startup_processes.deinit(utils.allocator);
}


pub inline fn get() *Self {
    std.debug.assert(ctx != null);

    return &ctx.?;
}


pub fn reload_config(self: *Self) void {
    log.debug("reload config", .{});

    const mask = Config.reload();

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

    const config = Config.get();

    self.bar_status_fd = if (config.bar.status) |area|
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
            .fifo => |fifo| try_open_fifo(fifo, &self.env) catch null,
        }
        else null;
}


pub fn stop_listening_status(self: *Self) void {
    const config = Config.get();

    if (config.bar.status) |area| {
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


pub fn handle_signal(self: *Self, sig: i32) void {
    switch (sig) {
        posix.SIG.INT, posix.SIG.TERM, posix.SIG.QUIT => self.quit(false),
        posix.SIG.KILL => self.quit(true),
        posix.SIG.CHLD => {
            while (true) {
                const res = utils.waitpid(-1, posix.W.NOHANG) catch |err| {
                    log.warn("wait failed: {}", .{ err });
                    break;
                };
                if (res.pid <= 0) break;
                log.debug("wait pid {}", .{ res.pid });
            }
        },
        else => {}
    }
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

    const config = Config.get();

    if (self.focused_window()) |window| {
        const wrap_around = !config.disable_wrap_around_for_scroller or window.output.?.current_layout() != .scroller;

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

    const config = Config.get();

    if (self.focused_window()) |window| {
        if (window.floating) return;
        if (window.fullscreen == .output) return;

        const wrap_around = !config.disable_wrap_around_for_scroller or window.output.?.current_layout() != .scroller;

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
                .tile => output.layout.tile.nmaster,
                .deck => 1,
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
                window.set_former_output(output.name);
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


pub fn spawn(self: *Self, argv: []const []const u8) ?process.Child {
    if (comptime builtins.mode == .Debug) {
        const cmd = mem.join(utils.allocator, " ", argv) catch |err| {
            log.err("join failed: {}", .{ err });
            return null;
        };
        defer utils.allocator.free(cmd);

        log.debug("spawn: `{s}`", .{ cmd });
    }

    const config = Config.get();

    var child = process.Child.init(argv, utils.allocator);
    child.pgid = 0;
    child.env_map = &self.env;
    child.cwd = switch (config.working_directory) {
        .none => null,
        .home => self.env.get("HOME"),
        .custom => |dir| dir,
    };

    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, posix.SIG.CHLD);
    posix.sigprocmask(posix.SIG.UNBLOCK, &mask, null);

    defer posix.sigprocmask(posix.SIG.BLOCK, &mask, null);

    child.spawn() catch |err| {
        log.err("spawn failed: {}", .{ err });
        return null;
    };
    return child;
}


pub inline fn spawn_shell(self: *Self, cmd: []const u8) ?process.Child {
    return self.spawn(&[_][]const u8 { "sh", "-c", cmd });
}


inline fn store_output_state(self: *Self, output: *const Output) !void {
    if (output.name) |name| {
        try self.output_states.put(
            try utils.allocator.dupe(u8, name),
            output.get_state()
        );
    }
}


fn init_env_map(self: *Self) void {
    self.env = process.getEnvMap(utils.allocator) catch |err| blk: {
        log.warn("get EnvMap failed: {}", .{ err });
        break :blk .init(utils.allocator);
    };

    const config = Config.get();

    for (config.env) |pair| {
        const key, const value = pair;
        ctx.?.env.put(key, value) catch |err| {
            log.warn("put (key: {s}, value: {s}) to env map failed: {}", .{ key, value, err });
        };
    }

    if (config.xcursor_theme) |xcursor_theme| blk: {
        ctx.?.env.put("XCURSOR_THEME", xcursor_theme.name) catch |err| {
            log.warn("put XCURSOR_THEME to `{s}` failed: {}", .{ xcursor_theme.name, err });
        };

        var buffer: [8]u8 = undefined;
        const xcursor_size = fmt.bufPrint(&buffer, "{}", .{ xcursor_theme.size }) catch |err| {
            log.warn("bufPrint failed: {}", .{ err });
            break :blk;
        };
        ctx.?.env.put("XCURSOR_SIZE", xcursor_size) catch |err| {
            log.warn("put XCURSOR_SIZE to `{}` failed: {}", .{ xcursor_theme.size, err });
        };
    }
}


fn run_startup_cmds(self: *Self) void {
    const config = Config.get();

    self.startup_processes.ensureTotalCapacity(utils.allocator, config.startup_cmds.len) catch |err| {
        log.err("initCapacity for startup_processes failed: {}", .{ err });
        return;
    };
    for (config.startup_cmds) |cmd| {
        ctx.?.startup_processes.appendBounded(ctx.?.spawn(cmd)) catch unreachable;
    }
}


fn kill_startup_process(self: *Self) void {
    for (self.startup_processes.items) |*proc| {
        if (proc.*) |*child| {
            _ = child.kill() catch |err| {
                log.err("kill startup process {} failed: {}", .{ child.id, err });
                continue;
            };
            log.debug("kill startup process {}", .{ child.id });
        }
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
}


fn prepare_render_windows(self: *Self) void {
    const config = Config.get();

    const focused = self.focused_window();

    var it = self.windows.safeIterator(.forward);
    while (it.next()) |window| {
        if (!window.is_visible()) {
            window.hide();
        } else {
            window.set_border(
                if (window.fullscreen == .output) 0
                else config.border.width,
                if (!self.focus_exclusive() and window == focused)
                    config.border.color.focus
                else config.border.color.unfocus
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

    const config = Config.get();

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
                config.default_attach_mode.getter.get(
                    if (context.current_output) |output| output.current_layout()
                    else config.default_layout,
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
            context.switch_mode(Config.lock_mode);
        },
        .session_unlocked => {
            log.debug("session unlocked", .{});

            context.switch_mode(mem.span(@as([*:0]const u8, @ptrCast(&cache.mode))));
        }
    }
}


fn try_open_fifo(fifo: []const u8, env: *const process.EnvMap) !posix.fd_t {
    var expanded_fifo = try utils.expand_env_str(utils.allocator, fifo, env);
    defer expanded_fifo.deinit(utils.allocator);

    log.debug("try open fifo file `{s}`", .{ expanded_fifo.items });

    const fd = posix.open(expanded_fifo.items, .{ .ACCMODE = .RDWR, .NONBLOCK = true }, 0) catch |err| {
        log.warn("open `{s}` failed: {}", .{ fifo, err });
        return error.OpenFailed;
    };
    errdefer posix.close(fd);

    const stat = posix.fstat(fd) catch |err| {
        log.warn("stat `{s}` failed: {}", .{ fifo, err });
        return error.StatFailed;
    };

    if (stat.mode & posix.S.IFMT == 0) {
        log.warn("`{s}` is not a fifo file", .{ fifo });
        return error.NotFifo;
    }
    return fd;
}
