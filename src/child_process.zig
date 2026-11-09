const std = @import("std");
const builtin = @import("builtin");

pub fn spawn(io: std.Io, environ: std.process.Environ, argv: []const []const u8, node: std.Progress.Node) !std.process.Child {
    // A child in a separate process group cannot read the foreground terminal.
    // Files and pipes can be inherited directly, without an input copy task.
    const terminal_stdin = try std.Io.File.stdin().isTty(io);
    if (builtin.os.tag != .macos or node.index == .none) {
        return std.process.spawn(io, .{
            .argv = argv,
            .stdin = if (terminal_stdin) .ignore else .inherit,
            .stdout = .pipe,
            .stderr = .pipe,
            .progress_node = node,
            .pgid = 0,
        });
    }

    // Zig 0.17.0's processSpawnDarwin creates a progress pipe but builds the
    // environment with zig_progress_fd = -1. Supply both through posix_spawnp
    // until the standard library passes the pipe descriptor to the child.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const argv_z = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| argv_z[i] = (try allocator.dupeSentinel(u8, arg, 0)).ptr;

    const stdout = try pipe(false);
    errdefer for (stdout) |file| file.close(io);
    const stderr = try pipe(false);
    errdefer for (stderr) |file| file.close(io);
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
    stdout[1].close(io);
    stderr[1].close(io);
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
