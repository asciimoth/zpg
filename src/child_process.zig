const std = @import("std");
const builtin = @import("builtin");
const capture = @import("output_capture.zig");

pub fn spawn(io: std.Io, environ: std.process.Environ, argv: []const []const u8, node: std.Progress.Node) !std.process.Child {
    return spawnWithProgressFile(io, environ, argv, node, null);
}

pub fn spawnWithProgressFile(io: std.Io, environ: std.process.Environ, argv: []const []const u8, node: std.Progress.Node, progress_file: ?std.Io.File) !std.process.Child {
    // A child in a separate process group cannot read the foreground terminal.
    // Files and pipes can be inherited directly, without an input copy task.
    const terminal_stdin = try std.Io.File.stdin().isTty(io);
    const stdout = try capture.open(io, .stdout());
    defer stdout[1].close(io);
    errdefer stdout[0].close(io);
    const stderr = try capture.open(io, .stderr());
    defer stderr[1].close(io);
    errdefer stderr[0].close(io);
    if (progress_file == null and (builtin.os.tag != .macos or node.index == .none)) {
        // PTYs let nested zpg commands detect a terminal again. Keep a disabled
        // outer display disabled in those commands, without disabling color.
        var child_env: ?std.process.Environ.Map = null;
        defer if (child_env) |*map| map.deinit();
        if (node.index == .none) {
            child_env = try environ.createMap(std.heap.page_allocator);
            try child_env.?.put("ZPG_NO_PROGRESS", "1");
        }
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .environ_map = if (child_env) |*map| map else null,
            .stdin = if (terminal_stdin) .ignore else .inherit,
            .stdout = .{ .file = stdout[1] },
            .stderr = .{ .file = stderr[1] },
            .progress_node = node,
            .pgid = 0,
        });
        child.stdout = stdout[0];
        child.stderr = stderr[0];
        return child;
    }

    // Build the pipe and environment together for raw progress capture.
    // On macOS this also avoids Zig 0.17.0's processSpawnDarwin bug: it creates
    // a progress pipe but builds the environment with zig_progress_fd = -1.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const argv_z = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| argv_z[i] = (try allocator.dupeSentinel(u8, arg, 0)).ptr;

    const progress = if (progress_file == null) try pipe(true) else null;
    errdefer if (progress) |files| for (files) |file| file.close(io);
    const progress_write = progress_file orelse progress.?[1];
    const env = try environ.createPosixBlock(allocator, .{ .zig_progress_fd = progress_write.handle });

    const pid = if (builtin.os.tag == .linux)
        try @import("spawn_linux.zig").spawn(allocator, argv_z.ptr, env.slice.ptr, environ.getPosix("PATH") orelse "/bin:/usr/bin", stdout[1].handle, stderr[1].handle, progress_write.handle, terminal_stdin)
    else
        try spawn_darwin(argv_z.ptr, env.slice.ptr, stdout[1].handle, stderr[1].handle, progress_write.handle, terminal_stdin);
    if (progress) |files| {
        files[1].close(io);
        node.setIpcFile(io.userdata, files[0]);
    }
    return .{
        .id = pid,
        .thread_handle = {},
        .stdin = null,
        .stdout = stdout[0],
        .stderr = stderr[0],
        .request_resource_usage_statistics = false,
    };
}

// macOS uses libSystem as its supported system call interface.
fn spawn_darwin(argv: [*:null]const ?[*:0]const u8, env: [*:null]const ?[*:0]const u8, out: c_int, err: c_int, progress_fd: c_int, ignore_stdin: bool) !std.posix.pid_t {
    var actions: std.c.posix_spawn_file_actions_t = undefined;
    try check(std.c.posix_spawn_file_actions_init(&actions));
    defer _ = std.c.posix_spawn_file_actions_destroy(&actions);
    var attributes: std.c.posix_spawnattr_t = undefined;
    try check(std.c.posix_spawnattr_init(&attributes));
    defer _ = std.c.posix_spawnattr_destroy(&attributes);
    if (ignore_stdin)
        try check(std.c.posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", @bitCast(std.posix.O{ .ACCMODE = .RDONLY }), 0));
    try check(std.c.posix_spawn_file_actions_adddup2(&actions, out, 1));
    try check(std.c.posix_spawn_file_actions_adddup2(&actions, err, 2));
    try check(std.c.posix_spawn_file_actions_addinherit_np(&actions, progress_fd));
    try check(std.c.posix_spawnattr_setpgroup(&attributes, 0));
    try check(std.c.posix_spawnattr_setflags(&attributes, .{ .SETPGROUP = true }));
    var pid: std.posix.pid_t = undefined;
    try check(std.c.posix_spawnp(&pid, argv[0].?, &actions, &attributes, argv, env));
    return pid;
}

fn pipe(nonblocking: bool) ![2]std.Io.File {
    const handles = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true, .NONBLOCK = nonblocking });
    return .{
        .{ .handle = handles[0], .flags = .{ .nonblocking = nonblocking } },
        .{ .handle = handles[1], .flags = .{ .nonblocking = nonblocking } },
    };
}

fn check(result: c_int) !void {
    const err: std.c.E = @fromBackingInt(@intCast(result));
    if (builtin.os.tag == .macos and (err == .BADEXEC or err == .BADARCH)) return error.InvalidExe;
    switch (err) {
        .SUCCESS => {},
        .NOENT => return error.FileNotFound,
        .ACCES, .PERM => return error.AccessDenied,
        .AGAIN, .NOMEM => return error.SystemResources,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NAMETOOLONG => return error.NameTooLong,
        .NOTDIR => return error.NotDir,
        .NOEXEC, .INVAL => return error.InvalidExe,
        else => return std.posix.unexpectedErrno(err),
    }
}
