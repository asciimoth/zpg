const std = @import("std");
const cli = @import("cli.zig");
const terminal = @import("terminal.zig");
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
var cursor: terminal.Cursor = .{};
var tracked_streams: [2]bool = .{ false, false };

pub fn configure(io: std.Io, choice: cli.ProgressStream) !?std.Io.File {
    const stream: Stream = switch (choice) {
        .auto => if (try Stream.stderr.file().isTty(io)) .stderr else if (try Stream.stdout.file().isTty(io)) .stdout else return null,
        .stdout => .stdout,
        .stderr => .stderr,
    };
    stream.file().enableAnsiEscapeCodes(io) catch return null;
    progress_stream = stream;
    for ([_]Stream{ .stdout, .stderr }, 0..) |candidate, index| {
        tracked_streams[index] = try candidate.file().isTty(io) and
            terminal.same_terminal(candidate.file().handle, stream.file().handle);
    }
    const attributes = try std.posix.tcgetattr(stream.file().handle);
    cursor = .{ .newline_resets_column = attributes.oflag.OPOST and attributes.oflag.ONLCR };
    var size: std.posix.winsize = .{ .row = 25, .col = 80, .xpixel = 0, .ypixel = 0 };
    _ = try io.operate(.{ .device_io_control = .{
        .file = stream.file(),
        .code = std.posix.T.IOCGWINSZ,
        .arg = &size,
    } });
    cursor.resize(size.col, size.row);
    return stream.file();
}

fn clearProgress(writer: *std.Io.File.Writer) !void {
    // Clear only our rows. The child may have moved back into an earlier
    // row, or used CR to leave text to the right of its current column.
    if (progress_visible) {
        const distance = cursor.below() + 1;
        try writer.interface.print("\x1b[{d}B\r\x1b[J\x1b[{d}A\x1b[{d}G", .{ distance, distance, cursor.column + 1 });
        progress_visible = false;
    }
}

fn clear_locked(io: std.Io) !void {
    const stream = progress_stream orelse return;
    var buffer: [64]u8 = undefined;
    var writer = std.Io.File.Writer.initStreaming(stream.file(), io, &buffer);
    if (!progress_visible) return;
    try writer.interface.writeAll("\x1b[?2026h");
    try clearProgress(&writer);
    try writer.interface.writeAll("\x1b[?2026l");
    try writer.interface.flush();
}

pub fn clear(io: std.Io) !void {
    _ = try io.vtable.lockStderr(io.userdata, null);
    defer io.unlockStderr();
    try clear_locked(io);
}

pub fn draw(io: std.Io, frame: []const u8, lines: usize, cols: usize, rows: usize) !void {
    if (lines == 0) return clear(io);
    const stream = progress_stream orelse return;
    _ = try io.vtable.lockStderr(io.userdata, null);
    defer io.unlockStderr();
    cursor.resize(cols, rows);
    if (!cursor.can_draw(lines)) {
        try clear_locked(io);
        return;
    }
    var buffer: [8192]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(stream.file(), io, &buffer);
    const writer = &file_writer.interface;
    try writer.writeAll("\x1b[?2026h");
    try clearProgress(&file_writer);
    // Reserve space below all child output, including a footer whose cursor
    // has returned to an earlier row. Do not use the child's saved cursor slot.
    const distance = cursor.below() + lines;
    try writer.splatBytesAll("\x1bD", distance);
    cursor.reserved(distance);
    try writer.print("\x1b[{d}A\x1b[{d}B\r", .{ distance, cursor.below() + 1 });
    try writer.writeAll(frame);
    try writer.print("\x1b[{d}A\x1b[{d}G\x1b[?2026l", .{ distance, cursor.column + 1 });
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
    var formatted: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer formatted.deinit();
    try formatted.writer.print(fmt, args);
    const bytes = formatted.written();
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
    track(.stderr, bytes);
}

pub fn writeStdout(io: std.Io, bytes: []const u8) !void {
    _ = try io.vtable.lockStderr(io.userdata, null);
    defer io.unlockStderr();
    try clear_locked(io);
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
    track(.stdout, bytes);
}

fn writeBatch(io: std.Io, chunks: []const Chunk) !void {
    _ = try io.vtable.lockStderr(io.userdata, null);
    defer io.unlockStderr();
    try clear_locked(io);
    for (chunks) |chunk| {
        const bytes = chunk.data[0..chunk.len];
        try chunk.stream.file().writeStreamingAll(io, bytes);
        track(chunk.stream, bytes);
    }
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

fn track(stream: Stream, bytes: []const u8) void {
    if (tracked_streams[@backingInt(stream)]) cursor.feed(bytes);
}

test {
    _ = terminal;
}
