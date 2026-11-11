const std = @import("std");
const process_wait = @import("process_wait.zig");
const output = @import("output.zig");
const signals = @import("signals.zig");
const reader = @import("stream_reader.zig");
const cli = @import("cli.zig");
const child_process = @import("child_process.zig");

// A fixed seed makes the demo repeatable. The tree shape and task times still vary.
const seed = 0x7a70672d6d6f636b;

const Colors = struct {
    stdout: bool,
    stderr: bool,

    fn detect(io: std.Io) !Colors {
        return .{
            .stdout = try std.Io.File.stdout().isTty(io),
            .stderr = try std.Io.File.stderr().isTty(io),
        };
    }

    fn writeStdout(self: Colors, io: std.Io, comptime line: []const u8) !void {
        try output.writeStdout(io, if (self.stdout) "\x1b[32m" ++ line[0 .. line.len - 1] ++ "\x1b[0m\n" else line);
    }

    fn printStderr(self: Colors, io: std.Io, comptime fmt: []const u8, args: anytype) !void {
        if (self.stderr) {
            try output.print(io, "\x1b[31m" ++ fmt[0 .. fmt.len - 1] ++ "\x1b[0m\n", args);
        } else {
            try output.print(io, fmt, args);
        }
    }
};

fn pause(io: std.Io, random: std.Random, base_ms: u32) !void {
    if (signals.get() != 0) return error.Interrupted;
    const jitter = random.uintLessThan(u32, 170);
    try io.sleep(.fromMilliseconds(2 * (base_ms + jitter)), .awake);
    if (signals.get() != 0) return error.Interrupted;
}

fn note(io: std.Io, colors: Colors, random: std.Random, phase: []const u8, detail: []const u8) !void {
    try colors.writeStdout(io, "mock stdout: work in progress\n");
    if (random.uintLessThan(u8, 3) != 0)
        try colors.printStderr(io, "mock stderr: {s}: {s}\n", .{ phase, detail });
}

fn work(io: std.Io, colors: Colors, random: std.Random, parent: std.Progress.Node, name: []const u8, phase: []const u8, base_ms: u32) !void {
    const task = parent.start(name, 1);
    defer task.end();
    try note(io, colors, random, phase, name);
    try pause(io, random, base_ms);
}

fn demonstrate(io: std.Io, colors: Colors, random: std.Random, root: std.Progress.Node) !void {
    {
        const discover = root.start("discover", 2);
        defer discover.end();
        try work(io, colors, random, discover, "read config", "discover", 100);
        const scan = discover.start("scan inputs", 0);
        defer scan.end();
        const inputs = 2 + random.uintLessThan(usize, 3);
        scan.setEstimatedTotalItems(inputs);
        for (0..inputs) |i| {
            const item = scan.startFmt(1, "input {d}", .{i + 1});
            defer item.end();
            try note(io, colors, random, "discover", "scan input");
            try pause(io, random, 55);
            if (i == 1) try work(io, colors, random, item, "inspect metadata", "discover", 75);
        }
    }
    {
        const build = root.start("build", 3);
        defer build.end();
        // Keep siblings live together so the display shows an uneven graph.
        const assets = build.start("assets", 0);
        var assets_done = false;
        defer if (!assets_done) assets.end();
        const code = build.start("code", 0);
        var code_done = false;
        defer if (!code_done) code.end();
        const verify = build.start("verify", 0);
        var verify_done = false;
        defer if (!verify_done) verify.end();

        const asset_count = 2 + random.uintLessThan(usize, 2);
        assets.setEstimatedTotalItems(asset_count);
        for (0..asset_count) |i| {
            const asset = assets.startFmt(1, "asset {d}", .{i + 1});
            defer asset.end();
            try note(io, colors, random, "build", "asset");
            try pause(io, random, 80);
            if (i == 0) {
                const transform = asset.start("transform", 2);
                defer transform.end();
                try work(io, colors, random, transform, "decode", "build", 90);
                try work(io, colors, random, transform, "compress", "build", 130);
            }
        }
        assets.end();
        assets_done = true;

        const module_count = 2 + random.uintLessThan(usize, 3);
        code.setEstimatedTotalItems(module_count);
        for (0..module_count) |i| {
            const module = code.startFmt(1, "module {d}", .{i + 1});
            defer module.end();
            try note(io, colors, random, "build", "module");
            try pause(io, random, 95);
            if (i == module_count - 1) {
                const generate = module.start("generate", 2);
                defer generate.end();
                try work(io, colors, random, generate, "emit source", "build", 100);
                const link = generate.start("link", 1);
                defer link.end();
                try work(io, colors, random, link, "resolve symbols", "build", 220);
            }
        }
        code.end();
        code_done = true;

        const checks = 1 + random.uintLessThan(usize, 2);
        verify.setEstimatedTotalItems(checks);
        for (0..checks) |i| {
            const check = verify.startFmt(1, "check {d}", .{i + 1});
            defer check.end();
            try note(io, colors, random, "build", "verify");
            try pause(io, random, 180);
            if (i == 0 and random.boolean())
                try work(io, colors, random, check, "repair index", "build", 130);
        }
        verify.end();
        verify_done = true;
    }
    {
        const publish = root.start("publish", 2);
        defer publish.end();
        const upload = publish.start("upload", 3);
        var upload_done = false;
        defer if (!upload_done) upload.end();
        for (0..3) |_| {
            try note(io, colors, random, "publish", "upload chunk");
            try pause(io, random, 65);
            upload.completeOne();
        }
        upload.end();
        upload_done = true;
        try work(io, colors, random, publish, "write manifest", "publish", 95);
    }
}

// Keep these examples separate from worker logs so each update owns its rows.
fn demonstrateTerminal(io: std.Io, colors: Colors, root: std.Progress.Node) !void {
    const task = root.start("terminal output", @intFromBool(colors.stdout) + @as(usize, @intFromBool(colors.stderr)));
    defer task.end();
    if (colors.stdout) {
        for ([_][]const u8{
            "\r\x1b[2K\x1b[32mmock carriage return: [----] 0%\x1b[0m",
            "\r\x1b[2K\x1b[32mmock carriage return: [##--] 50%\x1b[0m",
            "\r\x1b[2K\x1b[32mmock carriage return: [####] 100%\x1b[0m",
        }) |bytes| {
            try output.writeStdout(io, bytes);
            try io.sleep(.fromMilliseconds(120), .awake);
        }
        try output.writeStdout(io, "\n");
        task.completeOne();
    }
    if (colors.stderr) {
        // Leave the cursor above the footer between updates, as a small
        // progress display can do. Both rows must survive zpg's redraws.
        try output.print(io, "\x1b[31mmock footer: waiting\r\nmock footer items: 0/2\x1b[0m\r\x1b[A", .{});
        try io.sleep(.fromMilliseconds(120), .awake);
        try output.print(io, "\r\x1b[2K\x1b[31mmock footer: running\r\n\x1b[2Kmock footer items: 1/2\x1b[0m\r\x1b[A", .{});
        try io.sleep(.fromMilliseconds(120), .awake);
        try output.print(io, "\r\x1b[2K\x1b[31mmock footer: complete\r\n\x1b[2Kmock footer items: 2/2\x1b[0m\r\n", .{});
        task.completeOne();
        try io.sleep(.fromMilliseconds(120), .awake);
    }
}

fn emitInputLine(io: std.Io, line: []const u8, node: std.Progress.Node) !void {
    if (signals.get() != 0) return error.Interrupted;
    try output.writeStdout(io, line);
    node.completeOne();
    try io.sleep(.fromMilliseconds(120), .awake);
    if (signals.get() != 0) return error.Interrupted;
}

fn processInputChunk(io: std.Io, allocator: std.mem.Allocator, pending: *std.ArrayList(u8), bytes: []const u8, node: std.Progress.Node) !void {
    const max_pending = 64 * 1024;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const limit = offset + @min(bytes.len - offset, max_pending - pending.items.len);
        const end = if (std.mem.indexOfScalarPos(u8, bytes[0..limit], offset, '\n')) |index| index + 1 else limit;
        try pending.appendSlice(allocator, bytes[offset..end]);
        if (bytes[end - 1] == '\n') {
            try emitInputLine(io, pending.items, node);
            pending.clearRetainingCapacity();
        } else if (pending.items.len == max_pending) {
            // Stream long lines without unlimited allocation. Retain one byte
            // so EOF still completes and delays the final unterminated line.
            try output.writeStdout(io, pending.items[0 .. max_pending - 1]);
            pending.items[0] = pending.items[max_pending - 1];
            pending.shrinkRetainingCapacity(1);
        }
        offset = end;
    }
}

fn readInputTask(io: std.Io, buffer: *[4096]u8, done: *std.atomic.Value(bool)) !usize {
    defer done.store(true, .release);
    return std.Io.File.stdin().readStreaming(io, &.{buffer});
}

fn readInput(io: std.Io, buffer: *[4096]u8) !usize {
    var done = std.atomic.Value(bool).init(false);
    var task = try io.concurrent(readInputTask, .{ io, buffer, &done });
    defer _ = task.cancel(io) catch {};
    while (!done.load(.acquire)) {
        if (signals.get() != 0) return error.Interrupted;
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    return task.await(io);
}

fn runInput(io: std.Io, allocator: std.mem.Allocator, o: cli.Options, first: []const u8) !u8 {
    const root = if (o.progress) std.Progress.start(io, .{
        .root_name = o.name,
        .refresh_rate_ns = output.progress_refresh_rate,
        .disable_printing = true,
    }) else std.Progress.Node.none;
    defer root.end();
    const lines = root.start("input lines", 0);
    defer lines.end();
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);

    processInputChunk(io, allocator, &pending, first, lines) catch |err| switch (err) {
        error.Interrupted => return @intCast(128 + signals.get()),
        else => return err,
    };
    var buffer: [4096]u8 = undefined;
    while (true) {
        if (signals.get() != 0) return @intCast(128 + signals.get());
        const count = readInput(io, &buffer) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Interrupted => return @intCast(128 + signals.get()),
            else => return err,
        };
        if (count == 0) continue;
        processInputChunk(io, allocator, &pending, buffer[0..count], lines) catch |err| switch (err) {
            error.Interrupted => return @intCast(128 + signals.get()),
            else => return err,
        };
    }
    if (pending.items.len != 0) {
        emitInputLine(io, pending.items, lines) catch |err| switch (err) {
            error.Interrupted => return @intCast(128 + signals.get()),
            else => return err,
        };
    }
    return if (signals.get() != 0) @intCast(128 + signals.get()) else 0;
}

fn statusCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => |sig| @intCast(@min(255, 128 + @as(u32, @backingInt(sig)))),
        else => 1,
    };
}

fn waitChild(io: std.Io, child: *std.process.Child, exited: *std.atomic.Value(bool)) !std.process.Child.Term {
    defer exited.store(true, .release);
    return child.wait(io);
}

fn runWorkerProcess(
    io: std.Io,
    environ: std.process.Environ,
    exe: []const u8,
    kind: []const u8,
    node: std.Progress.Node,
    queue: *output.Queue,
    failed: *std.atomic.Value(bool),
) !std.process.Child.Term {
    var child = try child_process.spawn(io, environ, &.{ exe, "--mock-worker", kind }, node);
    defer child.kill(io);
    const pid = child.id.?;
    const stdout = child.stdout.?;
    child.stdout = null;
    defer stdout.close(io);
    const stderr = child.stderr.?;
    child.stderr = null;
    defer stderr.close(io);

    var done = std.atomic.Value(u32).init(0);
    var exited = std.atomic.Value(bool).init(false);
    var out = try io.concurrent(reader.run, .{ io, stdout, .stdout, queue, &done, failed });
    defer out.cancel(io);
    var err = try io.concurrent(reader.run, .{ io, stderr, .stderr, queue, &done, failed });
    defer err.cancel(io);
    var waiter = try io.concurrent(waitChild, .{ io, &child, &exited });
    defer _ = waiter.cancel(io) catch {};

    var shutdown: process_wait.Shutdown = .{};
    while (!exited.load(.acquire)) {
        if (shutdown.next_signal(std.Io.Clock.awake.now(io), signals.get() != 0 or failed.load(.acquire))) |sig| {
            std.posix.kill(-pid, sig) catch {};
        }
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    const result = try waiter.await(io);
    const truncated = !try process_wait.wait_for_drain(io, &done, 2);
    out.cancel(io);
    err.cancel(io);
    if (truncated) try output.print(io, "zpg: mock worker {s} pipe drain timeout\n", .{kind});
    if (failed.load(.acquire)) return error.StreamFailed;
    return result;
}

fn demonstrateWorker(io: std.Io, colors: Colors, kind: []const u8, root: std.Progress.Node, random: std.Random) !void {
    try colors.printStderr(io, "mock worker {s} (pid {d}): started\n", .{ kind, std.posix.system.getpid() });
    for (0..3) |batch_index| {
        const batch = root.startFmt(0, "{s} batch {d}", .{ kind, batch_index + 1 });
        defer batch.end();
        const items = 2 + random.uintLessThan(usize, 2);
        batch.setEstimatedTotalItems(items);
        for (0..items) |item_index| {
            const item = batch.startFmt(1, "item {d}", .{item_index + 1});
            defer item.end();
            try colors.writeStdout(io, "mock worker: processing item\n");
            try pause(io, random, 120 + @as(u32, @intCast(batch_index)) * 35);
            if (batch_index == 1 and item_index == 0) {
                const inspect = item.start("inspect", 2);
                defer inspect.end();
                try work(io, colors, random, inspect, "decode", kind, 130);
                try work(io, colors, random, inspect, "normalize", kind, 160);
            }
        }
    }
    try colors.printStderr(io, "mock worker {s}: complete\n", .{kind});
}

pub fn runWorker(io: std.Io, kind: []const u8, progress_enabled: bool) !u8 {
    if (!std.mem.eql(u8, kind, "indexer") and
        !std.mem.eql(u8, kind, "compiler") and
        !std.mem.eql(u8, kind, "uploader")) return error.InvalidMockWorker;

    const guard = signals.Guard.install();
    defer guard.restore();
    const root = if (progress_enabled) std.Progress.start(io, .{
        .root_name = kind,
        .estimated_total_items = 3,
        .refresh_rate_ns = output.progress_refresh_rate,
        .disable_printing = true,
    }) else std.Progress.Node.none;
    defer root.end();
    var prng = std.Random.DefaultPrng.init(seed ^ @as(u64, kind[0]));
    demonstrateWorker(io, try Colors.detect(io), kind, root, prng.random()) catch |err| switch (err) {
        error.Interrupted => return @intCast(128 + signals.get()),
        else => return err,
    };
    return 0;
}

pub fn run(io: std.Io, allocator: std.mem.Allocator, environ: std.process.Environ, o: cli.Options) !u8 {
    const guard = signals.Guard.install();
    defer guard.restore();
    if (!try std.Io.File.stdin().isTty(io)) {
        var first: [4096]u8 = undefined;
        while (true) {
            const count = readInput(io, &first) catch |err| switch (err) {
                error.EndOfStream => break,
                error.Interrupted => return @intCast(128 + signals.get()),
                else => return err,
            };
            if (count != 0) return runInput(io, allocator, o, first[0..count]);
        }
    }
    const colors = try Colors.detect(io);
    const exe = try std.process.executablePathAlloc(io, allocator);
    const root = if (o.progress) std.Progress.start(io, .{
        .root_name = "mock",
        .estimated_total_items = 7,
        .refresh_rate_ns = output.progress_refresh_rate,
        .disable_printing = true,
    }) else std.Progress.Node.none;
    defer root.end();

    const indexer_node = root.start("indexer", 0);
    defer indexer_node.end();
    const compiler_node = root.start("compiler", 0);
    defer compiler_node.end();
    const uploader_node = root.start("uploader", 0);
    defer uploader_node.end();

    var storage: [32]output.Chunk = undefined;
    var queue = output.Queue.init(&storage);
    var failed = std.atomic.Value(bool).init(false);
    var writer = try io.concurrent(output.run, .{ io, &queue, &failed });
    defer writer.cancel(io);
    var indexer = try io.concurrent(runWorkerProcess, .{ io, environ, exe, "indexer", indexer_node, &queue, &failed });
    defer _ = indexer.cancel(io) catch {};
    var compiler = try io.concurrent(runWorkerProcess, .{ io, environ, exe, "compiler", compiler_node, &queue, &failed });
    defer _ = compiler.cancel(io) catch {};
    var uploader = try io.concurrent(runWorkerProcess, .{ io, environ, exe, "uploader", uploader_node, &queue, &failed });
    defer _ = uploader.cancel(io) catch {};

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var first_error: ?anyerror = null;
    demonstrate(io, colors, random, root) catch |err| switch (err) {
        error.Interrupted => {},
        else => first_error = err,
    };

    const indexer_term = indexer.await(io) catch blk: {
        first_error = error.MockWorkerFailed;
        break :blk std.process.Child.Term{ .exited = 1 };
    };
    const compiler_term = compiler.await(io) catch blk: {
        first_error = error.MockWorkerFailed;
        break :blk std.process.Child.Term{ .exited = 1 };
    };
    const uploader_term = uploader.await(io) catch blk: {
        first_error = error.MockWorkerFailed;
        break :blk std.process.Child.Term{ .exited = 1 };
    };
    queue.close(io);
    writer.await(io);
    if (first_error) |err| return err;
    if (failed.load(.acquire)) return error.StreamFailed;
    if (signals.get() != 0) return @intCast(128 + signals.get());
    for ([_]std.process.Child.Term{ indexer_term, compiler_term, uploader_term }) |term| {
        const code = statusCode(term);
        if (code != 0) return code;
    }
    try demonstrateTerminal(io, colors, root);
    if (signals.get() != 0) return @intCast(128 + signals.get());
    try colors.writeStdout(io, "mock stdout: complete\n");
    try colors.printStderr(io, "mock stderr: complete\n", .{});
    return 0;
}
