const std = @import("std");
pub const Options = struct {
    name: []const u8 = "mock",
    progress: bool = true,
    mock: bool = false,
    help: bool = false,
    argv: []const []const u8 = &.{},
};
pub const usage = "Usage: zpg [--name TEXT] [--no-progress] <command> [args...]\n       zpg [--no-progress] --mock\n       zpg --help\n";
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
