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
    // macOS requires libSystem. Linux uses Zig's direct system calls.
    exe.root_module.link_libc = target.result.os.tag == .macos;
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const unit = b.addRunArtifact(tests);
    const integration = b.addSystemCommand(&.{ "python3", "test/integration.py" });
    integration.addArtifactArg(exe);
    const render_probe = b.addExecutable(.{
        .name = "render-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fixtures/render_probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration.addArtifactArg(render_probe);
    const terminal_tests = b.addSystemCommand(&.{ "python3", "test/terminal_output.py" });
    terminal_tests.addArtifactArg(exe);
    const test_step = b.step("test", "Run unit and integration checks (requires Python 3)");
    test_step.dependOn(&unit.step);
    test_step.dependOn(&integration.step);
    test_step.dependOn(&terminal_tests.step);

    const run_step = b.step("run", "Run zpg");
    run_step.dependOn(&run.step);
}
