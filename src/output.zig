const std = @import("std");
// Log writes clear the tree; the next progress snapshot restores it.
// Keep that blank interval near one display frame instead of the default 80 ms.
pub const progress_refresh_rate: std.Io.Duration = .fromMilliseconds(16);

// Protected by the stderr lock, including access from the renderer task.
var progress_visible = false;

fn clearProgress(writer: *std.Io.Writer) !void {
    if (!progress_visible) return;
    try writer.writeAll("\x1b[J");
    progress_visible = false;
}

pub fn clear(io: std.Io) !void {
    var buffer: [64]u8 = undefined;
    const locked = try io.lockStderr(&buffer, null);
    defer io.unlockStderr();
    try clearProgress(&locked.file_writer.interface);
    try locked.file_writer.interface.flush();
}

pub fn draw(io: std.Io, frame: []const u8, lines: usize) !void {
    if (lines == 0) return clear(io);
    var buffer: [8192]u8 = undefined;
    const locked = try io.lockStderr(&buffer, null);
    defer io.unlockStderr();
    const writer = &locked.file_writer.interface;
    try writer.writeAll("\x1b[?2026h");
    try clearProgress(writer);
    // Reserve space before saving the cursor. IND scrolls when needed and
    // preserves the column, so a partial log line can continue after redraw.
    try writer.splatBytesAll("\x1bD", lines);
    try writer.print("\x1b[{d}A\x1b7\r\n", .{lines});
    try writer.writeAll(frame);
    try writer.writeAll("\x1b8\x1b[?2026l");
    progress_visible = true;
    try writer.flush();
}

pub const Chunk = struct {
    data: [4096]u8 = undefined,
    len: usize = 0,
};
pub const Queue = std.Io.Queue(Chunk);
pub fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buffer: [8192]u8 = undefined;
    const locked = try io.lockStderr(&buffer, null);
    defer io.unlockStderr();
    try clearProgress(&locked.file_writer.interface);
    try locked.file_writer.interface.print(fmt, args);
    try locked.file_writer.interface.flush();
}

pub fn writeStdout(io: std.Io, bytes: []const u8) !void {
    // The standalone mock's stdout can share a terminal with the progress tree.
    // Clear the tree under its lock before writing on that terminal.
    var buffer: [64]u8 = undefined;
    const locked = try io.lockStderr(&buffer, null);
    defer io.unlockStderr();
    try clearProgress(&locked.file_writer.interface);
    try locked.file_writer.interface.flush();
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn writeBatch(io: std.Io, chunks: []const Chunk) !void {
    var buffer: [8192]u8 = undefined;
    const locked = try io.lockStderr(&buffer, null);
    defer io.unlockStderr();
    try clearProgress(&locked.file_writer.interface);
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
