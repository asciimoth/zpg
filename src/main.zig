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
    if (args.len == 3 and std.mem.eql(u8, args[1], "--mock-worker"))
        return @import("mock.zig").runWorker(init.io, args[2]);
    const o = cli.parse(args[1..], init.environ_map.get("UNICODE_PROGRESS_BAR")) catch |err| {
        try output.print(init.io, "zpg: {s}\n{s}", .{ @errorName(err), cli.usage });
        return 2;
    };
    if (o.help) {
        try output.print(init.io, "{s}", .{cli.usage});
        return 0;
    }
    if (o.mock) return @import("mock.zig").run(init.io, init.arena.allocator(), o);
    return @import("supervisor.zig").run(init.io, o);
}
test {
    _ = cli;
    _ = @import("progress.zig");
}
