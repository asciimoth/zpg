const std = @import("std");
const cli = @import("cli.zig");
const terminal = @import("terminal.zig");
// Collect updates promptly. Unchanged frames do not write to the terminal.
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
var frame_buffer: [131072]u8 = undefined;
var frame_len: usize = 0;
var frame_lines: usize = 0;
var frame_cols: usize = 0;
var frame_rows: usize = 0;

pub fn configure(io: std.Io, choice: cli.ProgressStream) !?std.Io.File {
    const stream: Stream = switch (choice) {
        .auto => if (try Stream.stderr.file().isTty(io)) .stderr else if (try Stream.stdout.file().isTty(io)) .stdout else return null,
        .stdout => .stdout,
        .stderr => .stderr,
    };
    stream.file().enableAnsiEscapeCodes(io) catch return null;
    progress_stream = stream;
    progress_visible = false;
    frame_len = 0;
    frame_lines = 0;
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
    frame_len = 0;
    frame_lines = 0;
    try clear_locked(io);
}

pub fn draw(io: std.Io, frame: []const u8, lines: usize, cols: usize, rows: usize) !void {
    if (lines == 0) return clear(io);
    const stream = progress_stream orelse return;
    _ = try io.vtable.lockStderr(io.userdata, null);
    defer io.unlockStderr();
    const unchanged = frame_cols == cols and frame_rows == rows and frame_lines == lines and
        std.mem.eql(u8, frame_buffer[0..frame_len], frame);
    if (unchanged and progress_visible) return;
    std.debug.assert(frame.len <= frame_buffer.len);
    @memcpy(frame_buffer[0..frame.len], frame);
    frame_len = frame.len;
    frame_lines = lines;
    frame_cols = cols;
    frame_rows = rows;
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
    try draw_cached(writer);
    try writer.writeAll("\x1b[?2026l");
    try writer.flush();
}

fn draw_cached(writer: *std.Io.Writer) !void {
    if (frame_lines == 0 or !cursor.can_draw(frame_lines)) return;
    // Reserve space below all child output, including a footer whose cursor
    // has returned to an earlier row. Do not use the child's saved cursor slot.
    const distance = cursor.below() + frame_lines;
    try writer.splatBytesAll("\x1bD", distance);
    cursor.reserved(distance);
    try writer.print("\x1b[{d}A\x1b[{d}B\r", .{ distance, cursor.below() + 1 });
    try writer.writeAll(frame_buffer[0..frame_len]);
    try writer.print("\x1b[{d}A\x1b[{d}G", .{ distance, cursor.column + 1 });
    progress_visible = true;
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
    var formatted: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer formatted.deinit();
    try formatted.writer.print(fmt, args);
    try write_locked(io, &.{.{ .stream = .stderr, .bytes = formatted.written() }});
}

pub fn writeStdout(io: std.Io, bytes: []const u8) !void {
    _ = try io.vtable.lockStderr(io.userdata, null);
    defer io.unlockStderr();
    try write_locked(io, &.{.{ .stream = .stdout, .bytes = bytes }});
}

const Write = struct { stream: Stream, bytes: []const u8 };

fn writeBatch(io: std.Io, chunks: []const Chunk) !void {
    _ = try io.vtable.lockStderr(io.userdata, null);
    defer io.unlockStderr();
    var writes: [8]Write = undefined;
    for (chunks, 0..) |*chunk, index| {
        writes[index] = .{ .stream = chunk.stream, .bytes = chunk.data[0..chunk.len] };
    }
    try write_locked(io, writes[0..chunks.len]);
}

fn write_locked(io: std.Io, writes: []const Write) !void {
    var next_cursor = cursor;
    var affects_terminal = false;
    for (writes) |write| {
        if (write.bytes.len != 0 and tracked_streams[@backingInt(write.stream)]) {
            next_cursor.feed(write.bytes);
            affects_terminal = true;
        }
    }
    // Never put a synchronization terminator inside a child's partial control
    // sequence, UTF-8 character, or pending line wrap.
    const synchronized = affects_terminal and progress_visible and next_cursor.ready();
    const file = if (progress_stream) |stream| stream.file() else std.Io.File.stderr();
    var buffer: [8192]u8 = undefined;
    var file_writer = std.Io.File.Writer.initStreaming(file, io, &buffer);
    const writer = &file_writer.interface;
    if (synchronized) {
        try writer.writeAll("\x1b[?2026h");
        try clearProgress(&file_writer);
        try writer.flush();
    } else if (affects_terminal) {
        try clear_locked(io);
    }
    errdefer if (synchronized) {
        file.writeStreamingAll(io, "\x1b[?2026l") catch {};
    };
    for (writes) |write| {
        try write.stream.file().writeStreamingAll(io, write.bytes);
        track(write.stream, write.bytes);
    }
    if (affects_terminal and frame_lines != 0 and cursor.can_draw(frame_lines)) {
        // A resize invalidates the cached clipping and reserved terminal space.
        // Wait for a fresh snapshot instead of drawing the old frame at a new size.
        var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        _ = try io.operate(.{ .device_io_control = .{
            .file = file,
            .code = std.posix.T.IOCGWINSZ,
            .arg = &size,
        } });
        if (size.col == frame_cols and size.row == frame_rows) {
            if (!synchronized) try writer.writeAll("\x1b[?2026h");
            try draw_cached(writer);
            if (!synchronized) try writer.writeAll("\x1b[?2026l");
        }
    }
    if (synchronized) try writer.writeAll("\x1b[?2026l");
    try writer.flush();
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
