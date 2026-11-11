const std = @import("std");

const max_expanded_bytes = 8 * 1024 * 1024;

pub const Task = struct {
    name: ?[]const u8 = null,
    command: []const []const u8,
    guess: bool = false,
};

pub const Config = struct {
    @"$schema": ?[]const u8 = null,
    tasks: []Task,
    stop_on_first_finish: bool = false,
};

// The caller owns an arena. Parse and expand the whole file before any spawn.
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8, values: []const []const u8) !Config {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    return parse(allocator, bytes, values);
}

fn parse(allocator: std.mem.Allocator, bytes: []const u8, values: []const []const u8) !Config {
    const config = try std.json.parseFromSliceLeaky(Config, allocator, bytes, .{ .allocate = .alloc_always });
    if (config.tasks.len == 0) return error.EmptyTasks;
    if (config.tasks.len > std.math.maxInt(u32) / 2) return error.TooManyTasks;
    var remaining: usize = max_expanded_bytes;
    for (config.tasks) |*task| {
        if (task.command.len == 0) return error.EmptyCommand;
        if (task.name) |name| {
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidTaskName;
        }
        const command = try allocator.alloc([]const u8, task.command.len);
        for (task.command, command) |arg, *expanded| {
            // Count the terminating NUL too, including for empty arguments.
            if (remaining == 0) return error.TaskArgumentsTooLarge;
            expanded.* = try substitute(allocator, arg, values, remaining - 1);
            remaining -= expanded.len + 1;
            if (std.mem.indexOfScalar(u8, expanded.*, 0) != null) return error.InvalidCommandArgument;
        }
        if (command[0].len == 0) return error.EmptyCommand;
        task.command = command;
    }
    return config;
}

fn substitute(allocator: std.mem.Allocator, arg: []const u8, values: []const []const u8, limit: usize) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, arg, offset, "{{.")) |start| {
        try append(allocator, &result, arg[offset..start], limit);
        const end = std.mem.indexOfPos(u8, arg, start + 3, "}}") orelse return error.InvalidTaskTemplate;
        const digits = arg[start + 3 .. end];
        if (digits.len == 0 or digits[0] == '0') return error.InvalidTaskTemplate;
        for (digits) |digit| if (digit < '0' or digit > '9') return error.InvalidTaskTemplate;
        const index = std.fmt.parseInt(usize, digits, 10) catch return error.InvalidTaskTemplate;
        if (index > values.len) return error.MissingTaskArgument;
        try append(allocator, &result, values[index - 1], limit);
        offset = end + 2;
    }
    try append(allocator, &result, arg[offset..], limit);
    return result.toOwnedSlice(allocator);
}

fn append(allocator: std.mem.Allocator, result: *std.ArrayList(u8), bytes: []const u8, limit: usize) !void {
    // Check before allocating: a small file can repeat a large value many times.
    if (bytes.len > limit - result.items.len) return error.TaskArgumentsTooLarge;
    try result.appendSlice(allocator, bytes);
}

test "task arguments expand literally and only once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config = try parse(arena.allocator(),
        \\{"$schema":"tasks.schema.json","tasks":[{"name":"copy","command":["cp","{{.1}}/{{.2}}","{{.1}}","{{.3}}"],"guess":true}],"stop_on_first_finish":true}
    , &.{ "a b;$HOME", "{{.1}}", "" });
    try std.testing.expect(config.stop_on_first_finish and config.tasks[0].guess);
    try std.testing.expectEqualStrings("a b;$HOME/{{.1}}", config.tasks[0].command[1]);
    try std.testing.expectEqualStrings("a b;$HOME", config.tasks[0].command[2]);
    try std.testing.expectEqualStrings("", config.tasks[0].command[3]);
}

test "invalid task files fail before execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.EmptyTasks, parse(allocator, "{\"tasks\":[]}", &.{}));
    try std.testing.expectError(error.EmptyCommand, parse(allocator, "{\"tasks\":[{\"command\":[]}]}", &.{}));
    try std.testing.expectError(error.UnknownField, parse(allocator, "{\"tasks\":[],\"typo\":true}", &.{}));
    try std.testing.expectError(error.InvalidCommandArgument, parse(allocator, "{\"tasks\":[{\"command\":[\"a\\u0000b\"]}]}", &.{}));
    for ([_][]const u8{ "{{.0}}", "{{.01}}", "{{.-1}}", "{{.}}", "{{.1", "{{.a}}" }) |arg| {
        try std.testing.expectError(error.InvalidTaskTemplate, substitute(allocator, arg, &.{"ok"}, max_expanded_bytes));
    }
    try std.testing.expectError(error.MissingTaskArgument, substitute(allocator, "{{.2}}", &.{"ok"}, max_expanded_bytes));
}

test "task expansion checks literal and inserted bytes before allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("abab", try substitute(allocator, "{{.1}}{{.1}}", &.{"ab"}, 4));
    for ([_][]const u8{ "{{.1}}{{.1}}", "ab{{.1}}", "{{.1}}ab", "abcd" }) |arg| {
        try std.testing.expectError(error.TaskArgumentsTooLarge, substitute(allocator, arg, &.{"ab"}, 3));
    }
    try std.testing.expectEqualStrings("", try substitute(allocator, "{{.1}}", &.{""}, 0));
}
