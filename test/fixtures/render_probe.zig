const std = @import("std");

fn checkpoint(init: std.process.Init, stage: u8, fallback_ms: i64) !void {
    const io = init.io;
    const directory = init.environ_map.get("ZPG_TEST_SYNC") orelse {
        try io.sleep(.fromMilliseconds(fallback_ms), .awake);
        return;
    };
    var buffer: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "{s}/{d}", .{ directory, stage });
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(10));
    while (true) {
        std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                if (std.Io.Clock.awake.now(io).compare(.gte, deadline)) return error.TestTimeout;
                try io.sleep(.fromMilliseconds(10), .awake);
                continue;
            },
            else => return err,
        };
        return;
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const root = std.Progress.start(io, .{
        .root_name = "render probe",
        .estimated_total_items = 4,
        .initial_delay_ns = .zero,
        .refresh_rate_ns = .fromMilliseconds(16),
    });
    defer root.end();
    root.setCompletedItems(3);
    const unknown = root.start("unknown", 0);
    defer unknown.end();
    unknown.setCompletedItems(2);
    const leaf = unknown.start("unsafe\x1b[2J label\u{202e}", 10);
    defer leaf.end();
    leaf.setCompletedItems(5);
    for (0..12) |_| try std.Io.File.stdout().writeStreamingAll(io, "log line\n");
    try std.Io.File.stdout().writeStreamingAll(io, "partial ");
    try checkpoint(init, 0, 400);
    try std.Io.File.stdout().writeStreamingAll(io, "continued\n");
    try checkpoint(init, 1, 300);
    root.setCompletedItems(7);
    try checkpoint(init, 2, 300);
}
