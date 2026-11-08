const std = @import("std");
var received = std.atomic.Value(u32).init(0);
fn handler(sig: std.posix.SIG) callconv(.c) void {
    received.store(@backingInt(sig), .monotonic);
}
pub fn get() u32 {
    return received.load(.monotonic);
}
pub const Guard = struct {
    int: std.posix.Sigaction,
    term: std.posix.Sigaction,
    pub fn install() Guard {
        received.store(0, .monotonic);
        var g: Guard = undefined;
        const action: std.posix.Sigaction = .{ .handler = .{ .handler = handler }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(.INT, &action, &g.int);
        std.posix.sigaction(.TERM, &action, &g.term);
        return g;
    }
    pub fn restore(g: *const Guard) void {
        std.posix.sigaction(.INT, &g.int, null);
        std.posix.sigaction(.TERM, &g.term, null);
    }
};
