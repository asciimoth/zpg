const std = @import("std");
const cli = @import("cli.zig");
// Log writes clear the tree; the next progress snapshot restores it.
// Keep that blank interval near one display frame instead of the default 80 ms.
pub const progress_refresh_rate: std.Io.Duration = .fromMilliseconds(16);

pub const Stream = enum {
    stdout,
    stderr,

    pub fn file(self: Stream) std.Io.File {
        return switch (self) {
            .stdout => .stdout(),
            .stderr => .stderr(),
        };
    }
};

// Configure before starting tasks. All output and both renderers share the
// stderr lock, even when the progress terminal is stdout.
var progress_stream: ?Stream = null;
var progress_visible = false;

pub fn configure(io: std.Io, choice: cli.ProgressStream) !?std.Io.File {
    const stream: Stream = switch (choice) {
        .auto => if (try Stream.stderr.file().isTty(io)) .stderr else if (try Stream.stdout.file().isTty(io)) .stdout else return null,
        .stdout => .stdout,
        .stderr => .stderr,
    };
    stream.file().enableAnsiEscapeCodes(io) catch return null;
    progress_stream = stream;
    return stream.file();
}

fn clearProgress(writer: *std.Io.File.Writer) !void {
    // The standard tree renderer and our bars renderer use the same terminal.
    try std.Progress.clearWrittenWithEscapeCodes(writer);
    if (progress_visible) {
        try writer.interface.writeAll("\x1b[J");
        progress_visible = false;
    }
}

fn clear_locked(io: std.Io) !void {
    const stream = progress_stream orelse return;
    var buffer: [64]u8 = undefined;
    var writer = std.Io.File.Writer.initStreaming(stream.file(), io, &buffer);
    try clearProgress(&writer);
    try writer.interface.flush();
}

pub fn clear(io: std.Io) !void {
    _ = try io.vtable.lockStderr(io.userdata, null);
    defer io.unlockStderr();
    try clear_locked(io);
}

pub fn draw(io: std.Io, frame: []const u8, lines: usize) !void {
    if (lines == 0) return clear(io);
    const stream = progress_stream orelse return;
    _ = try io.vtable.lockStderr(io.userdata, null);
    defer io.unlockStderr();
    var buffer: [8192]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(stream.file(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll("\x1b[?2026h");
    try clearProgress(&file_writer);
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
    stream: Stream,
    data: [4096]u8 = undefined,
    len: usize = 0,
};
pub const Queue = std.Io.Queue(Chunk);
pub fn print(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    _ = try io.vtable.lockStderr(io.userdata, null);
    defer io.unlockStderr();
    try clear_locked(io);
    var buffer: [8192]u8 = undefined;
    var writer = std.Io.File.Writer.initStreaming(.stderr(), io, &buffer);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

pub fn writeStdout(io: std.Io, bytes: []const u8) !void {
    _ = try io.vtable.lockStderr(io.userdata, null);
    defer io.unlockStderr();
    try clear_locked(io);
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn writeBatch(io: std.Io, chunks: []const Chunk) !void {
    _ = try io.vtable.lockStderr(io.userdata, null);
    defer io.unlockStderr();
    try clear_locked(io);
    for (chunks) |chunk| try chunk.stream.file().writeStreamingAll(io, chunk.data[0..chunk.len]);
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
