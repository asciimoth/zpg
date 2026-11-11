const std = @import("std");
const linux = std.os.linux;

// Supply a raw progress pipe without std.Progress's collector or libc.
pub fn spawn(allocator: std.mem.Allocator, argv: [*:null]const ?[*:0]const u8, env: [*:null]const ?[*:0]const u8, path: []const u8, out: linux.fd_t, err: linux.fd_t, progress_fd: linux.fd_t, ignore_stdin: bool) !linux.pid_t {
    // Allocate all paths before fork. The child must not use locks or allocators.
    var paths: std.ArrayList([*:0]const u8) = .empty;
    defer {
        for (paths.items) |candidate| allocator.free(std.mem.span(candidate));
        paths.deinit(allocator);
    }
    const name = std.mem.span(argv[0].?);
    if (name.len == 0) return error.FileNotFound;
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        try append_path(allocator, &paths, "", name);
    } else {
        var dirs = std.mem.splitScalar(u8, path, ':');
        while (dirs.next()) |dir| try append_path(allocator, &paths, dir, name);
    }

    const null_fd: ?linux.fd_t = if (ignore_stdin)
        @intCast(try check(linux.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0)))
    else
        null;
    defer if (null_fd) |fd| {
        _ = linux.close(fd);
    };

    var error_pipe: [2]linux.fd_t = undefined;
    _ = try check(linux.pipe2(&error_pipe, .{ .CLOEXEC = true }));
    defer _ = linux.close(error_pipe[0]);
    var write_open = true;
    defer if (write_open) {
        _ = linux.close(error_pipe[1]);
    };

    const result = try check(linux.fork());
    if (result == 0) {
        _ = linux.close(error_pipe[0]);
        const failure = child_exec(paths.items, argv, env, out, err, progress_fd, null_fd);
        const code: u32 = @intCast(@backingInt(failure));
        const bytes = std.mem.asBytes(&code);
        var written: usize = 0;
        while (written < bytes.len) {
            const rc = linux.write(error_pipe[1], bytes[written..].ptr, bytes.len - written);
            switch (linux.errno(rc)) {
                .SUCCESS => if (rc == 0) break else {
                    written += rc;
                },
                .INTR => continue,
                else => break,
            }
        }
        linux.exit_group(127);
    }

    const pid: linux.pid_t = @intCast(result);
    _ = linux.close(error_pipe[1]);
    write_open = false;
    errdefer {
        _ = linux.kill(pid, .KILL);
        reap(pid);
    }
    // EOF means exec closed the write end. A code means setup or exec failed.
    var code: u32 = undefined;
    const bytes = std.mem.asBytes(&code);
    var received: usize = 0;
    while (received < bytes.len) {
        const rc = linux.read(error_pipe[0], bytes[received..].ptr, bytes.len - received);
        if (linux.errno(rc) == .INTR) continue;
        const count = try check(rc);
        if (count == 0) {
            if (received != 0) return error.Unexpected;
            return pid;
        }
        received += count;
    }
    try check_errno(@fromBackingInt(@intCast(code)));
    return error.Unexpected;
}

fn append_path(allocator: std.mem.Allocator, paths: *std.ArrayList([*:0]const u8), dir: []const u8, name: []const u8) !void {
    const candidate = if (dir.len == 0)
        try allocator.dupeSentinel(u8, name, 0)
    else
        try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ dir, name }, 0);
    errdefer allocator.free(candidate);
    try paths.append(allocator, candidate.ptr);
}

fn child_exec(paths: []const [*:0]const u8, argv: [*:null]const ?[*:0]const u8, env: [*:null]const ?[*:0]const u8, out: linux.fd_t, err: linux.fd_t, progress_fd: linux.fd_t, null_fd: ?linux.fd_t) linux.E {
    if (null_fd) |fd| {
        const failure = duplicate(fd, 0);
        if (failure != .SUCCESS) return failure;
    }
    for ([_]linux.fd_t{ out, err }, [_]linux.fd_t{ 1, 2 }) |fd, destination| {
        const failure = duplicate(fd, destination);
        if (failure != .SUCCESS) return failure;
    }
    const inherit_error = linux.errno(linux.fcntl(progress_fd, linux.F.SETFD, 0));
    if (inherit_error != .SUCCESS) return inherit_error;
    const group_error = linux.errno(linux.setpgid(0, 0));
    if (group_error != .SUCCESS) return group_error;
    if (std.mem.indexOfScalar(u8, std.mem.span(argv[0].?), '/') != null)
        return linux.errno(linux.execve(argv[0].?, argv, env));
    var denied = false;
    for (paths) |candidate| {
        const failure = linux.errno(linux.execve(candidate, argv, env));
        switch (failure) {
            .ACCES => denied = true,
            .NOENT, .NOTDIR => {},
            else => return failure,
        }
    }
    return if (denied) .ACCES else .NOENT;
}

fn duplicate(source: linux.fd_t, destination: linux.fd_t) linux.E {
    while (true) {
        const rc = if (source == destination)
            linux.fcntl(source, linux.F.SETFD, 0)
        else
            linux.dup2(source, destination);
        const failure = linux.errno(rc);
        if (failure != .INTR) return failure;
    }
}

fn reap(pid: linux.pid_t) void {
    var status: i32 = undefined;
    while (linux.errno(linux.waitpid(pid, &status, 0)) == .INTR) {}
}

fn check(result: usize) !usize {
    try check_errno(linux.errno(result));
    return result;
}

fn check_errno(failure: linux.E) !void {
    switch (failure) {
        .SUCCESS => {},
        .NOENT => return error.FileNotFound,
        .ACCES, .PERM => return error.AccessDenied,
        .AGAIN, .NOMEM, .@"2BIG" => return error.SystemResources,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NAMETOOLONG => return error.NameTooLong,
        .NOTDIR => return error.NotDir,
        .NOEXEC, .INVAL => return error.InvalidExe,
        else => return std.posix.unexpectedErrno(failure),
    }
}

test "failed exec releases paths, descriptors and child processes" {
    const sink: linux.fd_t = @intCast(try check(linux.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0)));
    defer _ = linux.close(sink);
    var before: [2]linux.fd_t = undefined;
    _ = try check(linux.pipe2(&before, .{ .CLOEXEC = true }));
    _ = linux.close(before[0]);
    _ = linux.close(before[1]);
    const argv = [_:null]?[*:0]const u8{"/zpg-test-missing-command/child"};
    const env = [_:null]?[*:0]const u8{};
    for (0..16) |_| {
        try std.testing.expectError(error.FileNotFound, spawn(std.testing.allocator, &argv, &env, "", sink, sink, sink, false));
    }
    var after: [2]linux.fd_t = undefined;
    _ = try check(linux.pipe2(&after, .{ .CLOEXEC = true }));
    defer _ = linux.close(after[0]);
    defer _ = linux.close(after[1]);
    try std.testing.expectEqual(before, after);
    var status: i32 = undefined;
    try std.testing.expectEqual(linux.E.CHILD, linux.errno(linux.waitpid(-1, &status, linux.W.NOHANG)));
}

test "oversized executable arguments return a normal launch error" {
    const sink: linux.fd_t = @intCast(try check(linux.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0)));
    defer _ = linux.close(sink);
    // Linux limits each argument to 32 pages, even when ARG_MAX is larger.
    const argument = try std.testing.allocator.allocSentinel(u8, std.heap.pageSize() * 32, 0);
    defer std.testing.allocator.free(argument);
    @memset(argument, 'x');
    const argv = [_:null]?[*:0]const u8{ "/proc/self/exe", argument.ptr };
    const env = [_:null]?[*:0]const u8{};
    try std.testing.expectError(error.SystemResources, spawn(std.testing.allocator, &argv, &env, "", sink, sink, sink, false));
}
