const std = @import("std");
const builtin = @import("builtin");
const styles = @import("style.zig");

pub const unknown_name = "I/O estimate (unknown)";
const max_count = std.math.maxInt(u32) - 1;

const Sample = struct {
    position: u64,
    size: u64,
    pid: std.posix.pid_t,
    fd: u32,
    name: [std.Progress.Node.max_name_len]u8 = @splat(0),
    name_len: usize = 0,

    fn preferred(self: Sample, other: Sample) bool {
        if (self.size != other.size) return self.size > other.size;
        if (self.pid != other.pid) return self.pid < other.pid;
        return self.fd < other.fd;
    }
};

const Counts = struct {
    completed: u32,
    total: u32,
    unit: []const u8,
};

// The progress protocol has 32-bit counts. Scale both values together so
// large files keep their ratio; round the total up to avoid early completion.
fn counts(position: u64, size: u64) Counts {
    const units = [_][]const u8{ "bytes", "KiB", "MiB", "GiB", "TiB" };
    var scale: u64 = 1;
    var unit: usize = 0;
    while (std.math.divCeil(u64, size, scale) catch unreachable > max_count) {
        scale *= 1024;
        unit += 1;
    }
    const total: u32 = @intCast(std.math.divCeil(u64, size, scale) catch unreachable);
    return .{
        .completed = if (position >= size) total else @intCast(position / scale),
        .total = total,
        .unit = units[unit],
    };
}

pub fn run(io: std.Io, pgid: std.posix.pid_t, node: std.Progress.Node) void {
    if (builtin.os.tag != .linux) return;
    while (true) {
        const current = sample(io, pgid) catch |err| blk: {
            if (err == error.Canceled) return;
            break :blk null;
        };
        // Clear the previous file's counts, including when its descriptor
        // closes. A completed file does not mean the command has finished.
        node.setEstimatedTotalItems(0);
        node.setCompletedItems(0);
        if (current) |file| {
            const value = counts(file.position, file.size);
            var label: [std.Progress.Node.max_name_len]u8 = undefined;
            var writer = std.Io.Writer.fixed(&label);
            writer.print("I/O estimate ({s}): ", .{value.unit}) catch unreachable;
            write_name(&writer, file.name[0..file.name_len]);
            node.setName(writer.buffered());
            node.setCompletedItems(value.completed);
            node.setEstimatedTotalItems(value.total);
        } else {
            node.setName(unknown_name);
        }
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

fn sample(io: std.Io, pgid: std.posix.pid_t) !?Sample {
    const proc = try std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true });
    defer proc.close(io);
    var best: ?Sample = null;
    var processes = proc.iterate();
    while (try processes.next(io)) |entry| {
        const pid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
        if (pid <= 0) continue;
        scan_process(io, proc, entry.name, pid, pgid, &best) catch |err| {
            if (err == error.Canceled) return err;
            // Processes and descriptors can disappear during a scan. Permission
            // failures also leave the command running with an unknown estimate.
        };
    }
    return best;
}

fn scan_process(io: std.Io, proc: std.Io.Dir, name: []const u8, pid: std.posix.pid_t, pgid: std.posix.pid_t, best: *?Sample) !void {
    const process = try proc.openDir(io, name, .{});
    defer process.close(io);
    var stat_buffer: [4096]u8 = undefined;
    const stat = try read_proc(io, process, "stat", &stat_buffer);
    if (process_group(stat) != pgid) return;
    const fds = try process.openDir(io, "fd", .{ .iterate = true });
    defer fds.close(io);
    var entries = fds.iterate();
    while (try entries.next(io)) |entry| {
        const fd = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        var candidate = (inspect(io, process, entry.name, pid, fd) catch |err| {
            if (err == error.Canceled) return err;
            continue;
        }) orelse continue;
        if (best.*) |previous| if (!candidate.preferred(previous)) continue;
        var link_buffer: [4096]u8 = undefined;
        const len = fds.readLink(io, entry.name, &link_buffer) catch |err| {
            if (err == error.Canceled) return err;
            continue;
        };
        const basename = std.fs.path.basename(link_buffer[0..len]);
        candidate.name_len = @min(basename.len, candidate.name.len);
        @memcpy(candidate.name[0..candidate.name_len], basename[0..candidate.name_len]);
        best.* = candidate;
    }
}

fn inspect(io: std.Io, process: std.Io.Dir, name: []const u8, pid: std.posix.pid_t, fd: u32) !?Sample {
    var path_buffer: [64]u8 = undefined;
    const info_path = try std.fmt.bufPrint(&path_buffer, "fdinfo/{s}", .{name});
    var info_buffer: [4096]u8 = undefined;
    const info = parse_fd_info(try read_proc(io, process, info_path, &info_buffer)) orelse return null;
    // Write-only, read/write, and O_PATH descriptors cannot establish an
    // input size. In particular, a growing output must not show 100% forever.
    if (info.flags & 3 != 0 or info.flags & 0o10000000 != 0) return null;
    const fd_path = try std.fmt.bufPrint(&path_buffer, "fd/{s}", .{name});
    // Stat the proc link; never open or read the child's file itself.
    const stat = try process.statFile(io, fd_path, .{});
    if (stat.kind != .file or stat.size == 0) return null;
    return .{ .position = info.position, .size = stat.size, .pid = pid, .fd = fd };
}

const FdInfo = struct { position: u64, flags: u64 };

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
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        if (std.mem.eql(u8, key, "pos")) {
            position = std.fmt.parseInt(u64, value, 10) catch return null;
        } else if (std.mem.eql(u8, key, "flags")) {
            flags = std.fmt.parseInt(u64, value, 8) catch return null;
        }
    }
    return .{ .position = position orelse return null, .flags = flags orelse return null };
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
    const limit = counts(std.math.maxInt(u64) / 2, std.math.maxInt(u64));
    try std.testing.expectEqual(limit.total / 2 - 1, limit.completed);
    try std.testing.expect(limit.total <= max_count);
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
