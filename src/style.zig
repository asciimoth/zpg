const std = @import("std");

pub const Style = struct {
    bar: Bar = .{},
    spinner: Spinner = .{},
};

pub const Bar = struct {
    left: []const u8 = "[",
    filled: []const u8 = "#",
    empty: []const u8 = "-",
    right: []const u8 = "]",
    caps: ?struct {
        left_empty: []const u8,
        left_filled: []const u8,
        right_empty: []const u8,
        right_filled: []const u8,
    } = null,

    pub fn parse(text: []const u8) !Bar {
        if (std.mem.eql(u8, text, "ascii")) return .{};
        if (std.mem.eql(u8, text, "block")) return parse("█ ");
        if (std.mem.eql(u8, text, "fira")) return .{
            .left = "",
            .filled = "\u{ee04}",
            .empty = "\u{ee01}",
            .right = "",
            .caps = .{
                .left_empty = "\u{ee00}",
                .left_filled = "\u{ee03}",
                .right_empty = "\u{ee02}",
                .right_filled = "\u{ee05}",
            },
        };
        const count = validate(text) catch return error.InvalidBarStyle;
        if (count != 2 and count != 4) return error.InvalidBarStyle;
        var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
        const left = if (count == 4) iterator.nextCodepointSlice().? else "";
        const filled = iterator.nextCodepointSlice().?;
        const empty = iterator.nextCodepointSlice().?;
        const right = if (count == 4) iterator.nextCodepointSlice().? else "";
        return .{ .left = left, .filled = filled, .empty = empty, .right = right };
    }
};

pub const Spinner = struct {
    frames: []const u8 = "|/-\\",
    count: usize = 4,

    pub fn parse(text: []const u8) !Spinner {
        if (std.mem.eql(u8, text, "ascii")) return .{};
        if (std.mem.eql(u8, text, "dots")) return parse("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏");
        if (std.mem.eql(u8, text, "fira")) return parse("\u{ee06}\u{ee07}\u{ee08}\u{ee09}\u{ee0a}\u{ee0b}");
        const count = validate(text) catch return error.InvalidSpinnerStyle;
        if (count == 0 or count > 64) return error.InvalidSpinnerStyle;
        return .{ .frames = text, .count = count };
    }

    pub fn frame(self: Spinner, tick: usize) []const u8 {
        var iterator = std.unicode.Utf8View.initUnchecked(self.frames).iterator();
        for (0..tick % self.count) |_| _ = iterator.nextCodepointSlice();
        return iterator.nextCodepointSlice().?;
    }
};

fn validate(text: []const u8) !usize {
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    var count: usize = 0;
    while (iterator.nextCodepoint()) |codepoint| {
        if (!safe_codepoint(codepoint))
            return error.ControlCharacter;
        count += 1;
    }
    return count;
}

// These characters can change the order, width, or visibility of terminal
// text without occupying a normal cell. Do not accept them in style glyphs or
// pass them through from child-controlled progress labels.
pub fn safe_codepoint(cp: u21) bool {
    if (cp < 32 or (cp >= 127 and cp < 160)) return false;
    return switch (cp) {
        0x00ad, 0x034f, 0x0600...0x0605, 0x061c, 0x06dd, 0x070f => false,
        0x0890...0x0891, 0x08e2, 0x180e, 0x200b...0x200f => false,
        0x2028...0x202e, 0x2060...0x206f, 0x3164 => false,
        0xfe00...0xfe0f, 0xfeff, 0xfff9...0xfffb => false,
        0x110bd, 0x110cd, 0x13430...0x1343f => false,
        0x1bca0...0x1bca3, 0x1d173...0x1d17a => false,
        0xe0000...0xe007f, 0xe0100...0xe01ef => false,
        else => true,
    };
}

// Block, braille, and Fira Code progress characters occupy one terminal cell.
// Keep the renderer's conservative two-cell estimate for other non-ASCII codepoints.
pub fn cell_width(codepoint: u21) usize {
    return if (codepoint < 128 or
        (codepoint >= 0x2500 and codepoint <= 0x259f) or
        (codepoint >= 0x2800 and codepoint <= 0x28ff) or
        (codepoint >= 0xee00 and codepoint <= 0xee0b)) 1 else 2;
}

pub fn text_width(text: []const u8) usize {
    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
    var width: usize = 0;
    while (iterator.nextCodepoint()) |codepoint| width += cell_width(codepoint);
    return width;
}

test "bar presets and custom Unicode characters" {
    const block = try Bar.parse("block");
    try std.testing.expectEqualStrings("", block.left);
    try std.testing.expectEqualStrings("█", block.filled);
    try std.testing.expectEqualStrings(" ", block.empty);
    try std.testing.expectEqualStrings("", block.right);
    const custom = try Bar.parse("(▓░)");
    try std.testing.expectEqualStrings("(", custom.left);
    try std.testing.expectEqualStrings("▓", custom.filled);
    try std.testing.expectEqualStrings("░", custom.empty);
    try std.testing.expectEqualStrings(")", custom.right);
}

test "spinner frames use whole codepoints and wrap" {
    const spinner = try Spinner.parse("⠋⠙⠹");
    try std.testing.expectEqualStrings("⠋", spinner.frame(0));
    try std.testing.expectEqualStrings("⠹", spinner.frame(2));
    try std.testing.expectEqualStrings("⠋", spinner.frame(3));
    try std.testing.expectEqualStrings("⠙", (try Spinner.parse("dots")).frame(1));
    try std.testing.expectEqualStrings("x", (try Spinner.parse("x")).frame(100));
}

test "Fira Code spinner cycles through six single-cell frames" {
    const spinner = try Spinner.parse("fira");
    try std.testing.expectEqual(@as(usize, 6), spinner.count);
    for (0..12) |tick| {
        const frame = spinner.frame(tick);
        try std.testing.expectEqual(@as(u21, @intCast(0xee06 + tick % 6)), try std.unicode.utf8Decode(frame));
        try std.testing.expectEqual(@as(usize, 1), text_width(frame));
    }
    for (0xee00..0xee0c) |codepoint| {
        try std.testing.expectEqual(@as(usize, 1), cell_width(@intCast(codepoint)));
    }
}

test "styles reject invalid UTF-8, controls, and invalid lengths" {
    const long: [65]u8 = @splat('x');
    for ([_][]const u8{ "", "x", "abc", "abcde", "#\n", "\x1b-", "\xff-", "#\xc2\x85", "#\u{202e}", "#\u{200b}" }) |text| {
        try std.testing.expectError(error.InvalidBarStyle, Bar.parse(text));
    }
    for ([_][]const u8{ "", "\n", "\x1b[2J", "\xff", "\xc2\x85", "\u{2066}", "\u{fe0f}", &long }) |text| {
        try std.testing.expectError(error.InvalidSpinnerStyle, Spinner.parse(text));
    }
}
