const std = @import("std");
const builtin = @import("builtin");
const capture = @import("output_capture.zig");

pub fn spawn(io: std.Io, environ: std.process.Environ, argv: []const []const u8, node: std.Progress.Node) !std.process.Child {
    // A child in a separate process group cannot read the foreground terminal.
    // Files and pipes can be inherited directly, without an input copy task.
    const terminal_stdin = try std.Io.File.stdin().isTty(io);
    const stdout = try capture.open(io, .stdout());
    defer stdout[1].close(io);
    errdefer stdout[0].close(io);
    const stderr = try capture.open(io, .stderr());
    defer stderr[1].close(io);
    errdefer stderr[0].close(io);
    if (builtin.os.tag != .macos or node.index == .none) {
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

    // Zig 0.17.0's processSpawnDarwin creates a progress pipe but builds the
    // environment with zig_progress_fd = -1. Supply both through posix_spawnp
    // until the standard library passes the pipe descriptor to the child.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const argv_z = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| argv_z[i] = (try allocator.dupeSentinel(u8, arg, 0)).ptr;

    const progress = try pipe(true);
    errdefer for (progress) |file| file.close(io);
    const env = try environ.createPosixBlock(allocator, .{ .zig_progress_fd = progress[1].handle });

    var actions: std.c.posix_spawn_file_actions_t = undefined;
    try check(std.c.posix_spawn_file_actions_init(&actions));
    defer _ = std.c.posix_spawn_file_actions_destroy(&actions);
    if (terminal_stdin) {
        const read_only: std.posix.O = .{ .ACCMODE = .RDONLY };
        try check(std.c.posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", @bitCast(read_only), 0));
    }
    try check(std.c.posix_spawn_file_actions_adddup2(&actions, stdout[1].handle, 1));
    try check(std.c.posix_spawn_file_actions_adddup2(&actions, stderr[1].handle, 2));
    try check(std.c.posix_spawn_file_actions_addinherit_np(&actions, progress[1].handle));

    var attributes: std.c.posix_spawnattr_t = undefined;
    try check(std.c.posix_spawnattr_init(&attributes));
    defer _ = std.c.posix_spawnattr_destroy(&attributes);
    try check(std.c.posix_spawnattr_setpgroup(&attributes, 0));
    try check(std.c.posix_spawnattr_setflags(&attributes, .{ .SETPGROUP = true }));

    var pid: std.posix.pid_t = undefined;
    try check(std.c.posix_spawnp(&pid, argv_z[0].?, &actions, &attributes, argv_z.ptr, env.slice.ptr));
    progress[1].close(io);
    node.setIpcFile(io.userdata, progress[0]);
    return .{
        .id = pid,
        .thread_handle = {},
        .stdin = null,
        .stdout = stdout[0],
        .stderr = stderr[0],
        .request_resource_usage_statistics = false,
    };
}

fn pipe(nonblocking: bool) ![2]std.Io.File {
    const handles = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true, .NONBLOCK = nonblocking });
    return .{
        .{ .handle = handles[0], .flags = .{ .nonblocking = nonblocking } },
        .{ .handle = handles[1], .flags = .{ .nonblocking = nonblocking } },
    };
}

fn check(result: c_int) !void {
    switch (@as(std.c.E, @fromBackingInt(@intCast(result)))) {
        .SUCCESS => {},
        .NOENT => return error.FileNotFound,
        .ACCES, .PERM => return error.AccessDenied,
        .AGAIN, .NOMEM => return error.SystemResources,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NAMETOOLONG => return error.NameTooLong,
        .NOTDIR => return error.NotDir,
        .NOEXEC, .INVAL, .BADEXEC, .BADARCH => return error.InvalidExe,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}
