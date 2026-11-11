const std = @import("std");
const cli = @import("cli.zig");
const output = @import("output.zig");
pub fn main(init: std.process.Init) void {
    const code = run(init) catch |err| blk: {
        output.print(init.io, "zpg: {s}\n", .{@errorName(err)}) catch {};
        break :blk @as(u8, 1);
    };
    if (code != 0) std.process.exit(code);
}
fn run(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const progress_enabled = !std.mem.eql(u8, init.environ_map.get("ZPG_NO_PROGRESS") orelse "", "1");
    if (args.len == 3 and std.mem.eql(u8, args[1], "--mock-worker"))
        return @import("mock.zig").runWorker(init.io, args[2], progress_enabled);
    var o = cli.parse(args[1..], init.environ_map.get("UNICODE_PROGRESS_BAR")) catch |err| {
        try output.print(init.io, "zpg: {s}\n{s}", .{ @errorName(err), cli.usage });
        return 2;
    };
    o.progress = o.progress and progress_enabled;
    if (o.help) {
        try output.print(init.io, "{s}", .{cli.usage});
        return 0;
    }
    if (o.report) |counts| {
        try @import("report.zig").send(init.io, counts, o.name);
        return 0;
    }
    if (o.mock) return @import("mock.zig").run(init.io, init.arena.allocator(), init.minimal.environ, o);
    if (o.tasks_file) |path| {
        const config = @import("tasks.zig").load(init.io, init.arena.allocator(), path, o.argv) catch |err| {
            try output.print(init.io, "zpg: tasks file \"{f}\": {s}\n", .{ @import("diagnostic.zig").escaped(path), @errorName(err) });
            return 2;
        };
        return @import("tasks_runner.zig").run(init.io, init.arena.allocator(), init.minimal.environ, o, config);
    }
    return @import("supervisor.zig").run(init.io, init.minimal.environ, o);
}
test {
    _ = cli;
    _ = output;
    _ = @import("progress.zig");
    _ = @import("supervisor.zig");
    _ = @import("tasks.zig");
    if (@import("builtin").os.tag == .linux) {
        try std.testing.expect(!@import("builtin").link_libc);
        _ = @import("spawn_linux.zig");
    }
}
