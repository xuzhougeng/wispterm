//! AI Chat session state and OpenAI-compatible API bridge.
//!
//! This is intentionally kept outside Surface/PTY/VT paths: Ghostty keeps
//! terminal surfaces focused on terminal emulation, and Phantty's AI Chat is a
//! Phantty-specific session kind rendered by the window chrome.

const std = @import("std");
const win32_backend = @import("apprt/win32.zig");

pub const DEFAULT_NAME = "DeepSeek";
pub const DEFAULT_BASE_URL = "https://api.deepseek.com";
pub const DEFAULT_MODEL = "deepseek-v4-pro";
pub const DEFAULT_SYSTEM_PROMPT = "You are a helpful assistant.";

pub const Role = enum {
    user,
    assistant,

    pub fn label(self: Role) []const u8 {
        return switch (self) {
            .user => "You",
            .assistant => "AI",
        };
    }

    pub fn apiName(self: Role) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
        };
    }
};

pub const Message = struct {
    role: Role,
    content: []u8,
    reasoning: ?[]u8 = null,
};

const RequestMessage = struct {
    role: Role,
    content: []u8,
};

const ChatRequest = struct {
    allocator: std.mem.Allocator,
    session: *Session,
    base_url: []u8,
    api_key: []u8,
    model: []u8,
    system_prompt: []u8,
    messages: []RequestMessage,

    fn deinit(self: *ChatRequest) void {
        self.allocator.free(self.base_url);
        self.allocator.free(self.api_key);
        self.allocator.free(self.model);
        self.allocator.free(self.system_prompt);
        for (self.messages) |msg| self.allocator.free(msg.content);
        self.allocator.free(self.messages);
        self.allocator.destroy(self);
    }
};

const ApiResult = struct {
    content: []u8,
    reasoning: ?[]u8 = null,

    fn deinit(self: ApiResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.reasoning) |reasoning| allocator.free(reasoning);
    }
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    messages: std.ArrayListUnmanaged(Message) = .empty,
    input_buf: [8192]u8 = undefined,
    input_len: usize = 0,
    status_buf: [512]u8 = undefined,
    status_len: usize = 0,
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,
    base_url_buf: [256]u8 = undefined,
    base_url_len: usize = 0,
    api_key_buf: [512]u8 = undefined,
    api_key_len: usize = 0,
    model_buf: [128]u8 = undefined,
    model_len: usize = 0,
    system_prompt_buf: [512]u8 = undefined,
    system_prompt_len: usize = 0,
    request_inflight: bool = false,
    request_thread: ?std.Thread = null,
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scroll_px: f32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        base_url: []const u8,
        api_key: []const u8,
        model_name: []const u8,
        system_prompt: []const u8,
    ) !*Session {
        const session = try allocator.create(Session);
        session.* = .{
            .allocator = allocator,
        };
        session.copyTitle(if (name.len > 0) name else DEFAULT_NAME);
        session.copyBaseUrl(if (base_url.len > 0) base_url else DEFAULT_BASE_URL);
        session.copyModel(if (model_name.len > 0) model_name else DEFAULT_MODEL);
        session.copySystemPrompt(if (system_prompt.len > 0) system_prompt else DEFAULT_SYSTEM_PROMPT);
        session.copyApiKey(api_key);
        if (session.api_key_len == 0 and isDeepSeekBaseUrl(session.baseUrl())) {
            if (std.process.getEnvVarOwned(allocator, "DEEPSEEK_API_KEY")) |env_key| {
                defer allocator.free(env_key);
                session.copyApiKey(env_key);
            } else |_| {}
        }
        session.setStatus("Ready");
        return session;
    }

    pub fn deinit(self: *Session) void {
        self.closing.store(true, .release);
        if (self.request_thread) |thread| {
            thread.join();
            self.request_thread = null;
        }
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
            if (msg.reasoning) |reasoning| self.allocator.free(reasoning);
        }
        self.messages.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn title(self: *const Session) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn baseUrl(self: *const Session) []const u8 {
        return self.base_url_buf[0..self.base_url_len];
    }

    pub fn model(self: *const Session) []const u8 {
        return self.model_buf[0..self.model_len];
    }

    pub fn systemPrompt(self: *const Session) []const u8 {
        return self.system_prompt_buf[0..self.system_prompt_len];
    }

    pub fn apiKey(self: *const Session) []const u8 {
        return self.api_key_buf[0..self.api_key_len];
    }

    pub fn input(self: *const Session) []const u8 {
        return self.input_buf[0..self.input_len];
    }

    pub fn status(self: *const Session) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn setTitle(self: *Session, title_text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.copyTitle(title_text);
    }

    pub fn handleChar(self: *Session, codepoint: u21) void {
        if (codepoint < 0x20 or codepoint == 0x7f) return;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return;

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.input_len + len > self.input_buf.len) return;
        @memcpy(self.input_buf[self.input_len..][0..len], buf[0..len]);
        self.input_len += len;
    }

    pub fn appendInputText(self: *Session, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const len = @min(text.len, self.input_buf.len - self.input_len);
        if (len == 0) return;
        @memcpy(self.input_buf[self.input_len..][0..len], text[0..len]);
        self.input_len += len;
    }

    pub fn handleKey(self: *Session, ev: win32_backend.KeyEvent) void {
        if (ev.ctrl and !ev.alt and ev.vk == 0x55) {
            self.mutex.lock();
            self.input_len = 0;
            self.mutex.unlock();
            return;
        }
        if (ev.ctrl and !ev.alt and ev.vk == 0x4C) {
            self.clearMessages();
            return;
        }

        switch (ev.vk) {
            win32_backend.VK_BACK => self.backspaceInput(),
            win32_backend.VK_RETURN => {
                if (ev.shift) {
                    self.appendInputText("\n");
                } else {
                    self.submit();
                }
            },
            else => {},
        }
    }

    pub fn submit(self: *Session) void {
        self.mutex.lock();
        if (self.request_thread) |thread| {
            if (self.request_inflight) {
                self.mutex.unlock();
                return;
            }
            self.request_thread = null;
            self.mutex.unlock();
            thread.join();
            self.mutex.lock();
        }

        const prompt_raw = std.mem.trim(u8, self.input(), " \t\r\n");
        if (prompt_raw.len == 0) {
            self.mutex.unlock();
            return;
        }
        if (self.api_key_len == 0) {
            self.setStatusLocked("Missing API key. Edit the AI Chat profile or set DEEPSEEK_API_KEY.");
            self.mutex.unlock();
            return;
        }

        const prompt = self.allocator.dupe(u8, prompt_raw) catch {
            self.setStatusLocked("Out of memory");
            self.mutex.unlock();
            return;
        };
        self.messages.append(self.allocator, .{ .role = .user, .content = prompt }) catch {
            self.allocator.free(prompt);
            self.setStatusLocked("Out of memory");
            self.mutex.unlock();
            return;
        };
        self.input_len = 0;
        self.scroll_px = 1_000_000;

        const request = self.buildRequestLocked() catch {
            self.setStatusLocked("Could not prepare request");
            self.mutex.unlock();
            return;
        };

        self.request_inflight = true;
        self.setStatusLocked("Thinking...");
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, requestThreadMain, .{request}) catch {
            request.deinit();
            self.mutex.lock();
            self.request_inflight = false;
            self.setStatusLocked("Failed to start request thread");
            self.mutex.unlock();
            return;
        };

        self.mutex.lock();
        self.request_thread = thread;
        self.mutex.unlock();
    }

    fn clearMessages(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.request_inflight) return;
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
            if (msg.reasoning) |reasoning| self.allocator.free(reasoning);
        }
        self.messages.clearRetainingCapacity();
        self.scroll_px = 0;
        self.setStatusLocked("Cleared");
    }

    pub fn scrollBy(self: *Session, delta_px: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.scroll_px = @max(0.0, self.scroll_px + delta_px);
    }

    fn backspaceInput(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.input_len == 0) return;
        self.input_len -= 1;
        while (self.input_len > 0 and (self.input_buf[self.input_len] & 0xC0) == 0x80) {
            self.input_len -= 1;
        }
    }

    fn buildRequestLocked(self: *Session) !*ChatRequest {
        const req = try self.allocator.create(ChatRequest);
        errdefer self.allocator.destroy(req);

        const messages = try self.allocator.alloc(RequestMessage, self.messages.items.len);
        errdefer self.allocator.free(messages);

        var written: usize = 0;
        errdefer {
            for (messages[0..written]) |msg| self.allocator.free(msg.content);
        }

        for (self.messages.items, 0..) |msg, i| {
            messages[i] = .{
                .role = msg.role,
                .content = try self.allocator.dupe(u8, msg.content),
            };
            written += 1;
        }

        req.* = .{
            .allocator = self.allocator,
            .session = self,
            .base_url = try self.allocator.dupe(u8, self.baseUrl()),
            .api_key = try self.allocator.dupe(u8, self.apiKey()),
            .model = try self.allocator.dupe(u8, self.model()),
            .system_prompt = try self.allocator.dupe(u8, self.systemPrompt()),
            .messages = messages,
        };
        return req;
    }

    fn copyTitle(self: *Session, value: []const u8) void {
        self.title_len = @min(value.len, self.title_buf.len);
        @memcpy(self.title_buf[0..self.title_len], value[0..self.title_len]);
    }

    fn copyBaseUrl(self: *Session, value: []const u8) void {
        self.base_url_len = @min(value.len, self.base_url_buf.len);
        @memcpy(self.base_url_buf[0..self.base_url_len], value[0..self.base_url_len]);
    }

    fn copyApiKey(self: *Session, value: []const u8) void {
        self.api_key_len = @min(value.len, self.api_key_buf.len);
        @memcpy(self.api_key_buf[0..self.api_key_len], value[0..self.api_key_len]);
    }

    fn copyModel(self: *Session, value: []const u8) void {
        self.model_len = @min(value.len, self.model_buf.len);
        @memcpy(self.model_buf[0..self.model_len], value[0..self.model_len]);
    }

    fn copySystemPrompt(self: *Session, value: []const u8) void {
        self.system_prompt_len = @min(value.len, self.system_prompt_buf.len);
        @memcpy(self.system_prompt_buf[0..self.system_prompt_len], value[0..self.system_prompt_len]);
    }

    fn setStatus(self: *Session, value: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.setStatusLocked(value);
    }

    fn setStatusLocked(self: *Session, value: []const u8) void {
        self.status_len = @min(value.len, self.status_buf.len);
        @memcpy(self.status_buf[0..self.status_len], value[0..self.status_len]);
    }
};

fn requestThreadMain(request: *ChatRequest) void {
    const allocator = request.allocator;
    defer request.deinit();

    const result = runChatRequest(request) catch |err| blk: {
        const text = std.fmt.allocPrint(allocator, "AI request failed: {}", .{err}) catch return;
        break :blk ApiResult{ .content = text };
    };
    defer result.deinit(allocator);

    const session = request.session;
    if (session.closing.load(.acquire)) return;

    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.closing.load(.acquire)) return;

    const content = allocator.dupe(u8, result.content) catch {
        session.request_inflight = false;
        session.setStatusLocked("Out of memory");
        return;
    };
    var reasoning_copy: ?[]u8 = null;
    if (result.reasoning) |reasoning| {
        reasoning_copy = allocator.dupe(u8, reasoning) catch null;
    }
    session.messages.append(allocator, .{
        .role = .assistant,
        .content = content,
        .reasoning = reasoning_copy,
    }) catch {
        allocator.free(content);
        if (reasoning_copy) |r| allocator.free(r);
        session.request_inflight = false;
        session.setStatusLocked("Out of memory");
        return;
    };
    session.request_inflight = false;
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Ready");
}

fn runChatRequest(request: *const ChatRequest) !ApiResult {
    const allocator = request.allocator;
    const endpoint = try chatEndpoint(allocator, request.base_url);
    defer allocator.free(endpoint);

    const body = try buildRequestJson(allocator, request);
    defer allocator.free(body);

    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{request.api_key});
    defer allocator.free(bearer);

    var client: std.http.Client = .{
        .allocator = allocator,
        .write_buffer_size = 16384,
    };
    defer client.deinit();

    var resp_buf: std.Io.Writer.Allocating = .init(allocator);
    defer resp_buf.deinit();

    const result = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = body,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = bearer },
        },
        .response_writer = &resp_buf.writer,
    }) catch return error.RequestFailed;

    var resp_list = resp_buf.toArrayList();
    defer resp_list.deinit(allocator);

    if (result.status != .ok) {
        const trimmed = std.mem.trim(u8, resp_list.items, " \t\r\n");
        if (trimmed.len > 0) return ApiResult{ .content = try allocator.dupe(u8, trimmed) };
        return ApiResult{ .content = try std.fmt.allocPrint(allocator, "HTTP {d}", .{@intFromEnum(result.status)}) };
    }

    return parseApiResponse(allocator, resp_list.items);
}

fn chatEndpoint(allocator: std.mem.Allocator, base_url_raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, base_url_raw, " \t\r\n");
    if (trimmed.len == 0) return error.MissingBaseUrl;
    if (std.mem.endsWith(u8, trimmed, "/chat/completions")) {
        return allocator.dupe(u8, trimmed);
    }
    var end = trimmed.len;
    while (end > 0 and trimmed[end - 1] == '/') end -= 1;
    return std.fmt.allocPrint(allocator, "{s}/chat/completions", .{trimmed[0..end]});
}

fn buildRequestJson(allocator: std.mem.Allocator, request: *const ChatRequest) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"model\":");
    try appendJsonString(allocator, &out, request.model);
    try out.appendSlice(allocator, ",\"messages\":[");
    if (request.system_prompt.len > 0) {
        try out.appendSlice(allocator, "{\"role\":\"system\",\"content\":");
        try appendJsonString(allocator, &out, request.system_prompt);
        try out.append(allocator, '}');
        if (request.messages.len > 0) try out.append(allocator, ',');
    }
    for (request.messages, 0..) |msg, i| {
        if (i > 0) try out.append(allocator, ',');
        try out.appendSlice(allocator, "{\"role\":");
        try appendJsonString(allocator, &out, msg.role.apiName());
        try out.appendSlice(allocator, ",\"content\":");
        try appendJsonString(allocator, &out, msg.content);
        try out.append(allocator, '}');
    }
    try out.appendSlice(allocator, "],\"thinking\":{\"type\":\"enabled\"},\"reasoning_effort\":\"high\",\"stream\":false}");

    return out.toOwnedSlice(allocator);
}

fn parseApiResponse(allocator: std.mem.Allocator, body: []const u8) !ApiResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyResponse;
        return ApiResult{ .content = try allocator.dupe(u8, trimmed) };
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;
    const obj = root.object;

    if (obj.get("error")) |err_value| {
        if (err_value == .object) {
            if (err_value.object.get("message")) |message_value| {
                if (message_value == .string) {
                    return ApiResult{ .content = try allocator.dupe(u8, message_value.string) };
                }
            }
        }
        return ApiResult{ .content = try allocator.dupe(u8, "API returned an error") };
    }

    const choices_value = obj.get("choices") orelse return error.MissingChoices;
    if (choices_value != .array or choices_value.array.items.len == 0) return error.MissingChoices;
    const choice = choices_value.array.items[0];
    if (choice != .object) return error.InvalidChoice;
    const message_value = choice.object.get("message") orelse return error.MissingMessage;
    if (message_value != .object) return error.MissingMessage;

    const content = if (message_value.object.get("content")) |content_value|
        if (content_value == .string) content_value.string else ""
    else
        "";
    const reasoning = if (message_value.object.get("reasoning_content")) |reasoning_value|
        if (reasoning_value == .string and reasoning_value.string.len > 0) reasoning_value.string else null
    else
        null;

    return .{
        .content = try allocator.dupe(u8, content),
        .reasoning = if (reasoning) |r| try allocator.dupe(u8, r) else null,
    };
}

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    const hex = "0123456789abcdef";
    try out.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => if (ch < 0x20) {
                try out.appendSlice(allocator, "\\u00");
                try out.append(allocator, hex[ch >> 4]);
                try out.append(allocator, hex[ch & 0x0f]);
            } else try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
}

fn isDeepSeekBaseUrl(base_url: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(base_url, "deepseek.com") != null;
}

test "ai chat endpoint normalization" {
    const allocator = std.testing.allocator;
    const endpoint = try chatEndpoint(allocator, "https://api.deepseek.com/");
    defer allocator.free(endpoint);
    try std.testing.expectEqualStrings("https://api.deepseek.com/chat/completions", endpoint);
}

test "ai chat request json includes deepseek thinking mode" {
    const allocator = std.testing.allocator;
    var messages = [_]RequestMessage{.{
        .role = .user,
        .content = @constCast("Hello"),
    }};
    const request = ChatRequest{
        .allocator = allocator,
        .session = undefined,
        .base_url = @constCast("https://api.deepseek.com"),
        .api_key = @constCast("key"),
        .model = @constCast(DEFAULT_MODEL),
        .system_prompt = @constCast(DEFAULT_SYSTEM_PROMPT),
        .messages = messages[0..],
    };
    const json = try buildRequestJson(allocator, &request);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"thinking\":{\"type\":\"enabled\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reasoning_effort\":\"high\"") != null);
}
