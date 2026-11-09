const std = @import("std");
const builtin = @import("builtin");
const unicode_width = @import("unicode_width.zig");

// Inode numbers alone can collide on separate device filesystems.
pub fn same_terminal(first: std.posix.fd_t, second: std.posix.fd_t) bool {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var a: linux.Statx = undefined;
        var b: linux.Statx = undefined;
        if (linux.errno(linux.statx(first, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &a)) != .SUCCESS or
            linux.errno(linux.statx(second, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &b)) != .SUCCESS) return false;
        return a.mask.TYPE and b.mask.TYPE and
            linux.S.ISCHR(a.mode) and linux.S.ISCHR(b.mode) and
            a.rdev_major == b.rdev_major and a.rdev_minor == b.rdev_minor;
    }
    var a: std.c.Stat = undefined;
    var b: std.c.Stat = undefined;
    return std.c.fstat(first, &a) == 0 and std.c.fstat(second, &b) == 0 and
        std.c.S.ISCHR(a.mode) and std.c.S.ISCHR(b.mode) and a.rdev == b.rdev;
}

// Track only the cursor and the last occupied row. Output bytes are never
// changed. This is not a screen buffer or a full terminal emulator.
pub const Cursor = struct {
    row: usize = 0,
    column: usize = 0,
    bottom: usize = 0,
    cols: usize = 80,
    rows: usize = 25,
    // A lower bound: no cursor-position query or terminal input is required.
    space_below: usize = 0,
    newline_resets_column: bool = true,
    saved: ?struct { row: usize, column: usize, space_below: usize } = null,
    saving: bool = false,
    state: enum { text, escape, escape_intermediate, csi, string, string_escape } = .text,
    osc: bool = false,
    parameter: usize = 0,
    simple: bool = true,
    utf8: [4]u8 = undefined,
    utf8_len: usize = 0,
    utf8_needed: usize = 0,

    pub fn ready(self: Cursor) bool {
        // Do not insert a display inside a control sequence or UTF-8 character.
        // A saved cursor uses screen coordinates, so do not scroll it either.
        return self.state == .text and self.utf8_len == 0 and !self.saving and self.column < self.cols;
    }

    pub fn below(self: Cursor) usize {
        return self.bottom -| self.row;
    }

    fn down(self: *Cursor, count: usize) void {
        self.space_below -|= count;
        self.row +|= count;
        self.bottom = @max(self.bottom, self.row);
    }

    fn up(self: *Cursor, count: usize) void {
        self.space_below = @min(self.rows - 1, self.space_below +| count);
        self.row -|= count;
    }

    fn cancel_wrap(self: *Cursor) void {
        // column == cols represents the terminal's delayed-wrap flag, not
        // an extra cell. Cursor movement starts at the last real cell.
        self.column = @min(self.column, self.cols - 1);
    }

    pub fn resize(self: *Cursor, cols: usize, rows: usize) void {
        const new_cols = @max(1, cols);
        const new_rows = @max(1, rows);
        if (self.cols != new_cols or self.rows != new_rows) {
            self.space_below = 0;
            if (self.saved) |*saved| saved.space_below = 0;
        }
        self.cols = new_cols;
        self.rows = new_rows;
        self.column = @min(self.column, self.cols);
    }

    pub fn can_draw(self: Cursor, lines: usize) bool {
        const distance = self.below() +| lines;
        return self.ready() and distance < self.rows and
            (self.saved == null or distance <= self.space_below);
    }

    pub fn reserved(self: *Cursor, distance: usize) void {
        self.space_below = @max(self.space_below, distance);
    }

    fn save(self: *Cursor) void {
        self.saved = .{ .row = self.row, .column = self.column, .space_below = self.space_below };
        self.saving = true;
    }

    fn restore(self: *Cursor) void {
        if (self.saved) |saved| {
            self.row = saved.row;
            self.column = saved.column;
            self.space_below = saved.space_below;
        }
        self.saving = false;
    }

    fn cells(self: *Cursor, width: usize) void {
        if (width == 0) return;
        if (self.column + width > self.cols) {
            self.down(1);
            self.column = 0;
        }
        self.column += width;
    }

    fn csi(self: *Cursor, command: u8) void {
        if (!self.simple) return;
        const count = @max(1, self.parameter);
        if (std.mem.indexOfScalar(u8, "ABCDEFG", command) != null) self.cancel_wrap();
        switch (command) {
            'A' => self.up(count),
            'B' => self.down(count),
            'C' => self.column = @min(self.cols - 1, self.column +| count),
            'D' => self.column -|= count,
            'E' => {
                self.down(count);
                self.column = 0;
            },
            'F' => {
                self.up(count);
                self.column = 0;
            },
            'G' => self.column = @min(self.cols - 1, count - 1),
            'J' => {
                if (self.parameter == 0 or self.parameter == 2) {
                    self.bottom = self.row;
                    self.cancel_wrap();
                }
            },
            'K' => if (self.parameter == 0) {
                self.cancel_wrap();
            },
            's' => self.save(),
            'u' => self.restore(),
            else => {}, // SGR and line erasure do not move the cursor.
        }
    }

    fn control(self: *Cursor, byte: u8) void {
        switch (byte) {
            '\r' => self.column = 0,
            '\n', 11, 12 => {
                self.cancel_wrap();
                self.down(1);
                if (byte == '\n' and self.newline_resets_column) self.column = 0;
            },
            8 => {
                self.cancel_wrap();
                self.column -|= 1;
            },
            '\t' => {
                self.cancel_wrap();
                self.column = @min(self.cols - 1, (self.column / 8 + 1) * 8);
            },
            else => {},
        }
    }

    pub fn feed(self: *Cursor, bytes: []const u8) void {
        for (bytes) |byte| {
            if (self.utf8_len != 0) {
                if (byte & 0xc0 == 0x80) {
                    self.utf8[self.utf8_len] = byte;
                    self.utf8_len += 1;
                    if (self.utf8_len == self.utf8_needed) {
                        const cp = std.unicode.utf8Decode(self.utf8[0..self.utf8_len]) catch 0xfffd;
                        self.cells(unicode_width.cell_width(cp));
                        self.utf8_len = 0;
                    }
                    continue;
                }
                self.utf8_len = 0;
                self.cells(1);
            }
            if (byte == 0x18 or byte == 0x1a) {
                self.state = .text;
                continue;
            }
            if (self.state == .string or self.state == .string_escape) {
                if ((self.osc and byte == 7) or (self.state == .string_escape and byte == '\\')) {
                    self.state = .text;
                } else self.state = if (byte == 27) .string_escape else .string;
                continue;
            }
            if (byte == 27) {
                self.state = .escape;
                continue;
            }
            if (byte < 32) {
                // C0 controls also execute inside an unfinished CSI sequence.
                self.control(byte);
                continue;
            }
            if (byte == 127) continue;
            switch (self.state) {
                .escape => {
                    self.state = .text;
                    switch (byte) {
                        '[' => {
                            self.state = .csi;
                            self.parameter = 0;
                            self.simple = true;
                        },
                        ']', 'P', '^', '_', 'X' => {
                            self.state = .string;
                            self.osc = byte == ']';
                        },
                        '7' => self.save(),
                        '8' => self.restore(),
                        'D', 'E' => {
                            self.cancel_wrap();
                            self.down(1);
                            if (byte == 'E') self.column = 0;
                        },
                        'M' => {
                            self.cancel_wrap();
                            // At the top edge RI inserts a blank row instead
                            // of moving up. Retain the displaced child rows.
                            if (self.row == 0 or self.space_below == self.rows - 1) {
                                self.bottom +|= 1;
                            } else self.up(1);
                        },
                        0x20...0x2f => self.state = .escape_intermediate,
                        else => {},
                    }
                    continue;
                },
                .escape_intermediate => {
                    if (byte >= 0x30 and byte <= 0x7e) self.state = .text;
                    continue;
                },
                .csi => {
                    if (byte >= 0x40 and byte <= 0x7e) {
                        self.csi(byte);
                        self.state = .text;
                    } else if (byte >= '0' and byte <= '9') {
                        self.parameter = @min(65535, self.parameter * 10 + byte - '0');
                    } else self.simple = false;
                    continue;
                },
                .string, .string_escape => unreachable,
                .text => {},
            }
            if (byte < 127) {
                self.cells(1);
            } else {
                self.utf8_needed = std.unicode.utf8ByteSequenceLength(byte) catch 1;
                if (self.utf8_needed == 1) self.cells(1) else {
                    self.utf8[0] = byte;
                    self.utf8_len = 1;
                }
            }
        }
    }
};

test "carriage return, backspace, tabs and relative cursor movement" {
    var cursor: Cursor = .{};
    cursor.feed("long status\rOK");
    try std.testing.expectEqual(@as(usize, 2), cursor.column);
    cursor.feed("\x08\tX\nfirst\nsecond\x1b[2A\x1b[3G");
    try std.testing.expectEqual(@as(usize, 2), cursor.below());
    try std.testing.expectEqual(@as(usize, 2), cursor.column);
    cursor.feed("\x1b[B\x1b[2C\x1b[D\x1b[K");
    try std.testing.expectEqual(@as(usize, 1), cursor.below());
    try std.testing.expectEqual(@as(usize, 3), cursor.column);
    cursor.feed("\x1b[J");
    try std.testing.expectEqual(@as(usize, 0), cursor.below());
}

test "split controls and saved cursor defer drawing" {
    var cursor: Cursor = .{};
    for ([_][]const u8{ "\x1b[31", "mhello\x1b", "7\nfooter\x1b[", "1A\x1b" }) |bytes| {
        cursor.feed(bytes);
        try std.testing.expect(!cursor.ready());
    }
    cursor.feed("8");
    try std.testing.expect(cursor.ready());
    try std.testing.expectEqual(@as(usize, 5), cursor.column);
    try std.testing.expectEqual(@as(usize, 1), cursor.below());
    cursor.feed("\x1b]title");
    try std.testing.expect(!cursor.ready());
    cursor.feed("\x1b\\");
    try std.testing.expect(cursor.ready());
    cursor.feed("\x1b[s\n\x1b[u");
    try std.testing.expectEqual(@as(usize, 5), cursor.column);
}

test "UTF-8 and delayed line wrapping" {
    var cursor: Cursor = .{ .cols = 4 };
    cursor.feed("ab\xe7");
    try std.testing.expect(!cursor.ready());
    cursor.feed("\x95\x8c");
    try std.testing.expectEqual(@as(usize, 4), cursor.column);
    try std.testing.expect(!cursor.ready());
    cursor.feed("X");
    try std.testing.expectEqual(@as(usize, 1), cursor.row);
    try std.testing.expectEqual(@as(usize, 1), cursor.column);
}

test "narrow and combining Unicode characters preserve the column" {
    var cursor: Cursor = .{};
    cursor.feed("café e\u{0301}");
    try std.testing.expectEqual(@as(usize, 6), cursor.column);
    try std.testing.expect(cursor.ready());
}

test "right margin controls operate on the last cell and cancel delayed wrap" {
    const cases = .{
        .{ "\x08", 0, 2 },    .{ "\x1b[D", 0, 2 },
        .{ "\x1b[0D", 0, 2 }, .{ "\x1b[2D", 0, 1 },
        .{ "\x1b[C", 0, 3 },  .{ "\x1b[A", 0, 3 },
        .{ "\x1b[B", 1, 3 },  .{ "\x1b[E", 1, 0 },
        .{ "\x1b[F", 0, 0 },  .{ "\x1b[G", 0, 0 },
        .{ "\x1b[K", 0, 3 },  .{ "\x1b[J", 0, 3 },
        .{ "\n", 1, 3 },      .{ "\x0b", 1, 3 },
        .{ "\x0c", 1, 3 },    .{ "\x1bD", 1, 3 },
        .{ "\x1bE", 1, 0 },   .{ "\r", 0, 0 },
        .{ "\t", 0, 3 },
    };
    inline for (cases) |case| {
        var cursor: Cursor = .{ .cols = 4, .newline_resets_column = false };
        cursor.feed("abcd");
        try std.testing.expect(!cursor.ready());
        cursor.feed(case[0]);
        try std.testing.expectEqual(@as(usize, case[1]), cursor.row);
        try std.testing.expectEqual(@as(usize, case[2]), cursor.column);
        try std.testing.expect(cursor.ready());
    }
}

test "attributes and saved wrap do not consume a pending line wrap" {
    for ([_][]const u8{ "\x1b[31m", "\x1b[1K", "\x1b[2K", "\x1b7\x1b8", "\x1b[s\x1b[u" }) |sequence| {
        var cursor: Cursor = .{ .cols = 4 };
        cursor.feed("abcd");
        cursor.feed(sequence);
        try std.testing.expectEqual(@as(usize, 4), cursor.column);
        try std.testing.expect(!cursor.ready());
        cursor.feed("Z");
        try std.testing.expectEqual(@as(usize, 1), cursor.row);
        try std.testing.expectEqual(@as(usize, 1), cursor.column);
    }
}

test "LF follows output conversion while VT FF and IND retain the column" {
    for ([_]bool{ false, true }) |conversion| {
        for ([_][]const u8{ "\n", "\x0b", "\x0c", "\x1bD" }) |sequence| {
            var cursor: Cursor = .{ .newline_resets_column = conversion };
            cursor.feed("abc");
            cursor.feed(sequence);
            try std.testing.expectEqual(@as(usize, 1), cursor.row);
            try std.testing.expectEqual(@as(usize, if (conversion and sequence[0] == '\n') 0 else 3), cursor.column);
        }
    }
}

test "erasure retains footer extent unless rows below the cursor are erased" {
    for ([_][]const u8{ "\x1b[K", "\x1b[1K", "\x1b[2K", "\x1b[1J", "\x1b[31m" }) |sequence| {
        var cursor: Cursor = .{};
        cursor.feed("first\nsecond\nthird\x1b[2A");
        cursor.feed(sequence);
        try std.testing.expectEqual(@as(usize, 2), cursor.below());
    }
    for ([_][]const u8{ "\x1b[J", "\x1b[0J", "\x1b[2J" }) |sequence| {
        var cursor: Cursor = .{};
        cursor.feed("first\nsecond\nthird\x1b[2A");
        cursor.feed(sequence);
        try std.testing.expectEqual(@as(usize, 0), cursor.below());
    }
}

test "control strings handle BEL ST cancellation and repeated ESC correctly" {
    for ([_][]const u8{ "\x1b]title\x07", "\x1b]title\x1b\\", "\x1b]title\x1b\x07", "\x1b]title\x1b\x1b\\" }) |sequence| {
        var cursor: Cursor = .{};
        cursor.feed(sequence);
        try std.testing.expect(cursor.ready());
        try std.testing.expectEqual(@as(usize, 0), cursor.column);
    }
    for ([_][]const u8{ "\x1bP", "\x1b^", "\x1b_", "\x1bX" }) |introducer| {
        var cursor: Cursor = .{};
        cursor.feed(introducer);
        cursor.feed("payload\x07");
        try std.testing.expect(!cursor.ready());
        cursor.feed("more\x1b\\X");
        try std.testing.expect(cursor.ready());
        try std.testing.expectEqual(@as(usize, 1), cursor.column);
    }
    for ([_][]const u8{ "\x1b[123", "\x1b]title", "\x1bPdata", "\x1b(" }) |prefix| {
        for ([_]u8{ 0x18, 0x1a }) |cancel| {
            var cursor: Cursor = .{};
            cursor.feed(prefix);
            cursor.feed(&.{cancel});
            cursor.feed("XY");
            try std.testing.expect(cursor.ready());
            try std.testing.expectEqual(@as(usize, 2), cursor.column);
        }
    }
}

test "C0 controls execute within CSI and ESC restarts an incomplete sequence" {
    var cursor: Cursor = .{};
    cursor.feed("abc\x1b[\r2C");
    try std.testing.expectEqual(@as(usize, 2), cursor.column);
    cursor.feed("\x1b[99\x1b[3G");
    try std.testing.expectEqual(@as(usize, 2), cursor.column);
    cursor.feed("\x1b[\n2C");
    try std.testing.expectEqual(@as(usize, 1), cursor.row);
    try std.testing.expectEqual(@as(usize, 2), cursor.column);
    cursor.feed("\x1b(BX");
    try std.testing.expectEqual(@as(usize, 3), cursor.column);
    try std.testing.expect(cursor.ready());
}

test "saved cursor can be restored repeatedly without permitting overlay scroll" {
    var cursor: Cursor = .{ .rows = 8 };
    cursor.reserved(3);
    cursor.feed("abc\x1b7\nfooter\x1b8");
    try std.testing.expect(cursor.can_draw(2));
    try std.testing.expect(!cursor.can_draw(3));
    cursor.feed("X\x1b8");
    try std.testing.expectEqual(@as(usize, 3), cursor.column);
    try std.testing.expect(cursor.can_draw(2));
    cursor.resize(80, 7);
    try std.testing.expect(!cursor.can_draw(1));
    cursor.feed("\x1b8");
    try std.testing.expect(!cursor.can_draw(1));
}

test "zero sized terminals and large movement parameters remain bounded" {
    var cursor: Cursor = .{};
    cursor.resize(0, 0);
    cursor.feed("\t\x1b[9999999999999999999999999C");
    try std.testing.expectEqual(@as(usize, 0), cursor.column);
    try std.testing.expect(!cursor.can_draw(1));
    cursor.resize(20, 8);
    cursor.feed("\x1b[9999999999999999999999999A");
    try std.testing.expectEqual(@as(usize, 0), cursor.row);
    try std.testing.expectEqual(@as(usize, 7), cursor.space_below);
    cursor.feed("\x1b[9999999999999999999999999B");
    try std.testing.expectEqual(@as(usize, 0), cursor.space_below);
}

fn expect_same_cursor(expected: Cursor, actual: Cursor) !void {
    try std.testing.expectEqual(expected.row, actual.row);
    try std.testing.expectEqual(expected.column, actual.column);
    try std.testing.expectEqual(expected.bottom, actual.bottom);
    try std.testing.expectEqual(expected.space_below, actual.space_below);
    try std.testing.expectEqualDeep(expected.saved, actual.saved);
    try std.testing.expectEqual(expected.saving, actual.saving);
    try std.testing.expectEqual(expected.state, actual.state);
    try std.testing.expectEqual(expected.parameter, actual.parameter);
    try std.testing.expectEqual(expected.simple, actual.simple);
    try std.testing.expectEqual(expected.osc, actual.osc);
    try std.testing.expectEqual(expected.utf8_len, actual.utf8_len);
    try std.testing.expectEqualSlices(u8, expected.utf8[0..expected.utf8_len], actual.utf8[0..actual.utf8_len]);
    try std.testing.expectEqual(expected.ready(), actual.ready());
}

test "every byte boundary preserves parser state including unfinished sequences" {
    const sequences = [_][]const u8{
        "long status\rOK\x08\tX\n",
        "one\nsecond\nthird\x1b[2A\x1b[2C\x1b[0J",
        "\x1b[31;1mred\x1b[0m\x1b7\nfooter\x1b8",
        "\x1b[s\nfooter\x1b[u\x1b[u",
        "\x1b]0;title\x1b\\x\x1bPdata\x07\x1b\\",
        "\x1b[12\x18X\x1b[9\x1b[3G",
        "\x1b(BC0\x1b[\r2CX",
        "wide: 界 café e\u{0301}",
        "\xff\xc0\xe7X\xf0\x9f",
        "\x1b",
        "\x1b[",
        "\x1b[123",
        "\x1b]unterminated\x1b",
    };
    for (sequences) |sequence| {
        for (0..sequence.len + 1) |end| {
            var expected: Cursor = .{};
            expected.feed(sequence[0..end]);
            for (0..end + 1) |split| {
                var actual: Cursor = .{};
                actual.feed(sequence[0..split]);
                actual.feed(sequence[split..end]);
                try expect_same_cursor(expected, actual);
            }
            var bytes: Cursor = .{};
            for (sequence[0..end]) |byte| bytes.feed(&.{byte});
            try expect_same_cursor(expected, bytes);
        }
    }
}

test "random byte streams keep parser memory and drawing bounds valid" {
    var prng = std.Random.DefaultPrng.init(0x7a70672d63757273);
    const random = prng.random();
    for (0..64) |_| {
        var cursor: Cursor = .{};
        cursor.resize(1 + random.uintLessThan(usize, 120), 1 + random.uintLessThan(usize, 40));
        for (0..4096) |_| {
            cursor.feed(&.{random.int(u8)});
            try std.testing.expect(cursor.utf8_len < cursor.utf8.len);
            try std.testing.expect(cursor.parameter <= 65535);
            try std.testing.expect(cursor.space_below < cursor.rows);
            if (cursor.can_draw(1)) {
                try std.testing.expect(cursor.ready());
                try std.testing.expect(cursor.below() + 1 < cursor.rows);
            }
        }
    }
}

test "reverse index at the top retains the displaced child row" {
    var cursor: Cursor = .{ .rows = 8 };
    cursor.feed("first\x1bMsecond");
    try std.testing.expectEqual(@as(usize, 1), cursor.below());
    cursor.feed("\x1b[B\x1bM");
    try std.testing.expectEqual(@as(usize, 1), cursor.below());
}
