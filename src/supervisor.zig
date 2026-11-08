const std = @import("std");
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
fn wait_for_drain(io: std.Io, done: *std.atomic.Value(u32)) !bool {
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(2));
    while (done.load(.acquire) != 2) {
        if (std.Io.Clock.awake.now(io).compare(.gte, deadline)) return false;
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    return true;
}
pub fn run(io: std.Io, environ: std.process.Environ, o: cli.Options) !u8 {
    const guard = signals.Guard.install();
    defer guard.restore();
    const term = blk: {
        var display: progress.Progress = .{};
        const root = try display.start(io, o.progress, o.renderer, o.style, .{
            .root_name = "zpg",
            .refresh_rate_ns = output.progress_refresh_rate,
        });
        defer display.end(io);
        const node = root.start(o.name, 0);
        defer node.end();
        var child = try child_process.spawn(io, environ, o.argv, node);
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
        // An IPC node stores its pipe index in the completed count. Ending a
        // local child would increment that count, so use a sibling node.
        const estimate = if (o.guess) root.start(guess.unknown_name, 0) else std.Progress.Node.none;
        defer estimate.end();
        var estimator: ?std.Io.Future(void) = if (estimate.index != .none)
            try io.concurrent(guess.run, .{ io, pid, estimate })
        else
            null;
        defer if (estimator) |*task| task.cancel(io);
        var shutdown_started = false;
        var shutdown_deadline: ?std.Io.Timestamp = null;
        while (!exited.load(.acquire)) {
            if (shutdown_deadline) |deadline| {
                if (std.Io.Clock.awake.now(io).compare(.gte, deadline)) {
                    std.posix.kill(-pid, .KILL) catch {};
                    shutdown_deadline = null;
                }
            } else if (!shutdown_started and (signals.get() != 0 or failed.load(.acquire))) {
                std.posix.kill(-pid, .TERM) catch {};
                shutdown_started = true;
                shutdown_deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(2));
            }
            try io.sleep(.fromMilliseconds(20), .awake);
        }
        const result = try waiter.await(io);
        if (estimator) |*task| task.cancel(io);
        estimator = null;
        const truncated = !try wait_for_drain(io, &done);
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

test "pipe drain expires when sleeps take longer than requested" {
    const SlowClock = struct {
        elapsed: std.Io.Duration = .zero,
        done: std.atomic.Value(u32) = .init(0),

        fn now(userdata: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const self: *@This() = @ptrCast(@alignCast(userdata));
            return .fromNanoseconds(self.elapsed.nanoseconds);
        }

        fn sleep(userdata: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
            const self: *@This() = @ptrCast(@alignCast(userdata));
            // Model delayed wakeups and a descendant that closes its pipes
            // after four seconds, as in the integration fixture.
            self.elapsed.nanoseconds += std.Io.Duration.fromMilliseconds(50).nanoseconds;
            if (self.elapsed.toMilliseconds() >= 4000) self.done.store(2, .release);
        }
    };
    var clock: SlowClock = .{};
    var vtable = std.testing.io.vtable.*;
    vtable.now = SlowClock.now;
    vtable.sleep = SlowClock.sleep;
    const io: std.Io = .{ .userdata = &clock, .vtable = &vtable };
    try std.testing.expect(!try wait_for_drain(io, &clock.done));
    try std.testing.expect(clock.elapsed.toMilliseconds() >= 2000);
    try std.testing.expect(clock.elapsed.toMilliseconds() < 4000);
}

test {
    _ = guess;
}
