const std = @import("std");
const cli = @import("cli.zig");
const reader = @import("stream_reader.zig");
const output = @import("output.zig");
const signals = @import("signals.zig");
fn wait(io: std.Io, child: *std.process.Child, done: *std.atomic.Value(bool)) !std.process.Child.Term {
    defer done.store(true, .release);
    return child.wait(io);
}
pub fn run(io: std.Io, o: cli.Options) !u8 {
    const guard = signals.Guard.install();
    defer guard.restore();
    const term = blk: {
        const root = if (o.progress) std.Progress.start(io, .{
            .root_name = "zpg",
            .refresh_rate_ns = output.progress_refresh_rate,
        }) else std.Progress.Node.none;
        defer root.end();
        const node = root.start(o.name, 0);
        defer node.end();
        var child = try std.process.spawn(io, .{ .argv = o.argv, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe, .progress_node = node, .pgid = 0 });
        defer child.kill(io);
        const pid = child.id.?;
        const stdout = child.stdout.?;
        child.stdout = null;
        defer stdout.close(io);
        const stderr = child.stderr.?;
        child.stderr = null;
        defer stderr.close(io);
        // Readers borrow the pipe handles; wait must not close them.
        var storage: [32]output.Chunk = undefined;
        var queue = output.Queue.init(&storage);
        var failed = std.atomic.Value(bool).init(false);
        var done = std.atomic.Value(u32).init(0);
        var exited = std.atomic.Value(bool).init(false);
        var writer = try io.concurrent(output.run, .{ io, &queue, &failed });
        defer writer.cancel(io);
        var out = try io.concurrent(reader.run, .{ io, stdout, &queue, &done, &failed });
        defer out.cancel(io);
        var err = try io.concurrent(reader.run, .{ io, stderr, &queue, &done, &failed });
        defer err.cancel(io);
        var waiter = try io.concurrent(wait, .{ io, &child, &exited });
        defer _ = waiter.cancel(io) catch {};
        var shutdown_ticks: ?usize = null;
        while (!exited.load(.acquire)) {
            if (shutdown_ticks) |ticks| {
                if (ticks == 100) std.posix.kill(-pid, .KILL) catch {};
                shutdown_ticks = ticks + 1;
            } else if (signals.get() != 0 or failed.load(.acquire)) {
                std.posix.kill(-pid, .TERM) catch {};
                shutdown_ticks = 0;
            }
            try io.sleep(.fromMilliseconds(20), .awake);
        }
        const result = try waiter.await(io);
        var ticks: usize = 0;
        while (done.load(.acquire) != 2 and ticks < 100) : (ticks += 1) try io.sleep(.fromMilliseconds(20), .awake);
        const truncated = done.load(.acquire) != 2;
        out.cancel(io);
        err.cancel(io);
        queue.close(io);
        writer.await(io);
        if (truncated) try output.print(io, "zpg: pipe drain timeout; remaining output discarded\n", .{});
        if (failed.load(.acquire)) return error.StreamFailed;
        break :blk result;
    };
    if (signals.get() != 0) return @intCast(128 + signals.get());
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| @intCast(@min(255, 128 + @as(u32, @backingInt(sig)))),
        else => 1,
    };
}
