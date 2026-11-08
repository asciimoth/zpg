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
    \\  --bar-style ascii|block|CHARS
    \\                              Two characters: filled, empty; or four:
    \\                              left border, filled, empty, right border
    \\  --spinner-style ascii|dots|FRAMES
    \\                              One to 64 characters, one per frame
    \\  --no-progress               Disable progress display
    \\
    \\Styles default to ascii and apply only to the bars renderer.
    \\Quote custom characters that contain spaces or shell symbols.
    \\
;
pub fn parse(args: []const []const u8) !Options {
    var o: Options = .{};
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
test "custom styles only apply before the command and also work with mock" {
    const o = try parse(&.{ "--bar-style", "█ ", "--spinner-style", "dots", "tool", "--bar-style", "ascii", "--spinner-style", "ascii" });
    try std.testing.expectEqualStrings("█", o.style.bar.filled);
    try std.testing.expectEqualStrings("⠋", o.style.spinner.frame(0));
    try std.testing.expectEqualSlices([]const u8, &.{ "tool", "--bar-style", "ascii", "--spinner-style", "ascii" }, o.argv);
    const mock = try parse(&.{ "--mock", "--bar-style", "block", "--spinner-style", "ab" });
    try std.testing.expectEqualStrings("█", mock.style.bar.filled);
    try std.testing.expectEqualStrings("b", mock.style.spinner.frame(1));
    try std.testing.expectError(error.MissingBarStyle, parse(&.{"--bar-style"}));
    try std.testing.expectError(error.MissingSpinnerStyle, parse(&.{"--spinner-style"}));
    try std.testing.expectError(error.InvalidBarStyle, parse(&.{ "--bar-style", "bad", "true" }));
    try std.testing.expectError(error.InvalidSpinnerStyle, parse(&.{ "--spinner-style", "", "true" }));
}
test "renderer selection only applies before the command" {
    try std.testing.expectEqual(Renderer.bars, (try parse(&.{"true"})).renderer);
    const o = try parse(&.{ "--renderer", "tree", "tool", "--renderer", "bars" });
    try std.testing.expectEqual(Renderer.tree, o.renderer);
    try std.testing.expectEqualStrings("--renderer", o.argv[1]);
    try std.testing.expectEqual(@as(usize, 3), o.argv.len);
    try std.testing.expectError(error.MissingRenderer, parse(&.{"--renderer"}));
    try std.testing.expectError(error.InvalidRenderer, parse(&.{ "--renderer", "bad", "true" }));
}
test "leading flags and unchanged child arguments" {
    const o = try parse(&.{ "--name", "worker", "tool", "--help", "a b", "" });
    try std.testing.expectEqualStrings("worker", o.name);
    try std.testing.expectEqual(@as(usize, 4), o.argv.len);
    try std.testing.expectEqualStrings("--help", o.argv[1]);
    try std.testing.expectError(error.MockWithCommand, parse(&.{ "--mock", "tool" }));
    try std.testing.expectError(error.MissingCommand, parse(&.{}));
    try std.testing.expectError(error.UnknownFlag, parse(&.{"--bad"}));
    try std.testing.expectError(error.MissingName, parse(&.{"--name"}));
}
