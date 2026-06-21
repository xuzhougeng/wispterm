const std = @import("std");

pub const MAX_SKILL_MD_BYTES: usize = 256 * 1024;
pub const MAX_TOOL_DESCRIPTION_BYTES: usize = 4096;

const MAX_MANIFEST_BYTES: usize = 64 * 1024;

pub const ToolManifest = struct {
    id: []const u8,
    function_name: []const u8,
    enabled: bool,
    executable: []const u8,
    source_path: []const u8,
    sha256: []const u8,
    imported_at_ms: i64,
    description: []const u8,
};

pub const OwnedManifest = struct {
    id: []u8,
    function_name: []u8,
    enabled: bool,
    executable: []u8,
    source_path: []u8,
    sha256: []u8,
    imported_at_ms: i64,
    description: []u8,

    pub fn deinit(self: *OwnedManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.function_name);
        allocator.free(self.executable);
        allocator.free(self.source_path);
        allocator.free(self.sha256);
        allocator.free(self.description);
        self.* = undefined;
    }
};

pub const InstalledTool = struct {
    id: []u8,
    function_name: []u8,
    enabled: bool,
    executable_abs: []u8,
    skill_md: []u8,
    description: []u8,

    pub fn deinit(self: *const InstalledTool, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.function_name);
        allocator.free(self.executable_abs);
        allocator.free(self.skill_md);
        allocator.free(self.description);
    }
};

pub const GenerateHelpInput = struct {
    name: []const u8,
    description: []const u8,
    help: []const u8,
};

pub fn sanitizeFunctionName(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const without_exe = stripExeSuffix(raw);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var prev_underscore = false;
    for (without_exe) |byte| {
        const ch: u8 = if (byte >= 'A' and byte <= 'Z')
            byte + ('a' - 'A')
        else if ((byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9'))
            byte
        else
            '_';

        if (ch == '_') {
            if (prev_underscore) continue;
            prev_underscore = true;
        } else {
            prev_underscore = false;
        }
        try out.append(allocator, ch);
    }

    if (out.items.len == 0) {
        try out.appendSlice(allocator, "tool");
    } else if (!isValidFirstFunctionByte(out.items[0])) {
        try out.insertSlice(allocator, 0, "tool_");
    }

    return out.toOwnedSlice(allocator);
}

pub fn generateSkillMdFromHelp(allocator: std.mem.Allocator, input: GenerateHelpInput) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "---\nname: {s}\ndescription: {s}\n---\n\n" ++
            "# {s}\n\n" ++
            "Use this executable tool when the task matches the help text below.\n\n" ++
            "## Invocation\n\n" ++
            "Call the `{s}` tool with an `args` array containing the command-line arguments that should follow the executable name. Do not include the executable name itself.\n\n" ++
            "## Help\n\n" ++
            "```text\n{s}\n```\n",
        .{ input.name, input.description, input.name, input.name, input.help },
    );
}

pub fn generateSkillMdFromAiDraft(
    allocator: std.mem.Allocator,
    name: []const u8,
    evidence: []const u8,
    draft: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "---\nname: {s}\ndescription: Local executable tool imported into WispTerm\n---\n\n" ++
            "# {s}\n\n" ++
            "This tool was imported from a binary without `--skill`, `--help`, or a packaged `SKILL.md`. The description below is an AI-generated draft from limited metadata and must be corrected by the user before relying on it.\n\n" ++
            "## Invocation\n\n" ++
            "Call the `{s}` tool with an `args` array containing the command-line arguments that should follow the executable name. Do not include the executable name itself.\n\n" ++
            "## Known Evidence\n\n" ++
            "```text\n{s}\n```\n\n" ++
            "## Usage Notes\n\n" ++
            "{s}\n",
        .{ name, name, name, evidence, draft },
    );
}

pub fn manifestToJson(allocator: std.mem.Allocator, manifest: ToolManifest) ![]u8 {
    const JsonManifest = struct {
        kind: []const u8 = "binary_tool",
        id: []const u8,
        function_name: []const u8,
        enabled: bool,
        executable: []const u8,
        source_path: []const u8,
        sha256: []const u8,
        imported_at_ms: i64,
        description: []const u8,
    };

    return std.json.Stringify.valueAlloc(allocator, JsonManifest{
        .id = manifest.id,
        .function_name = manifest.function_name,
        .enabled = manifest.enabled,
        .executable = manifest.executable,
        .source_path = manifest.source_path,
        .sha256 = manifest.sha256,
        .imported_at_ms = manifest.imported_at_ms,
        .description = manifest.description,
    }, .{ .whitespace = .indent_2 });
}

pub fn parseManifestJson(allocator: std.mem.Allocator, bytes: []const u8) !OwnedManifest {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolManifest;

    if (parsed.value.object.get("kind")) |kind_value| {
        if (kind_value != .string) return error.InvalidToolManifest;
        if (!std.mem.eql(u8, kind_value.string, "binary_tool")) return error.InvalidToolManifest;
    }

    const id = jsonString(parsed.value, "id") orelse return error.InvalidToolManifest;
    const function_name = jsonString(parsed.value, "function_name") orelse return error.InvalidToolManifest;
    const executable = jsonString(parsed.value, "executable") orelse return error.InvalidToolManifest;
    if (id.len == 0 or function_name.len == 0 or executable.len == 0) return error.InvalidToolManifest;

    var owned = OwnedManifest{
        .id = try allocator.dupe(u8, id),
        .function_name = &.{},
        .enabled = jsonBool(parsed.value, "enabled"),
        .executable = &.{},
        .source_path = &.{},
        .sha256 = &.{},
        .imported_at_ms = jsonI64(parsed.value, "imported_at_ms") orelse 0,
        .description = &.{},
    };
    errdefer owned.deinit(allocator);

    owned.function_name = try allocator.dupe(u8, function_name);
    owned.executable = try allocator.dupe(u8, executable);
    owned.source_path = try allocator.dupe(u8, jsonString(parsed.value, "source_path") orelse "");
    owned.sha256 = try allocator.dupe(u8, jsonString(parsed.value, "sha256") orelse "");
    const description = jsonString(parsed.value, "description") orelse "";
    if (description.len > MAX_TOOL_DESCRIPTION_BYTES) return error.ToolDescriptionTooLarge;
    owned.description = try allocator.dupe(u8, description);
    return owned;
}

pub fn readInstalledTool(
    allocator: std.mem.Allocator,
    tools_root: []const u8,
    id: []const u8,
) !?InstalledTool {
    var root = std.fs.openDirAbsolute(tools_root, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer root.close();

    var tool_dir = root.openDir(id, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer tool_dir.close();

    const manifest_bytes = try tool_dir.readFileAlloc(allocator, "manifest.json", MAX_MANIFEST_BYTES);
    defer allocator.free(manifest_bytes);
    var manifest = try parseManifestJson(allocator, manifest_bytes);
    defer manifest.deinit(allocator);
    try validateInstalledManifest(id, manifest);

    const skill_md = try tool_dir.readFileAlloc(allocator, "SKILL.md", MAX_SKILL_MD_BYTES);
    errdefer allocator.free(skill_md);
    const executable_abs = try std.fs.path.join(allocator, &.{ tools_root, id, manifest.executable });
    errdefer allocator.free(executable_abs);
    const id_owned = try allocator.dupe(u8, manifest.id);
    errdefer allocator.free(id_owned);
    const function_name = try allocator.dupe(u8, manifest.function_name);
    errdefer allocator.free(function_name);
    const description = try allocator.dupe(u8, manifest.description);
    errdefer allocator.free(description);

    return .{
        .id = id_owned,
        .function_name = function_name,
        .enabled = manifest.enabled,
        .executable_abs = executable_abs,
        .skill_md = skill_md,
        .description = description,
    };
}

pub fn scanInstalledTools(allocator: std.mem.Allocator, tools_root: []const u8) ![]InstalledTool {
    var root = std.fs.openDirAbsolute(tools_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(InstalledTool, 0),
        else => return err,
    };
    defer root.close();

    var list: std.ArrayListUnmanaged(InstalledTool) = .empty;
    errdefer freeInstalledToolsBuilder(allocator, &list);

    var it = root.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const tool = readInstalledTool(allocator, tools_root, entry.name) catch continue;
        if (tool) |installed| {
            list.append(allocator, installed) catch |err| {
                installed.deinit(allocator);
                return err;
            };
        }
    }

    std.sort.insertion(InstalledTool, list.items, {}, installedToolLessThan);
    return list.toOwnedSlice(allocator);
}

pub fn freeInstalledTools(allocator: std.mem.Allocator, tools: []InstalledTool) void {
    for (tools) |*tool| tool.deinit(allocator);
    allocator.free(tools);
}

pub fn enabledSnapshot(allocator: std.mem.Allocator, tools: []const InstalledTool) ![]InstalledTool {
    var list: std.ArrayListUnmanaged(InstalledTool) = .empty;
    errdefer freeInstalledToolsBuilder(allocator, &list);

    for (tools) |tool| {
        if (!tool.enabled) continue;
        const copy = try copyInstalledTool(allocator, tool);
        list.append(allocator, copy) catch |err| {
            copy.deinit(allocator);
            return err;
        };
    }

    return list.toOwnedSlice(allocator);
}

pub fn freeEnabledSnapshot(allocator: std.mem.Allocator, tools: []InstalledTool) void {
    freeInstalledTools(allocator, tools);
}

fn stripExeSuffix(raw: []const u8) []const u8 {
    if (raw.len >= 4 and std.ascii.eqlIgnoreCase(raw[raw.len - 4 ..], ".exe")) {
        return raw[0 .. raw.len - 4];
    }
    return raw;
}

fn isValidFirstFunctionByte(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or byte == '_';
}

fn jsonString(root: std.json.Value, name: []const u8) ?[]const u8 {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn jsonBool(root: std.json.Value, name: []const u8) bool {
    if (root != .object) return false;
    const value = root.object.get(name) orelse return false;
    return switch (value) {
        .bool => |b| b,
        else => false,
    };
}

fn jsonI64(root: std.json.Value, name: []const u8) ?i64 {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    return switch (value) {
        .integer => |i| @intCast(i),
        else => null,
    };
}

fn validateInstalledManifest(dir_id: []const u8, manifest: OwnedManifest) !void {
    if (!std.mem.eql(u8, dir_id, manifest.id)) return error.InvalidToolManifest;
    try validateExecutablePath(manifest.executable);
}

fn validateExecutablePath(path: []const u8) !void {
    if (path.len <= "bin/".len) return error.InvalidToolManifest;
    if (path[0] == '/') return error.InvalidToolManifest;
    if (hasWindowsDrivePrefix(path)) return error.InvalidToolManifest;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidToolManifest;
    if (!std.mem.startsWith(u8, path, "bin/")) return error.InvalidToolManifest;

    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return error.InvalidToolManifest;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidToolManifest;
    }
}

fn hasWindowsDrivePrefix(path: []const u8) bool {
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
}

fn copyInstalledTool(allocator: std.mem.Allocator, tool: InstalledTool) !InstalledTool {
    const id = try allocator.dupe(u8, tool.id);
    errdefer allocator.free(id);
    const function_name = try allocator.dupe(u8, tool.function_name);
    errdefer allocator.free(function_name);
    const executable_abs = try allocator.dupe(u8, tool.executable_abs);
    errdefer allocator.free(executable_abs);
    const skill_md = try allocator.dupe(u8, tool.skill_md);
    errdefer allocator.free(skill_md);
    const description = try allocator.dupe(u8, tool.description);
    errdefer allocator.free(description);

    return .{
        .id = id,
        .function_name = function_name,
        .enabled = tool.enabled,
        .executable_abs = executable_abs,
        .skill_md = skill_md,
        .description = description,
    };
}

fn freeInstalledToolsBuilder(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(InstalledTool)) void {
    for (list.items) |*tool| tool.deinit(allocator);
    list.deinit(allocator);
}

fn installedToolLessThan(_: void, a: InstalledTool, b: InstalledTool) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

test "tool_registry: sanitizeFunctionName produces model-safe names" {
    const a = std.testing.allocator;
    const one = try sanitizeFunctionName(a, "agent-docx-review.exe");
    defer a.free(one);
    try std.testing.expectEqualStrings("agent_docx_review", one);
    const two = try sanitizeFunctionName(a, "123abc");
    defer a.free(two);
    try std.testing.expectEqualStrings("tool_123abc", two);
    const three = try sanitizeFunctionName(a, "My Tool");
    defer a.free(three);
    try std.testing.expectEqualStrings("my_tool", three);
}

test "tool_registry: generated skill markdown includes help and argv contract" {
    const a = std.testing.allocator;
    const md = try generateSkillMdFromHelp(a, .{
        .name = "agent_docx_review",
        .description = "Apply tracked-change review scripts to DOCX files",
        .help = "Usage:\n  agent_docx_review review input.docx output.docx --rules rules.json\n",
    });
    defer a.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "name: agent_docx_review") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "args` array") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "review input.docx") != null);
}

test "tool_registry: manifest json round trips enabled tool metadata" {
    const a = std.testing.allocator;
    const manifest = ToolManifest{
        .id = "agent_docx_review",
        .function_name = "agent_docx_review",
        .enabled = true,
        .executable = "bin/agent_docx_review.exe",
        .source_path = "C:/Users/alice/Downloads/agent_docx_review.exe",
        .sha256 = "abc123",
        .imported_at_ms = 1781971200000,
        .description = "Apply tracked-change review scripts to DOCX files",
    };
    const json = try manifestToJson(a, manifest);
    defer a.free(json);
    var parsed = try parseManifestJson(a, json);
    defer parsed.deinit(a);
    try std.testing.expectEqualStrings(manifest.id, parsed.id);
    try std.testing.expectEqualStrings(manifest.function_name, parsed.function_name);
    try std.testing.expect(parsed.enabled);
    try std.testing.expectEqualStrings(manifest.executable, parsed.executable);
}

test "tool_registry: manifest rejects non-string kind" {
    const a = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidToolManifest,
        parseManifestJson(a, "{\"kind\":123,\"id\":\"x\",\"function_name\":\"x\",\"executable\":\"bin/x\"}"),
    );
}

test "tool_registry: readInstalledTool rejects executable paths outside bin" {
    const a = std.testing.allocator;
    const cases = [_][]const u8{
        "../evil",
        "bin/../evil",
        "/tmp/evil",
        "C:\\evil.exe",
        "\\\\server\\share\\evil.exe",
        "..\\evil",
        "bin\\..\\evil",
    };

    for (cases, 0..) |executable, i| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const tools_root = try tmp.dir.realpathAlloc(a, ".");
        defer a.free(tools_root);
        const id = try std.fmt.allocPrint(a, "bad{d}", .{i});
        defer a.free(id);

        try writeInstalledToolFixture(a, tmp.dir, id, id, executable);
        try std.testing.expectError(error.InvalidToolManifest, readInstalledTool(a, tools_root, id));
    }
}

test "tool_registry: scanInstalledTools ignores malformed executable paths and id mismatches" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tools_root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(tools_root);

    try writeInstalledToolFixture(a, tmp.dir, "ok", "ok", "bin/ok.exe");
    try writeInstalledToolFixture(a, tmp.dir, "escape", "escape", "../evil");
    try writeInstalledToolFixture(a, tmp.dir, "mismatch", "other", "bin/mismatch.exe");

    const tools = try scanInstalledTools(a, tools_root);
    defer freeInstalledTools(a, tools);
    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("ok", tools[0].id);
    try std.testing.expectEqualStrings("ok", tools[0].function_name);
}

test "tool_registry: enabledToolSchemas skips disabled tools" {
    const a = std.testing.allocator;
    const enabled = InstalledTool{
        .id = try a.dupe(u8, "docx"),
        .function_name = try a.dupe(u8, "docx"),
        .enabled = true,
        .executable_abs = try a.dupe(u8, "/tmp/tools/docx/bin/docx"),
        .skill_md = try a.dupe(u8, "---\nname: docx\n---\nUse for DOCX review."),
        .description = try a.dupe(u8, "DOCX review"),
    };
    defer enabled.deinit(a);
    const disabled = InstalledTool{
        .id = try a.dupe(u8, "off"),
        .function_name = try a.dupe(u8, "off"),
        .enabled = false,
        .executable_abs = try a.dupe(u8, "/tmp/tools/off/bin/off"),
        .skill_md = try a.dupe(u8, "---\nname: off\n---\nOff."),
        .description = try a.dupe(u8, "Off"),
    };
    defer disabled.deinit(a);
    const list = [_]InstalledTool{ enabled, disabled };
    const snapshot = try enabledSnapshot(a, list[0..]);
    defer freeEnabledSnapshot(a, snapshot);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqualStrings("docx", snapshot[0].function_name);
}

fn writeInstalledToolFixture(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    id: []const u8,
    manifest_id: []const u8,
    executable: []const u8,
) !void {
    const bin_path = try std.fmt.allocPrint(allocator, "{s}/bin", .{id});
    defer allocator.free(bin_path);
    try dir.makePath(bin_path);

    const manifest_json = try manifestToJson(allocator, .{
        .id = manifest_id,
        .function_name = manifest_id,
        .enabled = true,
        .executable = executable,
        .source_path = "",
        .sha256 = "",
        .imported_at_ms = 1781971200000,
        .description = "Fixture tool",
    });
    defer allocator.free(manifest_json);

    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{id});
    defer allocator.free(manifest_path);
    try dir.writeFile(.{ .sub_path = manifest_path, .data = manifest_json });

    const skill_path = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{id});
    defer allocator.free(skill_path);
    try dir.writeFile(.{ .sub_path = skill_path, .data = "---\nname: fixture\n---\nUse fixture.\n" });
}
