const std = @import("std");
// lockStderr clears the tree; std.Progress restores it on its next timer tick.
// Keep that blank interval near one display frame instead of the default 80 ms.
pub const progress_refresh_rate: std.Io.Duration = .fromMilliseconds(16);

pub const Chunk = struct {
    data: [4096]u8 = undefined,
    len: usize = 0,
};
pub const Queue = std.Io.Queue(Chunk);
pub fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [8192]u8 = undefined;
    const locked = try io.lockStderr(&buffer, null);
    defer io.unlockStderr();
    try locked.file_writer.interface.print(fmt, args);
    try locked.file_writer.interface.flush();
}

pub fn writeStdout(io: std.Io, bytes: []const u8) !void {
    // The standalone mock's stdout can share a terminal with the progress tree.
    // Clear the tree under its lock before writing on that terminal.
    _ = try io.lockStderr(&.{}, null);
    defer io.unlockStderr();
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn writeBatch(io: std.Io, chunks: []const Chunk) !void {
    var buffer: [8192]u8 = undefined;
    const locked = try io.lockStderr(&buffer, null);
    defer io.unlockStderr();
    for (chunks) |chunk| try locked.file_writer.interface.writeAll(chunk.data[0..chunk.len]);
    try locked.file_writer.interface.flush();
}

pub fn run(io: std.Io, q: *Queue, failed: *std.atomic.Value(bool)) void {
    // Take available chunks together without waiting to fill the batch. Keep
    // batches bounded so the renderer can acquire the lock during heavy output.
    var chunks: [8]Chunk = undefined;
    while (true) {
        const count = q.get(io, &chunks, 1) catch return;
        writeBatch(io, chunks[0..count]) catch {
            failed.store(true, .release);
            q.close(io);
            return;
        };
    }
}
