# Active-tab UI Screenshot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `ui_screenshot` first-party agent tool that captures the active WispTerm tab or focused active-tab panel to a local PNG path, so WeChat-triggered agents can send it back with `weixin_send_attachment`.

**Architecture:** The agent tool parses `target` and optional `surface_id`, then calls a new optional `ToolHost.uiScreenshot` callback. The real AppWindow host marshals to the UI thread, resolves an active-tab framebuffer rectangle, reads the current visible framebuffer through a backend readback primitive, writes a PNG under `wispterm-files`, and returns path/size metadata. V1 supports the OpenGL backend used by the primary Windows target; the Metal backend returns `UnsupportedReadback` instead of pretending to work.

**Tech Stack:** Zig 0.15.2, WispTerm `ToolHost`, `appwindow/agent_requests.zig`, `thread_message.zig`, OpenGL `ReadPixels`, stdlib CRC/Adler hashing, pure PNG writer.

---

## Ghostty Comparison

Ghostty has no WeChat or AI screenshot tool. Its relevant precedent is renderer layering: `src/renderer/generic.zig` documents a hierarchy where `GraphicsAPI` owns render `Target`s and frame/render-pass objects, while terminal state remains separate. `src/renderer/opengl/Target.zig` wraps an OpenGL framebuffer as a render target. WispTerm should follow that split: `remote_snapshot.zig` remains terminal text/VT state, while `ui_screenshot` lives at the AppWindow/render-host boundary.

## File Structure

- Create `src/appwindow/png_writer.zig`: pure PNG encoder for RGBA8 data, row flipping, and tests. Uses stdlib `std.hash.crc.Crc32` and `std.hash.Adler32`; no new build dependency.
- Create `src/agent_tools/ui_screenshot.zig`: argument parsing, target defaults, host callback call, and text result formatting.
- Modify `src/assistant/conversation/types.zig`: add `UiScreenshotTarget`, `UiScreenshotResult`, and optional `ToolHost.uiScreenshot`.
- Modify `src/agent_tools/mod.zig`: dispatch `ui_screenshot` to the new leaf module and add focused tests.
- Modify `src/tools/first_party.zig`: add catalog entry.
- Modify `src/assistant/conversation/protocol.zig`: advertise schema to all supported model protocols.
- Create `src/renderer/gpu/opengl/readback.zig`: OpenGL `ReadPixels` RGBA readback.
- Create `src/renderer/gpu/metal/readback.zig`: explicit unsupported readback for macOS/Metal v1.
- Modify `src/renderer/gpu/opengl/api.zig`, `src/renderer/gpu/metal/api.zig`, `src/renderer/gpu/gpu.zig`: export `readback`.
- Modify `src/appwindow/thread_message.zig`: add `agent_ui_screenshot` message tag.
- Modify `src/appwindow/agent_requests.zig`: add synchronous UI-thread screenshot request bridge.
- Modify `src/AppWindow.zig`: install the host callback, handle the message, resolve capture rectangles, call readback/PNG writer, and return metadata.
- Modify `src/test_fast.zig`: include `appwindow/png_writer.zig`.

## Task 1: Pure PNG Writer

**Files:**
- Create: `src/appwindow/png_writer.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write failing tests for PNG encoding and row flipping**

Create `src/appwindow/png_writer.zig` with only tests and stub signatures:

```zig
const std = @import("std");
const png_dimensions = @import("../preview/png_dimensions.zig");

pub const Image = struct {
    width: u32,
    height: u32,
    rgba: []const u8,
};

pub fn encodeRgba(allocator: std.mem.Allocator, image: Image) ![]u8 {
    _ = allocator;
    _ = image;
    return error.Unimplemented;
}

pub fn flipRgbaRows(allocator: std.mem.Allocator, bottom_up: []const u8, width: u32, height: u32) ![]u8 {
    _ = allocator;
    _ = bottom_up;
    _ = width;
    _ = height;
    return error.Unimplemented;
}

test "png_writer encodes RGBA8 PNG with expected dimensions" {
    const rgba = [_]u8{
        255, 0, 0, 255,
        0, 255, 0, 255,
        0, 0, 255, 255,
        255, 255, 255, 255,
    };
    const png = try encodeRgba(std.testing.allocator, .{
        .width = 2,
        .height = 2,
        .rgba = &rgba,
    });
    defer std.testing.allocator.free(png);

    try std.testing.expect(std.mem.startsWith(u8, png, "\x89PNG\r\n\x1a\n"));
    const dims = png_dimensions.parse(png) orelse return error.MissingPngDimensions;
    try std.testing.expectEqual(@as(u32, 2), dims.width);
    try std.testing.expectEqual(@as(u32, 2), dims.height);
    try std.testing.expect(std.mem.endsWith(u8, png, "IEND\xaeB`\x82"));
}

test "png_writer flips OpenGL bottom-up RGBA rows into PNG top-down rows" {
    const bottom_up = [_]u8{
        1, 1, 1, 255, 2, 2, 2, 255,
        3, 3, 3, 255, 4, 4, 4, 255,
    };
    const top_down = try flipRgbaRows(std.testing.allocator, &bottom_up, 2, 2);
    defer std.testing.allocator.free(top_down);

    try std.testing.expectEqualSlices(u8, &[_]u8{
        3, 3, 3, 255, 4, 4, 4, 255,
        1, 1, 1, 255, 2, 2, 2, 255,
    }, top_down);
}

test "png_writer rejects RGBA buffers with the wrong size" {
    try std.testing.expectError(error.InvalidImageBuffer, encodeRgba(std.testing.allocator, .{
        .width = 2,
        .height = 2,
        .rgba = &[_]u8{0} ** 15,
    }));
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
zig test src/appwindow/png_writer.zig
```

Expected: failure with `Unimplemented` from `encodeRgba` or `flipRgbaRows`.

- [ ] **Step 3: Implement the minimal PNG writer**

Replace the stubs in `src/appwindow/png_writer.zig` with:

```zig
const std = @import("std");
const png_dimensions = @import("../preview/png_dimensions.zig");

const png_signature = "\x89PNG\r\n\x1a\n";
const max_deflate_block: usize = 65_535;

pub const Error = error{
    InvalidImageDimensions,
    InvalidImageBuffer,
} || std.mem.Allocator.Error;

pub const Image = struct {
    width: u32,
    height: u32,
    rgba: []const u8,
};

fn checkedRgbaLen(width: u32, height: u32) Error!usize {
    if (width == 0 or height == 0) return error.InvalidImageDimensions;
    const pixels = std.math.mul(usize, width, height) catch return error.InvalidImageDimensions;
    return std.math.mul(usize, pixels, 4) catch return error.InvalidImageDimensions;
}

fn appendU32(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .big);
    try out.appendSlice(allocator, &buf);
}

fn appendChunk(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, kind: *const [4]u8, data: []const u8) !void {
    try appendU32(out, allocator, @intCast(data.len));
    try out.appendSlice(allocator, kind);
    try out.appendSlice(allocator, data);

    var crc_bytes = try allocator.alloc(u8, kind.len + data.len);
    defer allocator.free(crc_bytes);
    @memcpy(crc_bytes[0..4], kind);
    @memcpy(crc_bytes[4..], data);
    try appendU32(out, allocator, std.hash.crc.Crc32.hash(crc_bytes));
}

fn appendZlibStored(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, payload: []const u8) !void {
    try out.appendSlice(allocator, &.{ 0x78, 0x01 });
    var remaining = payload;
    while (remaining.len > 0) {
        const n = @min(remaining.len, max_deflate_block);
        const final: u8 = if (n == remaining.len) 1 else 0;
        try out.append(allocator, final);

        var len_buf: [2]u8 = undefined;
        const len16: u16 = @intCast(n);
        std.mem.writeInt(u16, &len_buf, len16, .little);
        try out.appendSlice(allocator, &len_buf);
        std.mem.writeInt(u16, &len_buf, ~len16, .little);
        try out.appendSlice(allocator, &len_buf);

        try out.appendSlice(allocator, remaining[0..n]);
        remaining = remaining[n..];
    }
    try appendU32(out, allocator, std.hash.Adler32.hash(payload));
}

pub fn encodeRgba(allocator: std.mem.Allocator, image: Image) ![]u8 {
    const expected = try checkedRgbaLen(image.width, image.height);
    if (image.rgba.len != expected) return error.InvalidImageBuffer;

    const row_bytes = @as(usize, image.width) * 4;
    const filtered_len = (@as(usize, image.height) * (row_bytes + 1));
    var filtered = try std.ArrayListUnmanaged(u8).initCapacity(allocator, filtered_len);
    defer filtered.deinit(allocator);
    for (0..image.height) |row| {
        try filtered.append(allocator, 0);
        const start = row * row_bytes;
        try filtered.appendSlice(allocator, image.rgba[start .. start + row_bytes]);
    }

    var idat = std.ArrayListUnmanaged(u8).empty;
    defer idat.deinit(allocator);
    try appendZlibStored(&idat, allocator, filtered.items);

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, png_signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], image.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], image.height, .big);
    ihdr[8] = 8;
    ihdr[9] = 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendChunk(&out, allocator, "IHDR", &ihdr);
    try appendChunk(&out, allocator, "IDAT", idat.items);
    try appendChunk(&out, allocator, "IEND", &.{});
    return out.toOwnedSlice(allocator);
}

pub fn flipRgbaRows(allocator: std.mem.Allocator, bottom_up: []const u8, width: u32, height: u32) ![]u8 {
    const expected = try checkedRgbaLen(width, height);
    if (bottom_up.len != expected) return error.InvalidImageBuffer;
    const row_bytes = @as(usize, width) * 4;
    const out = try allocator.alloc(u8, bottom_up.len);
    errdefer allocator.free(out);
    for (0..height) |row| {
        const src_row = @as(usize, height) - 1 - row;
        @memcpy(out[row * row_bytes .. (row + 1) * row_bytes], bottom_up[src_row * row_bytes .. (src_row + 1) * row_bytes]);
    }
    return out;
}
```

- [ ] **Step 4: Add the pure module to the fast suite**

In `src/test_fast.zig`, add this import near the other `appwindow/*` imports:

```zig
    _ = @import("appwindow/png_writer.zig");
```

- [ ] **Step 5: Run tests and verify they pass**

Run:

```bash
zig test src/appwindow/png_writer.zig
zig build test
```

Expected: both pass.

- [ ] **Step 6: Commit**

```bash
git add src/appwindow/png_writer.zig src/test_fast.zig
git commit -m "feat(agent): add pure png writer for ui screenshots"
```

## Task 2: Agent Tool Types, Schema, and Dispatch

**Files:**
- Modify: `src/assistant/conversation/types.zig`
- Create: `src/agent_tools/ui_screenshot.zig`
- Modify: `src/agent_tools/mod.zig`
- Modify: `src/tools/first_party.zig`
- Modify: `src/assistant/conversation/protocol.zig`

- [ ] **Step 1: Write failing protocol/catalog tests**

In `src/assistant/conversation/protocol.zig`, add:

```zig
test "agent tool set includes ui_screenshot" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{.{ .role = .user, .content = @constCast("show me the screen") }};
    const params = RequestParams{ .model = "m", .system_prompt = "", .protocol = .chat_completions, .thinking_enabled = false, .reasoning_effort = "", .stream = false };
    const json = try buildRequestJson(a, params, &msgs, true);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ui_screenshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"target\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"surface_id\"") != null);
}
```

In `src/agent_tools/mod.zig`, add:

```zig
test "executeToolCall ui_screenshot reports missing host clearly" {
    const a = std.testing.allocator;
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{ .permission = .full, .access_rules = null, .working_dir = "/work" },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try executeToolCall(&ctx, .{
        .id = @constCast("call-shot"),
        .name = @constCast("ui_screenshot"),
        .arguments = @constCast("{}"),
    });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "No UI screenshot host") != null);
}
```

- [ ] **Step 2: Run focused tests and verify they fail**

Run:

```bash
zig test src/assistant/conversation/protocol.zig --test-filter ui_screenshot
zig test src/agent_tools/mod.zig --test-filter ui_screenshot
```

Expected: protocol test fails because the schema is absent; tool test fails because dispatch returns `Unknown tool`.

- [ ] **Step 3: Add shared types and optional host callback**

In `src/assistant/conversation/types.zig`, after `ToolClosedTab`, add:

```zig
pub const UiScreenshotTarget = enum {
    focused_panel,
    active_tab,

    pub fn label(self: UiScreenshotTarget) []const u8 {
        return switch (self) {
            .focused_panel => "focused_panel",
            .active_tab => "active_tab",
        };
    }
};

pub const UiScreenshotResult = struct {
    path: []u8,
    width: u32,
    height: u32,
    target: UiScreenshotTarget,

    pub fn deinit(self: UiScreenshotResult, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};
```

Then add this field at the end of `ToolHost`:

```zig
    uiScreenshot: ?*const fn (*anyopaque, std.mem.Allocator, UiScreenshotTarget, ?[]const u8, ?[]const u8) anyerror!UiScreenshotResult = null,
```

- [ ] **Step 4: Create the agent tool leaf module**

Create `src/agent_tools/ui_screenshot.zig`:

```zig
//! Agent UI screenshot tool.
const std = @import("std");
const types = @import("../assistant/conversation/types.zig");

const ToolContext = types.ToolContext;
const UiScreenshotTarget = types.UiScreenshotTarget;

fn parseTarget(text: ?[]const u8) ?UiScreenshotTarget {
    const raw = std.mem.trim(u8, text orelse "focused_panel", " \t\r\n");
    if (raw.len == 0 or std.ascii.eqlIgnoreCase(raw, "focused_panel") or std.ascii.eqlIgnoreCase(raw, "focused")) return .focused_panel;
    if (std.ascii.eqlIgnoreCase(raw, "active_tab") or std.ascii.eqlIgnoreCase(raw, "tab")) return .active_tab;
    return null;
}

pub fn run(ctx: *ToolContext, target_text: ?[]const u8, surface_id: ?[]const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");
    const target = parseTarget(target_text) orelse return ctx.allocator.dupe(u8, "Invalid target; expected focused_panel or active_tab.");
    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No UI screenshot host is available.");
    const callback = host.uiScreenshot orelse return ctx.allocator.dupe(u8, "No UI screenshot host is available.");
    const result = callback(host.ctx, ctx.allocator, target, surface_id, ctx.settings.working_dir) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "ui_screenshot failed: {s}", .{@errorName(err)});
    };
    defer result.deinit(ctx.allocator);
    return std.fmt.allocPrint(
        ctx.allocator,
        "screenshot path={s} width={d} height={d} target={s}",
        .{ result.path, result.width, result.height, result.target.label() },
    );
}

test "ui_screenshot target parser accepts defaults and aliases" {
    try std.testing.expectEqual(UiScreenshotTarget.focused_panel, parseTarget(null).?);
    try std.testing.expectEqual(UiScreenshotTarget.focused_panel, parseTarget("focused").?);
    try std.testing.expectEqual(UiScreenshotTarget.active_tab, parseTarget("tab").?);
    try std.testing.expect(parseTarget("pane") == null);
}
```

- [ ] **Step 5: Dispatch the tool**

In `src/agent_tools/mod.zig`, add the import:

```zig
const agent_ui_screenshot = @import("ui_screenshot.zig");
```

In `executeToolCall`, after `terminal_snapshot` or near other terminal observation tools, add:

```zig
    if (std.mem.eql(u8, call.name, "ui_screenshot")) {
        const args = tool_args.parse(ctx.allocator, call.arguments);
        defer if (args) |parsed| parsed.deinit();
        const target = if (args) |parsed| tool_args.string(parsed.value, "target") else null;
        const surface_id = if (args) |parsed| tool_args.string(parsed.value, "surface_id") else null;
        return agent_ui_screenshot.run(ctx, target, surface_id);
    }
```

- [ ] **Step 6: Add catalog and schema entries**

In `src/tools/first_party.zig`, add:

```zig
    .{ .name = "ui_screenshot", .label = "ui_screenshot", .description = "Capture the active WispTerm tab or focused active-tab panel as a local PNG file.", .category = .terminal },
```

In `src/assistant/conversation/protocol.zig`, in `forEachToolSpec` after `terminal_snapshot`, add:

```zig
    try Filtered.emitTool(ctx, opts, "ui_screenshot", "Capture a PNG screenshot of the active WispTerm tab or the focused panel in the active tab. Use target=focused_panel for the panel the user is looking at, or target=active_tab for the whole visible active tab. In a dedicated AI/Copilot tab, focused_panel falls back to active_tab. The tool returns a local PNG path; when the request came from Weixin, call weixin_send_attachment with kind=image and that path.", "{\"target\":{\"type\":\"string\",\"description\":\"Optional: focused_panel (default) or active_tab.\"},\"surface_id\":{\"type\":\"string\",\"description\":\"Optional terminal surface id from terminal_list. Only valid for terminal panels in the active tab.\"}}");
```

- [ ] **Step 7: Add a fake-host success test**

In `src/agent_tools/mod.zig`, add:

```zig
test "executeToolCall ui_screenshot calls host and formats path" {
    const Fake = struct {
        fn collectSnapshot(_: *anyopaque, allocator: std.mem.Allocator) anyerror!ToolSnapshot {
            return .{ .surfaces = try allocator.alloc(ToolSurface, 0), .active_tab = 0 };
        }
        fn surfaceSnapshot(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: *anyopaque) anyerror![]u8 {
            return allocator.dupe(u8, "");
        }
        fn writeSurface(_: *anyopaque, _: []const u8, _: *anyopaque, _: []const u8) bool {
            return false;
        }
        fn unsupportedSpawn(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: ?[]const u8) anyerror!ToolSurface {
            return error.Unsupported;
        }
        fn unsupportedClose(_: *anyopaque, _: std.mem.Allocator, _: ?usize, _: ?[]const u8, _: ?[]const u8) anyerror!ToolClosedTab {
            return error.Unsupported;
        }
        fn unsupportedSaveSsh(_: *anyopaque, _: std.mem.Allocator, _: SshProfileSaveArgs) anyerror!SavedSshProfile {
            return error.Unsupported;
        }
        fn unsupportedConnectSsh(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!ToolSurface {
            return error.Unsupported;
        }
        fn shot(_: *anyopaque, allocator: std.mem.Allocator, target: types.UiScreenshotTarget, surface_id: ?[]const u8, working_dir: ?[]const u8) anyerror!types.UiScreenshotResult {
            try std.testing.expectEqual(types.UiScreenshotTarget.active_tab, target);
            try std.testing.expectEqualStrings("abc", surface_id.?);
            try std.testing.expectEqualStrings("/work", working_dir.?);
            return .{
                .path = try allocator.dupe(u8, "/work/wispterm-files/ui-screenshot-1.png"),
                .width = 10,
                .height = 20,
                .target = target,
            };
        }
        var dummy: u8 = 0;
        fn host() ToolHost {
            return .{
                .ctx = &dummy,
                .collectSnapshot = collectSnapshot,
                .surfaceSnapshot = surfaceSnapshot,
                .writeSurface = writeSurface,
                .spawnTab = unsupportedSpawn,
                .closeTab = unsupportedClose,
                .saveSshProfile = unsupportedSaveSsh,
                .connectSshProfile = unsupportedConnectSsh,
                .uiScreenshot = shot,
            };
        }
    };

    const a = std.testing.allocator;
    var ctx = ToolContext{
        .allocator = a,
        .ctx = &Fake.dummy,
        .tool_host = Fake.host(),
        .tool_snapshot = null,
        .settings = .{ .permission = .full, .access_rules = null, .working_dir = "/work" },
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    const out = try executeToolCall(&ctx, .{
        .id = @constCast("call-shot"),
        .name = @constCast("ui_screenshot"),
        .arguments = @constCast("{\"target\":\"active_tab\",\"surface_id\":\"abc\"}"),
    });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "path=/work/wispterm-files/ui-screenshot-1.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "width=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "height=20") != null);
}
```

- [ ] **Step 8: Run tests and verify they pass**

Run:

```bash
zig test src/agent_tools/ui_screenshot.zig
zig test src/agent_tools/mod.zig --test-filter ui_screenshot
zig test src/assistant/conversation/protocol.zig --test-filter ui_screenshot
zig build test
```

Expected: all pass.

- [ ] **Step 9: Commit**

```bash
git add src/assistant/conversation/types.zig src/agent_tools/ui_screenshot.zig src/agent_tools/mod.zig src/tools/first_party.zig src/assistant/conversation/protocol.zig
git commit -m "feat(agent): add ui_screenshot tool surface"
```

## Task 3: GPU Readback Primitive

**Files:**
- Create: `src/renderer/gpu/opengl/readback.zig`
- Create: `src/renderer/gpu/metal/readback.zig`
- Modify: `src/renderer/gpu/opengl/api.zig`
- Modify: `src/renderer/gpu/metal/api.zig`
- Modify: `src/renderer/gpu/gpu.zig`

- [ ] **Step 1: Add the OpenGL readback module**

Create `src/renderer/gpu/opengl/readback.zig`:

```zig
//! OpenGL framebuffer readback helpers.
const std = @import("std");
const Context = @import("Context.zig");
const c = @import("c.zig").c;

pub fn readRgba(allocator: std.mem.Allocator, x: i32, y: i32, width: u32, height: u32) ![]u8 {
    if (width == 0 or height == 0) return error.InvalidReadbackRect;
    const pixels = std.math.mul(usize, @as(usize, width), @as(usize, height)) catch return error.InvalidReadbackRect;
    const len = std.math.mul(usize, pixels, 4) catch return error.InvalidReadbackRect;
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    const gl = Context.gl;
    gl.PixelStorei.?(c.GL_PACK_ALIGNMENT, 1);
    gl.ReadPixels.?(
        x,
        y,
        @intCast(width),
        @intCast(height),
        c.GL_RGBA,
        c.GL_UNSIGNED_BYTE,
        out.ptr,
    );
    return out;
}
```

- [ ] **Step 2: Add the Metal unsupported module**

Create `src/renderer/gpu/metal/readback.zig`:

```zig
//! Metal framebuffer readback is not wired in v1.
const std = @import("std");

pub fn readRgba(allocator: std.mem.Allocator, x: i32, y: i32, width: u32, height: u32) ![]u8 {
    _ = allocator;
    _ = x;
    _ = y;
    _ = width;
    _ = height;
    return error.UnsupportedReadback;
}

test "metal readback reports unsupported" {
    try std.testing.expectError(error.UnsupportedReadback, readRgba(std.testing.allocator, 0, 0, 1, 1));
}
```

- [ ] **Step 3: Export readback through backend APIs**

In `src/renderer/gpu/opengl/api.zig`, add:

```zig
pub const readback = @import("readback.zig");
```

In `src/renderer/gpu/metal/api.zig`, add:

```zig
pub const readback = @import("readback.zig");
```

In `src/renderer/gpu/gpu.zig`, add:

```zig
pub const readback = impl.readback;
```

- [ ] **Step 4: Run compile tests**

Run:

```bash
zig build test
zig build test-full
```

Expected: both pass.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/gpu/opengl/readback.zig src/renderer/gpu/metal/readback.zig src/renderer/gpu/opengl/api.zig src/renderer/gpu/metal/api.zig src/renderer/gpu/gpu.zig
git commit -m "feat(renderer): add framebuffer readback primitive"
```

## Task 4: AppWindow Screenshot Helpers

**Files:**
- Create: `src/appwindow/ui_screenshot.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write failing helper tests**

Create `src/appwindow/ui_screenshot.zig`:

```zig
//! Pure helpers for active-tab UI screenshot capture.
const std = @import("std");
const agent_file_copy = @import("../agent/file_copy.zig");

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub fn clampRect(rect: Rect, fb_width: u32, fb_height: u32) ?Rect {
    _ = rect;
    _ = fb_width;
    _ = fb_height;
    return null;
}

pub fn glReadY(rect: Rect, fb_height: u32) i32 {
    _ = rect;
    _ = fb_height;
    return 0;
}

pub fn outputPath(allocator: std.mem.Allocator, working_dir: []const u8, now_ms: i64) ![]u8 {
    _ = allocator;
    _ = working_dir;
    _ = now_ms;
    return error.Unimplemented;
}

test "ui_screenshot clamps rectangles to framebuffer bounds" {
    const r = clampRect(.{ .x = -5, .y = 10, .width = 20, .height = 20 }, 100, 100).?;
    try std.testing.expectEqual(@as(i32, 0), r.x);
    try std.testing.expectEqual(@as(i32, 10), r.y);
    try std.testing.expectEqual(@as(u32, 15), r.width);
    try std.testing.expectEqual(@as(u32, 20), r.height);
    try std.testing.expect(clampRect(.{ .x = 200, .y = 0, .width = 10, .height = 10 }, 100, 100) == null);
}

test "ui_screenshot converts top-left rect y to OpenGL read y" {
    const r = Rect{ .x = 10, .y = 20, .width = 30, .height = 40 };
    try std.testing.expectEqual(@as(i32, 40), glReadY(r, 100));
}

test "ui_screenshot output path uses wispterm-files and a png basename" {
    const path = try outputPath(std.testing.allocator, "/work/project", 1234);
    defer std.testing.allocator.free(path);
    const expected = try std.fs.path.join(std.testing.allocator, &.{ "/work/project", agent_file_copy.DEFAULT_DIR, "ui-screenshot-1234.png" });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path);
}
```

- [ ] **Step 2: Run the focused test and verify it fails**

Run:

```bash
zig test src/appwindow/ui_screenshot.zig
```

Expected: failure from stubbed `clampRect` or `outputPath`.

- [ ] **Step 3: Implement helpers**

Replace stubs in `src/appwindow/ui_screenshot.zig` with:

```zig
pub fn clampRect(rect: Rect, fb_width: u32, fb_height: u32) ?Rect {
    if (rect.width == 0 or rect.height == 0 or fb_width == 0 or fb_height == 0) return null;
    const x0 = @max(rect.x, 0);
    const y0 = @max(rect.y, 0);
    const x1 = @min(rect.x + @as(i32, @intCast(rect.width)), @as(i32, @intCast(fb_width)));
    const y1 = @min(rect.y + @as(i32, @intCast(rect.height)), @as(i32, @intCast(fb_height)));
    if (x1 <= x0 or y1 <= y0) return null;
    return .{
        .x = x0,
        .y = y0,
        .width = @intCast(x1 - x0),
        .height = @intCast(y1 - y0),
    };
}

pub fn glReadY(rect: Rect, fb_height: u32) i32 {
    return @as(i32, @intCast(fb_height)) - rect.y - @as(i32, @intCast(rect.height));
}

pub fn outputPath(allocator: std.mem.Allocator, working_dir: []const u8, now_ms: i64) ![]u8 {
    if (working_dir.len == 0) return error.MissingWorkingDir;
    const name = try std.fmt.allocPrint(allocator, "ui-screenshot-{d}.png", .{now_ms});
    defer allocator.free(name);
    if (!agent_file_copy.isSafeDestinationName(name)) return error.UnsafeDestinationName;
    const dir = try std.fs.path.join(allocator, &.{ working_dir, agent_file_copy.DEFAULT_DIR });
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, name });
}
```

- [ ] **Step 4: Add the helper module to the fast suite**

In `src/test_fast.zig`, add near other appwindow imports:

```zig
    _ = @import("appwindow/ui_screenshot.zig");
```

- [ ] **Step 5: Run tests**

Run:

```bash
zig test src/appwindow/ui_screenshot.zig
zig build test
```

Expected: both pass.

- [ ] **Step 6: Commit**

```bash
git add src/appwindow/ui_screenshot.zig src/test_fast.zig
git commit -m "feat(appwindow): add screenshot helper utilities"
```

## Task 5: UI-thread Screenshot Bridge and Capture

**Files:**
- Modify: `src/appwindow/thread_message.zig`
- Modify: `src/appwindow/agent_requests.zig`
- Modify: `src/AppWindow.zig`

- [ ] **Step 1: Write failing bridge tests**

In `src/appwindow/thread_message.zig`, extend `Tag` with:

```zig
    agent_ui_screenshot,
```

Do not add it to `offset` yet.

Run:

```bash
zig test src/appwindow/thread_message.zig
```

Expected: compile failure because `offset` switch is missing `.agent_ui_screenshot`.

- [ ] **Step 2: Add thread message offset**

In `src/appwindow/thread_message.zig`, add:

```zig
        .agent_ui_screenshot => 0x58,
```

Run:

```bash
zig test src/appwindow/thread_message.zig
```

Expected: pass.

- [ ] **Step 3: Add request bridge types and callback**

In `src/appwindow/agent_requests.zig`, extend `Host`:

```zig
    captureUiScreenshot: *const fn (std.mem.Allocator, ai_chat.UiScreenshotTarget, ?[]const u8, ?[]const u8) anyerror!ai_chat.UiScreenshotResult,
```

Add the request type:

```zig
pub const AgentUiScreenshotRequest = struct {
    allocator: std.mem.Allocator,
    target: ai_chat.UiScreenshotTarget,
    surface_id: ?[]const u8,
    working_dir: ?[]const u8,
    result: ?ai_chat.UiScreenshotResult = null,
    err: ?anyerror = null,
};
```

Add the post helper:

```zig
fn postAgentUiScreenshot(native_handle: window_backend.NativeHandle, request: *AgentUiScreenshotRequest) void {
    postAgentRequest(native_handle, .agent_ui_screenshot, @intFromPtr(request));
}
```

Add the public callback:

```zig
pub fn uiScreenshot(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    target: ai_chat.UiScreenshotTarget,
    surface_id: ?[]const u8,
    working_dir: ?[]const u8,
) anyerror!ai_chat.UiScreenshotResult {
    const host = try installedHost();
    const native_handle = host.nativeHandleForContext(ctx) orelse return error.WindowUnavailable;
    var request = AgentUiScreenshotRequest{
        .allocator = allocator,
        .target = target,
        .surface_id = surface_id,
        .working_dir = working_dir,
    };
    if (host.currentNativeHandle()) |current| {
        if (current == native_handle) {
            handleUiScreenshotRequest(&request, host);
        } else {
            postAgentUiScreenshot(native_handle, &request);
        }
    } else {
        postAgentUiScreenshot(native_handle, &request);
    }
    if (request.err) |err| return err;
    return request.result orelse error.ScreenshotFailed;
}
```

Add the UI-thread handler:

```zig
pub fn handleUiScreenshotRequest(request: *AgentUiScreenshotRequest, host: Host) void {
    request.result = host.captureUiScreenshot(
        request.allocator,
        request.target,
        request.surface_id,
        request.working_dir,
    ) catch |err| {
        request.err = err;
        return;
    };
}
```

- [ ] **Step 4: Wire AppWindow message dispatch and ToolHost install**

In `src/AppWindow.zig`, add imports near existing appwindow imports:

```zig
const appwindow_ui_screenshot = @import("appwindow/ui_screenshot.zig");
const png_writer = @import("appwindow/png_writer.zig");
```

In `onPlatformMessage`, add:

```zig
        .agent_ui_screenshot => agent_requests.handleUiScreenshotRequest(@ptrFromInt(decoded.ptr), agent_host),
```

In `installAgentToolHost`, add:

```zig
        .uiScreenshot = agent_requests.uiScreenshot,
```

In `agentRequestHost`, add:

```zig
        .captureUiScreenshot = agentRequestCaptureUiScreenshot,
```

- [ ] **Step 5: Add AppWindow rectangle resolution and capture implementation**

In `src/AppWindow.zig`, near `agentRequestSaveSshProfile`, add:

```zig
fn activeTabFullRect(fb_width: i32, fb_height: i32) appwindow_ui_screenshot.Rect {
    return .{
        .x = 0,
        .y = 0,
        .width = @intCast(@max(fb_width, 0)),
        .height = @intCast(@max(fb_height, 0)),
    };
}

fn activeTabPanelRect(target: ai_chat.UiScreenshotTarget, surface_id: ?[]const u8, fb_width: i32, fb_height: i32) !appwindow_ui_screenshot.Rect {
    if (target == .active_tab) return activeTabFullRect(fb_width, fb_height);
    const active = activeTab() orelse return activeTabFullRect(fb_width, fb_height);
    if (active.kind != .terminal) return activeTabFullRect(fb_width, fb_height);

    if (surface_id) |sid_raw| {
        const sid = std.mem.trim(u8, sid_raw, " \t\r\n");
        if (sid.len == 0 or std.ascii.eqlIgnoreCase(sid, "focused") or std.ascii.eqlIgnoreCase(sid, "active") or std.ascii.eqlIgnoreCase(sid, "current")) {
            return activeTabPanelRect(.focused_panel, null, fb_width, fb_height);
        }
        for (0..split_layout.g_split_rect_count) |i| {
            const r = split_layout.g_split_rects[i];
            if (!split_layout.cachedRectIsLive(r)) continue;
            if (r.pane.surface()) |surface| {
                if (std.mem.eql(u8, surface.remote_id[0..], sid)) {
                    return .{ .x = r.x, .y = r.y, .width = @intCast(@max(r.width, 0)), .height = @intCast(@max(r.height, 0)) };
                }
            }
        }
        return error.SurfaceNotInActiveTab;
    }

    for (0..split_layout.g_split_rect_count) |i| {
        const r = split_layout.g_split_rects[i];
        if (!split_layout.cachedRectIsLive(r)) continue;
        if (r.handle == active.focused) {
            return .{ .x = r.x, .y = r.y, .width = @intCast(@max(r.width, 0)), .height = @intCast(@max(r.height, 0)) };
        }
    }
    return activeTabFullRect(fb_width, fb_height);
}

fn writeScreenshotFile(path: []const u8, png: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try std.fs.cwd().makePath(parent);
    }
    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.createFileAbsolute(path, .{ .truncate = true })
    else
        try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(png);
}

fn agentRequestCaptureUiScreenshot(
    allocator: std.mem.Allocator,
    target: ai_chat.UiScreenshotTarget,
    surface_id: ?[]const u8,
    working_dir: ?[]const u8,
) anyerror!ai_chat.UiScreenshotResult {
    const win = g_window orelse return error.WindowUnavailable;
    if (window_backend.isMinimized(win)) return error.WindowUnavailable;
    const wd = working_dir orelse return error.MissingWorkingDir;
    const fb = window_backend.framebufferSize(win);
    if (fb.width <= 0 or fb.height <= 0) return error.WindowUnavailable;
    const effective_target: ai_chat.UiScreenshotTarget = blk: {
        if (target != .focused_panel) break :blk target;
        const active = activeTab() orelse break :blk .active_tab;
        break :blk if (active.kind == .terminal) .focused_panel else .active_tab;
    };

    const requested = try activeTabPanelRect(target, surface_id, fb.width, fb.height);
    const rect = appwindow_ui_screenshot.clampRect(requested, @intCast(fb.width), @intCast(fb.height)) orelse return error.InvalidReadbackRect;
    const read_y = appwindow_ui_screenshot.glReadY(rect, @intCast(fb.height));
    const bottom_up = try gpu.readback.readRgba(allocator, rect.x, read_y, rect.width, rect.height);
    defer allocator.free(bottom_up);
    const top_down = try png_writer.flipRgbaRows(allocator, bottom_up, rect.width, rect.height);
    defer allocator.free(top_down);
    const png = try png_writer.encodeRgba(allocator, .{ .width = rect.width, .height = rect.height, .rgba = top_down });
    defer allocator.free(png);

    const path = try appwindow_ui_screenshot.outputPath(allocator, wd, std.time.milliTimestamp());
    errdefer allocator.free(path);
    try writeScreenshotFile(path, png);
    return .{
        .path = path,
        .width = rect.width,
        .height = rect.height,
        .target = effective_target,
    };
}
```

- [ ] **Step 6: Run compile tests and source guards**

Run:

```bash
zig build test
zig build test-full
```

Expected: both pass, with no source-guard ceiling increases. Guard failures are fixed by moving helper code into `src/appwindow/ui_screenshot.zig` with explicit inputs.

- [ ] **Step 7: Commit**

```bash
git add src/appwindow/thread_message.zig src/appwindow/agent_requests.zig src/AppWindow.zig
git commit -m "feat(agent): capture active tab ui screenshots"
```

## Task 6: End-to-end Verification and Documentation Check

**Files:**
- Read-only unless verification exposes a compile/test failure.

- [ ] **Step 1: Run the fast suite**

Run:

```bash
zig build test
```

Expected: pass.

- [ ] **Step 2: Run the full suite**

Run:

```bash
zig build test-full
```

Expected: pass.

- [ ] **Step 3: Run the Windows checkout safety check if files were added**

Use the command documented in `docs/development.md#windows-checkout-safety`.

Expected: no reserved names, illegal characters, case-fold collisions, symlinks, or excessive path lengths.

- [ ] **Step 4: Manual Windows smoke**

Build/run WispTerm on Windows, open an agent session, and ask:

```text
Call ui_screenshot with target=focused_panel and report the returned path.
```

Expected: tool result contains `path=...wispterm-files...png`, nonzero `width`, nonzero `height`, and the file opens as a PNG.

- [ ] **Step 5: Manual split smoke**

Open a terminal tab with two split panels. Ask the agent:

```text
Call terminal_list, then call ui_screenshot for each active-tab surface_id.
```

Expected: each screenshot path exists and each image dimensions match its panel rectangle rather than the full window.

- [ ] **Step 6: Manual Copilot/AI chat tab smoke**

Switch to a dedicated AI chat/Copilot tab and ask:

```text
Call ui_screenshot with target=focused_panel.
```

Expected: tool succeeds and reports `target=active_tab`.

- [ ] **Step 7: Manual WeChat smoke**

From WeChat, ask the agent:

```text
请截一张当前界面的图发给我。
```

Expected: the agent calls `ui_screenshot`, then `weixin_send_attachment(kind=image, path=<returned path>)`, and the image arrives in WeChat.

- [ ] **Step 8: Metal/macOS behavior check**

On macOS, call:

```text
Call ui_screenshot with target=active_tab.
```

Expected for v1: clear tool result containing `UnsupportedReadback`. This is deliberate until Metal readback is wired.

- [ ] **Step 9: Final status**

If all required checks pass, report:

```text
Implemented ui_screenshot for active-tab OpenGL screenshots. Verified zig build test and zig build test-full. Manual Windows smoke passed. Metal/macOS returns UnsupportedReadback in v1.
```

Do not claim macOS screenshot support until Metal readback has a real implementation.

## Follow-up (2026-06-28): Metal readback implemented

The Metal backend now has a real readback, so macOS is supported too. The
drawable can't be read after `frame_end` presents+releases it, so the capture
happens inside `frame_end`: on frames the caller arms via
`gpu.state.armUiScreenshotCapture()` (no-op on OpenGL), the rendered drawable is
blitted into a shared CPU buffer and the GPU is waited on; `metal/readback.zig`
then crops it, swaps BGRA→RGBA, and flips to GL bottom-up so the AppWindow path
is backend-agnostic. `metal_layer.framebufferOnly` is `NO` to allow the blit.
Verified `zig build test-metal`, `macos-app -Dtarget=aarch64-macos`, and
`test-full -Dtarget=aarch64-macos`.
