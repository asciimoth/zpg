const std = @import("std");
const output = @import("output.zig");
pub fn run(io: std.Io, file: std.Io.File, q: *output.Queue, done: *std.atomic.Value(u32), failed: *std.atomic.Value(bool)) void {
    defer _ = done.fetchAdd(1, .release);
    var chunk: output.Chunk = .{};
    while (true) {
        const n = file.readStreaming(io, &.{&chunk.data}) catch |err| {
            if (err == error.EndOfStream) break;
            if (err != error.Canceled) failed.store(true, .release);
            return;
        };
        if (n == 0) continue;
        chunk.len = n;
        q.putOne(io, chunk) catch return;
    }
}
