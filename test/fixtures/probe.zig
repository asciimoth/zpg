const std = @import("std");
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const root = std.Progress.start(io, .{ .root_name = "probe" });
    defer root.end();
    const node = root.start("child", 0);
    defer node.end();
    var child = try std.process.spawn(io, .{ .argv = &.{"true"}, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe, .progress_node = node });
    const term = try child.wait(io);
    var buf: [256]u8 = undefined;
    const locked = try io.lockStderr(&buf, null);
    defer io.unlockStderr();
    try locked.file_writer.interface.print("probe: {f}\n", .{term});
    try locked.file_writer.interface.flush();
}
