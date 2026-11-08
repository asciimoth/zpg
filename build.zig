const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zpg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const unit = b.addRunArtifact(tests);
    const integration = b.addSystemCommand(&.{ "python3", "test/integration.py" });
    integration.addArtifactArg(exe);
    const test_step = b.step("test", "Run unit and integration checks (requires Python 3)");
    test_step.dependOn(&unit.step);
    test_step.dependOn(&integration.step);

    const run_step = b.step("run", "Run zpg");
    run_step.dependOn(&run.step);
}
