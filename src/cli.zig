const std = @import("std");
const style = @import("style.zig");
pub const Renderer = enum { bars, tree };
pub const ProgressStream = enum { auto, stdout, stderr };
pub const Report = struct {
    completed: u32,
    total: u32,
};
pub const Options = struct {
    name: []const u8 = "mock",
    progress: bool = true,
    guess: bool = false,
    mock: bool = false,
    help: bool = false,
    report: ?Report = null,
    renderer: Renderer = .bars,
    progress_stream: ProgressStream = .auto,
    style: style.Style = .{},
    argv: []const []const u8 = &.{},
};
pub const usage =
    \\Usage: zpg [options] <command> [args...]
    \\       zpg [options] --mock
    \\       zpg --report COMPLETED TOTAL [--name TEXT]
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
    \\  --progress-stream auto|stdout|stderr
    \\                              Progress terminal (default: auto, prefer stderr)
    \\  --guess                     Estimate file I/O progress (Linux)
    \\  --report COMPLETED TOTAL    Set parent progress counts (0 total: unknown)
    \\  --                        End options before a command starting with '-'
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
        if (std.mem.eql(u8, a, "--")) {
            o.argv = args[i + 1 ..];
            break;
        } else if (std.mem.eql(u8, a, "--name")) {
            i += 1;
            if (i == args.len) return error.MissingName;
            name = args[i];
        } else if (std.mem.eql(u8, a, "--no-progress")) {
            o.progress = false;
        } else if (std.mem.eql(u8, a, "--progress-stream")) {
            i += 1;
            if (i == args.len) return error.MissingProgressStream;
            o.progress_stream = std.meta.stringToEnum(ProgressStream, args[i]) orelse return error.InvalidProgressStream;
        } else if (std.mem.eql(u8, a, "--guess")) {
            o.guess = true;
        } else if (std.mem.eql(u8, a, "--report")) {
            if (o.report != null) return error.DuplicateReport;
            if (args.len - i < 3) return error.MissingReportCounts;
            o.report = .{
                .completed = try parseCount(args[i + 1]),
                .total = try parseCount(args[i + 2]),
            };
            i += 2;
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
    if (o.report != null and (o.mock or o.argv.len != 0)) return error.ReportWithCommand;
    if (o.guess and (o.mock or o.report != null)) return error.GuessRequiresCommand;
    if (!o.mock and !o.help and o.report == null and o.argv.len == 0) return error.MissingCommand;
    o.name = name orelse if (o.report != null) "" else if (o.argv.len != 0) std.fs.path.basename(o.argv[0]) else "mock";
    return o;
}

test "progress stream selection preserves child flags and no-progress" {
    try std.testing.expectEqual(ProgressStream.auto, (try parse(&.{"true"}, null)).progress_stream);
    for ([_]ProgressStream{ .auto, .stdout, .stderr }) |stream| {
        const o = try parse(&.{ "--progress-stream", @tagName(stream), "tool", "--progress-stream", "child-value" }, null);
        try std.testing.expectEqual(stream, o.progress_stream);
        try std.testing.expectEqualSlices([]const u8, &.{ "tool", "--progress-stream", "child-value" }, o.argv);
    }
    const disabled = try parse(&.{ "--no-progress", "--progress-stream", "stdout", "--mock" }, null);
    try std.testing.expect(!disabled.progress);
    try std.testing.expectEqual(ProgressStream.stdout, disabled.progress_stream);
    try std.testing.expectError(error.MissingProgressStream, parse(&.{"--progress-stream"}, null));
    try std.testing.expectError(error.InvalidProgressStream, parse(&.{ "--progress-stream", "bad", "true" }, null));
}

test "guess requires a command and preserves child options" {
    const o = try parse(&.{ "--guess", "--no-progress", "cp", "--guess" }, null);
    try std.testing.expect(o.guess and !o.progress);
    try std.testing.expectEqualSlices([]const u8, &.{ "cp", "--guess" }, o.argv);
    try std.testing.expect(!(try parse(&.{ "cp", "--guess" }, null)).guess);
    try std.testing.expectError(error.MissingCommand, parse(&.{"--guess"}, null));
    try std.testing.expectError(error.UnknownFlag, parse(&.{ "--guessa", "cp" }, null));
    try std.testing.expectError(error.GuessRequiresCommand, parse(&.{ "--guess", "--mock" }, null));
    try std.testing.expectError(error.GuessRequiresCommand, parse(&.{ "--guess", "--report", "1", "2" }, null));
}

fn parseCount(text: []const u8) !u32 {
    if (text.len == 0) return error.InvalidReportCount;
    for (text) |c| if (c < '0' or c > '9') return error.InvalidReportCount;
    const count = std.fmt.parseInt(u32, text, 10) catch return error.InvalidReportCount;
    // The progress protocol reserves this value for child process nodes.
    if (count == std.math.maxInt(u32)) return error.InvalidReportCount;
    return count;
}

test "report parses absolute counts and preserves child flags" {
    const o = try parse(&.{ "--report", "3", "10", "--name", "build" }, null);
    try std.testing.expectEqual(Report{ .completed = 3, .total = 10 }, o.report.?);
    try std.testing.expectEqualStrings("build", o.name);
    try std.testing.expectEqualStrings("", (try parse(&.{ "--report", "0", "0" }, null)).name);
    for ([_][]const u8{ "", "-1", "+1", "1.5", "0xff", "4_000", "4294967295", "4294967296" }) |value| {
        try std.testing.expectError(error.InvalidReportCount, parse(&.{ "--report", value, "10" }, null));
        try std.testing.expectError(error.InvalidReportCount, parse(&.{ "--report", "0", value }, null));
    }
    try std.testing.expectError(error.MissingReportCounts, parse(&.{ "--report", "1" }, null));
    try std.testing.expectError(error.ReportWithCommand, parse(&.{ "--report", "1", "2", "true" }, null));
    try std.testing.expectError(error.ReportWithCommand, parse(&.{ "--mock", "--report", "1", "2" }, null));
    try std.testing.expectError(error.DuplicateReport, parse(&.{ "--report", "1", "2", "--report", "2", "2" }, null));
    const child = try parse(&.{ "sh", "--report", "1", "2" }, null);
    try std.testing.expect(child.report == null);
    try std.testing.expectEqual(@as(usize, 4), child.argv.len);
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
    const dashed = try parse(&.{ "--", "-command", "--help" }, null);
    try std.testing.expectEqualSlices([]const u8, &.{ "-command", "--help" }, dashed.argv);
    try std.testing.expectError(error.MissingCommand, parse(&.{"--"}, null));
}
