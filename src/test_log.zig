const std = @import("std");
const renderer = @import("renderer.zig");

/// Read the original wire stream, before std.Progress can discard snapshots.
pub const Log = struct {
    file: std.Io.File,
    packets: usize = 0,
    invalid: bool = false,

    pub fn print(self: *Log, io: std.Io, comptime fmt: []const u8, args: anytype) !void {
        _ = try io.vtable.lockStderr(io.userdata, null);
        defer io.unlockStderr();
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.Writer.initStreaming(self.file, io, &buffer);
        try writer.interface.print("zpg-test: " ++ fmt ++ "\n", args);
        try writer.interface.flush();
    }

    pub fn run(self: *Log, io: std.Io, pipe: std.Io.File, done: *std.atomic.Value(u32), failed: *std.atomic.Value(bool)) void {
        defer _ = done.fetchAdd(1, .release);
        self.receive(io, pipe) catch |err| {
            if (err != error.Canceled) failed.store(true, .release);
        };
    }

    fn receive(self: *Log, io: std.Io, pipe: std.Io.File) !void {
        var packet: [33000]u8 = undefined;
        var previous: [33000]u8 = undefined;
        var previous_len: usize = 0;
        try self.print(io, "progress pipe opened", .{});
        while (true) {
            const first = pipe.readStreaming(io, &.{packet[0..1]}) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return err,
            };
            if (first == 0) {
                try self.print(io, "progress pipe closed; snapshots={d}", .{self.packets});
                if (self.packets == 0) try self.print(io, "no progress received", .{});
                return;
            }
            const len = renderer.packetSize(packet[0]);
            var offset: usize = 1;
            while (offset < len) {
                const n = pipe.readStreaming(io, &.{packet[offset..len]}) catch |err| switch (err) {
                    error.EndOfStream => 0,
                    else => return err,
                };
                if (n == 0) {
                    self.invalid = true;
                    try self.print(io, "error: truncated packet; received={d} expected={d}", .{ offset, len });
                    return;
                }
                offset += n;
            }
            self.packets += 1;
            const changed = !std.mem.eql(u8, previous[0..previous_len], packet[0..len]);
            try self.print(io, "snapshot={d} nodes={d} {s}", .{ self.packets, packet[0], if (changed) "changed" else "unchanged" });
            const count: usize = packet[0];
            const record_size = 8 + std.Progress.Node.max_name_len;
            if (count >= 254) {
                self.invalid = true;
                try self.print(io, "error: reserved node count {d}", .{count});
            }
            for (0..count) |i| {
                const record = packet[1 + i * record_size ..][0..record_size];
                const parent = packet[1 + count * record_size + i];
                // The root is first; every other node must reach it without a cycle.
                var cursor: usize = i;
                var steps: usize = 0;
                while (cursor != 0 and cursor < count and steps < count) : (steps += 1) {
                    cursor = packet[1 + count * record_size + cursor];
                }
                if ((i == 0 and parent != 255) or (i != 0 and (cursor != 0 or steps == count))) {
                    self.invalid = true;
                    try self.print(io, "error: node={d} invalid parent tree; parent={d}", .{ i, parent });
                }
                const completed = std.mem.readInt(u32, record[0..4], .little);
                const total = std.mem.readInt(u32, record[4..8], .little);
                if (total == std.math.maxInt(u32)) {
                    self.invalid = true;
                    try self.print(io, "error: node={d} reserved total count", .{i});
                }
                if (changed) {
                    const name = std.mem.sliceTo(record[8..], 0);
                    // Escape arbitrary bytes so labels cannot inject terminal controls or log lines.
                    try self.print(io, "node={d} parent={d} completed={d} total={d} name=\"{f}\"", .{ i, parent, completed, total, @import("diagnostic.zig").escaped(name) });
                }
            }
            @memcpy(previous[0..len], packet[0..len]);
            previous_len = len;
        }
    }
};
