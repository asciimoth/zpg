const std = @import("std");

pub const Shutdown = struct {
    started: bool = false,
    deadline: ?std.Io.Timestamp = null,

    pub fn next_signal(self: *Shutdown, now: std.Io.Timestamp, requested: bool) ?std.posix.SIG {
        if (self.deadline) |deadline| {
            if (now.compare(.gte, deadline)) {
                self.deadline = null;
                return .KILL;
            }
        } else if (!self.started and requested) {
            self.started = true;
            self.deadline = now.addDuration(.fromSeconds(2));
            return .TERM;
        }
        return null;
    }
};

test "shutdown escalates once after a delayed wakeup" {
    var shutdown: Shutdown = .{};
    const start = std.Io.Timestamp.fromNanoseconds(1000000000);
    try std.testing.expectEqual(null, shutdown.next_signal(start, false));
    try std.testing.expectEqual(std.posix.SIG.TERM, shutdown.next_signal(start, true).?);
    try std.testing.expectEqual(null, shutdown.next_signal(start.addDuration(.fromMilliseconds(1999)), true));
    try std.testing.expectEqual(std.posix.SIG.KILL, shutdown.next_signal(start.addDuration(.fromSeconds(3)), true).?);
    try std.testing.expectEqual(null, shutdown.next_signal(start.addDuration(.fromSeconds(4)), true));
}

pub fn wait_for_drain(io: std.Io, done: *std.atomic.Value(u32), target: u32) !bool {
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(2));
    while (done.load(.acquire) != target) {
        if (std.Io.Clock.awake.now(io).compare(.gte, deadline)) return false;
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    return true;
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
            // after four seconds.
            self.elapsed.nanoseconds += std.Io.Duration.fromMilliseconds(50).nanoseconds;
            if (self.elapsed.toMilliseconds() >= 4000) self.done.store(2, .release);
        }
    };
    var clock: SlowClock = .{};
    var vtable = std.testing.io.vtable.*;
    vtable.now = SlowClock.now;
    vtable.sleep = SlowClock.sleep;
    const io: std.Io = .{ .userdata = &clock, .vtable = &vtable };
    try std.testing.expect(!try wait_for_drain(io, &clock.done, 2));
    try std.testing.expect(clock.elapsed.toMilliseconds() >= 2000);
    try std.testing.expect(clock.elapsed.toMilliseconds() < 4000);
}
