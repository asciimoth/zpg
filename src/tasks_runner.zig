const std = @import("std");
const cli = @import("cli.zig");
const tasks = @import("tasks.zig");
const progress = @import("progress.zig");
const output = @import("output.zig");
const reader = @import("stream_reader.zig");
const child_process = @import("child_process.zig");
const process_wait = @import("process_wait.zig");
const signals = @import("signals.zig");
const guess = @import("guess.zig");

const Job = struct {
    child: ?std.process.Child = null,
    pid: ?std.posix.pid_t = null,
    node: std.Progress.Node = .none,
    command_node: std.Progress.Node = .none,
    estimate: std.Progress.Node = .none,
    stdout: ?std.Io.File = null,
    stderr: ?std.Io.File = null,
    out: ?std.Io.Future(void) = null,
    err: ?std.Io.Future(void) = null,
    estimator: ?std.Io.Future(void) = null,
    waiter: ?std.Io.Future(std.process.Child.WaitError!std.process.Child.Term) = null,
    exited: std.atomic.Value(bool) = .init(false),
    code: ?u8 = null,

    fn wait(self: *Job, io: std.Io, first: *std.atomic.Value(usize), index: usize) std.process.Child.WaitError!std.process.Child.Term {
        defer self.exited.store(true, .release);
        const term = try self.child.?.wait(io);
        _ = first.cmpxchgStrong(std.math.maxInt(usize), index, .acq_rel, .acquire);
        return term;
    }

    fn stop(self: *Job, sig: std.posix.SIG) void {
        if (self.pid) |pid| std.posix.kill(-pid, sig) catch {};
    }

    fn end_progress(self: *Job, io: std.Io) void {
        if (self.estimator) |*future| future.cancel(io);
        self.estimator = null;
        self.estimate.end();
        self.estimate = .none;
        self.command_node.end();
        self.command_node = .none;
        self.node.end();
        self.node = .none;
    }

    fn close(self: *Job, io: std.Io) void {
        // The caller kills all groups before joining any waiter on error.
        if (self.waiter) |*future| _ = future.cancel(io) catch {};
        if (self.child) |*child| child.kill(io);
        if (self.out) |*future| future.cancel(io);
        if (self.err) |*future| future.cancel(io);
        if (self.stdout) |file| file.close(io);
        if (self.stderr) |file| file.close(io);
        self.end_progress(io);
    }
};

pub fn run(io: std.Io, allocator: std.mem.Allocator, environ: std.process.Environ, o: cli.Options, config: tasks.Config) !u8 {
    const guard = signals.Guard.install();
    defer guard.restore();
    var display: progress.Progress = .{};
    const root = try display.start(io, o.progress, o.progress_stream, o.renderer, o.style, .{
        .root_name = "zpg",
        .refresh_rate_ns = output.progress_refresh_rate,
    });
    defer display.end(io);
    const tree = root.start("tasks", config.tasks.len);
    defer tree.end();
    var storage: [32]output.Chunk = undefined;
    var queue = output.Queue.init(&storage);
    var failed = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(u32).init(0);
    var first = std.atomic.Value(usize).init(std.math.maxInt(usize));
    var writer = try io.concurrent(output.run, .{ io, &queue, &failed });
    defer writer.cancel(io);
    const jobs = try allocator.alloc(Job, config.tasks.len);
    defer allocator.free(jobs);
    for (jobs) |*job| job.* = .{};
    defer for (jobs) |*job| job.close(io);
    errdefer for (jobs) |*job| job.stop(.KILL);

    var started: usize = 0;
    for (config.tasks, jobs, 0..) |task, *job, index| {
        // Launching many tasks can take time. Stop creating processes as soon
        // as shutdown is requested, then use the normal group shutdown below.
        if (signals.get() != 0 or failed.load(.acquire) or
            (config.stop_on_first_finish and first.load(.acquire) != std.math.maxInt(usize))) break;
        job.node = tree.start(task.name orelse std.fs.path.basename(task.command[0]), 0);
        // Keep estimates beside the IPC node: ending a local child of an IPC
        // node would change the pipe index stored in its completed count.
        job.command_node = job.node.start("command", 0);
        job.child = child_process.spawn(io, environ, task.command, job.command_node) catch |err| {
            try output.print(io, "zpg: task {d} (\"{f}\"): {s}\n", .{ index + 1, @import("diagnostic.zig").escaped(task.name orelse task.command[0]), @errorName(err) });
            return err;
        };
        job.pid = job.child.?.id.?;
        job.stdout = job.child.?.stdout;
        job.child.?.stdout = null;
        job.stderr = job.child.?.stderr;
        job.child.?.stderr = null;
        job.out = try io.concurrent(reader.run, .{ io, job.stdout.?, .stdout, &queue, &done, &failed });
        job.err = try io.concurrent(reader.run, .{ io, job.stderr.?, .stderr, &queue, &done, &failed });
        job.waiter = try io.concurrent(Job.wait, .{ job, io, &first, index });
        if (task.guess) {
            job.estimate = job.node.start(guess.unknown_name, 0);
            if (job.estimate.index != .none)
                job.estimator = io.concurrent(guess.run, .{ io, job.pid.?, job.estimate }) catch null;
        }
        started += 1;
    }

    const active = jobs[0..started];
    var remaining = active.len;
    var shutdown: process_wait.Shutdown = .{};
    while (remaining != 0) {
        const requested = signals.get() != 0 or failed.load(.acquire) or
            (config.stop_on_first_finish and first.load(.acquire) != std.math.maxInt(usize));
        if (shutdown.next_signal(std.Io.Clock.awake.now(io), requested)) |sig| {
            for (jobs) |*job| job.stop(sig);
        }
        for (active) |*job| {
            if (job.code != null or !job.exited.load(.acquire)) continue;
            const term = try job.waiter.?.await(io);
            job.waiter = null;
            job.code = switch (term) {
                .exited => |code| code,
                .signal => |sig| @intCast(@min(255, 128 + @as(u32, @backingInt(sig)))),
                else => 1,
            };
            job.end_progress(io);
            remaining -= 1;
        }
        if (remaining != 0) try io.sleep(.fromMilliseconds(20), .awake);
    }
    // A group leader can exit before its descendants. Do not leave those
    // descendants running when tasks were stopped by a signal or finish rule.
    if (shutdown.started or config.stop_on_first_finish) for (jobs) |*job| job.stop(.KILL);
    const truncated = !try process_wait.wait_for_drain(io, &done, @intCast(active.len * 2));
    // An interrupt can also arrive while descendants keep the pipes open.
    if (signals.get() != 0 or failed.load(.acquire)) for (jobs) |*job| job.stop(.KILL);
    for (jobs) |*job| {
        if (job.out) |*future| future.cancel(io);
        job.out = null;
        if (job.err) |*future| future.cancel(io);
        job.err = null;
    }
    queue.close(io);
    writer.await(io);
    if (truncated) try output.print(io, "zpg: pipe drain timeout; remaining output discarded\n", .{});
    if (failed.load(.acquire)) return error.StreamFailed;
    if (signals.get() != 0) return @intCast(128 + signals.get());
    if (config.stop_on_first_finish) return jobs[first.load(.acquire)].code.?;
    // File order makes the result stable when several tasks fail together.
    for (active) |job| if (job.code.? != 0) return job.code.?;
    return 0;
}
