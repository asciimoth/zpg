const std = @import("std");
const cli = @import("cli.zig");

/// Send one complete Zig progress snapshot. The shell keeps the pipe open,
/// so the parent retains these counts after this reporter exits.
pub fn send(io: std.Io, counts: cli.Report, name: []const u8) !void {
    const file = io.vtable.progressParentFile(io.userdata) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return,
        else => return err,
    };
    // Same little-endian layout as renderer.Snapshot and std.Progress.
    // One small write keeps reports from concurrent shell processes intact.
    var packet: [1 + 8 + std.Progress.Node.max_name_len + 1]u8 = @splat(0);
    packet[0] = 1;
    std.mem.writeInt(u32, packet[1..5], counts.completed, .little);
    std.mem.writeInt(u32, packet[5..9], counts.total, .little);
    const len = @min(name.len, std.Progress.Node.max_name_len);
    @memcpy(packet[9..][0..len], name[0..len]);
    packet[packet.len - 1] = 255;
    try file.writeStreamingAll(io, &packet);
}
