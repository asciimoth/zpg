const std = @import("std");
const styles = @import("style.zig");

// This is the packet layout emitted by the linked Zig standard library:
// node count, little-endian counters and names, then one parent byte per node.
const record_size = 8 + std.Progress.Node.max_name_len;
const no_parent = 255;

pub const Snapshot = struct {
    bytes: []const u8,
    count: usize,

    pub fn init(bytes: []const u8) !Snapshot {
        if (bytes.len == 0 or bytes[0] == 0 or bytes[0] >= 254 or
            bytes.len != 1 + @as(usize, bytes[0]) * (record_size + 1))
            return error.InvalidProgressPacket;
        return .{ .bytes = bytes, .count = bytes[0] };
    }

    fn parent(self: Snapshot, index: usize) u8 {
        return self.bytes[1 + self.count * record_size + index];
    }

    fn record(self: Snapshot, index: usize) []const u8 {
        return self.bytes[1 + index * record_size ..][0..record_size];
    }

    fn hasSibling(self: Snapshot, index: usize) bool {
        for (index + 1..self.count) |other| {
            if (self.parent(other) == self.parent(index)) return true;
        }
        return false;
    }
};

pub fn packetSize(count: u8) usize {
    return 1 + @as(usize, count) * (record_size + 1);
}

// Keep codepoints intact and use conservative terminal cell widths.
fn clipped(writer: *std.Io.Writer, text: []const u8, width: usize) !void {
    var index: usize = 0;
    var cells: usize = 0;
    while (index < text.len and cells < width) {
        const byte = text[index];
        if (byte < 128) {
            try writer.writeByte(if (byte >= 32 and byte != 127) byte else '?');
            index += 1;
            cells += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        const end = index + len;
        const codepoint = if (len > 1 and end <= text.len)
            std.unicode.utf8Decode(text[index..end]) catch 0
        else
            0;
        if (codepoint < 160) {
            try writer.writeByte('?');
            index += 1;
            cells += 1;
        } else {
            const cell_width = styles.cell_width(codepoint);
            if (cells + cell_width > width) break;
            try writer.writeAll(text[index..end]);
            index = end;
            cells += cell_width;
        }
    }
}

fn counter(writer: *std.Io.Writer, completed: u32, total: u32, tick: usize, style: styles.Style) !void {
    const bar_width = 12;
    if (total == 0 or total == std.math.maxInt(u32)) {
        try writer.print(" {s}", .{style.spinner.frame(tick)});
        if (total == 0 and completed != 0) try writer.print(" {d} done", .{completed});
    } else {
        try writer.writeByte(' ');
        try writer.writeAll(style.bar.left);
        const value: u64 = @min(completed, total);
        const filled = value * bar_width / total;
        for (0..bar_width) |index| {
            const is_filled = index < filled;
            const glyph = if (style.bar.caps) |caps| blk: {
                if (index == 0) break :blk if (is_filled) caps.left_filled else caps.left_empty;
                if (index == bar_width - 1) break :blk if (is_filled) caps.right_filled else caps.right_empty;
                break :blk if (is_filled) style.bar.filled else style.bar.empty;
            } else if (is_filled) style.bar.filled else style.bar.empty;
            try writer.writeAll(glyph);
        }
        try writer.print("{s} {d}% {d}/{d}", .{ style.bar.right, value * 100 / total, completed, total });
    }
}

const Frame = struct {
    writer: *std.Io.Writer,
    snapshot: Snapshot,
    width: usize,
    limit: usize,
    tick: usize,
    style: styles.Style,
    lines: usize = 0,
    visited: [254]bool = @splat(false),
    branches: [254]bool = @splat(false),

    fn node(self: *Frame, index: usize, depth: usize) std.Io.Writer.Error!void {
        if (self.lines == self.limit or self.visited[index]) return;
        self.visited[index] = true;
        const record = self.snapshot.record(index);
        const name = std.mem.sliceTo(record[8..], 0);
        const completed = std.mem.readInt(u32, record[0..4], .little);
        const total = std.mem.readInt(u32, record[4..8], .little);
        var suffix_buffer: [96]u8 = undefined;
        var suffix = std.Io.Writer.fixed(&suffix_buffer);
        try counter(&suffix, completed, total, self.tick, self.style);
        var line_buffer: [2048]u8 = undefined;
        var line = std.Io.Writer.fixed(&line_buffer);
        if (depth != 0) {
            for (0..depth - 1) |ancestor| {
                try line.writeAll(if (self.branches[ancestor]) "│  " else "   ");
            }
            try line.writeAll(if (self.snapshot.hasSibling(index)) "├─ " else "└─ ");
        }
        const name_width = @max(8, self.width -| (styles.text_width(line.buffered()) + styles.text_width(suffix.buffered())));
        try clipped(&line, name, name_width);
        try line.writeAll(suffix.buffered());
        if (self.lines != 0) try self.writer.writeAll("\r\n");
        try clipped(self.writer, line.buffered(), self.width);
        self.lines += 1;
        if (depth != 0) self.branches[depth - 1] = self.snapshot.hasSibling(index);
        for (0..self.snapshot.count) |child| {
            if (self.snapshot.parent(child) == index) try self.node(child, depth + 1);
            if (self.lines == self.limit) break;
        }
    }
};

/// The frame contains printable labels and CRLF separators, without cursor codes.
pub fn render(writer: *std.Io.Writer, snapshot: Snapshot, cols: usize, rows: usize, tick: usize, style: styles.Style) !usize {
    var frame: Frame = .{
        .writer = writer,
        .snapshot = snapshot,
        .width = @min(cols -| 1, 512),
        .limit = @min(rows -| 2, snapshot.count),
        .tick = tick,
        .style = style,
    };
    if (frame.width == 0 or frame.limit == 0) return 0;
    // Only the first node is the root. Detached or cyclic nodes are omitted.
    if (snapshot.parent(0) == no_parent) try frame.node(0, 0);
    return frame.lines;
}

fn testPacket(buffer: []u8, parents: []const u8, names: []const []const u8) []u8 {
    const bytes = buffer[0..packetSize(@intCast(parents.len))];
    @memset(bytes, 0);
    bytes[0] = @intCast(parents.len);
    for (names, 0..) |name, index| {
        @memcpy(bytes[1 + index * record_size + 8 ..][0..name.len], name);
    }
    @memcpy(bytes[1 + parents.len * record_size ..], parents);
    return bytes;
}

test "bars clamp estimates and distinguish unknown totals" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try counter(&writer, 3, 4, 0, .{});
    try std.testing.expectEqualStrings(" [#########---] 75% 3/4", writer.buffered());
    writer.end = 0;
    try counter(&writer, 9, 4, 0, .{});
    try std.testing.expectEqualStrings(" [############] 100% 9/4", writer.buffered());
    writer.end = 0;
    try counter(&writer, 4, 0, 2, .{});
    try std.testing.expectEqualStrings(" - 4 done", writer.buffered());
    writer.end = 0;
    try counter(&writer, std.math.maxInt(u32), std.math.maxInt(u32) - 1, 0, .{});
    try std.testing.expect(std.mem.find(u8, writer.buffered(), "100%") != null);
}

test "custom counters retain counts, estimates, and spinner timing" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const style: styles.Style = .{
        .bar = try styles.Bar.parse("block"),
        .spinner = try styles.Spinner.parse("⠋⠙"),
    };
    try counter(&writer, 1, 2, 0, style);
    try std.testing.expectEqualStrings(" ██████       50% 1/2", writer.buffered());
    writer.end = 0;
    try counter(&writer, 0, 2, 0, style);
    try std.testing.expectEqualStrings("              0% 0/2", writer.buffered());
    writer.end = 0;
    try counter(&writer, 3, 2, 0, style);
    try std.testing.expectEqualStrings(" ████████████ 100% 3/2", writer.buffered());
    writer.end = 0;
    try counter(&writer, 4, 0, 3, style);
    try std.testing.expectEqualStrings(" ⠙ 4 done", writer.buffered());
    writer.end = 0;
    try counter(&writer, 4, std.math.maxInt(u32), 2, style);
    try std.testing.expectEqualStrings(" ⠋", writer.buffered());
    writer.end = 0;
    try counter(&writer, 1, 2, 0, .{ .bar = try styles.Bar.parse("(▓░)") });
    try std.testing.expectEqualStrings(" (▓▓▓▓▓▓░░░░░░) 50% 1/2", writer.buffered());
}

test "Fira Code bars fill end caps as part of the twelve positions" {
    const style: styles.Style = .{ .bar = try styles.Bar.parse("fira") };
    const cases = .{
        .{ 0, " \u{ee00}" ++ "\u{ee01}\u{ee01}\u{ee01}\u{ee01}\u{ee01}\u{ee01}\u{ee01}\u{ee01}\u{ee01}\u{ee01}" ++ "\u{ee02} 0% 0/12" },
        .{ 1, " \u{ee03}" ++ "\u{ee01}\u{ee01}\u{ee01}\u{ee01}\u{ee01}\u{ee01}\u{ee01}\u{ee01}\u{ee01}\u{ee01}" ++ "\u{ee02} 8% 1/12" },
        .{ 6, " \u{ee03}" ++ "\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}" ++ "\u{ee01}\u{ee01}\u{ee01}\u{ee01}\u{ee01}" ++ "\u{ee02} 50% 6/12" },
        .{ 11, " \u{ee03}" ++ "\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}" ++ "\u{ee02} 91% 11/12" },
        .{ 12, " \u{ee03}" ++ "\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}" ++ "\u{ee05} 100% 12/12" },
        .{ 15, " \u{ee03}" ++ "\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}" ++ "\u{ee05} 100% 15/12" },
    };
    inline for (cases) |case| {
        var buffer: [96]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try counter(&writer, case[0], 12, 0, style);
        try std.testing.expectEqualStrings(case[1], writer.buffered());
    }
}

test "Fira Code bars and spinners fit terminal columns" {
    var packet: [1024]u8 = undefined;
    const bytes = testPacket(&packet, &.{255}, &.{"build"});
    std.mem.writeInt(u32, bytes[1..5], 1, .little);
    std.mem.writeInt(u32, bytes[5..9], 2, .little);
    const snapshot = try Snapshot.init(bytes);
    const style: styles.Style = .{
        .bar = try styles.Bar.parse("fira"),
        .spinner = try styles.Spinner.parse("fira"),
    };
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    _ = try render(&writer, snapshot, 27, 24, 0, style);
    try std.testing.expectEqualStrings("build \u{ee03}" ++ "\u{ee04}\u{ee04}\u{ee04}\u{ee04}\u{ee04}" ++ "\u{ee01}\u{ee01}\u{ee01}\u{ee01}\u{ee01}" ++ "\u{ee02} 50% 1/2", writer.buffered());
    for (2..27) |cols| {
        writer.end = 0;
        _ = try render(&writer, snapshot, cols, 24, 0, style);
        try std.testing.expect(std.unicode.utf8ValidateSlice(writer.buffered()));
        try std.testing.expect(styles.text_width(writer.buffered()) < cols);
    }
    std.mem.writeInt(u32, bytes[5..9], 0, .little);
    writer.end = 0;
    _ = try render(&writer, snapshot, 16, 24, 5, style);
    try std.testing.expectEqualStrings("build \u{ee0b} 1 done", writer.buffered());
}

test "Unicode styles fit by cells instead of bytes and clip whole codepoints" {
    var packet: [1024]u8 = undefined;
    const bytes = testPacket(&packet, &.{255}, &.{"long build label"});
    std.mem.writeInt(u32, bytes[1..5], 1, .little);
    std.mem.writeInt(u32, bytes[5..9], 2, .little);
    const snapshot = try Snapshot.init(bytes);
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const style: styles.Style = .{ .bar = try styles.Bar.parse("block") };
    _ = try render(&writer, snapshot, 38, 24, 0, style);
    try std.testing.expectEqualStrings("long build label ██████       50% 1/2", writer.buffered());
    for (2..38) |cols| {
        writer.end = 0;
        _ = try render(&writer, snapshot, cols, 24, 0, style);
        try std.testing.expect(std.unicode.utf8ValidateSlice(writer.buffered()));
        try std.testing.expect(styles.text_width(writer.buffered()) < cols);
    }
    writer.end = 0;
    try clipped(&writer, "█⠋界", 3);
    try std.testing.expectEqualStrings("█⠋", writer.buffered());
}

test "tree follows parents even when children precede them" {
    var packet: [1024]u8 = undefined;
    const snapshot = try Snapshot.init(testPacket(&packet, &.{ 255, 3, 0, 0 }, &.{ "root", "leaf", "first", "second" }));
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(@as(usize, 4), try render(&writer, snapshot, 80, 24, 0, .{}));
    try std.testing.expectEqualStrings(
        "root |\r\n├─ first |\r\n└─ second |\r\n   └─ leaf |",
        writer.buffered(),
    );
}

test "tree continuation branches use terminal cell widths" {
    var packet: [1024]u8 = undefined;
    const snapshot = try Snapshot.init(testPacket(&packet, &.{ 255, 0, 1, 0 }, &.{ "root", "first", "long leaf keys", "last" }));
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    _ = try render(&writer, snapshot, 22, 24, 0, .{});
    try std.testing.expectEqualStrings(
        "root |\r\n├─ first |\r\n│  └─ long leaf key |\r\n└─ last |",
        writer.buffered(),
    );
}

test "small terminals and unsafe names stay within bounds" {
    var packet: [1024]u8 = undefined;
    const snapshot = try Snapshot.init(testPacket(&packet, &.{ 255, 0, 1 }, &.{ "root\x1b[2J", "child\nline", "leaf" }));
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(@as(usize, 2), try render(&writer, snapshot, 10, 4, 0, .{}));
    try std.testing.expect(std.mem.findScalar(u8, writer.buffered(), 27) == null);
    var lines = std.mem.splitSequence(u8, writer.buffered(), "\r\n");
    while (lines.next()) |line| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(line));
        try std.testing.expect(styles.text_width(line) <= 9);
    }
    writer.end = 0;
    try std.testing.expectEqual(@as(usize, 0), try render(&writer, snapshot, 1, 1, 0, .{}));
    try std.testing.expectEqual(@as(usize, 0), writer.end);
}

test "invalid packets and detached cycles cannot escape the tree" {
    try std.testing.expectError(error.InvalidProgressPacket, Snapshot.init(&.{}));
    try std.testing.expectError(error.InvalidProgressPacket, Snapshot.init(&.{ 1, 0 }));
    var packet: [1024]u8 = undefined;
    const snapshot = try Snapshot.init(testPacket(&packet, &.{ 255, 2, 1, 99 }, &.{ "root", "cycle", "cycle", "orphan" }));
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try std.testing.expectEqual(@as(usize, 1), try render(&writer, snapshot, 80, 24, 0, .{}));
}

test "Unicode names remain whole and invalid bytes are replaced" {
    var buffer: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try clipped(&writer, "café \xe7\x95\x8c", 6);
    try std.testing.expectEqualStrings("café ", writer.buffered());
    writer.end = 0;
    try clipped(&writer, "bad\xe2\x82\xff\x1b", 80);
    try std.testing.expectEqualStrings("bad????", writer.buffered());
    writer.end = 0;
    try clipped(&writer, "short\xe2\x82", 80);
    try std.testing.expectEqualStrings("short??", writer.buffered());
}
