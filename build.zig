const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // vendored libyaml（MIT，见 vendor/libyaml/LICENSE）：完整 YAML 1.1 解析。
    // 0.17 起 @cImport 移除，改为 translate-c 生成 Zig 模块。
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/libyaml/include/yaml.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(b.path("vendor/libyaml/include"));
    const c_module = translate_c.createModule();

    const exe = b.addExecutable(.{
        .name = "node2outbound",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.link_libc = true;
    exe.root_module.addCSourceFiles(.{
        .files = &.{
            "vendor/libyaml/src/api.c",
            "vendor/libyaml/src/parser.c",
            "vendor/libyaml/src/reader.c",
            "vendor/libyaml/src/scanner.c",
        },
    });
    exe.root_module.addIncludePath(b.path("vendor/libyaml/include"));
    exe.root_module.addImport("c", c_module);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
