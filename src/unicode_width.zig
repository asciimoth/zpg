const std = @import("std");
const tables = @import("unicode_width_tables.zig");

// Count terminal cells, not grapheme clusters. Ambiguous widths use one cell.
// Invalid and unassigned characters also use one cell unless listed as wide.
pub fn cell_width(codepoint: u21) usize {
    if (codepoint == 0) return 0;
    if (contains(&tables.zero_width, codepoint)) return 0;
    if (contains(&tables.wide, codepoint)) return 2;
    return 1;
}

fn contains(ranges: []const [2]u21, codepoint: u21) bool {
    var low: usize = 0;
    var high = ranges.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const range = ranges[middle];
        if (codepoint < range[0]) {
            high = middle;
        } else if (codepoint > range[1]) {
            low = middle + 1;
        } else return true;
    }
    return false;
}

test "terminal widths cover narrow, combining, wide and supplementary characters" {
    const cases = .{
        .{ 'a', 1 },
        .{ 'é', 1 },
        .{ 0x0301, 0 },
        .{ 0x200d, 0 },
        .{ 0xfe0f, 0 },
        .{ 0x1160, 0 },
        .{ 0xd7b0, 0 },
        .{ 0x00ad, 1 },
        .{ '界', 2 },
        .{ 0xff01, 2 },
        .{ 0x1f600, 2 },
        .{ 0x20000, 2 },
        .{ 0xe0100, 0 },
        .{ 0x00a1, 1 },
        .{ 0xfffd, 1 },
        .{ 0x10ffff, 1 },
        .{ 0x1fffff, 1 },
        .{ 0x7f, 1 },
    };
    inline for (cases) |case| {
        try std.testing.expectEqual(@as(usize, case[1]), cell_width(case[0]));
    }
}

test "width ranges are sorted, disjoint and searchable at every boundary" {
    for ([_][]const [2]u21{ &tables.zero_width, &tables.wide }) |ranges| {
        for (ranges, 0..) |range, index| {
            try std.testing.expect(range[0] <= range[1]);
            if (index > 0) try std.testing.expect(ranges[index - 1][1] + 1 < range[0]);
            try std.testing.expect(contains(ranges, range[0]));
            try std.testing.expect(contains(ranges, range[1]));
            if (range[0] > 0) try std.testing.expect(!contains(ranges, range[0] - 1));
            try std.testing.expect(!contains(ranges, range[1] + 1));
        }
    }
}
