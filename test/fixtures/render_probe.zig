const std = @import("std");

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
    try io.sleep(.fromMilliseconds(400), .awake);
    try std.Io.File.stdout().writeStreamingAll(io, "continued\n");
    try io.sleep(.fromMilliseconds(300), .awake);
    root.setCompletedItems(7);
    try io.sleep(.fromMilliseconds(300), .awake);
}
