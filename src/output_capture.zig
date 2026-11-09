const std = @import("std");
const builtin = @import("builtin");

// Return the reader and the child's writer. Each output has its own capture
// device, even when stdout and stderr refer to the same terminal.
pub fn open(io: std.Io, destination: std.Io.File) ![2]std.Io.File {
    if (!try destination.isTty(io)) {
        const handles = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
        return .{ file(handles[0]), file(handles[1]) };
    }

    const master = try open_terminal("/dev/ptmx");
    errdefer master.close(io);
    var path_buffer: [128]u8 = undefined;
    const path = switch (builtin.os.tag) {
        .linux => blk: {
            var unlocked: c_int = 0;
            try control(io, master, std.posix.T.IOCSPTLCK, &unlocked);
            var number: c_uint = undefined;
            try control(io, master, std.posix.T.IOCGPTN, &number);
            break :blk try std.fmt.bufPrint(&path_buffer, "/dev/pts/{d}", .{number});
        },
        .macos => blk: {
            // Darwin sys/ttycom.h: TIOCPTYGRANT, TIOCPTYUNLK, TIOCPTYGNAME.
            // These constants are not exposed by Zig's std.posix.T.
            try control(io, master, 0x20007454, null);
            try control(io, master, 0x20007452, null);
            try control(io, master, 0x40807453, &path_buffer);
            break :blk std.mem.sliceTo(&path_buffer, 0);
        },
        else => @compileError("unsupported operating system"),
    };
    const slave = try open_terminal(path);
    errdefer slave.close(io);

    // No terminal output conversion: in particular, do not turn LF into CRLF.
    // The master is only read, so there is no terminal input to process.
    var attributes = try std.posix.tcgetattr(slave.handle);
    attributes.oflag.OPOST = false;
    attributes.lflag.ECHO = false;
    try std.posix.tcsetattr(slave.handle, .NOW, attributes);

    var size: std.posix.winsize = undefined;
    try control(io, destination, std.posix.T.IOCGWINSZ, &size);
    const set_size = if (builtin.os.tag == .macos) 0x80087467 else std.posix.T.IOCSWINSZ;
    try control(io, slave, set_size, &size);
    return .{ master, slave };
}

fn file(handle: std.posix.fd_t) std.Io.File {
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

fn open_terminal(path: []const u8) !std.Io.File {
    return file(try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .RDWR,
        .NOCTTY = true,
        .CLOEXEC = true,
    }, 0));
}

fn control(io: std.Io, terminal: std.Io.File, code: u32, arg: ?*anyopaque) !void {
    const result = (try io.operate(.{ .device_io_control = .{
        .file = terminal,
        .code = code,
        .arg = arg,
    } })).device_io_control;
    if (result < 0) return error.TerminalSetupFailed;
}
