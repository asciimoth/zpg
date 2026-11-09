const std = @import("std");
const builtin = @import("builtin");
const output = @import("output.zig");
pub fn run(io: std.Io, file: std.Io.File, stream: output.Stream, q: *output.Queue, done: *std.atomic.Value(u32), failed: *std.atomic.Value(bool)) void {
    defer _ = done.fetchAdd(1, .release);
    const terminal = file.isTty(io) catch return;
    var chunk: output.Chunk = .{ .stream = stream };
    while (true) {
        const n = file.readStreaming(io, &.{&chunk.data}) catch |err| {
            if (err == error.EndOfStream) break;
            // Linux returns EIO after the last PTY slave closes and all queued
            // output has been read. Other stream I/O errors remain failures.
            if (builtin.os.tag == .linux and terminal and err == error.InputOutput) break;
            if (err != error.Canceled) failed.store(true, .release);
            return;
        };
        if (n == 0) continue;
        chunk.len = n;
        q.putOne(io, chunk) catch return;
    }
}
