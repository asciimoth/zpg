const std = @import("std");
const builtin = @import("builtin");
const styles = @import("style.zig");
const network = @import("guess_net.zig");

const limit = 256;
const recent_ns = 2 * std.time.ns_per_s;

pub const unknown_name = "I/O estimate (unknown)";
const max_count = std.math.maxInt(u32) - 1;

const Sample = struct {
    position: u64,
    size: u64,
    pid: std.posix.pid_t,
    fd: u32,
    start: u64 = 0,
    mount: u64 = 0,
    inode: u64 = 0,
    name: [std.Progress.Node.max_name_len]u8 = @splat(0),
    name_len: usize = 0,
    moved: i96 = 0,
    confirmed: bool = false,
    suspect: bool = false,

    fn same_file(self: Sample, other: Sample) bool {
        return self.mount == other.mount and self.inode == other.inode;
    }

    fn same_reader(self: Sample, other: Sample) bool {
        return self.pid == other.pid and self.start == other.start and
            self.fd == other.fd and self.same_file(other);
    }
};

const Process = struct {
    pid: std.posix.pid_t,
    start: u64,
    cpu: u64,
    read: u64 = 0,
    written: u64 = 0,
    has_io: bool = false,
};

const Snapshot = struct {
    files: [limit]Sample = undefined,
    len: usize = 0,
    processes: [limit]Process = undefined,
    process_len: usize = 0,
    sockets: [network.limit]u64 = undefined,
    socket_len: usize = 0,
    inspected: usize = 0,
    limited: bool = false,

    fn process(self: *const Snapshot, pid: std.posix.pid_t, start: u64) ?Process {
        for (self.processes[0..self.process_len]) |item| {
            if (item.pid == pid and item.start == start) return item;
        }
        return null;
    }

    fn observe(self: *Snapshot, previous: *const Snapshot, now: i96) void {
        for (self.files[0..self.len]) |*file| {
            file.suspect = file.position > file.size;
            for (previous.files[0..previous.len]) |old| {
                if (!file.same_reader(old)) continue;
                file.confirmed = old.confirmed;
                file.moved = old.moved;
                // Once a reader seeks back or its input changes size, offsets
                // no longer describe a single pass. Do not invent coverage.
                file.suspect = file.suspect or old.suspect or
                    file.position < old.position or file.size != old.size;
                if (file.position > old.position) {
                    file.confirmed = true;
                    file.moved = now;
                }
                break;
            }
        }
        // A second descriptor must not restore a percentage for a file whose
        // observed readers no longer form a sequential pass.
        for (self.files[0..self.len]) |file| {
            if (!file.suspect) continue;
            for (self.files[0..self.len]) |*other| {
                if (file.same_file(other.*)) other.suspect = true;
            }
        }
    }
};

const Selection = struct {
    indices: [limit]usize = undefined,
    len: usize = 0,
};

fn select(current: *const Snapshot, now: i96) Selection {
    var result: Selection = .{};
    var moving = false;
    var confirmed = false;
    for (current.files[0..current.len]) |file| {
        if (!file.suspect and file.confirmed and file.position < file.size) {
            confirmed = true;
            if (now - file.moved <= recent_ns) moving = true;
        }
    }
    for (current.files[0..current.len], 0..) |file, index| {
        if (file.suspect or file.position == 0) continue;
        if (confirmed and !file.confirmed) continue;
        if (moving and (!file.confirmed or now - file.moved > recent_ns)) continue;
        // A full input can remain open while CPU work or output continues.
        // Show EOF briefly, then return to activity with no completion claim.
        if (file.position >= file.size and (!file.confirmed or now - file.moved > std.time.ns_per_s)) continue;
        var duplicate = false;
        for (result.indices[0..result.len]) |*selected| {
            const old = current.files[selected.*];
            if (!file.same_file(old)) continue;
            duplicate = true;
            // Duplicated/inherited descriptors must not multiply file size.
            if (file.position > old.position) selected.* = index;
            break;
        }
        if (!duplicate) {
            result.indices[result.len] = index;
            result.len += 1;
        }
    }
    return result;
}

const Activity = struct {
    read_rate: u64 = 0,
    write_rate: u64 = 0,
    cpu: bool = false,
    has_cpu: bool = false,
    has_io: bool = false,

    fn update(self: *Activity, current: *const Snapshot, previous: *const Snapshot, elapsed: i96) void {
        var read: u64 = 0;
        var written: u64 = 0;
        self.cpu = false;
        self.has_cpu = false;
        self.has_io = false;
        // /proc/PID/io includes reaped children. Skip deltas when a known
        // process disappears to reduce double counting at process exit.
        // Delayed reaping and short-lived processes can still skew rates.
        var disappeared = false;
        for (previous.processes[0..previous.process_len]) |old| {
            if (current.process(old.pid, old.start) == null) disappeared = true;
        }
        for (current.processes[0..current.process_len]) |item| {
            const old = previous.process(item.pid, item.start) orelse continue;
            self.has_cpu = true;
            self.cpu = self.cpu or item.cpu > old.cpu;
            if (disappeared or !item.has_io or !old.has_io) continue;
            self.has_io = true;
            read +|= item.read -| old.read;
            written +|= item.written -| old.written;
        }
        self.read_rate = if (self.has_io) smooth(self.read_rate, rate(read, elapsed)) else 0;
        self.write_rate = if (self.has_io) smooth(self.write_rate, rate(written, elapsed)) else 0;
    }
};

fn rate(bytes: u64, elapsed: i96) u64 {
    if (elapsed <= 0) return 0;
    return @intCast(@min(std.math.maxInt(u64), @as(u128, bytes) * std.time.ns_per_s / @as(u96, @intCast(elapsed))));
}

fn smooth(previous: u64, current: u64) u64 {
    // A short exponential average reduces bursts without a long stale tail.
    return @intCast((@as(u128, previous) + current) / 2);
}

fn write_bytes(writer: *std.Io.Writer, bytes: u64) void {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };
    var value = bytes;
    var divisor: u64 = 1;
    var unit: usize = 0;
    while (value >= 1024 and unit + 1 < units.len) : (unit += 1) {
        value /= 1024;
        divisor *= 1024;
    }
    const fraction = (bytes % divisor) * 10 / divisor;
    writer.print("{d}", .{value}) catch unreachable;
    if (fraction != 0) writer.print(".{d}", .{fraction}) catch unreachable;
    writer.print(" {s}", .{units[unit]}) catch unreachable;
}

const Counts = struct {
    completed: u32,
    total: u32,
    unit: []const u8,
};

// Leave room in the progress protocol for native reports and other estimates.
// The terminal renderer can further clip this tree to the available height.
const file_row_limit = 32;
const FileRows = struct {
    const Row = struct {
        node: std.Progress.Node = .none,
        mount: u64 = 0,
        inode: u64 = 0,

        fn matches(self: Row, file: Sample) bool {
            return self.node.index != .none and self.mount == file.mount and self.inode == file.inode;
        }
    };
    rows: [file_row_limit]Row = @splat(.{}),

    fn end(self: *FileRows) void {
        for (&self.rows) |*row| {
            row.node.end();
            row.* = .{};
        }
    }

    fn update(self: *FileRows, parent: std.Progress.Node, current: *const Snapshot, selected: *const Selection) usize {
        // Preserve nodes by file identity, even if /proc enumeration changes.
        // End old nodes before allocating replacements so slots can be reused.
        for (&self.rows) |*row| {
            var keep = false;
            if (selected.len > 1) {
                for (selected.indices[0..selected.len]) |index| {
                    if (row.matches(current.files[index])) {
                        keep = true;
                        break;
                    }
                }
            }
            if (!keep) {
                row.node.end();
                row.* = .{};
            }
        }
        var shown: usize = 0;
        if (selected.len > 1) {
            for (selected.indices[0..selected.len]) |index| {
                const file = current.files[index];
                var existing: ?*Row = null;
                var free: ?*Row = null;
                for (&self.rows) |*row| {
                    if (row.matches(file)) existing = row;
                    if (row.node.index == .none and free == null) free = row;
                }
                const row = existing orelse free orelse continue;
                if (existing == null) row.* = .{
                    .node = parent.start("Input estimate", 0),
                    .mount = file.mount,
                    .inode = file.inode,
                };
                if (row.node.index == .none) continue;
                show_file(row.node, file, false, current.limited);
                shown += 1;
            }
        }
        // Node.end increments its parent's completed count. Removed input
        // estimates are not completed work, so discard that count.
        parent.setCompletedItems(0);
        return shown;
    }
};

fn show_file(node: std.Progress.Node, file: Sample, compact: bool, partial: bool) void {
    const value = counts(file.position, file.size);
    var label: [std.Progress.Node.max_name_len]u8 = undefined;
    var writer = std.Io.Writer.fixed(&label);
    if (compact) {
        writer.print("I/O estimate ({s}{s}): ", .{ value.unit, if (partial) ", partial" else "" }) catch unreachable;
    } else {
        writer.print("{s}: ", .{value.unit}) catch unreachable;
    }
    write_name(&writer, file.name[0..file.name_len]);
    node.setEstimatedTotalItems(0);
    node.setName(writer.buffered());
    node.setCompletedItems(value.completed);
    node.setEstimatedTotalItems(value.total);
}

// The progress protocol has 32-bit counts. Scale both values together so
// large files keep their ratio; round the total up to avoid early completion.
fn counts(position: u128, size: u128) Counts {
    const units = [_][]const u8{ "bytes", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB" };
    var scale: u128 = 1;
    var unit: usize = 0;
    while (std.math.divCeil(u128, size, scale) catch unreachable > max_count) {
        scale *= 1024;
        unit += 1;
    }
    const total: u32 = @intCast(std.math.divCeil(u128, size, scale) catch unreachable);
    return .{
        .completed = if (position >= size) total else @intCast(position / scale),
        .total = total,
        .unit = units[unit],
    };
}

pub fn run(io: std.Io, pgid: std.posix.pid_t, node: std.Progress.Node) void {
    if (builtin.os.tag != .linux) return;
    var previous: Snapshot = .{};
    var activity: Activity = .{};
    var file_rows: FileRows = .{};
    defer file_rows.end();
    const activity_node = node.start("Activity (unknown)", 0);
    defer activity_node.end();
    var tcp_node: std.Progress.Node = .none;
    defer tcp_node.end();
    var previous_tcp: network.Snapshot = .{};
    var tcp_time = std.Io.Clock.awake.now(io);
    var received: u64 = 0;
    var sent: u64 = 0;
    var receive_rate: u64 = 0;
    var send_rate: u64 = 0;
    var previous_time = tcp_time;
    while (true) {
        var current: Snapshot = .{};
        sample(io, pgid, &current) catch |err| {
            if (err == error.Canceled) return;
            current.limited = true;
        };
        const now = std.Io.Clock.awake.now(io);
        current.observe(&previous, now.nanoseconds);
        const selected = select(&current, now.nanoseconds);
        activity.update(&current, &previous, previous_time.durationTo(now).nanoseconds);
        previous_time = now;
        var label: [std.Progress.Node.max_name_len]u8 = undefined;
        var writer = std.Io.Writer.fixed(&label);
        node.setEstimatedTotalItems(0);
        node.setCompletedItems(0);
        const shown = file_rows.update(node, &current, &selected);
        if (selected.len == 1) {
            show_file(node, current.files[selected.indices[0]], true, current.limited);
        } else if (selected.len > 1) {
            writer.print("I/O estimate{s}: {d} active inputs", .{ if (current.limited) " (partial)" else "", selected.len }) catch unreachable;
            if (shown < selected.len) writer.print("; showing {d}", .{shown}) catch unreachable;
            node.setName(writer.buffered());
        } else {
            node.setName(unknown_name);
        }
        writer.end = 0;
        writer.print("Activity{s}: ", .{if (current.limited) " (partial)" else ""}) catch unreachable;
        if (activity.has_io) {
            writer.writeAll("read ") catch unreachable;
            write_bytes(&writer, activity.read_rate);
            writer.writeAll("/s, write ") catch unreachable;
            write_bytes(&writer, activity.write_rate);
            writer.writeAll("/s; ") catch unreachable;
        } else writer.writeAll("I/O unknown; ") catch unreachable;
        writer.print("CPU {s}", .{if (!activity.has_cpu) "unknown" else if (activity.cpu) "active" else "quiet"}) catch unreachable;
        activity_node.setName(writer.buffered());

        // Socket dumps are more expensive than file metadata. Sample at most
        // once a second, and only while the group owns sockets.
        const tcp_elapsed = tcp_time.durationTo(now).nanoseconds;
        if (tcp_elapsed >= std.time.ns_per_s) {
            const tcp = network.sample(io, current.sockets[0..current.socket_len]) catch |err| blk: {
                if (err == error.Canceled) return;
                break :blk network.Snapshot{ .partial = true };
            };
            const change = tcp.delta(&previous_tcp);
            received +|= change.received;
            sent +|= change.sent;
            receive_rate = smooth(receive_rate, rate(change.received, tcp_elapsed));
            send_rate = smooth(send_rate, rate(change.sent, tcp_elapsed));
            if (tcp.len != 0 and tcp_node.index == .none) tcp_node = node.start("TCP activity", 0);
            if (tcp_node.index != .none and tcp.len == 0) {
                tcp_node.setName("TCP activity (unknown)");
                receive_rate = 0;
                send_rate = 0;
            } else if (tcp_node.index != .none) {
                writer.end = 0;
                writer.print("TCP observed{s}: ", .{if (tcp.partial or current.limited) " (partial)" else ""}) catch unreachable;
                write_bytes(&writer, received);
                writer.writeAll(" in, ") catch unreachable;
                write_bytes(&writer, sent);
                writer.writeAll(" out; ") catch unreachable;
                write_bytes(&writer, receive_rate);
                writer.writeAll("/s in, ") catch unreachable;
                write_bytes(&writer, send_rate);
                writer.writeAll("/s out") catch unreachable;
                tcp_node.setName(writer.buffered());
            }
            previous_tcp = tcp;
            tcp_time = now;
        }
        previous = current;
        io.sleep(.fromMilliseconds(200), .awake) catch return;
    }
}

// File names are arbitrary bytes. Both renderers must receive safe UTF-8,
// and truncation must preserve complete codepoints.
fn write_name(writer: *std.Io.Writer, name: []const u8) void {
    var index: usize = 0;
    while (index < name.len) {
        const len = std.unicode.utf8ByteSequenceLength(name[index]) catch 1;
        const end = index + len;
        const cp = if (name[index] < 128)
            @as(u21, name[index])
        else if (len > 1 and end <= name.len)
            std.unicode.utf8Decode(name[index..end]) catch 0
        else
            0;
        const safe = styles.safe_codepoint(cp);
        const bytes = if (safe) name[index..end] else "?";
        if (bytes.len > writer.buffer.len - writer.end) return;
        writer.writeAll(bytes) catch return;
        index += if (cp == 0) 1 else len;
    }
}

fn sample(io: std.Io, pgid: std.posix.pid_t, result: *Snapshot) !void {
    const proc = try std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true });
    defer proc.close(io);
    var processes = proc.iterate();
    while (try processes.next(io)) |entry| {
        try io.checkCancel();
        const pid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
        if (pid <= 0) continue;
        scan_process(io, proc, entry.name, pid, pgid, result) catch |err| {
            if (err == error.Canceled) return err;
            // Processes and descriptors can disappear during a scan.
        };
    }
}

fn scan_process(io: std.Io, proc: std.Io.Dir, name: []const u8, pid: std.posix.pid_t, pgid: std.posix.pid_t, result: *Snapshot) !void {
    const process = try proc.openDir(io, name, .{});
    defer process.close(io);
    var buffer: [4096]u8 = undefined;
    const stat = try read_proc(io, process, "stat", &buffer);
    if (process_group(stat) != pgid) return;
    errdefer result.limited = true;
    var info = parse_process(stat, pid) orelse {
        result.limited = true;
        return;
    };
    if (read_proc(io, process, "io", &buffer)) |bytes| {
        if (parse_io(bytes)) |value| {
            info.read = value.read;
            info.written = value.written;
            info.has_io = true;
        } else result.limited = true;
    } else |err| {
        if (err == error.Canceled) return err;
        result.limited = true;
    }
    if (result.process_len == limit) {
        result.limited = true;
        return;
    }
    result.processes[result.process_len] = info;
    result.process_len += 1;
    const fds = try process.openDir(io, "fd", .{ .iterate = true });
    defer fds.close(io);
    var entries = fds.iterate();
    while (try entries.next(io)) |entry| {
        try io.checkCancel();
        if (result.inspected == 4096) {
            result.limited = true;
            break;
        }
        result.inspected += 1;
        const fd = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        const len = fds.readLink(io, entry.name, &buffer) catch |err| {
            if (err == error.Canceled) return err;
            result.limited = true;
            continue;
        };
        const link = buffer[0..len];
        if (socket_inode(link)) |inode| {
            if (std.mem.indexOfScalar(u64, result.sockets[0..result.socket_len], inode) == null) {
                if (result.socket_len < result.sockets.len) {
                    result.sockets[result.socket_len] = inode;
                    result.socket_len += 1;
                } else result.limited = true;
            }
            continue;
        }
        if (result.len == limit) {
            result.limited = true;
            continue;
        }
        var candidate = (inspect(io, process, entry.name, pid, fd) catch |err| {
            if (err == error.Canceled) return err;
            result.limited = true;
            continue;
        }) orelse continue;
        candidate.start = info.start;
        const basename = std.fs.path.basename(link);
        candidate.name_len = @min(basename.len, candidate.name.len);
        @memcpy(candidate.name[0..candidate.name_len], basename[0..candidate.name_len]);
        result.files[result.len] = candidate;
        result.len += 1;
    }
}

fn inspect(io: std.Io, process: std.Io.Dir, name: []const u8, pid: std.posix.pid_t, fd: u32) !?Sample {
    var path_buffer: [64]u8 = undefined;
    const info_path = try std.fmt.bufPrint(&path_buffer, "fdinfo/{s}", .{name});
    var info_buffer: [4096]u8 = undefined;
    const info = parse_fd_info(try read_proc(io, process, info_path, &info_buffer)) orelse return null;
    // A writable or growing output cannot establish an input total.
    if (info.flags & 3 != 0 or info.flags & 0o10000000 != 0) return null;
    const fd_path = try std.fmt.bufPrint(&path_buffer, "fd/{s}", .{name});
    const stat = try process.statFile(io, fd_path, .{});
    if (stat.kind != .file or stat.size == 0) return null;
    // Detect an FD replacement between the two metadata reads.
    if (info.inode == null or info.inode.? != stat.inode) return null;
    return .{ .position = info.position, .size = stat.size, .pid = pid, .fd = fd, .mount = info.mount orelse return null, .inode = stat.inode };
}

const FdInfo = struct { position: u64, flags: u64, mount: ?u64 = null, inode: ?u64 = null };

fn socket_inode(link: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, link, "socket:[") or !std.mem.endsWith(u8, link, "]")) return null;
    return std.fmt.parseInt(u64, link[8 .. link.len - 1], 10) catch null;
}

fn parse_process(stat: []const u8, pid: std.posix.pid_t) ?Process {
    const end = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = std.mem.tokenizeAny(u8, stat[end + 1 ..], " \t\r\n");
    var result: Process = .{ .pid = pid, .start = 0, .cpu = 0 };
    var field: usize = 3;
    while (fields.next()) |value| : (field += 1) {
        if (field == 14 or field == 15) result.cpu +|= std.fmt.parseInt(u64, value, 10) catch return null;
        if (field == 22) {
            result.start = std.fmt.parseInt(u64, value, 10) catch return null;
            return result;
        }
    }
    return null;
}

const IoCounts = struct { read: u64, written: u64 };

fn parse_io(bytes: []const u8) ?IoCounts {
    var read: ?u64 = null;
    var written: ?u64 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        if (std.mem.eql(u8, key, "rchar")) read = std.fmt.parseInt(u64, value, 10) catch return null;
        if (std.mem.eql(u8, key, "wchar")) written = std.fmt.parseInt(u64, value, 10) catch return null;
    }
    return .{ .read = read orelse return null, .written = written orelse return null };
}

fn read_proc(io: std.Io, dir: std.Io.Dir, path: []const u8, buffer: []u8) ![]const u8 {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var len: usize = 0;
    while (len < buffer.len) {
        try io.checkCancel();
        // Proc reads can return ENOENT or ESRCH after a successful open.
        // Zig 0.17's generic reader treats these as unexpected and prints a
        // stack trace in Debug builds. Handle these short metadata reads here.
        const rc = std.os.linux.read(file.handle, buffer[len..].ptr, buffer.len - len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return buffer[0..len];
                len += rc;
            },
            .INTR => continue,
            else => return error.ProcUnavailable,
        }
    }
    return error.ProcTooLong;
}

fn parse_fd_info(text: []const u8) ?FdInfo {
    var position: ?u64 = null;
    var flags: ?u64 = null;
    var mount: ?u64 = null;
    var inode: ?u64 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        if (std.mem.eql(u8, key, "pos")) {
            position = std.fmt.parseInt(u64, value, 10) catch return null;
        } else if (std.mem.eql(u8, key, "flags")) {
            flags = std.fmt.parseInt(u64, value, 8) catch return null;
        } else if (std.mem.eql(u8, key, "mnt_id")) {
            mount = std.fmt.parseInt(u64, value, 10) catch return null;
        } else if (std.mem.eql(u8, key, "ino")) {
            inode = std.fmt.parseInt(u64, value, 10) catch return null;
        }
    }
    return .{ .position = position orelse return null, .flags = flags orelse return null, .mount = mount, .inode = inode };
}

fn process_group(stat: []const u8) ?std.posix.pid_t {
    // comm can contain spaces, newlines, and parentheses. Its closing ')' is
    // the last one; fields after it start with state, ppid, then pgrp.
    const end = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = std.mem.tokenizeAny(u8, stat[end + 1 ..], " \t\r\n");
    _ = fields.next() orelse return null;
    _ = fields.next() orelse return null;
    return std.fmt.parseInt(std.posix.pid_t, fields.next() orelse return null, 10) catch null;
}

test "proc metadata accepts unusual command names and octal flags" {
    try std.testing.expectEqual(@as(?std.posix.pid_t, 42), process_group("123 (a ) strange\n(name)) S 1 42 99 0"));
    try std.testing.expectEqual(@as(?std.posix.pid_t, null), process_group("123 (bad) S 1"));
    const info = parse_fd_info("pos:\t12345678901\nflags:\t02100000\nmnt_id:\t27\n").?;
    try std.testing.expectEqual(@as(u64, 12345678901), info.position);
    try std.testing.expectEqual(@as(u64, 0o2100000), info.flags);
    try std.testing.expect(parse_fd_info("pos: -1\nflags: 0\n") == null);
    try std.testing.expect(parse_fd_info("pos: 1\nflags: 9\n") == null);
    try std.testing.expect(parse_fd_info("flags: 0\n") == null);
}

test "large file counts preserve ratios and clamp seeks beyond EOF" {
    const small = counts(512, 1024);
    try std.testing.expectEqual(@as(u32, 512), small.completed);
    try std.testing.expectEqual(@as(u32, 1024), small.total);
    try std.testing.expectEqualStrings("bytes", small.unit);
    const large = counts(1 << 33, 1 << 34);
    try std.testing.expectEqual(@as(u32, 1 << 23), large.completed);
    try std.testing.expectEqual(@as(u32, 1 << 24), large.total);
    try std.testing.expectEqualStrings("KiB", large.unit);
    const maximum = counts(std.math.maxInt(u64) / 2, std.math.maxInt(u64));
    try std.testing.expectEqual(maximum.total / 2 - 1, maximum.completed);
    try std.testing.expect(maximum.total <= max_count);
    const beyond = counts(200, 100);
    try std.testing.expectEqual(beyond.total, beyond.completed);
}

test "file labels replace controls and invalid bytes without splitting UTF-8" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    write_name(&writer, "a\n\x1b[2J\xff\u{202e}é.bin");
    try std.testing.expectEqualStrings("a??[2J??é.bin", writer.buffered());
    var short = std.Io.Writer.fixed(buffer[0..2]);
    write_name(&short, "aé");
    try std.testing.expectEqualStrings("a", short.buffered());
}

fn test_file(inode: u64, position: u64, size: u64) Sample {
    return .{ .pid = 10, .fd = @intCast(inode), .inode = inode, .mount = 1, .start = 100, .position = position, .size = size };
}

test "active inputs beat idle files and duplicate descriptors count once" {
    var before: Snapshot = .{};
    before.files[0] = test_file(1, 0, 1024);
    before.files[1] = test_file(2, 0, 2048);
    before.files[2] = test_file(3, 1, 1 << 30);
    before.len = 3;
    var after = before;
    after.files[0].position = 256;
    after.files[1].position = 512;
    after.files[3] = after.files[0];
    after.files[3].fd = 9;
    after.len = 4;
    after.observe(&before, std.time.ns_per_s);
    const chosen = select(&after, std.time.ns_per_s);
    try std.testing.expectEqual(@as(usize, 2), chosen.len);
    try std.testing.expectEqual(@as(u64, 1), after.files[chosen.indices[0]].inode);
    try std.testing.expectEqual(@as(u64, 2), after.files[chosen.indices[1]].inode);
    // Pausing the inputs must not bring an unrelated idle file back.
    const paused = select(&after, 10 * std.time.ns_per_s);
    try std.testing.expectEqualSlices(usize, chosen.indices[0..chosen.len], paused.indices[0..paused.len]);
    // A remaining input gets its own scope when another descriptor closes.
    after.files[0] = after.files[1];
    after.len = 1;
    const remaining = select(&after, std.time.ns_per_s);
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
    try std.testing.expectEqual(@as(u64, 2), after.files[remaining.indices[0]].inode);
}

test "seeks, size changes, EOF and identity reuse do not imply completed work" {
    var before: Snapshot = .{};
    before.files[0] = test_file(1, 256, 1024);
    before.len = 1;
    var after = before;
    after.files[0].position = 128;
    after.observe(&before, 1);
    try std.testing.expectEqual(@as(usize, 0), select(&after, 1).len);
    after.files[1] = test_file(1, 512, 1024);
    after.files[1].fd = 9;
    after.len = 2;
    after.observe(&before, 1);
    try std.testing.expectEqual(@as(usize, 0), select(&after, 1).len);
    var forward = after;
    forward.files[0].position = 512;
    forward.observe(&after, 2);
    try std.testing.expectEqual(@as(usize, 0), select(&forward, 2).len);
    after = before;
    after.files[0].size = 2048;
    after.observe(&before, 1);
    try std.testing.expectEqual(@as(usize, 0), select(&after, 1).len);
    after = before;
    after.files[0].position = 1024;
    after.observe(&before, 1);
    try std.testing.expectEqual(@as(usize, 1), select(&after, 1).len);
    try std.testing.expectEqual(@as(usize, 0), select(&after, 2 * std.time.ns_per_s).len);
    // A reused FD or PID cannot inherit the previous reader's state.
    after = before;
    after.files[0].position = 128;
    after.files[0].inode = 2;
    after.observe(&before, 1);
    try std.testing.expect(!after.files[0].suspect and !after.files[0].confirmed);
    after.files[0].inode = 1;
    after.files[0].start = 200;
    after.observe(&before, 1);
    try std.testing.expect(!after.files[0].suspect and !after.files[0].confirmed);
}

test "aggregate counts remain proportional beyond u64 and proc metadata is strict" {
    const value = counts(@as(u128, 1) << 70, @as(u128, 1) << 71);
    try std.testing.expectEqual(value.total / 2, value.completed);
    const info = parse_fd_info("pos: 8\nflags: 0100000\nmnt_id: 4\nino: 99\n").?;
    try std.testing.expectEqual(@as(?u64, 4), info.mount);
    try std.testing.expectEqual(@as(?u64, 99), info.inode);
    try std.testing.expectEqual(@as(?u64, 99), socket_inode("socket:[99]"));
    try std.testing.expect(socket_inode("socket:[]") == null);
    try std.testing.expect(socket_inode("pipe:[99]") == null);
    const io = parse_io("rchar: 1000\nwchar: 20\nread_bytes: 0\n").?;
    try std.testing.expectEqual(@as(u64, 1000), io.read);
    try std.testing.expect(parse_io("rchar: -1\nwchar: 20\n") == null);
    const process = parse_process("10 (a ) b) S 1 10 0 0 0 0 0 0 0 0 12 34 90 90 0 0 0 0 567", 10).?;
    try std.testing.expectEqual(@as(u64, 46), process.cpu);
    try std.testing.expectEqual(@as(u64, 567), process.start);
}

test "activity uses elapsed time and skips counter resets and reaped children" {
    var before: Snapshot = .{};
    before.processes[0] = .{ .pid = 10, .start = 1, .cpu = 10, .read = 1024, .written = 0, .has_io = true };
    before.process_len = 1;
    var after = before;
    after.processes[0].read += 4096;
    after.processes[0].cpu += 1;
    var activity: Activity = .{};
    activity.update(&after, &before, 2 * std.time.ns_per_s);
    try std.testing.expectEqual(@as(u64, 1024), activity.read_rate);
    try std.testing.expect(activity.cpu);
    activity = .{};
    activity.update(&before, &after, std.time.ns_per_s);
    try std.testing.expectEqual(@as(u64, 0), activity.read_rate);
    before.processes[1] = .{ .pid = 11, .start = 1, .cpu = 0 };
    before.process_len = 2;
    activity.update(&after, &before, std.time.ns_per_s);
    try std.testing.expectEqual(@as(u64, 0), activity.read_rate);
    try std.testing.expect(!activity.has_io);
}

test "missing proc metrics keep CPU activity and recover without stale I/O rates" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "stat", .data = "10 (worker) S 1 10 0 0 0 0 0 0 0 0 12 34 90 90 0 0 0 0 567" });
    var before: Snapshot = .{};
    // No io file or fd directory: CPU metadata must survive the failure.
    try std.testing.expectError(error.FileNotFound, scan_process(io, tmp.dir, ".", 10, 10, &before));
    try std.testing.expect(before.limited);
    try std.testing.expectEqual(@as(usize, 1), before.process_len);
    try std.testing.expect(!before.processes[0].has_io);
    var activity: Activity = .{ .read_rate = 9000, .write_rate = 9000 };
    activity.update(&before, &before, std.time.ns_per_s);
    try std.testing.expect(activity.has_cpu);
    try std.testing.expect(!activity.has_io);
    try std.testing.expectEqual(@as(u64, 0), activity.read_rate);
    try std.testing.expectEqual(@as(u64, 0), activity.write_rate);
    try tmp.dir.createDir(io, "fd", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "io", .data = "rchar: 100\nwchar: 200\n" });
    var recovered: Snapshot = .{};
    try scan_process(io, tmp.dir, ".", 10, 10, &recovered);
    try std.testing.expect(!recovered.limited);
    activity.update(&recovered, &before, std.time.ns_per_s);
    try std.testing.expect(!activity.has_io);
    var next = recovered;
    next.processes[0].read += 1024;
    activity.update(&next, &recovered, std.time.ns_per_s);
    try std.testing.expect(activity.has_io);
    try std.testing.expectEqual(@as(u64, 512), activity.read_rate);
    // Complete loss clears both activity and file selection.
    const unavailable: Snapshot = .{};
    activity.update(&unavailable, &next, std.time.ns_per_s);
    try std.testing.expect(!activity.has_io and !activity.has_cpu);
    try std.testing.expectEqual(@as(usize, 0), select(&unavailable, 0).len);
}

test "sampler tolerates missing or denied proc access until canceled" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const Unavailable = struct {
        denied: bool,
        polls: usize = 0,

        fn open(userdata: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir.OpenOptions) std.Io.Dir.OpenError!std.Io.Dir {
            const self: *@This() = @ptrCast(@alignCast(userdata));
            return if (self.denied) error.AccessDenied else error.FileNotFound;
        }

        fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            return .fromNanoseconds(0);
        }

        fn sleep(userdata: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
            const self: *@This() = @ptrCast(@alignCast(userdata));
            self.polls += 1;
            if (self.polls == 3) return error.Canceled;
        }
    };
    for ([_]bool{ false, true }) |denied| {
        var state: Unavailable = .{ .denied = denied };
        var vtable = std.testing.io.vtable.*;
        vtable.dirOpenDir = Unavailable.open;
        vtable.now = Unavailable.now;
        vtable.sleep = Unavailable.sleep;
        run(.{ .userdata = &state, .vtable = &vtable }, 10, .none);
        try std.testing.expectEqual(@as(usize, 3), state.polls);
    }
}
