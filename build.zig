const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const json_module = b.addModule("json", .{
        .root_source_file = b.path("src/json.zig"),
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/json.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    // JSONTestSuite (github.com/nst/JSONTestSuite), the conformance suite most
    // JSON parsers are measured against. Its cases are vendored under
    // test/JSONTestSuite; see the README there for why.
    const conformance = b.addExecutable(.{
        .name = "conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/conformance.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    conformance.root_module.addImport("json", json_module);

    const options = b.addOptions();
    options.addOptionPath("suite_path", b.path("test/JSONTestSuite/test_parsing"));
    conformance.root_module.addOptions("build_options", options);

    const run_conformance = b.addRunArtifact(conformance);
    if (b.args) |args| run_conformance.addArgs(args);

    const conformance_step = b.step("conformance", "Run the JSONTestSuite conformance suite");
    conformance_step.dependOn(&run_conformance.step);
}
