const std = @import("std");
const process_wait = @import("process_wait.zig");
const cli = @import("cli.zig");
const reader = @import("stream_reader.zig");
const output = @import("output.zig");
const signals = @import("signals.zig");
const progress = @import("progress.zig");
const child_process = @import("child_process.zig");
const guess = @import("guess.zig");
fn wait(io: std.Io, child: *std.process.Child, done: *std.atomic.Value(bool)) !std.process.Child.Term {
    defer done.store(true, .release);
    return child.wait(io);
}
pub fn run(io: std.Io, environ: std.process.Environ, o: cli.Options) !u8 {
    const log_file = if (o.test_output) |path| try std.Io.Dir.cwd().createFile(io, path, .{}) else std.Io.File.stderr();
    defer if (o.test_output != null) log_file.close(io);
    var test_log: @import("test_log.zig").Log = .{ .file = log_file };
    const handles = if (o.test_mode) try std.Io.Threaded.pipe2(.{ .CLOEXEC = true }) else null;
    const test_pipe: ?[2]std.Io.File = if (handles) |fds| .{ .{ .handle = fds[0], .flags = .{ .nonblocking = false } }, .{ .handle = fds[1], .flags = .{ .nonblocking = false } } } else null;
    defer if (test_pipe) |files| files[0].close(io);
    var write_open = test_pipe != null;
    defer if (write_open) test_pipe.?[1].close(io);
    const guard = signals.Guard.install();
    defer guard.restore();
    const term = blk: {
        var display: progress.Progress = .{};
        const root = try display.start(io, o.progress and !o.test_mode, o.progress_stream, o.renderer, o.style, .{
            .root_name = "zpg",
            .refresh_rate_ns = output.progress_refresh_rate,
        });
        defer display.end(io);
        const node = root.start(o.name, 0);
        defer node.end();
        var child = try child_process.spawnWithProgressFile(io, environ, o.argv, node, if (test_pipe) |files| files[1] else null);
        defer child.kill(io);
        if (test_pipe) |files| {
            files[1].close(io);
            write_open = false;
        }
        const pid = child.id.?;
        const stdout = child.stdout.?;
        child.stdout = null;
        defer stdout.close(io);
        const stderr = child.stderr.?;
        child.stderr = null;
        defer stderr.close(io);
        // Readers borrow the capture handles; wait must not close them.
        var storage: [32]output.Chunk = undefined;
        var queue = output.Queue.init(&storage);
        var failed = std.atomic.Value(bool).init(false);
        var done = std.atomic.Value(u32).init(0);
        var logger: ?std.Io.Future(void) = if (test_pipe) |files| try io.concurrent(@import("test_log.zig").Log.run, .{ &test_log, io, files[0], &done, &failed }) else null;
        defer if (logger) |*task| task.cancel(io);
        var exited = std.atomic.Value(bool).init(false);
        var writer = try io.concurrent(output.run, .{ io, &queue, &failed });
        defer writer.cancel(io);
        var out = try io.concurrent(reader.run, .{ io, stdout, .stdout, &queue, &done, &failed });
        defer out.cancel(io);
        var err = try io.concurrent(reader.run, .{ io, stderr, .stderr, &queue, &done, &failed });
        defer err.cancel(io);
        var waiter = try io.concurrent(wait, .{ io, &child, &exited });
        defer _ = waiter.cancel(io) catch {};
        // An IPC node stores its pipe index in the completed count. Ending a
        // local child would increment that count, so use a sibling node.
        const estimate = if (o.guess) root.start(guess.unknown_name, 0) else std.Progress.Node.none;
        defer estimate.end();
        var estimator: ?std.Io.Future(void) = if (estimate.index != .none)
            try io.concurrent(guess.run, .{ io, pid, estimate })
        else
            null;
        defer if (estimator) |*task| task.cancel(io);
        var shutdown: process_wait.Shutdown = .{};
        while (!exited.load(.acquire)) {
            if (shutdown.next_signal(std.Io.Clock.awake.now(io), signals.get() != 0 or failed.load(.acquire))) |sig| {
                std.posix.kill(-pid, sig) catch {};
            }
            try io.sleep(.fromMilliseconds(20), .awake);
        }
        const result = try waiter.await(io);
        if (estimator) |*task| task.cancel(io);
        estimator = null;
        const truncated = !try process_wait.wait_for_drain(io, &done, if (o.test_mode) 3 else 2);
        if (logger) |*task| task.cancel(io);
        logger = null;
        if (o.test_mode and truncated) try test_log.print(io, "progress/output drain timeout; capture incomplete", .{});
        out.cancel(io);
        err.cancel(io);
        queue.close(io);
        writer.await(io);
        if (truncated) try output.print(io, "zpg: pipe drain timeout; remaining output discarded\n", .{});
        if (failed.load(.acquire)) return error.StreamFailed;
        break :blk result;
    };
    if (o.test_mode) try test_log.print(io, "process result={any}; protocol={s}", .{ term, if (test_log.invalid) "invalid" else "no errors detected" });
    if (signals.get() != 0) return @intCast(128 + signals.get());
    return switch (term) {
        .exited => |code| if (code == 0 and test_log.invalid) 1 else code,
        .signal => |sig| @intCast(@min(255, 128 + @as(u32, @backingInt(sig)))),
        else => 1,
    };
}

test {
    _ = guess;
}
