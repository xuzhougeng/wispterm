const std = @import("std");
const builtin = @import("builtin");
const process_runner = @import("../process_runner.zig");
const tool_registry = @import("registry.zig");

pub const PROBE_TIMEOUT_MS: u32 = 3000;
pub const PROBE_OUTPUT_LIMIT: u32 = 64 * 1024;

pub const DocSource = enum { skill_flag, sibling_skill, generated_from_help, ai_draft };

pub const ResolveDocsInput = struct {
    tool_name: []const u8,
    help_output: []const u8,
    skill_output: []const u8,
    sibling_skill: ?[]const u8,
    ai_draft: ?[]const u8,
};

pub const ResolvedDocs = struct {
    source: DocSource,
    skill_md: []u8,
};

pub const ProbeOutput = struct {
    help: []u8,
    skill: []u8,

    pub fn deinit(self: *ProbeOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.help);
        allocator.free(self.skill);
        self.* = undefined;
    }
};

pub fn resolveDocs(allocator: std.mem.Allocator, input: ResolveDocsInput) !ResolvedDocs {
    const skill = trimAscii(input.skill_output);
    if (skill.len != 0) {
        return .{ .source = .skill_flag, .skill_md = try allocator.dupe(u8, skill) };
    }

    if (input.sibling_skill) |sibling_raw| {
        const sibling = trimAscii(sibling_raw);
        if (sibling.len != 0) {
            return .{ .source = .sibling_skill, .skill_md = try allocator.dupe(u8, sibling) };
        }
    }

    const help = trimAscii(input.help_output);
    if (help.len != 0) {
        const description = firstUsefulLine(help, 180) orelse input.tool_name;
        return .{
            .source = .generated_from_help,
            .skill_md = try tool_registry.generateSkillMdFromHelp(allocator, .{
                .name = input.tool_name,
                .description = description,
                .help = help,
            }),
        };
    }

    if (input.ai_draft) |draft_raw| {
        const draft = trimAscii(draft_raw);
        if (draft.len != 0) {
            return .{
                .source = .ai_draft,
                .skill_md = try tool_registry.generateSkillMdFromAiDraft(
                    allocator,
                    input.tool_name,
                    "No --help, --skill, or sibling SKILL.md was available.",
                    draft,
                ),
            };
        }
    }

    return error.MissingToolDocumentation;
}

pub fn probeBinary(allocator: std.mem.Allocator, binary_path: []const u8) !ProbeOutput {
    try validateLaunchableBinaryPath(binary_path);
    const help = try runArgvProbe(allocator, &.{ binary_path, "--help" });
    errdefer allocator.free(help);
    const skill = try runArgvProbe(allocator, &.{ binary_path, "--skill" });
    return .{ .help = help, .skill = skill };
}

pub fn readSiblingSkillMd(allocator: std.mem.Allocator, binary_path: []const u8) ?[]u8 {
    const parent = std.fs.path.dirname(binary_path) orelse ".";
    const skill_path = std.fs.path.join(allocator, &.{ parent, "SKILL.md" }) catch return null;
    defer allocator.free(skill_path);
    var file = openFileAny(skill_path) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, tool_registry.MAX_SKILL_MD_BYTES) catch null;
}

pub fn sha256FileHex(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try openFileAny(path);
    defer file.close();
    const hex = try allocator.alloc(u8, 64);
    errdefer allocator.free(hex);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const stack_hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(hex, &stack_hex);
    return hex;
}

pub fn installToolPackageWithSource(
    allocator: std.mem.Allocator,
    tools_root: []const u8,
    source_binary_path: []const u8,
    manifest_source_path: []const u8,
    function_name: []const u8,
    skill_md: []const u8,
    enabled: bool,
) ![]u8 {
    try tool_registry.validateImportedFunctionName(function_name);
    try validatePackageName(function_name);
    const basename = std.fs.path.basename(source_binary_path);
    try validatePackageName(basename);

    try ensureDirAbsolute(tools_root);

    const target = try std.fs.path.join(allocator, &.{ tools_root, function_name });
    errdefer allocator.free(target);
    if (pathExists(target)) return error.ToolAlreadyExists;

    const staging_name = try std.fmt.allocPrint(allocator, ".staging-{s}", .{function_name});
    defer allocator.free(staging_name);
    const staging = try std.fs.path.join(allocator, &.{ tools_root, staging_name });
    defer allocator.free(staging);
    std.fs.deleteTreeAbsolute(staging) catch {};
    errdefer std.fs.deleteTreeAbsolute(staging) catch {};

    const bin_dir = try std.fs.path.join(allocator, &.{ staging, "bin" });
    defer allocator.free(bin_dir);
    try ensureDirAbsolute(bin_dir);

    const dest_binary = try std.fs.path.join(allocator, &.{ bin_dir, basename });
    defer allocator.free(dest_binary);
    try copyFilePreserveMode(source_binary_path, dest_binary);

    const skill_path = try std.fs.path.join(allocator, &.{ staging, "SKILL.md" });
    defer allocator.free(skill_path);
    try writeFileAbsolute(skill_path, skill_md);

    const executable_rel = try std.fmt.allocPrint(allocator, "bin/{s}", .{basename});
    defer allocator.free(executable_rel);
    const sha256 = try sha256FileHex(allocator, source_binary_path);
    defer allocator.free(sha256);
    const description = manifestDescription(skill_md);
    const manifest_json = try tool_registry.manifestToJson(allocator, .{
        .id = function_name,
        .function_name = function_name,
        .enabled = enabled,
        .executable = executable_rel,
        .source_path = manifest_source_path,
        .sha256 = sha256,
        .imported_at_ms = std.time.milliTimestamp(),
        .description = description,
    });
    defer allocator.free(manifest_json);

    const manifest_path = try std.fs.path.join(allocator, &.{ staging, "manifest.json" });
    defer allocator.free(manifest_path);
    try writeFileAbsolute(manifest_path, manifest_json);

    std.fs.renameAbsolute(staging, target) catch |err| switch (err) {
        error.PathAlreadyExists => return error.ToolAlreadyExists,
        else => return err,
    };
    return target;
}

pub fn cleanupStagedBinaryPath(staged_binary_path: []const u8) void {
    const stage_root = stageRootFromStagedBinaryPath(staged_binary_path) orelse return;
    std.fs.deleteTreeAbsolute(stage_root) catch {};
}

/// Probe a tool binary for `--help` / `--skill` output. Migrated onto the
/// unified `process_runner.runCapture`, which owns the whole lifecycle:
/// concurrent stdout/stderr drain (no pipe deadlock), the 3s timeout, and
/// reaping the child exactly once. External behavior is preserved verbatim:
///   • timeout  → return "" (probe yielded nothing usable)
///   • nonzero exit → return ""
///   • exit 0 → return stdout if it is non-empty or stderr is empty; otherwise
///     fall back to the (trimmed-at-cap) stderr text
///   • each stream is capped at PROBE_OUTPUT_LIMIT bytes
fn runArgvProbe(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = process_runner.runCapture(allocator, argv, .{
        .timeout_ms = PROBE_TIMEOUT_MS,
        .max_stdout_bytes = PROBE_OUTPUT_LIMIT,
        .max_stderr_bytes = PROBE_OUTPUT_LIMIT,
    }) catch |err| switch (err) {
        error.SpawnFailed => return error.ProbeSpawnFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    // `result` owns two heap slices; free whichever we do not hand back.
    const stdout_data = result.stdout;
    const stderr_data = result.stderr;
    const exited_zero = switch (result.termination) {
        .exited => |code| code == 0,
        .killed => false,
    };

    if (result.timed_out or result.cancelled or !exited_zero) {
        allocator.free(stdout_data);
        allocator.free(stderr_data);
        return allocator.dupe(u8, "");
    }

    if (stdout_data.len != 0 or stderr_data.len == 0) {
        allocator.free(stderr_data);
        return stdout_data;
    }
    allocator.free(stdout_data);
    return stderr_data;
}

fn setProcessUmask(mode: std.posix.mode_t) std.posix.mode_t {
    return switch (builtin.os.tag) {
        .windows => unreachable,
        .linux => @intCast(std.os.linux.syscall1(.umask, mode)),
        else => std.c.umask(mode),
    };
}

fn trimAscii(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r\n");
}

fn firstUsefulLine(bytes: []const u8, max_bytes: usize) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = trimAscii(line_raw);
        if (line.len == 0) continue;
        return line[0..@min(line.len, max_bytes)];
    }
    return null;
}

fn manifestDescription(skill_md: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, skill_md, '\n');
    while (lines.next()) |line_raw| {
        const line = trimAscii(line_raw);
        if (std.mem.startsWith(u8, line, "description:")) {
            const value = trimAscii(line["description:".len..]);
            if (value.len != 0) return value[0..@min(value.len, tool_registry.MAX_TOOL_DESCRIPTION_BYTES)];
        }
    }
    if (firstUsefulLine(skill_md, tool_registry.MAX_TOOL_DESCRIPTION_BYTES)) |line| return line;
    return "Local executable tool";
}

fn validatePackageName(name: []const u8) !void {
    if (name.len == 0) return error.UnsafeToolPath;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.UnsafeToolPath;
    if (name[0] == '/' or name[0] == '\\') return error.UnsafeToolPath;
    if (name.len >= 2 and std.ascii.isAlphabetic(name[0]) and name[1] == ':') return error.UnsafeToolPath;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.UnsafeToolPath;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return error.UnsafeToolPath;
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn ensureDirAbsolute(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return err;
            try ensureDirAbsolute(parent);
            std.fs.makeDirAbsolute(path) catch |err2| switch (err2) {
                error.PathAlreadyExists => {},
                else => return err2,
            };
        },
        else => return err,
    };
}

fn openFileAny(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.openFileAbsolute(path, .{});
    return std.fs.cwd().openFile(path, .{});
}

fn validateLaunchableBinaryPath(path: []const u8) !void {
    var file = openFileAny(path) catch return error.ProbeSpawnFailed;
    defer file.close();
    const stat = file.stat() catch return error.ProbeSpawnFailed;
    if (stat.kind != .file) return error.ProbeSpawnFailed;
    if (builtin.os.tag != .windows and (stat.mode & 0o111) == 0) return error.ProbeSpawnFailed;
}

fn createFileAbsolute(path: []const u8, mode: std.fs.File.Mode) !std.fs.File {
    return std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = mode });
}

fn writeFileAbsolute(path: []const u8, data: []const u8) !void {
    var file = try createFileAbsolute(path, std.fs.File.default_mode);
    defer file.close();
    try file.writeAll(data);
}

pub fn copyFilePreserveMode(src_path: []const u8, dst_path: []const u8) !void {
    var src = try openFileAny(src_path);
    defer src.close();
    const src_mode = if (builtin.os.tag == .windows) std.fs.File.default_mode else (try src.stat()).mode & 0o7777;
    var dst = try createFileAbsolute(dst_path, src_mode);
    defer dst.close();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try src.read(&buf);
        if (n == 0) break;
        try dst.writeAll(buf[0..n]);
    }
    if (builtin.os.tag != .windows) try dst.chmod(src_mode);
}

fn stageRootFromStagedBinaryPath(staged_binary_path: []const u8) ?[]const u8 {
    const bin_dir = std.fs.path.dirname(staged_binary_path) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basename(bin_dir), "bin")) return null;
    return std.fs.path.dirname(bin_dir);
}

test "tool_import: resolveDocs prefers --skill over sibling skill and help" {
    const a = std.testing.allocator;
    const docs = try resolveDocs(a, .{
        .tool_name = "docx",
        .help_output = "help text",
        .skill_output = "---\nname: docx\n---\nAuthor skill.",
        .sibling_skill = "---\nname: docx\n---\nSibling skill.",
        .ai_draft = null,
    });
    defer a.free(docs.skill_md);
    try std.testing.expectEqual(DocSource.skill_flag, docs.source);
    try std.testing.expect(std.mem.indexOf(u8, docs.skill_md, "Author skill") != null);
}

test "tool_import: resolveDocs uses sibling SKILL.md when --skill is unavailable" {
    const a = std.testing.allocator;
    const docs = try resolveDocs(a, .{
        .tool_name = "docx",
        .help_output = "help text",
        .skill_output = "",
        .sibling_skill = "---\nname: docx\n---\nSibling skill.",
        .ai_draft = null,
    });
    defer a.free(docs.skill_md);
    try std.testing.expectEqual(DocSource.sibling_skill, docs.source);
}

test "tool_import: resolveDocs generates deterministic skill from help" {
    const a = std.testing.allocator;
    const docs = try resolveDocs(a, .{
        .tool_name = "docx",
        .help_output = "docx edits files\nUsage: docx review input output",
        .skill_output = "",
        .sibling_skill = null,
        .ai_draft = null,
    });
    defer a.free(docs.skill_md);
    try std.testing.expectEqual(DocSource.generated_from_help, docs.source);
    try std.testing.expect(std.mem.indexOf(u8, docs.skill_md, "Usage: docx review") != null);
}

test "tool_import: resolveDocs accepts AI draft when no authored docs exist" {
    const a = std.testing.allocator;
    const docs = try resolveDocs(a, .{
        .tool_name = "mystery",
        .help_output = "",
        .skill_output = "",
        .sibling_skill = null,
        .ai_draft = "Use cautiously after the user explains what arguments are needed.",
    });
    defer a.free(docs.skill_md);
    try std.testing.expectEqual(DocSource.ai_draft, docs.source);
    try std.testing.expect(std.mem.indexOf(u8, docs.skill_md, "limited metadata") != null);
}

test "tool_import: resolveDocs blocks when no docs and no AI draft exist" {
    try std.testing.expectError(error.MissingToolDocumentation, resolveDocs(std.testing.allocator, .{
        .tool_name = "mystery",
        .help_output = "",
        .skill_output = "",
        .sibling_skill = null,
        .ai_draft = null,
    }));
}

test "tool_import: sha256FileHex streams lowercase digest" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "payload.bin", .data = "abc" });
    const path = try tmp.dir.realpathAlloc(a, "payload.bin");
    defer a.free(path);

    const hex = try sha256FileHex(a, path);
    defer a.free(hex);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hex);
}

test "tool_import: readSiblingSkillMd reads SKILL.md beside binary" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "tool", .data = "bin" });
    try tmp.dir.writeFile(.{ .sub_path = "SKILL.md", .data = "---\nname: tool\n---\nSibling docs.\n" });
    const binary_path = try tmp.dir.realpathAlloc(a, "tool");
    defer a.free(binary_path);

    const skill = readSiblingSkillMd(a, binary_path) orelse return error.ExpectedSiblingSkill;
    defer a.free(skill);
    try std.testing.expect(std.mem.indexOf(u8, skill, "Sibling docs") != null);
}

test "tool_import: installToolPackage stages package with manifest and binary" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.makePath("tools");
    try tmp.dir.writeFile(.{ .sub_path = "src/docx", .data = "binary bytes" });
    const source_path = try tmp.dir.realpathAlloc(a, "src/docx");
    defer a.free(source_path);
    const tools_root = try tmp.dir.realpathAlloc(a, "tools");
    defer a.free(tools_root);

    const installed = try installToolPackageWithSource(
        a,
        tools_root,
        source_path,
        source_path,
        "docx",
        "---\nname: docx\ndescription: DOCX helper\n---\nUse docs.\n",
        true,
    );
    defer a.free(installed);
    const expected_dir = try std.fs.path.join(a, &.{ tools_root, "docx" });
    defer a.free(expected_dir);
    try std.testing.expectEqualStrings(expected_dir, installed);

    const copied_path = try std.fs.path.join(a, &.{ installed, "bin", "docx" });
    defer a.free(copied_path);
    const copied = try std.fs.cwd().readFileAlloc(a, copied_path, 1024);
    defer a.free(copied);
    try std.testing.expectEqualStrings("binary bytes", copied);

    const manifest_path = try std.fs.path.join(a, &.{ installed, "manifest.json" });
    defer a.free(manifest_path);
    const manifest_json = try std.fs.cwd().readFileAlloc(a, manifest_path, 16 * 1024);
    defer a.free(manifest_json);
    var manifest = try tool_registry.parseManifestJson(a, manifest_json);
    defer manifest.deinit(a);
    try std.testing.expectEqualStrings("docx", manifest.id);
    try std.testing.expectEqualStrings("docx", manifest.function_name);
    try std.testing.expect(manifest.enabled);
    try std.testing.expectEqualStrings("bin/docx", manifest.executable);
    try std.testing.expectEqualStrings(source_path, manifest.source_path);

    try std.testing.expectError(error.ToolAlreadyExists, installToolPackageWithSource(
        a,
        tools_root,
        source_path,
        source_path,
        "docx",
        "---\nname: docx\n---\nUse docs.\n",
        false,
    ));
}

test "tool_import: installToolPackageWithSource keeps original source metadata while installing staged bytes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.makePath("stage/bin");
    try tmp.dir.makePath("tools");
    try tmp.dir.writeFile(.{ .sub_path = "src/docx", .data = "original bytes" });
    try tmp.dir.writeFile(.{ .sub_path = "stage/bin/docx", .data = "staged bytes" });
    const original_path = try tmp.dir.realpathAlloc(a, "src/docx");
    defer a.free(original_path);
    const staged_path = try tmp.dir.realpathAlloc(a, "stage/bin/docx");
    defer a.free(staged_path);
    const tools_root = try tmp.dir.realpathAlloc(a, "tools");
    defer a.free(tools_root);

    const installed = try installToolPackageWithSource(
        a,
        tools_root,
        staged_path,
        original_path,
        "docx",
        "---\nname: docx\ndescription: DOCX helper\n---\nUse docs.\n",
        false,
    );
    defer a.free(installed);

    const copied_path = try std.fs.path.join(a, &.{ installed, "bin", "docx" });
    defer a.free(copied_path);
    const copied = try std.fs.cwd().readFileAlloc(a, copied_path, 1024);
    defer a.free(copied);
    try std.testing.expectEqualStrings("staged bytes", copied);

    const manifest_path = try std.fs.path.join(a, &.{ installed, "manifest.json" });
    defer a.free(manifest_path);
    const manifest_json = try std.fs.cwd().readFileAlloc(a, manifest_path, 16 * 1024);
    defer a.free(manifest_json);
    var manifest = try tool_registry.parseManifestJson(a, manifest_json);
    defer manifest.deinit(a);
    try std.testing.expectEqualStrings(original_path, manifest.source_path);

    const staged_sha = try sha256FileHex(a, staged_path);
    defer a.free(staged_sha);
    try std.testing.expectEqualStrings(staged_sha, manifest.sha256);
}

test "tool_import: runArgvProbe is bounded when child leaves inherited pipes open" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script =
        "#!/bin/sh\n" ++
        "if [ \"$1\" = \"--help\" ]; then\n" ++
        "  ( sleep 2 ) &\n" ++
        "  printf 'help text\\n'\n" ++
        "  exit 0\n" ++
        "fi\n" ++
        "exit 1\n";
    try tmp.dir.writeFile(.{ .sub_path = "probe.sh", .data = script });
    var file = try tmp.dir.openFile("probe.sh", .{});
    defer file.close();
    try file.chmod(0o755);
    const script_path = try tmp.dir.realpathAlloc(a, "probe.sh");
    defer a.free(script_path);

    const started = std.time.milliTimestamp();
    const output = try runArgvProbe(a, &.{ script_path, "--help" });
    defer a.free(output);
    const elapsed = std.time.milliTimestamp() - started;

    try std.testing.expectEqualStrings("help text\n", output);
    try std.testing.expect(elapsed < 1000);
}

test "tool_import: runArgvProbe owns no hand-rolled spawn/drain/wait" {
    // The lifecycle now lives entirely in process_runner.runCapture; tool_import
    // must not reach for the raw child primitives again. (Full-range Windows
    // exit codes no longer narrow-panic because runCapture surfaces them as a
    // u32 Termination.exited, mapped to "" here via the !exited_zero branch.)
    const source = @embedFile("import.zig");
    // Split the needles so this guard's own source does not match them.
    const raw_spawn = "std.process." ++ "Child.init";
    const runner_call = "process_runner." ++ "runCapture";
    try std.testing.expect(std.mem.indexOf(u8, source, raw_spawn) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, runner_call) != null);
}

test "tool_import: runArgvProbe maps a nonzero exit to empty output" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script =
        "#!/bin/sh\n" ++
        "printf 'noise\\n'\n" ++
        "exit 7\n";
    try tmp.dir.writeFile(.{ .sub_path = "probe-fail.sh", .data = script });
    var file = try tmp.dir.openFile("probe-fail.sh", .{});
    defer file.close();
    try file.chmod(0o755);
    const script_path = try tmp.dir.realpathAlloc(a, "probe-fail.sh");
    defer a.free(script_path);

    const output = try runArgvProbe(a, &.{ script_path, "--help" });
    defer a.free(output);
    try std.testing.expectEqual(@as(usize, 0), output.len);
}

test "tool_import: runArgvProbe falls back to stderr when stdout is empty" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script =
        "#!/bin/sh\n" ++
        "printf 'help via stderr\\n' 1>&2\n" ++
        "exit 0\n";
    try tmp.dir.writeFile(.{ .sub_path = "probe-stderr.sh", .data = script });
    var file = try tmp.dir.openFile("probe-stderr.sh", .{});
    defer file.close();
    try file.chmod(0o755);
    const script_path = try tmp.dir.realpathAlloc(a, "probe-stderr.sh");
    defer a.free(script_path);

    const output = try runArgvProbe(a, &.{ script_path, "--help" });
    defer a.free(output);
    try std.testing.expectEqualStrings("help via stderr\n", output);
}

test "tool_import: probeBinary treats capped nonzero help output as empty" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const script =
        "#!/bin/sh\n" ++
        "if [ \"$1\" = \"--help\" ]; then\n" ++
        "  i=0\n" ++
        "  while [ \"$i\" -lt 70000 ]; do printf x; i=$((i + 1)); done\n" ++
        "  exit 7\n" ++
        "fi\n" ++
        "exit 1\n";
    try tmp.dir.writeFile(.{ .sub_path = "probe-big.sh", .data = script });
    var file = try tmp.dir.openFile("probe-big.sh", .{});
    defer file.close();
    try file.chmod(0o755);
    const script_path = try tmp.dir.realpathAlloc(a, "probe-big.sh");
    defer a.free(script_path);

    var probe = try probeBinary(a, script_path);
    defer probe.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), probe.help.len);
}

test "tool_import: probeBinary returns spawn failure for missing executable" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.ProbeSpawnFailed, probeBinary(a, "/definitely/missing/wispterm-tool-probe"));
}

test "tool_import: installToolPackage rejects reserved built-in function names" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.makePath("tools");
    try tmp.dir.writeFile(.{ .sub_path = "src/read-file", .data = "#!/bin/sh\nexit 0\n" });
    var source_file = try tmp.dir.openFile("src/read-file", .{});
    defer source_file.close();
    if (builtin.os.tag != .windows) try source_file.chmod(0o755);
    const source_path = try tmp.dir.realpathAlloc(a, "src/read-file");
    defer a.free(source_path);
    const tools_root = try tmp.dir.realpathAlloc(a, "tools");
    defer a.free(tools_root);

    try std.testing.expectError(error.ReservedToolName, installToolPackageWithSource(
        a,
        tools_root,
        source_path,
        source_path,
        "read_file",
        "---\nname: read_file\n---\nReserved.\n",
        false,
    ));
}

test "tool_import: installToolPackage preserves executable bits through restrictive umask" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.makePath("tools");
    try tmp.dir.writeFile(.{ .sub_path = "src/runme", .data = "#!/bin/sh\nexit 0\n" });
    var source_file = try tmp.dir.openFile("src/runme", .{});
    defer source_file.close();
    try source_file.chmod(0o755);
    const source_path = try tmp.dir.realpathAlloc(a, "src/runme");
    defer a.free(source_path);
    const tools_root = try tmp.dir.realpathAlloc(a, "tools");
    defer a.free(tools_root);

    const old_umask = setProcessUmask(0o077);
    defer _ = setProcessUmask(old_umask);
    const installed = try installToolPackageWithSource(
        a,
        tools_root,
        source_path,
        source_path,
        "runme",
        "---\nname: runme\n---\nUse runme.\n",
        true,
    );
    defer a.free(installed);

    const copied_path = try std.fs.path.join(a, &.{ installed, "bin", "runme" });
    defer a.free(copied_path);
    var copied = try std.fs.openFileAbsolute(copied_path, .{});
    defer copied.close();
    const mode = (try copied.stat()).mode;
    try std.testing.expectEqual(@as(std.fs.File.Mode, 0o755), mode & 0o777);
}
