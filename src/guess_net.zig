// Linux SOCK_DIAG supplies TCP counters without opening the child's sockets,
// tracing syscalls, or reading network payloads. Restrict results to socket
// inodes found in the supervised process group. Other network namespaces and
// protocols are deliberately left unknown.
const std = @import("std");
const linux = std.os.linux;
const endian = @import("builtin").cpu.arch.endian();

pub const limit = 256;
pub const Counters = struct {
    inode: u64,
    cookie: u64,
    received: u64,
    sent: u64,
};
const Delta = struct { received: u64 = 0, sent: u64 = 0 };
pub const Snapshot = struct {
    items: [limit]Counters = undefined,
    len: usize = 0,
    partial: bool = false,

    pub fn slice(self: *const Snapshot) []const Counters {
        return self.items[0..self.len];
    }

    pub fn delta(self: *const Snapshot, previous: *const Snapshot) Delta {
        var result: Delta = .{};
        for (self.slice()) |item| {
            for (previous.slice()) |old| {
                if (item.inode != old.inode or item.cookie != old.cookie) continue;
                result.received +|= item.received -| old.received;
                result.sent +|= item.sent -| old.sent;
                break;
            }
        }
        return result;
    }
};

pub fn sample(io: std.Io, inodes: []const u64) !Snapshot {
    return sample_with(io, inodes, dump);
}

fn sample_with(io: std.Io, inodes: []const u64, comptime dump_fn: anytype) !Snapshot {
    var result: Snapshot = .{};
    if (inodes.len == 0) return result;
    for ([_]u8{ linux.AF.INET, linux.AF.INET6 }) |family| {
        const before = result.len;
        dump_fn(io, family, inodes, &result) catch |err| {
            if (err == error.Canceled) return err;
            result.len = before;
            result.partial = true;
            // Missing kernel support, permissions, races and large socket
            // tables must never affect the supervised command.
        };
    }
    return result;
}

fn dump(io: std.Io, family: u8, inodes: []const u64, result: *Snapshot) !void {
    const rc = linux.socket(linux.AF.NETLINK, linux.SOCK.RAW | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, linux.NETLINK.SOCK_DIAG);
    if (linux.errno(rc) != .SUCCESS) return error.Unavailable;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    // nlmsghdr + inet_diag_req_v2. Request INET_DIAG_INFO for all TCP states.
    var request: [72]u8 = @splat(0);
    put(u32, &request, 0, request.len);
    put(u16, &request, 4, 20); // SOCK_DIAG_BY_FAMILY
    put(u16, &request, 6, 0x301); // REQUEST | DUMP
    put(u32, &request, 8, 1);
    request[16] = family;
    request[17] = linux.IPPROTO.TCP;
    request[18] = 2; // 1 << (INET_DIAG_INFO - 1)
    put(u32, &request, 20, std.math.maxInt(u32));
    const address: linux.sockaddr.nl = .{ .pid = 0, .groups = 0 };
    if (linux.errno(linux.sendto(fd, &request, request.len, 0, @ptrCast(&address), @sizeOf(@TypeOf(address)))) != .SUCCESS)
        return error.Unavailable;

    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(40));
    var buffer: [32768]u8 = undefined;
    // Bound both time and data on machines with large socket tables.
    for (0..128) |_| {
        try io.checkCancel();
        if (std.Io.Clock.awake.now(io).compare(.gte, deadline)) return error.Unavailable;
        const n = linux.recvfrom(fd, &buffer, buffer.len, linux.MSG.TRUNC, null, null);
        switch (linux.errno(n)) {
            .SUCCESS => {
                if (n == 0 or n > buffer.len) return error.Unavailable;
                if (try parse(buffer[0..n], inodes, result)) return;
            },
            .AGAIN => try io.sleep(.fromMilliseconds(1), .awake),
            .INTR => continue,
            else => return error.Unavailable,
        }
    }
    return error.Unavailable;
}

fn get(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], endian);
}

fn put(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, endian);
}

// Netlink messages and attributes have 4-byte alignment, but tcp_info has
// 64-bit fields at potentially unaligned addresses. Decode bytes explicitly.
fn parse(bytes: []const u8, inodes: []const u64, result: *Snapshot) !bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (bytes.len - offset < 16) return error.InvalidMessage;
        const message = bytes[offset..];
        const len = get(u32, message, 0);
        if (len < 16 or len > message.len) return error.InvalidMessage;
        if (get(u32, message, 8) != 1) return error.InvalidMessage;
        const kind = get(u16, message, 4);
        if (kind == 2 or get(u16, message, 6) & 0x10 != 0) return error.Unavailable;
        if (kind == 3) {
            if (len >= 20 and get(i32, message, 16) != 0) return error.Unavailable;
            return true; // NLMSG_DONE
        }
        if (kind == 20) try parse_socket(message[16..len], inodes, result);
        offset += std.mem.alignForward(usize, len, 4);
    }
    return false;
}

fn parse_socket(bytes: []const u8, inodes: []const u64, result: *Snapshot) !void {
    if (bytes.len < 72) return error.InvalidMessage;
    const inode = get(u32, bytes, 68);
    if (inode == 0 or std.mem.indexOfScalar(u64, inodes, inode) == null) return;
    const cookie = get(u64, bytes, 44);
    for (result.slice()) |previous| if (previous.inode == inode and previous.cookie == cookie) return;
    var offset: usize = 72;
    while (offset < bytes.len) {
        if (bytes.len - offset < 4) return error.InvalidMessage;
        const attribute = bytes[offset..];
        const len = get(u16, attribute, 0);
        if (len < 4 or len > attribute.len) return error.InvalidMessage;
        if (get(u16, attribute, 2) == 2 and len >= 4 + 208 and result.len < limit) {
            // Linux UAPI tcp_info: bytes_received at 128, bytes_sent at 200.
            // Older kernels with shorter tcp_info have no usable counters.
            result.items[result.len] = .{
                .inode = inode,
                .cookie = cookie,
                .received = get(u64, attribute, 4 + 128),
                .sent = get(u64, attribute, 4 + 200),
            };
            result.len += 1;
            return;
        }
        offset += std.mem.alignForward(usize, len, 4);
    }
    // The socket exists, but its kernel counters are absent or too short.
    result.partial = true;
}

test "TCP metadata filters ownership, deduplicates and accepts extended tcp_info" {
    var packet: [16 + 72 + 4 + 240]u8 = @splat(0);
    put(u32, &packet, 0, packet.len);
    put(u16, &packet, 4, 20);
    put(u32, &packet, 8, 1);
    put(u32, &packet, 16 + 68, 42);
    put(u64, &packet, 16 + 44, 99);
    put(u16, &packet, 88, 244);
    put(u16, &packet, 90, 2);
    put(u64, &packet, 92 + 128, 123456);
    put(u64, &packet, 92 + 200, 654321);
    var result: Snapshot = .{};
    _ = try parse(&packet, &.{43}, &result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
    _ = try parse(&packet, &.{42}, &result);
    _ = try parse(&packet, &.{42}, &result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(u64, 123456), result.items[0].received);
    try std.testing.expectEqual(@as(u64, 654321), result.items[0].sent);
    try std.testing.expectError(error.InvalidMessage, parse(packet[0..100], &.{42}, &result));
    put(u16, &packet, 6, 0x10);
    try std.testing.expectError(error.Unavailable, parse(&packet, &.{42}, &result));
}

test "TCP activity uses stable socket cookies and never subtracts closed sockets" {
    var before: Snapshot = .{};
    before.items[0] = .{ .inode = 1, .cookie = 2, .received = 100, .sent = 500 };
    before.items[1] = .{ .inode = 2, .cookie = 3, .received = 9000, .sent = 9000 };
    before.len = 2;
    var after = before;
    after.len = 1;
    after.items[0].received = 200;
    after.items[0].sent = 600;
    const change = after.delta(&before);
    try std.testing.expectEqual(@as(u64, 100), change.received);
    try std.testing.expectEqual(@as(u64, 100), change.sent);
    after.items[0].cookie = 4;
    try std.testing.expectEqual(@as(u64, 0), after.delta(&before).received);
    after.items[0].cookie = 2;
    after.items[0].received = 0;
    try std.testing.expectEqual(@as(u64, 0), after.delta(&before).received);
}

test "TCP metadata rejects malformed attributes and tolerates old short counters" {
    var body: [72 + 4 + 104]u8 = @splat(0);
    put(u32, &body, 68, 42);
    put(u16, &body, 72, 108);
    put(u16, &body, 74, 2);
    var result: Snapshot = .{};
    try parse_socket(&body, &.{42}, &result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
    try std.testing.expect(result.partial);
    put(u16, &body, 72, 1);
    try std.testing.expectError(error.InvalidMessage, parse_socket(&body, &.{42}, &result));
    put(u16, &body, 72, 200);
    try std.testing.expectError(error.InvalidMessage, parse_socket(&body, &.{42}, &result));
    var done: [20]u8 = @splat(0);
    put(u32, &done, 0, done.len);
    put(u16, &done, 4, 3);
    put(u32, &done, 8, 1);
    try std.testing.expect(try parse(&done, &.{}, &result));
    put(i32, &done, 16, -1);
    try std.testing.expectError(error.Unavailable, parse(&done, &.{}, &result));
}

test "unavailable TCP families fall back independently and discard incomplete dumps" {
    const Probe = struct {
        fn denied(_: std.Io, _: u8, _: []const u64, _: *Snapshot) !void {
            return error.AccessDenied;
        }
        fn mixed(_: std.Io, family: u8, _: []const u64, result: *Snapshot) !void {
            result.items[result.len] = .{ .inode = 42, .cookie = 1, .received = 100, .sent = 200 };
            result.len += 1;
            if (family == linux.AF.INET6) return error.Unavailable;
        }
        fn canceled(_: std.Io, _: u8, _: []const u64, _: *Snapshot) !void {
            return error.Canceled;
        }
    };
    const missing = try sample_with(std.testing.io, &.{42}, Probe.denied);
    try std.testing.expect(missing.partial);
    try std.testing.expectEqual(@as(usize, 0), missing.len);
    const partial = try sample_with(std.testing.io, &.{42}, Probe.mixed);
    try std.testing.expect(partial.partial);
    try std.testing.expectEqual(@as(usize, 1), partial.len);
    try std.testing.expectError(error.Canceled, sample_with(std.testing.io, &.{42}, Probe.canceled));
}
