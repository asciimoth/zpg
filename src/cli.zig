const std = @import("std");
const style = @import("style.zig");
pub const Renderer = enum { bars, tree };
pub const Options = struct {
    name: []const u8 = "mock",
    progress: bool = true,
    mock: bool = false,
    help: bool = false,
    renderer: Renderer = .bars,
    style: style.Style = .{},
    argv: []const []const u8 = &.{},
};
pub const usage =
    \\Usage: zpg [options] <command> [args...]
    \\       zpg [options] --mock
    \\       zpg --help
    \\
    \\Options:
    \\  --name TEXT                 Progress node label
    \\  --renderer bars|tree        Renderer (default: bars)
    \\  --bar-style ascii|block|fira|CHARS
    \\                              Two characters: filled, empty; or four:
    \\                              left border, filled, empty, right border
    \\  --spinner-style ascii|dots|fira|FRAMES
    \\                              One to 64 characters, one per frame
    \\  --no-progress               Disable progress display
    \\
    \\Styles apply only to the bars renderer and default to ascii.
    \\UNICODE_PROGRESS_BAR=true defaults both styles to fira (Fira Code).
    \\CLI style options override these defaults separately.
    \\Quote custom characters that contain spaces or shell symbols.
    \\
;
pub fn parse(args: []const []const u8, unicode_progress_bar: ?[]const u8) !Options {
    var o: Options = .{};
    if (std.mem.eql(u8, unicode_progress_bar orelse "", "true")) {
        o.style = .{
            .bar = try style.Bar.parse("fira"),
            .spinner = try style.Spinner.parse("fira"),
        };
    }
    var name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--name")) {
            i += 1;
            if (i == args.len) return error.MissingName;
            name = args[i];
        } else if (std.mem.eql(u8, a, "--no-progress")) {
            o.progress = false;
        } else if (std.mem.eql(u8, a, "--renderer")) {
            i += 1;
            if (i == args.len) return error.MissingRenderer;
            o.renderer = std.meta.stringToEnum(Renderer, args[i]) orelse return error.InvalidRenderer;
        } else if (std.mem.eql(u8, a, "--bar-style")) {
            i += 1;
            if (i == args.len) return error.MissingBarStyle;
            o.style.bar = try style.Bar.parse(args[i]);
        } else if (std.mem.eql(u8, a, "--spinner-style")) {
            i += 1;
            if (i == args.len) return error.MissingSpinnerStyle;
            o.style.spinner = try style.Spinner.parse(args[i]);
        } else if (std.mem.eql(u8, a, "--mock")) {
            o.mock = true;
        } else if (std.mem.eql(u8, a, "--help")) {
            o.help = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.UnknownFlag;
        } else {
            o.argv = args[i..];
            break;
        }
    }
    if (o.mock and o.argv.len != 0) return error.MockWithCommand;
    if (!o.mock and !o.help and o.argv.len == 0) return error.MissingCommand;
    o.name = name orelse if (o.argv.len != 0) std.fs.path.basename(o.argv[0]) else "mock";
    return o;
}
test "environment selects Fira Code defaults and flags override each style" {
    const defaults = try parse(&.{"--mock"}, "true");
    try std.testing.expectEqualStrings("\u{ee04}", defaults.style.bar.filled);
    try std.testing.expectEqualStrings("\u{ee06}", defaults.style.spinner.frame(0));
    for ([_]?[]const u8{ null, "", "false", "1", "TRUE" }) |value| {
        const o = try parse(&.{"true"}, value);
        try std.testing.expectEqualStrings("#", o.style.bar.filled);
        try std.testing.expectEqualStrings("|", o.style.spinner.frame(0));
    }
    const bar = try parse(&.{ "--bar-style", "ascii", "true" }, "true");
    try std.testing.expectEqualStrings("#", bar.style.bar.filled);
    try std.testing.expectEqualStrings("\u{ee06}", bar.style.spinner.frame(0));
    const spinner = try parse(&.{ "--spinner-style", "dots", "true" }, "true");
    try std.testing.expectEqualStrings("\u{ee04}", spinner.style.bar.filled);
    try std.testing.expectEqualStrings("⠋", spinner.style.spinner.frame(0));
    const both = try parse(&.{ "--bar-style", "block", "--spinner-style", "ascii", "true" }, "true");
    try std.testing.expectEqualStrings("█", both.style.bar.filled);
    try std.testing.expectEqualStrings("|", both.style.spinner.frame(0));
    const explicit = try parse(&.{ "--bar-style", "fira", "--spinner-style", "fira", "true" }, "false");
    try std.testing.expectEqualStrings("\u{ee04}", explicit.style.bar.filled);
    try std.testing.expectEqualStrings("\u{ee06}", explicit.style.spinner.frame(0));
}

test "custom styles only apply before the command and also work with mock" {
    const o = try parse(&.{ "--bar-style", "█ ", "--spinner-style", "dots", "tool", "--bar-style", "ascii", "--spinner-style", "ascii" }, null);
    try std.testing.expectEqualStrings("█", o.style.bar.filled);
    try std.testing.expectEqualStrings("⠋", o.style.spinner.frame(0));
    try std.testing.expectEqualSlices([]const u8, &.{ "tool", "--bar-style", "ascii", "--spinner-style", "ascii" }, o.argv);
    const mock = try parse(&.{ "--mock", "--bar-style", "block", "--spinner-style", "ab" }, null);
    try std.testing.expectEqualStrings("█", mock.style.bar.filled);
    try std.testing.expectEqualStrings("b", mock.style.spinner.frame(1));
    try std.testing.expectError(error.MissingBarStyle, parse(&.{"--bar-style"}, null));
    try std.testing.expectError(error.MissingSpinnerStyle, parse(&.{"--spinner-style"}, null));
    try std.testing.expectError(error.InvalidBarStyle, parse(&.{ "--bar-style", "bad", "true" }, null));
    try std.testing.expectError(error.InvalidSpinnerStyle, parse(&.{ "--spinner-style", "", "true" }, null));
}
test "renderer selection only applies before the command" {
    try std.testing.expectEqual(Renderer.bars, (try parse(&.{"true"}, null)).renderer);
    const o = try parse(&.{ "--renderer", "tree", "tool", "--renderer", "bars" }, null);
    try std.testing.expectEqual(Renderer.tree, o.renderer);
    try std.testing.expectEqualStrings("--renderer", o.argv[1]);
    try std.testing.expectEqual(@as(usize, 3), o.argv.len);
    try std.testing.expectError(error.MissingRenderer, parse(&.{"--renderer"}, null));
    try std.testing.expectError(error.InvalidRenderer, parse(&.{ "--renderer", "bad", "true" }, null));
}
test "leading flags and unchanged child arguments" {
    const o = try parse(&.{ "--name", "worker", "tool", "--help", "a b", "" }, null);
    try std.testing.expectEqualStrings("worker", o.name);
    try std.testing.expectEqual(@as(usize, 4), o.argv.len);
    try std.testing.expectEqualStrings("--help", o.argv[1]);
    try std.testing.expectError(error.MockWithCommand, parse(&.{ "--mock", "tool" }, null));
    try std.testing.expectError(error.MissingCommand, parse(&.{}, null));
    try std.testing.expectError(error.UnknownFlag, parse(&.{"--bad"}, null));
    try std.testing.expectError(error.MissingName, parse(&.{"--name"}, null));
}
