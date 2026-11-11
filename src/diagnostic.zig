const std = @import("std");
const style = @import("style.zig");

// Quote arbitrary bytes without terminal controls, extra lines, or Unicode
// direction controls. Keep ordinary UTF-8 readable and invalid bytes exact.
pub fn escaped(bytes: []const u8) std.fmt.Alt([]const u8, format) {
    return .{ .data = bytes };
}

fn format(bytes: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var index: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        const len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        if (byte >= 128 and len > 1 and len <= bytes.len - index) {
            const cp = std.unicode.utf8Decode(bytes[index..][0..len]) catch 0;
            if (style.safe_codepoint(cp)) {
                try writer.writeAll(bytes[index..][0..len]);
                index += len;
                continue;
            }
        }
        switch (byte) {
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '"', '\\' => {
                try writer.writeByte('\\');
                try writer.writeByte(byte);
            },
            32...33, 35...91, 93...126 => try writer.writeByte(byte),
            else => try writer.print("\\x{x:0>2}", .{byte}),
        }
        index += 1;
    }
}

test "diagnostics escape terminal and direction controls and preserve text" {
    try std.testing.expectFmt(
        \\hello café \"quote\" \\ \n\r\t\x1b[2J\x7f\xc2\x9b\xe2\x80\xae\xff
    , "{f}", .{
        escaped("hello café \"quote\" \\ \n\r\t\x1b[2J\x7f\u{009b}\u{202e}\xff"),
    });
}

test "all individual bytes are safe in diagnostics" {
    for (0..256) |value| {
        var buffer: [8]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try format(&.{@intCast(value)}, &writer);
        for (writer.buffered()) |byte| try std.testing.expect(byte >= 32 and byte < 127);
    }
}
