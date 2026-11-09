const std = @import("std");
const cli = @import("cli.zig");
const output = @import("output.zig");
const renderer = @import("renderer.zig");
const styles = @import("style.zig");

// std.Progress has one process-wide instance. Its I/O adapters use this state
// while all callbacks keep the original I/O userdata.
var local_parent: std.Io.File = undefined;
var terminal: std.Io.File = undefined;

fn parentFile(_: ?*anyopaque) std.Progress.ParentFileError!std.Io.File {
    return local_parent;
}

pub const Progress = struct {
    root: std.Progress.Node = .none,
    vtable: std.Io.VTable = undefined,
    pipe: ?[2]std.Io.File = null,
    worker: ?std.Io.Future(void) = null,

    // Keep this object at a stable address until end() returns: std.Progress
    // borrows the vtable while it collects child progress and emits snapshots.
    pub fn start(self: *Progress, io: std.Io, enabled: bool, stream: cli.ProgressStream, mode: cli.Renderer, style: styles.Style, options: std.Progress.Options) !std.Progress.Node {
        if (!enabled) return .none;
        const no_parent = if (io.vtable.progressParentFile(io.userdata)) |_| false else |err| err == error.EnvironmentVariableMissing;
        if (!no_parent) {
            self.root = std.Progress.start(io, options);
            return self.root;
        }
        terminal = (try output.configure(io, stream)) orelse return .none;
        // Both renderers send plain frames through output.draw so the same
        // cursor tracking protects child output in either display mode.
        self.vtable = io.vtable.*;
        const handles = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
        const pipe: [2]std.Io.File = .{ .{ .handle = handles[0], .flags = .{ .nonblocking = false } }, .{ .handle = handles[1], .flags = .{ .nonblocking = false } } };
        errdefer for (pipe) |file| file.close(io);
        self.worker = try io.concurrent(receive, .{ io, pipe[0], style, mode });
        self.pipe = pipe;
        local_parent = pipe[1];
        self.vtable.progressParentFile = parentFile;
        self.root = std.Progress.start(.{ .userdata = io.userdata, .vtable = &self.vtable }, options);
        return self.root;
    }

    pub fn end(self: *Progress, io: std.Io) void {
        // Stop the producer before the reader and keep both pipe ends open
        // until both tasks have stopped, including during cancellation.
        self.root.end();
        if (self.worker) |*worker| worker.cancel(io);
        if (self.pipe) |pipe| {
            for (pipe) |file| file.close(io);
            output.clear(io) catch {};
        }
    }
};

fn readAll(io: std.Io, file: std.Io.File, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = try file.readStreaming(io, &.{bytes[offset..]});
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}

fn receive(io: std.Io, file: std.Io.File, style: styles.Style, mode: cli.Renderer) void {
    var packet: [std.Progress.max_packet_len]u8 = undefined;
    var frame_buffer: [131072]u8 = undefined;
    var tick: usize = 0;
    while (true) : (tick +%= 1) {
        readAll(io, file, packet[0..1]) catch return;
        const len = renderer.packetSize(packet[0]);
        if (len > packet.len) return;
        readAll(io, file, packet[1..len]) catch return;
        const snapshot = renderer.Snapshot.init(packet[0..len]) catch continue;
        var size: std.posix.winsize = .{ .row = 25, .col = 80, .xpixel = 0, .ypixel = 0 };
        _ = io.operate(.{ .device_io_control = .{
            .file = terminal,
            .code = std.posix.T.IOCGWINSZ,
            .arg = &size,
        } }) catch return;
        var frame = std.Io.Writer.fixed(&frame_buffer);
        const lines = renderer.renderMode(&frame, snapshot, size.col, size.row, tick / 5, style, mode) catch continue;
        // A failed display must not stop draining the progress pipe and block
        // the stdlib collector. The log writer reports output errors separately.
        output.draw(io, frame.buffered(), lines, size.col, size.row) catch {};
    }
}

test {
    _ = renderer;
}
