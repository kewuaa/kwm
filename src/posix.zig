// SPDX-FileCopyrightText: © 2026 kewuaa
// SPDX-License-Identifier: GPL-3.0-or-later

const builtin = @import("builtin");
const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const linux = std.os.linux;
pub const system = std.posix.system;

pub const fd_t = posix.fd_t;
pub const pid_t = posix.pid_t;
pub const pollfd = posix.pollfd;
pub const siginfo_t = posix.siginfo_t;

pub const F = posix.F;
pub const O = posix.O;
pub const W = posix.W;
pub const SIG = posix.SIG;
pub const POLL = posix.POLL;
pub const STDIN_FILENO = posix.STDIN_FILENO;

pub const poll = posix.poll;
pub const read = posix.read;
pub const signalfd = posix.signalfd;
pub const sigaddset = posix.sigaddset;
pub const sigemptyset = posix.sigemptyset;
pub const sigprocmask = posix.sigprocmask;
pub const memfd_create = posix.memfd_create;
pub const mmap = posix.mmap;
pub const munmap = posix.munmap;


pub const TimerFdCreateError = error{
    PermissionDenied,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    SystemResources,
} || posix.UnexpectedError;
pub fn timerfd_create(clock_id: system.timerfd_clockid_t, flags: system.TFD) TimerFdCreateError!posix.fd_t {
    const rc = system.timerfd_create(clock_id, @bitCast(flags));
    return switch (posix.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .INVAL => unreachable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NODEV => return error.NoDevice,
        .NOMEM => return error.SystemResources,
        .PERM => return error.PermissionDenied,
        else => |err| return posix.unexpectedErrno(err),
    };
}


pub const TimerFdGetError = error{InvalidHandle} || posix.UnexpectedError;
pub const TimerFdSetError = TimerFdGetError || error{Canceled};
pub fn timerfd_settime(
    fd: i32,
    flags: system.TFD.TIMER,
    new_value: *const system.itimerspec,
    old_value: ?*system.itimerspec,
) TimerFdSetError!void {
    const rc = system.timerfd_settime(fd, @bitCast(flags), new_value, old_value);
    return switch (posix.errno(rc)) {
        .SUCCESS => {},
        .BADF => error.InvalidHandle,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .CANCELED => error.Canceled,
        else => |err| return posix.unexpectedErrno(err),
    };
}


pub const OpenError = error{
    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to open a new resource relative to it.
    AccessDenied,
    PermissionDenied,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    /// Either:
    /// * One of the path components does not exist.
    /// * Cwd was used, but cwd has been deleted.
    /// * The path associated with the open directory handle has been deleted.
    /// * On macOS, multiple processes or threads raced to create the same file
    ///   with `O.EXCL` set to `false`.
    FileNotFound,

    /// The path exceeded `max_path_bytes` bytes.
    NameTooLong,

    /// Insufficient kernel memory was available, or
    /// the named file is a FIFO and per-user hard limit on
    /// memory allocation for pipes has been reached.
    SystemResources,

    /// The file is too large to be opened. This error is unreachable
    /// for 64-bit targets, as well as when opening directories.
    FileTooBig,

    /// The path refers to directory but the `DIRECTORY` flag was not provided.
    IsDir,

    /// A new path cannot be created because the device has no room for the new file.
    /// This error is only reachable when the `CREAT` flag is provided.
    NoSpaceLeft,

    /// A component used as a directory in the path was not, in fact, a directory, or
    /// `DIRECTORY` was specified and the path was not a directory.
    NotDir,

    /// The path already exists and the `CREAT` and `EXCL` flags were provided.
    PathAlreadyExists,
    DeviceBusy,

    /// The underlying filesystem does not support file locks
    FileLocksNotSupported,

    /// Path contains characters that are disallowed by the underlying filesystem.
    BadPathName,

    /// WASI-only; file paths must be valid UTF-8.
    InvalidUtf8,

    /// Windows-only; file paths provided by the user must be valid WTF-8.
    /// https://simonsapin.github.io/wtf-8/
    InvalidWtf8,

    /// On Windows, `\\server` or `\\server\share` was not found.
    NetworkNotFound,

    /// This error occurs in Linux if the process to be open was not found.
    ProcessNotFound,

    /// One of these three things:
    /// * pathname  refers to an executable image which is currently being
    ///   executed and write access was requested.
    /// * pathname refers to a file that is currently in  use  as  a  swap
    ///   file, and the O_TRUNC flag was specified.
    /// * pathname  refers  to  a file that is currently being read by the
    ///   kernel (e.g., for module/firmware loading), and write access was
    ///   requested.
    FileBusy,

    WouldBlock,
} || posix.UnexpectedError;
pub fn openZ(file_path: [*:0]const u8, flags: O, perm: posix.mode_t) OpenError!fd_t {
    const open_sym = if (posix.lfs64_abi) system.open64 else system.open;
    while (true) {
        const rc = open_sym(file_path, flags, perm);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,

            .FAULT => unreachable,
            .INVAL => return error.BadPathName,
            .ACCES => return error.AccessDenied,
            .FBIG => return error.FileTooBig,
            .OVERFLOW => return error.FileTooBig,
            .ISDIR => return error.IsDir,
            .LOOP => return error.SymLinkLoop,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NODEV => return error.NoDevice,
            .NOENT => return error.FileNotFound,
            .SRCH => return error.ProcessNotFound,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            .EXIST => return error.PathAlreadyExists,
            .BUSY => return error.DeviceBusy,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}
pub fn open(file_path: []const u8, flags: O, perm: posix.mode_t) OpenError!fd_t {
    const file_path_c = try posix.toPosixPath(file_path);
    return openZ(&file_path_c, flags, perm);
}


pub fn close(fd: fd_t) void {
    switch (posix.errno(system.close(fd))) {
        .BADF => unreachable, // Always a race condition.
        .INTR => return, // This is still a success. See https://github.com/ziglang/zig/issues/2425
        else => return,
    }
}


pub const FcntlError = error{
    PermissionDenied,
    FileBusy,
    ProcessFdQuotaExceeded,
    Locked,
    DeadLock,
    LockedRegionLimitExceeded,
} || posix.UnexpectedError;
pub fn fcntl(fd: fd_t, cmd: i32, arg: usize) FcntlError!usize {
    while (true) {
        const rc = system.fcntl(fd, cmd, arg);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN, .ACCES => return error.Locked,
            .BADF => unreachable,
            .BUSY => return error.FileBusy,
            .INVAL => unreachable, // invalid parameters
            .PERM => return error.PermissionDenied,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NOTDIR => unreachable, // invalid parameter
            .DEADLK => return error.DeadLock,
            .NOLCK => return error.LockedRegionLimitExceeded,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}


pub const ForkError = error{SystemResources} || posix.UnexpectedError;
pub fn fork() ForkError!pid_t {
    const rc = system.fork();
    switch (posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .AGAIN => return error.SystemResources,
        .NOMEM => return error.SystemResources,
        else => |err| return posix.unexpectedErrno(err),
    }
}


pub const SetSidError = error{
    /// The calling process is already a process group leader, or the process group ID of a process other than the calling process matches the process ID of the calling process.
    PermissionDenied,
} || posix.UnexpectedError;
pub fn setsid() SetSidError!pid_t {
    const rc = system.setsid();
    switch (posix.errno(rc)) {
        .SUCCESS => return rc,
        .PERM => return error.PermissionDenied,
        else => |err| return posix.unexpectedErrno(err),
    }
}


pub const ChangeCurDirError = error{
    AccessDenied,
    FileSystem,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    SystemResources,
    NotDir,
    BadPathName,
    /// WASI-only; file paths must be valid UTF-8.
    InvalidUtf8,
    /// Windows-only; file paths provided by the user must be valid WTF-8.
    /// https://simonsapin.github.io/wtf-8/
    InvalidWtf8,
} || posix.UnexpectedError;
pub fn chdirZ(dir_path: [*:0]const u8) ChangeCurDirError!void {
    switch (posix.errno(system.chdir(dir_path))) {
        .SUCCESS => return,
        .ACCES => return error.AccessDenied,
        .FAULT => unreachable,
        .IO => return error.FileSystem,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOTDIR => return error.NotDir,
        else => |err| return posix.unexpectedErrno(err),
    }
}
pub fn chdir(dir_path: []const u8) ChangeCurDirError!void {
    const dir_path_c = try posix.toPosixPath(dir_path);
    return chdirZ(&dir_path_c);
}


pub const TruncateError = error{
    FileTooBig,
    InputOutput,
    FileBusy,
    AccessDenied,
    PermissionDenied,
    NonResizable,
} || posix.UnexpectedError;
pub fn ftruncate(fd: fd_t, length: u64) TruncateError!void {
    const signed_len: i64 = @bitCast(length);
    if (signed_len < 0) return error.FileTooBig; // avoid ambiguous EINVAL errors

    const ftruncate_sym = if (posix.lfs64_abi) system.ftruncate64 else system.ftruncate;
    while (true) {
        switch (posix.errno(ftruncate_sym(fd, signed_len))) {
            .SUCCESS => return,
            .INTR => continue,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .PERM => return error.PermissionDenied,
            .TXTBSY => return error.FileBusy,
            .BADF => unreachable, // Handle not open for writing
            .INVAL => return error.NonResizable, // This is returned for /dev/null for example.
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}


pub fn exit(status: u8) noreturn {
    if (builtin.link_libc) {
        std.c.exit(status);
    }
    if (!builtin.single_threaded) {
        linux.exit_group(status);
    }
    system.exit(status);
}


pub const ExecveError = error{
    SystemResources,
    AccessDenied,
    PermissionDenied,
    InvalidExe,
    FileSystem,
    IsDir,
    FileNotFound,
    NotDir,
    FileBusy,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NameTooLong,
} || posix.UnexpectedError;
pub fn execveZ(
    path: [*:0]const u8,
    child_argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) ExecveError {
    switch (posix.errno(system.execve(path, child_argv, envp))) {
        .SUCCESS => unreachable,
        .FAULT => unreachable,
        .@"2BIG" => return error.SystemResources,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NAMETOOLONG => return error.NameTooLong,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .INVAL => return error.InvalidExe,
        .NOEXEC => return error.InvalidExe,
        .IO => return error.FileSystem,
        .LOOP => return error.FileSystem,
        .ISDIR => return error.IsDir,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .TXTBSY => return error.FileBusy,
        else => |err| switch (err) {
            .LIBBAD => return error.InvalidExe,
            else => return posix.unexpectedErrno(err),
        },
    }
}


pub fn execve(
    file: [*:0]const u8,
    child_argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) ExecveError {
    const file_slice = mem.sliceTo(file, 0);
    if (mem.indexOfScalar(u8, file_slice, '/') != null) return execveZ(file, child_argv, envp);

    const PATH = mem.sliceTo(system.getenv("PATH"), 0) orelse "/usr/local/bin:/bin/:/usr/bin";
    // Use of PATH_MAX here is valid as the path_buf will be passed
    // directly to the operating system in execveZ.
    var path_buf: [system.PATH_MAX]u8 = undefined;
    var it = mem.tokenizeScalar(u8, PATH, ':');
    var seen_eacces = false;
    var err: ExecveError = error.FileNotFound;

    while (it.next()) |search_path| {
        const path_len = search_path.len + file_slice.len + 1;
        if (path_buf.len < path_len + 1) return error.NameTooLong;
        @memcpy(path_buf[0..search_path.len], search_path);
        path_buf[search_path.len] = '/';
        @memcpy(path_buf[search_path.len + 1 ..][0..file_slice.len], file_slice);
        path_buf[path_len] = 0;
        const full_path = path_buf[0..path_len :0].ptr;
        err = execveZ(full_path, child_argv, envp);
        switch (err) {
            error.AccessDenied => seen_eacces = true,
            error.FileNotFound, error.NotDir => {},
            else => |e| return e,
        }
    }
    if (seen_eacces) return error.AccessDenied;
    return err;
}


pub const WaitPidResult = struct {
    pid: pid_t,
    status: u32,
};
pub fn waitpid(pid: pid_t, flags: u32) !WaitPidResult {
    var status: if (builtin.link_libc) c_int else u32 = undefined;
    while (true) {
        const rc = system.waitpid(pid, &status, @intCast(flags));
        const err = posix.errno(rc);
        switch (err) {
            .SUCCESS => return .{
                .pid = @intCast(rc),
                .status = @bitCast(status),
            },
            .INTR => continue,
            .CHILD => return error.ChildProcessDoesNotExist,
            .INVAL => return error.InvalidWaitpidFlags,
            else => return posix.unexpectedErrno(err),
        }
    }
}
