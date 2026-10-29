const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version-string", "Override the version reported by --version") orelse
        resolveVersion(b, manifestVersion(b));

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "edidrandr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run edidrandr").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}

/// `.version` from build.zig.zon, the single source of truth for the version.
/// Read at build time on purpose: `@import("build.zig.zon")` would be baked
/// into the cached build runner, which Zig 0.15 doesn't rebuild when only the
/// manifest changes, so a version bump would go unnoticed.
fn manifestVersion(b: *std.Build) []const u8 {
    const source = b.build_root.handle.readFileAllocOptions(b.allocator, "build.zig.zon", 1 << 16, null, .of(u8), 0) catch |err|
        std.process.fatal("reading build.zig.zon: {t}", .{err});
    const Manifest = struct { version: []const u8 };
    const manifest = std.zon.parse.fromSlice(Manifest, b.allocator, source, null, .{ .ignore_unknown_fields = true }) catch |err|
        std.process.fatal("parsing build.zig.zon: {t}", .{err});
    return manifest.version;
}

/// The manifest version, refined with git information when available:
///   on tag v0.1.0, clean tree   -> 0.1.0
///   5 commits after v0.1.0      -> 0.1.0-dev.5+gabc1234
///   uncommitted changes         -> ...+gabc1234.dirty
///   no git / no matching tag    -> 0.1.0-dev+gabc1234 or plain 0.1.0
fn resolveVersion(b: *std.Build, manifest_version: []const u8) []const u8 {
    const root = b.build_root.path orelse ".";
    var code: u8 = undefined;
    const describe_raw = b.runAllowFail(
        &.{ "git", "-C", root, "describe", "--tags", "--match", "v*", "--long", "--dirty", "--abbrev=7" },
        &code,
        .Ignore,
    ) catch {
        const hash_raw = b.runAllowFail(&.{ "git", "-C", root, "rev-parse", "--short=7", "HEAD" }, &code, .Ignore) catch
            return manifest_version;
        return b.fmt("{s}-dev+g{s}", .{ manifest_version, std.mem.trim(u8, hash_raw, " \r\n") });
    };

    // <tag>-<commits>-g<hash>[-dirty]; the tag itself may contain dashes.
    var describe = std.mem.trim(u8, describe_raw, " \r\n");
    const dirty = std.mem.endsWith(u8, describe, "-dirty");
    if (dirty) describe = describe[0 .. describe.len - "-dirty".len];
    var parts = std.mem.splitBackwardsScalar(u8, describe, '-');
    const hash = parts.next() orelse return manifest_version;
    const commits = parts.next() orelse return manifest_version;
    const tag = parts.rest();
    const suffix = if (dirty) ".dirty" else "";

    if (!std.mem.eql(u8, tag[1..], manifest_version)) {
        // Building a clean checkout of a tag that disagrees with the manifest
        // means the release was tagged without bumping the version.
        if (std.mem.eql(u8, commits, "0") and !dirty) {
            std.process.fatal("git tag {s} does not match version {s} in build.zig.zon", .{ tag, manifest_version });
        }
        return b.fmt("{s}-dev+{s}{s}", .{ manifest_version, hash, suffix });
    }
    if (std.mem.eql(u8, commits, "0") and !dirty) return manifest_version;
    return b.fmt("{s}-dev.{s}+{s}{s}", .{ manifest_version, commits, hash, suffix });
}
