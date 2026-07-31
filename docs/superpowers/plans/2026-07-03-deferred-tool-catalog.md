# Deferred Tool Catalog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** MCP 工具 schema 延迟注入(目录摘要 + `mcp_activate` 整 server 激活),启动零 spawn(tools/list 结果磁盘缓存),skill 列表对模型可见。

**Architecture:** 新增 `mcp_catalog.zig` 磁盘缓存(`<configDir>/mcp_catalog.json`,config_hash 失效);`mcp_registry` 的 reloadCache 改为读缓存(不 spawn),缓存增加 per-server 分组与激活集;system prompt 追加 inactive-server/skill 目录摘要;新元工具 `mcp_activate` 激活(必要时现场发现);agent loop 在 mcp_activate 后同轮刷新 ChatRequest 的 spec/dispatch 快照。MCP 调用路径本来就是 spawn-per-call([mcp.zig:7](../../src/agent_tools/mcp.zig) `ponytail: spawn-per-call`),不改。

**Tech Stack:** Zig 0.15.2(`std.ArrayListUnmanaged` `.empty`/`.print(alloc,...)`,`std.json.Stringify.valueAlloc`,`std.hash.Wyhash`,threadlocal 缓存模式照抄 mcp_registry 现状)。

**Spec:** `docs/superpowers/specs/2026-07-03-deferred-tool-catalog-design.md`

## Global Constraints

- 分支:从 `feat/mcp-panel-autosave-copilot` 切出 `feat/deferred-tool-catalog`(实现依赖该分支的 mcp_config/面板代码,PR #473 尚未合并)。
- 每个任务收尾:`zig build test`(fast 套件)必须 PASS;提交前 `zig fmt build.zig src`(CI 有 fmt gate,本地 test 不含)。
- `zig build` 默认目标是 Windows;凡是要真正跑 app 测试用 `-Dtarget=aarch64-macos`。
- `src/agent_tools/*` 不得 import session/AppWindow(source guard);新工具文件只依赖 types.zig / tools/ / args.zig / output.zig。
- 提交信息结尾:`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。
- 与 spec 的一处偏差(已定):激活集是**进程级全局**(mutex 保护),不是 per-session——工具层拿不到 Session 指针(guard),且跨会话共享激活是可接受行为。spec 已同步修订。
- 已知 flaky:`skill center tool import` 测试偶发 FileNotFound(.zig-cache/tmp),与本工作无关。

---

### Task 1: 磁盘目录缓存 `mcp_catalog.zig`

**Files:**
- Create: `src/tools/mcp_catalog.zig`
- Modify: `src/test_fast.zig`(在 `_ = @import("agent_tools/mcp_config.zig");` 附近加一行)

**Interfaces:**
- Consumes: `platform/dirs.zig` `pathInConfigDir`/`setTestConfigDirOverride`,`platform/atomic_file.zig` `writeFileReplaceSafe`,`assistant/conversation/protocol.zig` `McpToolSpec{name,description,properties_json}`。
- Produces(后续任务依赖的精确签名):
  - `pub const CatalogTool = struct { name: []u8, description: []u8, properties_json: []u8 }`
  - `pub const CatalogServer = struct { name: []u8, config_hash: u64, discovered_at: i64, tools: []CatalogTool }`
  - `pub const Catalog = struct { servers: []CatalogServer = &.{}; pub fn deinit(*Catalog, Allocator) void; pub fn find(*const Catalog, []const u8) ?*const CatalogServer }`
  - `pub fn configHash(command: []const u8, args: []const []const u8) u64`
  - `pub fn load(allocator: Allocator) Catalog`(永不失败,缺失/损坏→空)
  - `pub fn upsertServer(allocator, name: []const u8, config_hash: u64, discovered_at: i64, tools: []const McpToolSpec) !void`(load-modify-save + `bumpGeneration`)
  - `pub fn generation() u64` / `pub fn bumpGeneration() void`(atomic 计数器,供跨线程缓存失效)

- [ ] **Step 1: 写失败测试**(文件底部,连同实现一起新建文件,先只写测试跑一遍确认编译失败)

```zig
test "configHash changes when command or args change" {
    const a1 = [_][]const u8{ "-y", "pkg" };
    const h1 = configHash("npx", a1[0..]);
    const h2 = configHash("npx2", a1[0..]);
    const a2 = [_][]const u8{ "-y", "pkg2" };
    const h3 = configHash("npx", a2[0..]);
    try std.testing.expect(h1 != h2);
    try std.testing.expect(h1 != h3);
    try std.testing.expectEqual(h1, configHash("npx", a1[0..]));
}

test "upsertServer then load round-trips tools; corrupt file loads empty" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);

    const specs = [_]McpToolSpec{
        .{ .name = "search", .description = "Search things", .properties_json = "{\"q\":{\"type\":\"string\"}}" },
        .{ .name = "read", .description = "Read things", .properties_json = "{}" },
    };
    const gen_before = generation();
    try upsertServer(a, "jina", 42, 1000, specs[0..]);
    try std.testing.expect(generation() > gen_before);

    var cat = load(a);
    defer cat.deinit(a);
    const entry = cat.find("jina").?;
    try std.testing.expectEqual(@as(u64, 42), entry.config_hash);
    try std.testing.expectEqual(@as(usize, 2), entry.tools.len);
    try std.testing.expectEqualStrings("search", entry.tools[0].name);
    try std.testing.expectEqualStrings("{\"q\":{\"type\":\"string\"}}", entry.tools[0].properties_json);

    // upsert 同名替换,不同名共存
    try upsertServer(a, "jina", 43, 1001, specs[0..1]);
    try upsertServer(a, "other", 7, 1002, specs[1..]);
    var cat2 = load(a);
    defer cat2.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), cat2.servers.len);
    try std.testing.expectEqual(@as(u64, 43), cat2.find("jina").?.config_hash);
    try std.testing.expectEqual(@as(usize, 1), cat2.find("jina").?.tools.len);

    // 损坏文件 → 空目录
    const path = try platform_dirs.pathInConfigDir(a, "mcp_catalog.json");
    defer a.free(path);
    try atomic_file.writeFileReplaceSafe(path, "not json");
    var cat3 = load(a);
    defer cat3.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), cat3.servers.len);
}

test "load returns empty when the file is absent" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);
    var cat = load(a);
    defer cat.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), cat.servers.len);
}
```

- [ ] **Step 2: 实现模块**(同一文件;JSON 形状 `{"servers":{"<name>":{"configHash":"<hex>","discoveredAt":N,"tools":[{"name","description","propertiesJson"}]}}}`,hash 以 16 进制字符串存,避免 JSON number 精度问题)

```zig
//! Disk cache of MCP server tool listings: <configDir>/mcp_catalog.json.
//! Lets the registry build the tool catalog at startup WITHOUT spawning any
//! MCP server. Entries are keyed by server name and invalidated when the
//! server's command+args hash changes. Written by: panel probe ("Test"),
//! mcp_activate live discovery. Read by: mcp_registry.reloadCache.
const std = @import("std");
const platform_dirs = @import("../platform/dirs.zig");
const atomic_file = @import("../platform/atomic_file.zig");
const ai_chat_protocol = @import("../assistant/conversation/protocol.zig");

const McpToolSpec = ai_chat_protocol.McpToolSpec;
const MAX_CATALOG_BYTES: usize = 4 * 1024 * 1024;

pub const CatalogTool = struct { name: []u8, description: []u8, properties_json: []u8 };

pub const CatalogServer = struct {
    name: []u8,
    config_hash: u64,
    discovered_at: i64,
    tools: []CatalogTool,
};

pub const Catalog = struct {
    servers: []CatalogServer = &.{},

    pub fn deinit(self: *Catalog, allocator: std.mem.Allocator) void {
        for (self.servers) |s| {
            allocator.free(s.name);
            for (s.tools) |t| {
                allocator.free(t.name);
                allocator.free(t.description);
                allocator.free(t.properties_json);
            }
            allocator.free(s.tools);
        }
        allocator.free(self.servers);
        self.servers = &.{};
    }

    pub fn find(self: *const Catalog, name: []const u8) ?*const CatalogServer {
        for (self.servers) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }
};

/// Identity of a server config for cache invalidation: command + args.
pub fn configHash(command: []const u8, args: []const []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(command);
    h.update(&[_]u8{0});
    for (args) |arg| {
        h.update(arg);
        h.update(&[_]u8{0});
    }
    return h.final();
}

// Cross-thread invalidation signal: bumped on every catalog/config write.
// Threadlocal registry caches compare against this and reload lazily.
var g_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(1);

pub fn generation() u64 {
    return g_generation.load(.monotonic);
}

pub fn bumpGeneration() void {
    _ = g_generation.fetchAdd(1, .monotonic);
}

fn catalogPath(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.pathInConfigDir(allocator, "mcp_catalog.json");
}

/// Read the catalog. Missing or corrupt file → empty catalog (never an error;
/// the next successful discovery rewrites it).
pub fn load(allocator: std.mem.Allocator) Catalog {
    return loadInner(allocator) catch .{ .servers = &.{} };
}

fn loadInner(allocator: std.mem.Allocator) !Catalog {
    const path = try catalogPath(allocator);
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_CATALOG_BYTES) catch
        return .{ .servers = &.{} };
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch
        return .{ .servers = &.{} };
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .servers = &.{} };
    const servers_val = parsed.value.object.get("servers") orelse return .{ .servers = &.{} };
    if (servers_val != .object) return .{ .servers = &.{} };

    var list: std.ArrayListUnmanaged(CatalogServer) = .empty;
    errdefer {
        for (list.items) |s| {
            allocator.free(s.name);
            for (s.tools) |t| {
                allocator.free(t.name);
                allocator.free(t.description);
                allocator.free(t.properties_json);
            }
            allocator.free(s.tools);
        }
        list.deinit(allocator);
    }

    var it = servers_val.object.iterator();
    while (it.next()) |entry| {
        const spec = entry.value_ptr.*;
        if (spec != .object) continue;
        const hash_v = spec.object.get("configHash") orelse continue;
        if (hash_v != .string) continue;
        const hash = std.fmt.parseInt(u64, hash_v.string, 16) catch continue;
        const discovered_at: i64 = if (spec.object.get("discoveredAt")) |d|
            (if (d == .integer) d.integer else 0)
        else
            0;

        var tools: std.ArrayListUnmanaged(CatalogTool) = .empty;
        errdefer {
            for (tools.items) |t| {
                allocator.free(t.name);
                allocator.free(t.description);
                allocator.free(t.properties_json);
            }
            tools.deinit(allocator);
        }
        if (spec.object.get("tools")) |tools_v| {
            if (tools_v == .array) {
                for (tools_v.array.items) |tv| {
                    if (tv != .object) continue;
                    const name_v = tv.object.get("name") orelse continue;
                    if (name_v != .string) continue;
                    const desc_v = tv.object.get("description");
                    const props_v = tv.object.get("propertiesJson");
                    const t_name = try allocator.dupe(u8, name_v.string);
                    errdefer allocator.free(t_name);
                    const t_desc = try allocator.dupe(u8, if (desc_v != null and desc_v.? == .string) desc_v.?.string else "");
                    errdefer allocator.free(t_desc);
                    const t_props = try allocator.dupe(u8, if (props_v != null and props_v.? == .string) props_v.?.string else "{}");
                    errdefer allocator.free(t_props);
                    try tools.append(allocator, .{ .name = t_name, .description = t_desc, .properties_json = t_props });
                }
            }
        }

        const s_name = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(s_name);
        try list.append(allocator, .{
            .name = s_name,
            .config_hash = hash,
            .discovered_at = discovered_at,
            .tools = try tools.toOwnedSlice(allocator),
        });
    }
    return .{ .servers = try list.toOwnedSlice(allocator) };
}

fn save(allocator: std.mem.Allocator, catalog: *const Catalog) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var servers_obj = std.json.ObjectMap.init(aa);
    for (catalog.servers) |s| {
        var entry = std.json.ObjectMap.init(aa);
        try entry.put("configHash", .{ .string = try std.fmt.allocPrint(aa, "{x}", .{s.config_hash}) });
        try entry.put("discoveredAt", .{ .integer = s.discovered_at });
        var arr = std.json.Array.init(aa);
        for (s.tools) |t| {
            var tool_obj = std.json.ObjectMap.init(aa);
            try tool_obj.put("name", .{ .string = t.name });
            try tool_obj.put("description", .{ .string = t.description });
            try tool_obj.put("propertiesJson", .{ .string = t.properties_json });
            try arr.append(.{ .object = tool_obj });
        }
        try entry.put("tools", .{ .array = arr });
        try servers_obj.put(s.name, .{ .object = entry });
    }
    var root = std.json.ObjectMap.init(aa);
    try root.put("servers", .{ .object = servers_obj });

    const body = try std.json.Stringify.valueAlloc(aa, std.json.Value{ .object = root }, .{});
    const path = try catalogPath(allocator);
    defer allocator.free(path);
    const dir = try platform_dirs.configDir(allocator);
    defer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch {};
    try atomic_file.writeFileReplaceSafe(path, body);
}

/// Insert or replace one server's tool listing, persist, and bump the
/// generation so other threads' registry caches reload lazily.
pub fn upsertServer(
    allocator: std.mem.Allocator,
    name: []const u8,
    config_hash: u64,
    discovered_at: i64,
    tools: []const McpToolSpec,
) !void {
    var cat = load(allocator);
    defer cat.deinit(allocator);

    var list: std.ArrayListUnmanaged(CatalogServer) = .empty;
    defer list.deinit(allocator);
    for (cat.servers) |s| {
        if (std.mem.eql(u8, s.name, name)) continue; // replaced below
        try list.append(allocator, s);
    }

    // Borrow the caller's spec strings for the duration of the save (save only
    // reads them; same borrowing trick as mcp_config.addServer).
    const borrowed = try allocator.alloc(CatalogTool, tools.len);
    defer allocator.free(borrowed);
    for (tools, 0..) |t, i| borrowed[i] = .{
        .name = @constCast(t.name),
        .description = @constCast(t.description),
        .properties_json = @constCast(t.properties_json),
    };
    try list.append(allocator, .{
        .name = @constCast(name),
        .config_hash = config_hash,
        .discovered_at = discovered_at,
        .tools = borrowed,
    });

    const to_save: Catalog = .{ .servers = list.items };
    try save(allocator, &to_save);
    bumpGeneration();
}
```

- [ ] **Step 3: 挂进 fast 测试**——`src/test_fast.zig` 在 `_ = @import("agent_tools/mcp_config.zig");` 那行后加:

```zig
    _ = @import("tools/mcp_catalog.zig");
```

- [ ] **Step 4: 跑测试**

Run: `zig build test`
Expected: PASS(新增 3 个 mcp_catalog 测试)

- [ ] **Step 5: 提交**

```bash
zig fmt build.zig src
git add src/tools/mcp_catalog.zig src/test_fast.zig
git commit -m "feat(mcp): disk tool catalog cache (mcp_catalog.json)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: registry 改读目录缓存,启动零 spawn

**Files:**
- Modify: `src/tools/mcp_registry.zig`(`loadSnapshots`/`reloadCache`/`freeCache`/threadlocal 区,~503-627 行)
- Modify: `src/main.zig:239-242`(仅注释)

**Interfaces:**
- Consumes: Task 1 的 `mcp_catalog.load/configHash/generation`。
- Produces:
  - `pub const CachedServer = struct { name: []u8, discovered: bool, spec_off: usize, spec_len: usize }`(specs 与 tools 同序 1:1,一个 range 够用)
  - `pub fn cachedServers() []const CachedServer`(borrowed,同 cachedSpecs 语义)
  - `pub fn ensureCacheFresh(allocator: Allocator) void`(generation 不一致时 reloadCache;本线程首次访问自动加载)
  - `cachedSpecs()`/`cachedTools()` 语义不变 = 全部**已发现**工具(dispatch 继续用全量 → 兜底自动执行零代码)。
  - `discover()` 保留原样(激活现场发现与既有测试都用它)。

- [ ] **Step 1: 写失败测试**(加在 mcp_registry.zig 底部)

```zig
test "reloadCache builds specs from the disk catalog without spawning" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);

    // 配一个根本不存在的命令——若 reloadCache 还会 spawn,这个测试拿不到工具
    var args0 = [_][]u8{@constCast("--x")};
    const servers = [_]ServerConfig{
        .{ .name = @constCast("cached"), .command = @constCast("/nonexistent/bin"), .args = args0[0..], .enabled = true },
        .{ .name = @constCast("fresh"), .command = @constCast("/nonexistent/bin2"), .args = &.{}, .enabled = true },
        .{ .name = @constCast("off"), .command = @constCast("/nonexistent/bin3"), .args = &.{}, .enabled = false },
    };
    try saveConfigFile(a, servers[0..]);

    // 只有 "cached" 有匹配 hash 的目录条目
    const one_arg = [_][]const u8{"--x"};
    const specs = [_]McpToolSpec{.{ .name = "greet", .description = "Greet", .properties_json = "{}" }};
    try mcp_catalog.upsertServer(a, "cached", mcp_catalog.configHash("/nonexistent/bin", one_arg[0..]), 1, specs[0..]);

    reloadCache(a);
    defer reloadCacheFromServersForTest(a, &.{}); // 释放缓存

    try std.testing.expectEqual(@as(usize, 1), cachedSpecs().len);
    try std.testing.expectEqualStrings("greet", cachedSpecs()[0].name);
    try std.testing.expectEqual(@as(usize, 1), cachedTools().len);
    try std.testing.expectEqualStrings("/nonexistent/bin", cachedTools()[0].server_command);

    const srvs = cachedServers();
    try std.testing.expectEqual(@as(usize, 2), srvs.len); // disabled 的不进目录
    try std.testing.expectEqualStrings("cached", srvs[0].name);
    try std.testing.expect(srvs[0].discovered);
    try std.testing.expectEqual(@as(usize, 1), srvs[0].spec_len);
    try std.testing.expectEqualStrings("fresh", srvs[1].name);
    try std.testing.expect(!srvs[1].discovered);
    try std.testing.expectEqual(@as(usize, 0), srvs[1].spec_len);
}

test "reloadCache treats a hash-mismatched catalog entry as undiscovered" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);

    const servers = [_]ServerConfig{.{ .name = @constCast("s"), .command = @constCast("/bin/new"), .args = &.{}, .enabled = true }};
    try saveConfigFile(a, servers[0..]);
    const specs = [_]McpToolSpec{.{ .name = "old", .description = "", .properties_json = "{}" }};
    try mcp_catalog.upsertServer(a, "s", 999999, 1, specs[0..]); // 错的 hash

    reloadCache(a);
    defer reloadCacheFromServersForTest(a, &.{});
    try std.testing.expectEqual(@as(usize, 0), cachedSpecs().len);
    try std.testing.expect(!cachedServers()[0].discovered);
}

test "ensureCacheFresh reloads after a generation bump" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);

    const servers = [_]ServerConfig{.{ .name = @constCast("s"), .command = @constCast("/bin/x"), .args = &.{}, .enabled = true }};
    try saveConfigFile(a, servers[0..]);
    reloadCache(a);
    defer reloadCacheFromServersForTest(a, &.{});
    try std.testing.expectEqual(@as(usize, 0), cachedSpecs().len);

    const specs = [_]McpToolSpec{.{ .name = "t", .description = "", .properties_json = "{}" }};
    const no_args = [_][]const u8{};
    try mcp_catalog.upsertServer(a, "s", mcp_catalog.configHash("/bin/x", no_args[0..]), 1, specs[0..]); // bumps generation
    ensureCacheFresh(a);
    try std.testing.expectEqual(@as(usize, 1), cachedSpecs().len);
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test`
Expected: FAIL — `mcp_catalog`/`cachedServers`/`ensureCacheFresh` 未定义。

- [ ] **Step 3: 实现**

3a. 顶部 import 区加 `const mcp_catalog = @import("mcp_catalog.zig");`。

3b. `saveConfigFile`(200 行)末尾加一行,让 mcp.json 变更也触发跨线程失效:

```zig
    try atomic_file.writeFileReplaceSafe(path, json);
    mcp_catalog.bumpGeneration();
```

3c. threadlocal 区(508 行起)追加:

```zig
pub const CachedServer = struct {
    name: []u8,
    discovered: bool,
    spec_off: usize,
    spec_len: usize,
};

threadlocal var g_cache_servers: []CachedServer = &.{};
threadlocal var g_cache_servers_owned: bool = false;
threadlocal var g_cache_seen_gen: u64 = 0;

/// Per-server grouping of the cached specs/tools (borrowed, same lifetime as
/// cachedSpecs). Order follows mcp.json; disabled servers are absent.
pub fn cachedServers() []const CachedServer {
    return g_cache_servers;
}
```

3d. `freeCache` 里追加对 servers 的释放:

```zig
    if (g_cache_servers_owned) {
        for (g_cache_servers) |s| allocator.free(s.name);
        allocator.free(g_cache_servers);
        g_cache_servers = &.{};
        g_cache_servers_owned = false;
    }
```

3e. 用读目录的实现**替换** `loadSnapshots`(538-550 行):

```zig
const CatalogSnapshots = struct {
    snap: Snapshots,
    servers: []CachedServer,
};

/// Build the cache from mcp.json + the disk catalog. Spawns NOTHING — a
/// server without a valid (hash-matched) catalog entry appears with
/// discovered=false and zero tools until it is probed or activated.
fn loadSnapshotsFromCatalog(allocator: std.mem.Allocator) !CatalogSnapshots {
    const configs = try loadConfigFile(allocator);
    defer freeServersConfig(allocator, configs);
    var catalog = mcp_catalog.load(allocator);
    defer catalog.deinit(allocator);

    var specs: std.ArrayListUnmanaged(McpToolSpec) = .empty;
    var tools: std.ArrayListUnmanaged(McpTool) = .empty;
    var servers: std.ArrayListUnmanaged(CachedServer) = .empty;
    errdefer {
        freeSpecItems(allocator, specs.items);
        specs.deinit(allocator);
        freeToolItems(allocator, tools.items);
        tools.deinit(allocator);
        for (servers.items) |s| allocator.free(s.name);
        servers.deinit(allocator);
    }

    for (configs) |server| {
        if (!server.enabled) continue;
        const hash = mcp_catalog.configHash(server.command, server.args);
        const entry = catalog.find(server.name);
        const valid = entry != null and entry.?.config_hash == hash;
        const off = specs.items.len;

        if (valid) {
            for (entry.?.tools) |t| {
                if (ai_chat_protocol.builtinToolNameReserved(t.name)) continue;
                const spec_name = try allocator.dupe(u8, t.name);
                errdefer allocator.free(spec_name);
                const spec_desc = try allocator.dupe(u8, t.description);
                errdefer allocator.free(spec_desc);
                const props = try allocator.dupe(u8, t.properties_json);
                errdefer allocator.free(props);
                try specs.append(allocator, .{ .name = spec_name, .description = spec_desc, .properties_json = props });

                const t_name = try allocator.dupe(u8, t.name);
                errdefer allocator.free(t_name);
                const t_desc = try allocator.dupe(u8, t.description);
                errdefer allocator.free(t_desc);
                const t_cmd = try allocator.dupe(u8, server.command);
                errdefer allocator.free(t_cmd);
                const t_args = try dupeStringList(allocator, server.args);
                errdefer freeStringList(allocator, t_args);
                try tools.append(allocator, .{ .function_name = t_name, .description = t_desc, .server_command = t_cmd, .server_args = t_args });
            }
        }
        const s_name = try allocator.dupe(u8, server.name);
        errdefer allocator.free(s_name);
        try servers.append(allocator, .{
            .name = s_name,
            .discovered = valid,
            .spec_off = off,
            .spec_len = specs.items.len - off,
        });
    }
    return .{
        .snap = .{ .specs = try specs.toOwnedSlice(allocator), .tools = try tools.toOwnedSlice(allocator) },
        .servers = try servers.toOwnedSlice(allocator),
    };
}
```

3f. **替换** `reloadCache`(555-566 行)并新增 `ensureCacheFresh`:

```zig
/// Re-read <configDir>/mcp.json + mcp_catalog.json and swap the cache. Never
/// fails: on any error the cache is left empty. Spawns no servers (discovery
/// moved to probe/activation — see mcp_catalog.zig).
pub fn reloadCache(allocator: std.mem.Allocator) void {
    const gen = mcp_catalog.generation();
    freeCache(allocator);
    const loaded = loadSnapshotsFromCatalog(allocator) catch |err| {
        log.warn("reload failed: {s}", .{@errorName(err)});
        return;
    };
    g_cache_specs = loaded.snap.specs;
    g_cache_specs_owned = loaded.snap.specs.len != 0;
    g_cache_tools = loaded.snap.tools;
    g_cache_tools_owned = loaded.snap.tools.len != 0;
    g_cache_servers = loaded.servers;
    g_cache_servers_owned = loaded.servers.len != 0;
    g_cache_seen_gen = gen;
    log.info("ready: {d} tool(s) across {d} server(s) from catalog", .{ g_cache_tools.len, g_cache_servers.len });
}

/// Reload this thread's cache iff the catalog/config changed since it was
/// built (or it was never built on this thread). Cheap: one atomic load.
pub fn ensureCacheFresh(allocator: std.mem.Allocator) void {
    if (g_cache_seen_gen == mcp_catalog.generation()) return;
    reloadCache(allocator);
}
```

3g. 旧测试适配:原 `test "cache stores discovered tools and frees them on the next reload"` 保留(走 `reloadCacheFromServersForTest`→`discover`,不受影响);`reloadCacheFromServersForTest` 不用改(freeCache 已顺带清 servers)。

3h. `main.zig:239-242` 注释更新:

```zig
    // Build the MCP tool catalog from <configDir>/mcp.json + the disk catalog
    // cache. No MCP server is spawned at startup — discovery happens in the
    // panel "Test" probe or on first mcp_activate (see mcp_catalog.zig).
    ai_chat.reloadMcpTools(allocator);
```

- [ ] **Step 4: 跑测试**

Run: `zig build test`
Expected: PASS(含 Task 1、旧 registry 测试、新 3 个)

- [ ] **Step 5: 提交**

```bash
zig fmt build.zig src
git add src/tools/mcp_registry.zig src/main.zig
git commit -m "feat(mcp): registry cache reads disk catalog; zero server spawns at startup

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: 激活集 + 按激活过滤的 specs + 目录摘要

**Files:**
- Modify: `src/tools/mcp_registry.zig`(接着 Task 2 的区域追加)

**Interfaces:**
- Produces:
  - `pub fn activateServer(name: []const u8) bool`(幂等;满/超长→false)
  - `pub fn isActivated(name: []const u8) bool`
  - `pub fn resetActivationForTest() void`
  - `pub fn cloneActivatedSpecs(allocator) ![]McpToolSpec`(owned 深拷贝,只含已激活 server;调用前自带 `ensureCacheFresh`)
  - `pub fn inactiveDigest(allocator) !?[]u8`(未激活 server 摘要;全激活/无 server → null)

- [ ] **Step 1: 写失败测试**

```zig
test "activation filters cloneActivatedSpecs and inactiveDigest" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);
    resetActivationForTest();
    defer resetActivationForTest();

    const servers = [_]ServerConfig{
        .{ .name = @constCast("alpha"), .command = @constCast("/bin/a"), .args = &.{}, .enabled = true },
        .{ .name = @constCast("beta"), .command = @constCast("/bin/b"), .args = &.{}, .enabled = true },
    };
    try saveConfigFile(a, servers[0..]);
    const no_args = [_][]const u8{};
    const sa = [_]McpToolSpec{.{ .name = "a_tool", .description = "A", .properties_json = "{}" }};
    const sb = [_]McpToolSpec{.{ .name = "b_tool", .description = "B", .properties_json = "{}" }};
    try mcp_catalog.upsertServer(a, "alpha", mcp_catalog.configHash("/bin/a", no_args[0..]), 1, sa[0..]);
    try mcp_catalog.upsertServer(a, "beta", mcp_catalog.configHash("/bin/b", no_args[0..]), 1, sb[0..]);
    reloadCache(a);
    defer reloadCacheFromServersForTest(a, &.{});

    // 未激活:specs 空,摘要两行都在
    const none = try cloneActivatedSpecs(a);
    defer a.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const digest1 = (try inactiveDigest(a)).?;
    defer a.free(digest1);
    try std.testing.expect(std.mem.indexOf(u8, digest1, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, digest1, "b_tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, digest1, "mcp_activate") != null);

    // 激活 alpha:只克隆 alpha 的;摘要只剩 beta
    try std.testing.expect(activateServer("alpha"));
    try std.testing.expect(isActivated("alpha"));
    try std.testing.expect(activateServer("alpha")); // 幂等
    const only_a = try cloneActivatedSpecs(a);
    defer {
        for (only_a) |s| {
            a.free(s.name);
            a.free(s.description);
            a.free(s.properties_json);
        }
        a.free(only_a);
    }
    try std.testing.expectEqual(@as(usize, 1), only_a.len);
    try std.testing.expectEqualStrings("a_tool", only_a[0].name);
    const digest2 = (try inactiveDigest(a)).?;
    defer a.free(digest2);
    try std.testing.expect(std.mem.indexOf(u8, digest2, "alpha") == null);
    try std.testing.expect(std.mem.indexOf(u8, digest2, "beta") != null);

    // 全部激活 → null
    _ = activateServer("beta");
    try std.testing.expect(try inactiveDigest(a) == null);
}

test "inactiveDigest marks an undiscovered server" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);
    resetActivationForTest();
    defer resetActivationForTest();

    const servers = [_]ServerConfig{.{ .name = @constCast("mystery"), .command = @constCast("/bin/m"), .args = &.{}, .enabled = true }};
    try saveConfigFile(a, servers[0..]);
    reloadCache(a);
    defer reloadCacheFromServersForTest(a, &.{});

    const digest = (try inactiveDigest(a)).?;
    defer a.free(digest);
    try std.testing.expect(std.mem.indexOf(u8, digest, "mystery") != null);
    try std.testing.expect(std.mem.indexOf(u8, digest, "not discovered yet") != null);
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test` → FAIL(符号未定义)。

- [ ] **Step 3: 实现**(mcp_registry.zig,threadlocal 缓存区之后)

```zig
// ---------------------------------------------------------------------------
// Activation: which servers' tool schemas are advertised to the model.
// ponytail: app-global (process lifetime), not per chat session — tools can't
// reach the Session object, and sharing activation across sessions is fine.
// Fixed-size name slots; server names longer than 64 bytes can't be activated.
// ---------------------------------------------------------------------------

const MAX_ACTIVATED = 32;
const MAX_ACT_NAME = 64;
var g_act_mutex: std.Thread.Mutex = .{};
var g_act_names: [MAX_ACTIVATED][MAX_ACT_NAME]u8 = undefined;
var g_act_lens: [MAX_ACTIVATED]usize = @splat(0);
var g_act_count: usize = 0;

/// Mark a server's tools as advertised. Idempotent. False when the slot table
/// is full or the name doesn't fit.
pub fn activateServer(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_ACT_NAME) return false;
    g_act_mutex.lock();
    defer g_act_mutex.unlock();
    for (0..g_act_count) |i| {
        if (std.mem.eql(u8, g_act_names[i][0..g_act_lens[i]], name)) return true;
    }
    if (g_act_count >= MAX_ACTIVATED) return false;
    @memcpy(g_act_names[g_act_count][0..name.len], name);
    g_act_lens[g_act_count] = name.len;
    g_act_count += 1;
    return true;
}

pub fn isActivated(name: []const u8) bool {
    g_act_mutex.lock();
    defer g_act_mutex.unlock();
    for (0..g_act_count) |i| {
        if (std.mem.eql(u8, g_act_names[i][0..g_act_lens[i]], name)) return true;
    }
    return false;
}

pub fn resetActivationForTest() void {
    g_act_mutex.lock();
    defer g_act_mutex.unlock();
    g_act_count = 0;
}

/// Owned deep copies of the specs belonging to ACTIVATED servers only — what a
/// request advertises. Caller frees each spec's three strings + the slice
/// (session's freeOwnedMcpToolSpecs shape).
pub fn cloneActivatedSpecs(allocator: std.mem.Allocator) ![]McpToolSpec {
    ensureCacheFresh(allocator);
    var out: std.ArrayListUnmanaged(McpToolSpec) = .empty;
    errdefer {
        freeSpecItems(allocator, out.items);
        out.deinit(allocator);
    }
    for (g_cache_servers) |srv| {
        if (!isActivated(srv.name)) continue;
        for (g_cache_specs[srv.spec_off..][0..srv.spec_len]) |s| {
            const n = try allocator.dupe(u8, s.name);
            errdefer allocator.free(n);
            const d = try allocator.dupe(u8, s.description);
            errdefer allocator.free(d);
            const p = try allocator.dupe(u8, s.properties_json);
            errdefer allocator.free(p);
            try out.append(allocator, .{ .name = n, .description = d, .properties_json = p });
        }
    }
    return out.toOwnedSlice(allocator);
}

const DIGEST_MAX_TOOL_NAMES = 8;

/// System-prompt digest of the INACTIVE servers (the model's map of what it
/// can mcp_activate). Null when every configured server is already activated
/// (or none are configured).
pub fn inactiveDigest(allocator: std.mem.Allocator) !?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var listed: usize = 0;
    for (g_cache_servers) |srv| {
        if (isActivated(srv.name)) continue;
        if (listed == 0) {
            try out.appendSlice(allocator, "Inactive MCP servers — call mcp_activate with the server name before using their tools:\n");
        }
        if (srv.discovered) {
            try out.print(allocator, "- {s} ({d} tools): ", .{ srv.name, srv.spec_len });
            const n = @min(srv.spec_len, DIGEST_MAX_TOOL_NAMES);
            for (g_cache_specs[srv.spec_off..][0..n], 0..) |s, i| {
                if (i > 0) try out.appendSlice(allocator, ", ");
                try out.appendSlice(allocator, s.name);
            }
            if (srv.spec_len > DIGEST_MAX_TOOL_NAMES) try out.appendSlice(allocator, ", ...");
            try out.append(allocator, '\n');
        } else {
            try out.print(allocator, "- {s} (not discovered yet; mcp_activate connects to it and lists its tools)\n", .{srv.name});
        }
        listed += 1;
    }
    if (listed == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}
```

- [ ] **Step 4: 跑测试**

Run: `zig build test` → PASS。

- [ ] **Step 5: 提交**

```bash
zig fmt build.zig src
git add src/tools/mcp_registry.zig
git commit -m "feat(mcp): server activation set, activated-spec cloning, inactive digest

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `mcp_activate` 元工具(注册四件套 + 现场发现)

**Files:**
- Create: `src/agent_tools/mcp_activate.zig`
- Modify: `src/agent_tools/mod.zig`(`mcp_config` 分派臂旁,~31 与 ~225 行)
- Modify: `src/assistant/conversation/protocol.zig`(`emitTool` mcp_config 行后 ~794;`builtinToolNameReserved` 表 ~718)
- Modify: `src/tools/first_party.zig`(static_definitions 中 mcp_config 条目后)
- Modify: `src/test_fast.zig`

**Interfaces:**
- Consumes: Task 1-3 全部;`mcp_registry.discover`(单 server 现场发现)、`tool_args.string/parse`。
- Produces: `pub fn run(ctx: *ToolContext, arguments_json: []const u8) ![]u8`;核心 op `pub fn activateByName(allocator, name: []const u8) ![]u8`(纯 allocator,可单测)。

- [ ] **Step 1: 新建文件(实现 + 测试一起)**

```zig
//! Native Copilot tool `mcp_activate`: turn on one configured MCP server's
//! tools for this process. The system prompt lists inactive servers; the model
//! calls this before using their tools. If the server has no valid catalog
//! entry yet, this spawns it once (initialize + tools/list), writes the disk
//! catalog, and reloads the registry cache — so activation doubles as
//! first-time discovery. No approval gate: it only launches a server the user
//! already configured, and the real tool calls keep their own gate.
const std = @import("std");
const types = @import("../assistant/conversation/types.zig");
const mcp_registry = @import("../tools/mcp_registry.zig");
const mcp_catalog = @import("../tools/mcp_catalog.zig");
const tool_args = @import("args.zig");

const ToolContext = types.ToolContext;

/// Core op, allocator-only for tests. Returns the model-facing text.
pub fn activateByName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const servers = try mcp_registry.loadConfigFile(allocator);
    defer mcp_registry.freeServersConfig(allocator, servers);

    const server = for (servers) |s| {
        if (std.mem.eql(u8, s.name, name)) break s;
    } else {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.print(allocator, "No MCP server named \"{s}\".", .{name});
        if (servers.len > 0) {
            try out.appendSlice(allocator, " Configured servers:");
            for (servers) |s| try out.print(allocator, " {s}", .{s.name});
        } else {
            try out.appendSlice(allocator, " None configured; use mcp_config action=add.");
        }
        return out.toOwnedSlice(allocator);
    };
    if (!server.enabled) {
        return std.fmt.allocPrint(allocator, "MCP server \"{s}\" is disabled. Enable it first with mcp_config action=enable.", .{name});
    }

    const hash = mcp_catalog.configHash(server.command, server.args);
    var catalog = mcp_catalog.load(allocator);
    const cached_ok = if (catalog.find(name)) |e| e.config_hash == hash else false;
    catalog.deinit(allocator);

    if (!cached_ok) {
        // First-time (or config-changed) discovery: spawn the server once.
        const one = [_]mcp_registry.ServerConfig{server};
        const snap = try mcp_registry.discover(allocator, one[0..]);
        defer mcp_registry.freeSnapshots(allocator, snap);
        if (snap.specs.len == 0) {
            return std.fmt.allocPrint(allocator, "Could not discover tools from MCP server \"{s}\" — it failed to start, failed the handshake, or listed no tools. Check its command with mcp_config action=list.", .{name});
        }
        try mcp_catalog.upsertServer(allocator, name, hash, std.time.timestamp(), snap.specs);
    }

    mcp_registry.reloadCache(allocator);
    _ = mcp_registry.activateServer(name);

    // Summarize what just became available from this thread's fresh cache.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (mcp_registry.cachedServers()) |srv| {
        if (!std.mem.eql(u8, srv.name, name)) continue;
        try out.print(allocator, "Activated MCP server \"{s}\" — {d} tool(s) now available:\n", .{ name, srv.spec_len });
        const specs = mcp_registry.cachedSpecs();
        for (specs[srv.spec_off..][0..srv.spec_len]) |s| {
            try out.print(allocator, "- {s}: {s}\n", .{ s.name, s.description });
        }
        return out.toOwnedSlice(allocator);
    }
    try out.print(allocator, "Activated MCP server \"{s}\".", .{name});
    return out.toOwnedSlice(allocator);
}

/// Tool entrypoint.
pub fn run(ctx: *ToolContext, arguments_json: []const u8) ![]u8 {
    var parsed = tool_args.parse(ctx.allocator, arguments_json) orelse
        return ctx.allocator.dupe(u8, "Invalid tool arguments.");
    defer parsed.deinit();
    const name = tool_args.string(parsed.value, "server") orelse
        tool_args.string(parsed.value, "name") orelse
        return ctx.allocator.dupe(u8, "mcp_activate requires a \"server\" name (see the inactive-server list in the system prompt or mcp_config action=list).");
    return activateByName(ctx.allocator, name) catch |err|
        std.fmt.allocPrint(ctx.allocator, "MCP activate error: {s}", .{@errorName(err)});
}

// --- tests -------------------------------------------------------------------

const builtin = @import("builtin");
const dirs = @import("../platform/dirs.zig");

test "activateByName reports unknown and disabled servers" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    dirs.setTestConfigDirOverride(dir_path);
    defer dirs.setTestConfigDirOverride(null);
    mcp_registry.resetActivationForTest();
    defer mcp_registry.resetActivationForTest();

    const servers = [_]mcp_registry.ServerConfig{.{ .name = @constCast("off"), .command = @constCast("/bin/false"), .args = &.{}, .enabled = false }};
    try mcp_registry.saveConfigFile(a, servers[0..]);

    const unknown = try activateByName(a, "nope");
    defer a.free(unknown);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "No MCP server named") != null);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "off") != null); // 列出可用名

    const disabled = try activateByName(a, "off");
    defer a.free(disabled);
    try std.testing.expect(std.mem.indexOf(u8, disabled, "disabled") != null);
}

test "activateByName discovers a live server, writes the catalog, and activates" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /bin/sh
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    dirs.setTestConfigDirOverride(dir_path);
    defer dirs.setTestConfigDirOverride(null);
    mcp_registry.resetActivationForTest();
    defer mcp_registry.resetActivationForTest();

    const init_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"serverInfo\":{\"name\":\"fake\",\"version\":\"1\"}}}";
    const list_line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"greet\",\"description\":\"Greet someone\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"who\":{\"type\":\"string\"}}}}]}}";
    const script = "printf '%s\\n' '" ++ init_line ++ "' '" ++ list_line ++ "'; exec cat >/dev/null";
    var args0 = [_][]u8{ @constCast("-c"), @constCast(script) };
    const servers = [_]mcp_registry.ServerConfig{.{ .name = @constCast("demo"), .command = @constCast("/bin/sh"), .args = args0[0..], .enabled = true }};
    try mcp_registry.saveConfigFile(a, servers[0..]);

    const msg = try activateByName(a, "demo");
    defer a.free(msg);
    defer mcp_registry.reloadCacheFromServersForTest(a, &.{}); // 释放本线程缓存
    try std.testing.expect(std.mem.indexOf(u8, msg, "Activated MCP server \"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "greet") != null);
    try std.testing.expect(mcp_registry.isActivated("demo"));

    // 目录已落盘且 hash 匹配
    var cat = mcp_catalog.load(a);
    defer cat.deinit(a);
    const entry = cat.find("demo").?;
    const arg_view = [_][]const u8{ "-c", script };
    try std.testing.expectEqual(mcp_catalog.configHash("/bin/sh", arg_view[0..]), entry.config_hash);
    try std.testing.expectEqual(@as(usize, 1), entry.tools.len);
}
```

- [ ] **Step 2: 注册四件套**

2a. `src/agent_tools/mod.zig`:import 区 `const agent_mcp_config = ...` 后加

```zig
const agent_mcp_activate = @import("mcp_activate.zig");
```

`executeToolCall` 里 mcp_config 分派臂(~225)后加:

```zig
    if (std.mem.eql(u8, call.name, "mcp_activate")) {
        return agent_mcp_activate.run(ctx, call.arguments);
    }
```

2b. `protocol.zig` `builtinToolNameReserved` 的 `"mcp_config",` 后加 `"mcp_activate",`。

2c. `protocol.zig` `forEachToolSpec` 中 mcp_config 的 emitTool(~794 行)后加:

```zig
    try Filtered.emitTool(ctx, opts, "mcp_activate", "Activate one of the user's configured MCP servers so its tools become callable in this conversation. Inactive servers are listed in the system prompt. If the server was never discovered, this connects to it once to list its tools. Call this before using any tool that belongs to an inactive MCP server.", "{\"server\":{\"type\":\"string\",\"description\":\"MCP server name, as listed in the system prompt or by mcp_config action=list.\"}}");
```

2d. `src/tools/first_party.zig` static_definitions 中 mcp_config 条目后加:

```zig
    .{ .name = "mcp_activate", .label = "mcp_activate", .description = "Activate a configured MCP server's tools for the conversation.", .category = .agent },
```

2e. `src/test_fast.zig` 加 `_ = @import("agent_tools/mcp_activate.zig");`。

- [ ] **Step 3: 协议广告测试**(protocol.zig 底部测试区,模仿相邻 advertise 测试)

```zig
test "buildRequestJson advertises mcp_activate" {
    const a = std.testing.allocator;
    const params = RequestParams{ .model = "m", .system_prompt = "s", .protocol = .chat_completions, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const json = try buildRequestJson(a, params, &.{}, true);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"mcp_activate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"server\"") != null);
}
```

注意:`collectBuiltinToolNamesForTesting names all active first-party catalog tools` 这个既有测试会因为 first_party 多了一个名字而要求 forEachToolSpec 里也有——2c 已满足;若它反向断言数量,按实际失败信息把 `mcp_activate` 加进它的期望清单。

- [ ] **Step 4: 跑测试**

Run: `zig build test`
Expected: PASS(新 3 个测试 + 既有 protocol/first_party 一致性测试)

- [ ] **Step 5: 提交**

```bash
zig fmt build.zig src
git add src/agent_tools/mcp_activate.zig src/agent_tools/mod.zig src/assistant/conversation/protocol.zig src/tools/first_party.zig src/test_fast.zig
git commit -m "feat(mcp): mcp_activate tool — activate a server, discovering on demand

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: 请求管线接入(按激活注入 + 目录摘要 + 同轮刷新)

**Files:**
- Modify: `src/assistant/conversation/skills.zig`(新增 `skillsDigest`)
- Modify: `src/assistant/conversation/session.zig`(createChatRequestLocked ~4150-4170;新 pub fn `refreshRequestMcpTools`、`composeToolCatalogDigest`)
- Modify: `src/assistant/ai_chat.zig`(按 `reloadMcpTools` 的既有再导出方式,再导出 `refreshRequestMcpTools`)
- Modify: `src/assistant/conversation/request.zig`(agent loop ~338-357)

**Interfaces:**
- Consumes: Task 3 `cloneActivatedSpecs/ensureCacheFresh/inactiveDigest`、`cachedTools`;session 既有 `cloneMcpTools`/`freeOwnedMcpToolSpecs`/`freeOwnedMcpTools`。
- Produces:
  - `skills.zig`: `pub fn skillsDigest(allocator) !?[]u8`
  - `session.zig`: `pub fn refreshRequestMcpTools(request: *ChatRequest) void`(经 ai_chat 再导出)

- [ ] **Step 1: skills.zig 的 skillsDigest + 测试**

实现(放在 `listSkillsForDisplayFromRoots` 后):

```zig
/// System-prompt digest of available skills (one line each), so the model
/// knows what skill_info can load. Null when no skills are installed.
pub fn skillsDigest(allocator: std.mem.Allocator) !?[]u8 {
    const roots = try defaultSkillRootPaths(allocator);
    defer freeSkillRootPaths(allocator, roots);
    return skillsDigestFromRoots(allocator, roots);
}

fn skillsDigestFromRoots(allocator: std.mem.Allocator, root_paths: []const []const u8) !?[]u8 {
    const merged = try loadSkillSuggestionListFromRoots(allocator, root_paths);
    defer {
        freeOwnedSkillMetaList(allocator, merged);
        allocator.free(merged);
    }
    if (merged.len == 0) return null;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Skills — call skill_info with the name to load full instructions:\n");
    for (merged) |meta| {
        try out.print(allocator, "- {s}: {s}\n", .{ meta.name, meta.description });
    }
    return try out.toOwnedSlice(allocator);
}
```

测试(模仿本文件既有 root-based 测试的 tmp-root 构造;若已有构造 skill 目录的测试 helper 直接复用):

```zig
test "skillsDigest lists skills or returns null when none" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const roots = [_][]const u8{root};

    try std.testing.expect(try skillsDigestFromRoots(a, roots[0..]) == null);

    try tmp.dir.makePath("skills/pdf-tools");
    var f = try tmp.dir.createFile("skills/pdf-tools/SKILL.md", .{});
    defer f.close();
    try f.writeAll("---\nname: pdf-tools\ndescription: Extract and convert PDF files\n---\nbody\n");

    const digest = (try skillsDigestFromRoots(a, roots[0..])).?;
    defer a.free(digest);
    try std.testing.expect(std.mem.indexOf(u8, digest, "pdf-tools: Extract and convert PDF files") != null);
    try std.testing.expect(std.mem.indexOf(u8, digest, "skill_info") != null);
}
```

(SKILL.md 前导格式如与 skill_registry 实际解析不符,参照 `src/skill/registry.zig` 既有测试的 fixture 写法修正。)

- [ ] **Step 2: session.zig — 请求构建改造**

2a. createChatRequestLocked 中(4149 行 `working_dir` 之后、4150 compose 之前)无需动;**替换 4150 行**为带目录摘要的组合:

```zig
        const base_prompt = try composeSystemPromptWithMemory(self.allocator, self.systemPrompt(), settings.memory_enabled, working_dir);
        const system_prompt = appendToolCatalogDigest(self.allocator, base_prompt);
```

新增两个私有函数(composeSystemPromptWithMemory 附近,~4431):

```zig
/// Append the deferred-tool digest (inactive MCP servers + installed skills)
/// to the composed system prompt. Takes ownership of `base`; returns either
/// `base` unchanged or a new owned string (base freed). Never fails the
/// request — digest errors just mean no digest.
fn appendToolCatalogDigest(allocator: std.mem.Allocator, base: []u8) []u8 {
    const digest = composeToolCatalogDigest(allocator) orelse return base;
    defer allocator.free(digest);
    const joined = std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ base, digest }) catch return base;
    allocator.free(base);
    return joined;
}

fn composeToolCatalogDigest(allocator: std.mem.Allocator) ?[]u8 {
    mcp_registry.ensureCacheFresh(allocator);
    const mcp_part = mcp_registry.inactiveDigest(allocator) catch null;
    defer if (mcp_part) |p| allocator.free(p);
    const skills_part = ai_chat_skills.skillsDigest(allocator) catch null;
    defer if (skills_part) |p| allocator.free(p);
    if (mcp_part == null and skills_part == null) return null;
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
        if (mcp_part) |p| p else "",
        if (mcp_part != null and skills_part != null) "\n" else "",
        if (skills_part) |p| p else "",
    }) catch null;
}
```

(`ai_chat_skills` 是 session.zig 对 skills.zig 的既有 import 名;grep `skills.zig` 的 import 行确认真实别名并沿用。)

2b. **替换 4165 行**:

```zig
        const mcp_tool_specs = try mcp_registry.cloneActivatedSpecs(self.allocator);
```

2c. **替换 4168 行**(dispatch 快照直接取 registry,保证与 2b 同源同鲜度;`ensureCacheFresh` 已在 2a 调过):

```zig
        const mcp_tools = try cloneMcpTools(self.allocator, mcp_registry.cachedTools());
```

2d. 新增同轮刷新入口(ChatRequest 定义附近,`toParams` 之后):

```zig
/// Re-snapshot the request's MCP advertise + dispatch lists from the registry.
/// Called by the agent loop after an mcp_activate call so newly activated
/// (possibly newly discovered) tools are usable in the SAME turn.
pub fn refreshRequestMcpTools(request: *ChatRequest) void {
    mcp_registry.ensureCacheFresh(request.allocator);
    const specs = mcp_registry.cloneActivatedSpecs(request.allocator) catch return;
    const tools = cloneMcpTools(request.allocator, mcp_registry.cachedTools()) catch {
        freeOwnedMcpToolSpecs(request.allocator, specs);
        return;
    };
    freeOwnedMcpToolSpecs(request.allocator, request.mcp_tool_specs);
    freeOwnedMcpTools(request.allocator, request.mcp_tools);
    request.mcp_tool_specs = specs;
    request.mcp_tools = tools;
}
```

2e. `src/assistant/ai_chat.zig`:找到 `reloadMcpTools` 的再导出行,紧邻加同样式的 `refreshRequestMcpTools` 再导出。

- [ ] **Step 3: request.zig — agent loop 钩子**(338-357 行的 tool_calls for 循环)

在 `for (result.tool_calls.?) |call| {` 前加 `var mcp_specs_dirty = false;`;循环体内(`executeToolCall` 之后)加:

```zig
            if (std.mem.eql(u8, call.name, "mcp_activate")) mcp_specs_dirty = true;
```

循环结束后、`result.deinit(...)` 之前加:

```zig
        if (mcp_specs_dirty) ai_chat.refreshRequestMcpTools(request);
```

- [ ] **Step 4: 跑测试 + 全量编译检查**

Run: `zig build test` → PASS
Run: `zig build test-full -Dtarget=aarch64-macos`(真正跑 app 测试,~2300 个;`skill center tool import` 偶发 FileNotFound 可忽略)
Expected: PASS

- [ ] **Step 5: 提交**

```bash
zig fmt build.zig src
git add src/assistant/conversation/skills.zig src/assistant/conversation/session.zig src/assistant/conversation/request.zig src/assistant/ai_chat.zig
git commit -m "feat(mcp): advertise only activated servers; tool-catalog digest in system prompt; same-turn refresh after mcp_activate

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: 面板 probe 顺手写目录 + 文档

**Files:**
- Modify: `src/assistant/mcp_probe.zig`(`probeBlocking`/`start`/`Ctx` 签名加 `catalog_name`)
- Modify: `src/renderer/overlays.zig:2617-2640`(`mcpStartProbeFromForm` 传表单 name)
- Modify: `docs/ai-agent.md`(MCP 配置节)

**Interfaces:**
- Consumes: `mcp_catalog.upsertServer/configHash`、`mcp_registry.mcpPropertiesFromSchema`(pub)、overlays 的 `st.formField(.name)`。
- Produces: `pub fn probeBlocking(allocator, command, args, catalog_name: ?[]const u8) Result`;`pub fn start(allocator, command, args, catalog_name: ?[]const u8, done, ctx) void`。

- [ ] **Step 1: 写失败测试**(mcp_probe.zig 底部;既有 2 个测试的调用处补 `null` 参数)

```zig
test "probeBlocking with catalog_name writes the disk catalog" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);

    const init_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"serverInfo\":{\"name\":\"f\",\"version\":\"1\"}}}";
    const list_line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"e\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"t\":{\"type\":\"string\"}}}}]}}";
    const script = "printf '%s\\n' '" ++ init_line ++ "' '" ++ list_line ++ "'; exec cat >/dev/null";
    var args = [_][]const u8{ "-c", script };

    const r = probeBlocking(a, "/bin/sh", args[0..], "probed");
    try std.testing.expect(r.ok);

    var cat = mcp_catalog.load(a);
    defer cat.deinit(a);
    const entry = cat.find("probed").?;
    try std.testing.expectEqual(mcp_catalog.configHash("/bin/sh", args[0..]), entry.config_hash);
    try std.testing.expectEqual(@as(usize, 1), entry.tools.len);
    try std.testing.expectEqualStrings("{\"t\":{\"type\":\"string\"}}", entry.tools[0].properties_json);
}
```

- [ ] **Step 2: 实现**

2a. mcp_probe.zig 顶部 import 加:

```zig
const mcp_catalog = @import("../tools/mcp_catalog.zig");
const mcp_registry = @import("../tools/mcp_registry.zig");
const ai_chat_protocol = @import("conversation/protocol.zig");
const platform_dirs = @import("../platform/dirs.zig");
```

2b. `probeBlocking` 签名加第 4 参 `catalog_name: ?[]const u8`;在 `result.tool_count = n; result.ok = true;` 之前插入:

```zig
    if (catalog_name) |cname| {
        if (cname.len > 0) {
            writeCatalog(allocator, cname, command, args, tools) catch |err|
                log.warn("mcp probe: catalog write for '{s}' failed: {s}", .{ cname, @errorName(err) });
        }
    }
```

新增:

```zig
/// Persist a successful probe's full tool listing so the registry can build
/// the catalog without spawning this server again.
fn writeCatalog(
    allocator: std.mem.Allocator,
    name: []const u8,
    command: []const u8,
    args: []const []const u8,
    defs: []const mcp_client.ToolDef,
) !void {
    const specs = try allocator.alloc(ai_chat_protocol.McpToolSpec, defs.len);
    var filled: usize = 0;
    defer {
        for (specs[0..filled]) |s| allocator.free(s.properties_json);
        allocator.free(specs);
    }
    for (defs) |def| {
        const props = try mcp_registry.mcpPropertiesFromSchema(allocator, def.input_schema_json);
        specs[filled] = .{ .name = def.name, .description = def.description, .properties_json = props };
        filled += 1;
    }
    try mcp_catalog.upsertServer(allocator, name, mcp_catalog.configHash(command, args), std.time.timestamp(), specs[0..filled]);
}
```

2c. `Ctx` 加字段 `catalog_name: ?[]u8`;`worker` 里调用改为 `probeBlocking(ctx.allocator, ctx.command, ctx.args, ctx.catalog_name)`,defer 释放区加 `if (ctx.catalog_name) |n| ctx.allocator.free(n);`。

2d. `start` 签名在 `args` 后加 `catalog_name: ?[]const u8`,按 `command_copy` 同样方式 dupe(失败时按既有 OOM 分支模式清理),填进 `worker_ctx`。

2e. 既有 2 个 probeBlocking 测试补第 4 参 `null`。

2f. overlays.zig `mcpStartProbeFromForm`(2639 行)改:

```zig
    const name = st.formField(.name);
    mcp_probe.start(allocator, command, args_buf[0..args_len], if (name.len > 0) name else null, mcpProbeDone, @ptrCast(st));
```

- [ ] **Step 3: 文档**——`docs/ai-agent.md` 的 MCP 节追加一段(中英与文件既有风格一致):

- 说明启动不再连接 MCP server;系统提示会列出未激活 server 与 skill;
- 模型用 `mcp_activate` 激活(首次自动发现并缓存到 `mcp_catalog.json`);
- 面板"Test"成功也会写缓存,所以配好后测一次 = 之后目录直接可用。

- [ ] **Step 4: 全量验证**

Run: `zig build test` → PASS
Run: `zig fmt build.zig src`(无 diff)
Run: `zig build test-full -Dtarget=aarch64-macos` → PASS(flaky skill-center 除外)
Run: `zig build macos-app -Dtarget=aarch64-macos`(能出 app;人工冒烟可选:启动应秒开,无 MCP 进程;对模型说"用 jina 搜索 x"应看到 mcp_activate → 工具调用)

- [ ] **Step 5: 提交**

```bash
zig fmt build.zig src
git add src/assistant/mcp_probe.zig src/renderer/overlays.zig docs/ai-agent.md
git commit -m "feat(mcp): panel Test probe writes the tool catalog; docs for deferred loading

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review 记录

- **Spec 覆盖**:磁盘缓存(T1)、零 spawn 启动(T2)、激活+过滤注入(T3/T5)、目录摘要含 skill(T3/T5)、mcp_activate 含现场发现(T4)、同轮生效(T5)、probe 写缓存(T6)、`enabled=false` 不进目录(T2 测试)、损坏文件降级(T1 测试)。**兜底自动执行**:dispatch 快照始终为全量已发现工具(T5 2c),模型未激活直接调用已发现工具时 `agent_mcp.find` 命中即执行——零新代码,spec 第 5 节达成。**缓存过时重试一次**(spec 错误处理表第 3 行):有意降级不做——spawn-per-call 下 server 每次调用都是新进程,工具改名会返回 MCP 错误文本,模型可自行 mcp_activate 重发现;记为 spec 修订。
- **偏差(均已回写 spec)**:① 激活集为进程级全局而非 per-session(guard 限制 + 行为可接受);② 摘要在 session 层拼进 system_prompt 而非 buildRequestJson(三协议一处覆盖);③ 缓存过时不自动重试。
- **类型一致性**:`cloneActivatedSpecs` 返回 owned `[]McpToolSpec` ↔ ChatRequest.deinit 的 `freeOwnedMcpToolSpecs`;`CachedServer.spec_off/len` 同时索引 specs 与 tools(1:1,同序追加);`upsertServer(allocator, name, hash, i64, []const McpToolSpec)` 在 T1 定义、T4/T6 消费,签名一致。
