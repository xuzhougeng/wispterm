//! AI Chat session state and OpenAI-compatible API bridge.
//!
//! This is intentionally kept outside Surface/PTY/VT paths: Ghostty keeps
//! terminal surfaces focused on terminal emulation, and WispTerm's AI Chat is a
//! WispTerm-specific session kind rendered by the window chrome.

const std = @import("std");
const builtin = @import("builtin");
const ai_chat_input_text = @import("ai_chat_input_text.zig");
const input_key = @import("input/key.zig");
const platform_agent_prompt = @import("platform/agent_prompt.zig");
const platform_process = @import("platform/process.zig");
const platform_pty_command = @import("platform/pty_command.zig");
const agent_history = @import("agent_history.zig");
const skill_registry = @import("skill_registry.zig");
const command_registry = @import("command_registry.zig");
const tool_registry = @import("tool_registry.zig");
const markdown_text = @import("markdown_text.zig");
const ai_chat_protocol = @import("ai_chat_protocol.zig");
const ai_chat_composer = @import("ai_chat_composer.zig");
const ai_model_switch = @import("ai_model_switch.zig");
const ai_chat_skills = @import("ai_chat_skills.zig");
const ai_skill_distill = @import("ai_skill_distill.zig");
const ai_chat_types = @import("ai_chat_types.zig");
const ai_chat_tools = @import("ai_chat_tools.zig");
const ai_agent_access = @import("ai_agent_access.zig");
const platform_dirs = @import("platform/dirs.zig");
const ai_chat_markdown = @import("ai_chat_markdown.zig");
const weixin_types = @import("weixin/types.zig");
const ai_loop_store = @import("ai_loop_store.zig");
const ai_loop_schedule = @import("ai_loop_schedule.zig");

pub const AgentSettings = ai_chat_types.AgentSettings;
pub const AgentPermission = ai_chat_types.AgentPermission;
pub const ToolSurface = ai_chat_types.ToolSurface;
pub const ToolSnapshot = ai_chat_types.ToolSnapshot;
pub const ToolClosedTab = ai_chat_types.ToolClosedTab;
pub const SshProfileSaveArgs = ai_chat_types.SshProfileSaveArgs;
pub const SavedSshProfile = ai_chat_types.SavedSshProfile;
pub const ToolHost = ai_chat_types.ToolHost;
pub const ApprovalView = ai_chat_types.ApprovalView;
pub const QuestionOption = ai_chat_types.QuestionOption;
pub const QuestionView = ai_chat_types.QuestionView;
pub const AskResult = ai_chat_types.AskResult;
const WeixinReplyContext = ai_chat_types.WeixinReplyContext;
pub const ToolContext = ai_chat_types.ToolContext;

pub const DEFAULT_NAME = "DeepSeek";
pub const DEFAULT_BASE_URL = "https://api.deepseek.com";
pub const DEFAULT_MODEL = "deepseek-v4-pro";
pub const DEFAULT_SYSTEM_PROMPT = platform_agent_prompt.defaultSystemPrompt;
pub const COPILOT_SYSTEM_PROMPT = platform_agent_prompt.copilotSystemPrompt;
pub const DEFAULT_THINKING = ai_chat_protocol.DEFAULT_THINKING;
pub const DEFAULT_REASONING_EFFORT = ai_chat_protocol.DEFAULT_REASONING_EFFORT;
pub const DEFAULT_STREAM = ai_chat_protocol.DEFAULT_STREAM;
pub const DEFAULT_AGENT = ai_chat_protocol.DEFAULT_AGENT;
pub const DEFAULT_PROTOCOL = ai_chat_protocol.DEFAULT_PROTOCOL;
pub const DEFAULT_MAX_TOKENS = ai_chat_protocol.DEFAULT_MAX_TOKENS;
pub const DEFAULT_VISION = ai_chat_protocol.DEFAULT_VISION;

/// Cap on a single pasted image (decoded PNG bytes) before base64. Larger images
/// are dropped with a log rather than ballooning the request body.
pub const MAX_PASTED_IMAGE_BYTES: usize = 8 * 1024 * 1024;

/// Parse a profile "vision" field into the boolean session flag.
pub fn parseVisionEnabled(value: []const u8) bool {
    return std.mem.eql(u8, value, "on") or
        std.mem.eql(u8, value, "true") or
        std.mem.eql(u8, value, "enabled");
}

const REMOTE_SNAPSHOT_MAX_BYTES: usize = 24 * 1024;
const INPUT_PROMPT_MAX_BYTES: usize = 64 * 1024;
const SYSTEM_PROMPT_MAX_BYTES: usize = 16 * 1024;
const WORKING_DIR_MAX_BYTES: usize = 1024;
/// 两次 ESC 间隔不超过此毫秒数时判定为"双击"，用于打开回溯选择器。
const DOUBLE_ESC_WINDOW_MS: i64 = 400;

pub const COPILOT_CONTEXT_LINES: usize = 40;

pub const ApiProtocol = ai_chat_protocol.ApiProtocol;
pub const Role = ai_chat_protocol.Role;

pub const Message = struct {
    role: Role,
    content: []u8,
    /// Model-only context appended when building API requests. This is not
    /// rendered, exported, or persisted in history.
    model_context: ?[]u8 = null,
    reasoning: ?[]u8 = null,
    usage_footer: ?[]u8 = null,
    tool_call_id: ?[]u8 = null,
    tool_name: ?[]u8 = null,
    // base64 images attached to a user message (vision). Owned by the message.
    images: ?[]ai_chat_protocol.ImageBlock = null,
    replay_to_model: bool = false,
    persist_to_history: bool = true,
    content_collapsed: bool = false,
    content_auto_expand: bool = false,
    /// Synthetic "上文摘要" card produced by a model switch. Rendered like a
    /// collapsible tool card but sent to the model as a normal user message.
    is_context_summary: bool = false,
    reasoning_collapsed: bool = true,
    reasoning_auto_expand: bool = false,

    fn deinit(self: Message, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        if (self.model_context) |ctx| allocator.free(ctx);
        if (self.reasoning) |reasoning| allocator.free(reasoning);
        if (self.usage_footer) |footer| allocator.free(footer);
        if (self.tool_call_id) |id| allocator.free(id);
        if (self.tool_name) |name| allocator.free(name);
        if (self.images) |images| {
            for (images) |img| img.deinit(allocator);
            allocator.free(images);
        }
    }
};

pub const MarkdownExportMode = enum {
    full,
    clean,
};

pub const TextSelectionRange = struct {
    start: usize,
    end: usize,
};

pub const TranscriptSelection = struct {
    message_index: usize,
    anchor: usize,
    cursor: usize,

    pub fn range(self: TranscriptSelection) ?TextSelectionRange {
        if (self.anchor == self.cursor) return null;
        return .{
            .start = @min(self.anchor, self.cursor),
            .end = @max(self.anchor, self.cursor),
        };
    }

    pub fn rangeForMessage(self: TranscriptSelection, message_index: usize) ?TextSelectionRange {
        if (self.message_index != message_index) return null;
        return self.range();
    }
};

const RequestMessage = ai_chat_protocol.RequestMessage;
const ImageBlock = ai_chat_protocol.ImageBlock;
const ai_chat_title = @import("ai_chat_title.zig");
const ToolCall = ai_chat_protocol.ToolCall;
const ai_chat_request = @import("ai_chat_request.zig");
const web_search = @import("web_search.zig");
const pubmed = @import("pubmed.zig");
const agent_memory = @import("agent_memory.zig");

pub const ChatRequest = struct {
    allocator: std.mem.Allocator,
    session: *Session,
    base_url: []u8,
    api_key: []u8,
    model: []u8,
    protocol: ApiProtocol = .chat_completions,
    system_prompt: []u8,
    messages: []RequestMessage,
    thinking_enabled: bool,
    reasoning_effort: []u8,
    stream: bool,
    max_tokens: u32 = 8192,
    agent_enabled: bool,
    memory_enabled: bool = false,
    dynamic_tools: []const ai_chat_protocol.DynamicToolSpec = &.{},
    dynamic_binary_tools: []const ai_chat_types.DynamicBinaryTool = &.{},
    copilot: bool = false,
    tool_host: ?ToolHost,
    tool_snapshot: ?ToolSnapshot,
    weixin_reply_context: ?WeixinReplyContext = null,
    started_ms: i64,
    write_context_surface_id: [64]u8 = undefined,
    write_context_surface_id_len: usize = 0,
    toolset: ai_chat_protocol.Toolset = .full,
    subagent_profile: ?SubagentProfileOverride = null,
    /// Usage burned by nested subagent runs; merged into the agent loop's
    /// total when the final answer returns.
    subagent_usage: ai_chat_protocol.ApiUsage = .{},
    subagent_usage_present: bool = false,

    pub fn deinit(self: *ChatRequest) void {
        self.allocator.free(self.base_url);
        self.allocator.free(self.api_key);
        self.allocator.free(self.model);
        self.allocator.free(self.system_prompt);
        self.allocator.free(self.reasoning_effort);
        for (self.messages) |msg| msg.deinit(self.allocator);
        self.allocator.free(self.messages);
        freeOwnedDynamicToolSpecs(self.allocator, self.dynamic_tools);
        freeOwnedDynamicBinaryTools(self.allocator, self.dynamic_binary_tools);
        if (self.tool_snapshot) |snapshot| snapshot.deinit(self.allocator);
        if (self.weixin_reply_context) |*ctx| ctx.deinit(self.allocator);
        if (self.subagent_profile) |profile| profile.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn toParams(self: *const ChatRequest) ai_chat_protocol.RequestParams {
        return .{
            .model = self.model,
            .system_prompt = self.system_prompt,
            .protocol = self.protocol,
            .thinking_enabled = self.thinking_enabled,
            .reasoning_effort = self.reasoning_effort,
            .stream = self.stream,
            .max_tokens = self.max_tokens,
            .memory_enabled = self.memory_enabled,
            .dynamic_tools = self.dynamic_tools,
            .toolset = self.toolset,
        };
    }
};

/// Lightweight background job for a `$websearch` user command. Owns its query.
/// The spawning code stores the thread in `session.request_thread`, so
/// `Session.deinit` joins it before freeing the session (no use-after-free).
pub const WebSearchRequest = struct {
    allocator: std.mem.Allocator,
    session: *Session,
    query: []u8,

    pub fn create(allocator: std.mem.Allocator, session: *Session, query: []const u8) !*WebSearchRequest {
        const self = try allocator.create(WebSearchRequest);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .session = session, .query = try allocator.dupe(u8, query) };
        return self;
    }

    pub fn deinit(self: *WebSearchRequest) void {
        self.allocator.free(self.query);
        self.allocator.destroy(self);
    }
};

/// Self-contained background job for the post-switch context summary. Owns the
/// inner `ChatRequest` plus the pre-switch message `boundary` and the source
/// (OLD) model name, so the worker can splice the result without re-reading
/// possibly-changed session state.
pub const SummaryRequest = struct {
    allocator: std.mem.Allocator,
    req: *ChatRequest,
    boundary: usize,
    from_model_buf: [128]u8 = undefined,
    from_model_len: usize = 0,

    pub fn setFromModel(self: *SummaryRequest, value: []const u8) void {
        self.from_model_len = @min(value.len, self.from_model_buf.len);
        @memcpy(self.from_model_buf[0..self.from_model_len], value[0..self.from_model_len]);
    }
    pub fn fromModel(self: *const SummaryRequest) []const u8 {
        return self.from_model_buf[0..self.from_model_len];
    }
    pub fn deinit(self: *SummaryRequest) void {
        self.req.deinit();
        self.allocator.destroy(self);
    }
};

/// Lightweight background job for a `$webread` user command. Owns its target.
/// Mirrors `WebSearchRequest`; joined by `Session.deinit` via `request_thread`.
pub const WebReadRequest = struct {
    allocator: std.mem.Allocator,
    session: *Session,
    target: []u8,
    working_dir: []u8, // "" = none; used as the cache root

    pub fn create(allocator: std.mem.Allocator, session: *Session, target: []const u8, working_dir: []const u8) !*WebReadRequest {
        const self = try allocator.create(WebReadRequest);
        errdefer allocator.destroy(self);
        const target_dup = try allocator.dupe(u8, target);
        errdefer allocator.free(target_dup);
        self.* = .{ .allocator = allocator, .session = session, .target = target_dup, .working_dir = try allocator.dupe(u8, working_dir) };
        return self;
    }

    pub fn deinit(self: *WebReadRequest) void {
        self.allocator.free(self.target);
        self.allocator.free(self.working_dir);
        self.allocator.destroy(self);
    }
};

/// Lightweight background job for a `$pubmed` user command. Owns its query.
/// Mirrors `WebSearchRequest`; joined by `Session.deinit` via `request_thread`.
pub const WebPubMedRequest = struct {
    allocator: std.mem.Allocator,
    session: *Session,
    query: []u8,

    pub fn create(allocator: std.mem.Allocator, session: *Session, query: []const u8) !*WebPubMedRequest {
        const self = try allocator.create(WebPubMedRequest);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .session = session, .query = try allocator.dupe(u8, query) };
        return self;
    }

    pub fn deinit(self: *WebPubMedRequest) void {
        self.allocator.free(self.query);
        self.allocator.destroy(self);
    }
};

const ApiResult = ai_chat_protocol.ApiResult;
pub const ApiUsage = ai_chat_protocol.ApiUsage;

/// History hooks may run on request worker threads as well as the UI thread.
/// Consumers must treat the callback as asynchronous cross-thread delivery and
/// take ownership of the provided self-contained snapshot event.
pub const HistoryChangeHook = *const fn (HistoryChangeEvent) void;

pub const HistoryChangeEvent = struct {
    allocator: std.mem.Allocator,
    record: agent_history.SessionRecord,

    pub fn deinit(self: *HistoryChangeEvent) void {
        agent_history.freeOwnedRecord(self.allocator, &self.record);
        self.* = undefined;
    }
};

const PendingHistoryChange = struct {
    hook: HistoryChangeHook,
    event: HistoryChangeEvent,
};

/// A side-effect that a built-in command wants run AFTER the session mutex is
/// released (the targets live in the app layer and re-lock the session mutex).
const DeferredAction = union(enum) {
    none,
    resume_picker,
    copilot_conversation_picker,
    model_switch_picker,
    export_markdown: MarkdownExportMode,
};

/// Result of running a built-in command under the lock: the (optional) history
/// change to notify and any action to fire once the caller has unlocked.
const BuiltinResult = struct {
    history_change: ?PendingHistoryChange = null,
    deferred: DeferredAction = .none,
    suppress_output: bool = false,
};

/// Fires a deferred built-in side-effect. Call ONLY after `self.mutex` has been
/// unlocked: `resume_picker`/`export_markdown` re-enter the session through the
/// app layer and would deadlock if fired while the mutex is held.
fn fireDeferredAction(session: *Session, action: DeferredAction) void {
    switch (action) {
        .none => {},
        .resume_picker => if (g_session_resume_trigger) |t| t(),
        .copilot_conversation_picker => if (g_copilot_picker_trigger) |t| t(),
        // Targets the session that submitted `/model` (copilot sidebar OR a tab),
        // not the active tab — they can differ.
        .model_switch_picker => if (g_model_switch_trigger) |t| t(session),
        .export_markdown => |mode| if (g_markdown_export_trigger) |t| t(mode),
    }
}

var g_agent_mutex: std.Thread.Mutex = .{};
var g_agent_settings: AgentSettings = .{};
var g_access_rules_storage: ?ai_agent_access.AccessRules = null;
var g_access_rules: ?*const ai_agent_access.AccessRules = null;
var g_default_working_dir_buf: [WORKING_DIR_MAX_BYTES]u8 = undefined;
var g_default_working_dir_len: usize = 0;
var g_session_id_counter = std.atomic.Value(u64).init(1);
var g_session_resume_trigger: ?*const fn () void = null;
var g_copilot_picker_trigger: ?*const fn () void = null;
var g_markdown_export_trigger: ?*const fn (MarkdownExportMode) void = null;
var g_model_switch_trigger: ?*const fn (*Session) void = null;
threadlocal var g_dynamic_tool_specs: []ai_chat_protocol.DynamicToolSpec = &.{};
threadlocal var g_dynamic_tool_specs_owned: bool = false;
threadlocal var g_dynamic_binary_tools: []ai_chat_types.DynamicBinaryTool = &.{};
threadlocal var g_dynamic_binary_tools_owned: bool = false;

/// Resolved credentials for the `ai-subagent-profile` config key. Owned
/// strings; freed by ChatRequest.deinit.
pub const SubagentProfileOverride = struct {
    base_url: []u8,
    api_key: []u8,
    model: []u8,
    protocol: ApiProtocol,
    thinking_enabled: bool,
    reasoning_effort: []u8,
    max_tokens: u32,

    pub fn deinit(self: SubagentProfileOverride, allocator: std.mem.Allocator) void {
        allocator.free(self.base_url);
        allocator.free(self.api_key);
        allocator.free(self.model);
        allocator.free(self.reasoning_effort);
    }
};

pub const SubagentProfileResolver = *const fn (allocator: std.mem.Allocator) ?SubagentProfileOverride;
var g_subagent_profile_resolver: ?SubagentProfileResolver = null;

/// Wire the UI-thread resolver that maps the `ai-subagent-profile` config key
/// to concrete profile credentials. Registered at startup by the app layer
/// (mirrors the other startup trigger setters). Resolution happens in buildRequestLocked
/// on the UI thread; the worker only reads the owned copy on its ChatRequest.
pub fn setSubagentProfileResolver(cb: ?SubagentProfileResolver) void {
    g_subagent_profile_resolver = cb;
}

fn resolveSubagentProfileForRequest(allocator: std.mem.Allocator, agent_enabled: bool) ?SubagentProfileOverride {
    if (!agent_enabled) return null;
    const resolve = g_subagent_profile_resolver orelse return null;
    return resolve(allocator);
}

/// Wire the callback that `/resume` fires to open the agent history picker.
/// Fired AFTER the session mutex unlocks (the picker lives in the app layer).
pub fn setSessionResumeTrigger(cb: ?*const fn () void) void {
    g_session_resume_trigger = cb;
}

/// Wire the callback that `/resume` fires in a Copilot sidebar session to open
/// the Copilot conversation picker. Fired AFTER the session mutex unlocks.
pub fn setCopilotPickerTrigger(cb: ?*const fn () void) void {
    g_copilot_picker_trigger = cb;
}

/// Wire the callback that `/model` fires (after unlock) to either switch by the
/// pending name or open the profile picker. Lives in the app layer.
pub fn setModelSwitchTrigger(cb: ?*const fn (*Session) void) void {
    g_model_switch_trigger = cb;
}

/// Wire the callback that `/export [full|clean]` fires to write the conversation
/// Markdown. Fired AFTER the session mutex unlocks, because the export reads the
/// session under the SAME mutex (`allocMarkdownExport`) and would otherwise deadlock.
pub fn setMarkdownExportTrigger(cb: ?*const fn (MarkdownExportMode) void) void {
    g_markdown_export_trigger = cb;
}
threadlocal var g_tool_host: ?ToolHost = null;

pub fn setDynamicToolSpecsForTest(specs: []ai_chat_protocol.DynamicToolSpec) void {
    g_dynamic_tool_specs = specs;
    g_dynamic_tool_specs_owned = false;
}

pub fn setDynamicBinaryToolsForTest(tools: []ai_chat_types.DynamicBinaryTool) void {
    g_dynamic_binary_tools = tools;
    g_dynamic_binary_tools_owned = false;
}

fn freeDynamicToolSpecsSlice(allocator: std.mem.Allocator, specs: []ai_chat_protocol.DynamicToolSpec) void {
    freeOwnedDynamicToolSpecs(allocator, specs);
}

fn freeOwnedDynamicToolSpecs(allocator: std.mem.Allocator, specs: []const ai_chat_protocol.DynamicToolSpec) void {
    if (specs.len == 0) return;
    for (specs) |spec| {
        allocator.free(spec.name);
        allocator.free(spec.description);
    }
    allocator.free(specs);
}

fn freeOwnedDynamicBinaryTools(allocator: std.mem.Allocator, tools: []const ai_chat_types.DynamicBinaryTool) void {
    if (tools.len == 0) return;
    for (tools) |tool| {
        allocator.free(tool.function_name);
        allocator.free(tool.executable_abs);
        allocator.free(tool.description);
    }
    allocator.free(tools);
}

fn cloneDynamicToolSpecs(allocator: std.mem.Allocator, specs: []const ai_chat_protocol.DynamicToolSpec) ![]ai_chat_protocol.DynamicToolSpec {
    if (specs.len == 0) return &.{};
    const out = try allocator.alloc(ai_chat_protocol.DynamicToolSpec, specs.len);
    var written: usize = 0;
    errdefer {
        for (out[0..written]) |spec| {
            allocator.free(spec.name);
            allocator.free(spec.description);
        }
        allocator.free(out);
    }
    for (specs) |spec| {
        const name = try allocator.dupe(u8, spec.name);
        errdefer allocator.free(name);
        const description = try allocator.dupe(u8, spec.description);
        out[written] = .{ .name = name, .description = description };
        written += 1;
    }
    return out;
}

fn cloneDynamicBinaryTools(allocator: std.mem.Allocator, tools: []const ai_chat_types.DynamicBinaryTool) ![]ai_chat_types.DynamicBinaryTool {
    if (tools.len == 0) return &.{};
    const out = try allocator.alloc(ai_chat_types.DynamicBinaryTool, tools.len);
    var written: usize = 0;
    errdefer {
        for (out[0..written]) |tool| {
            allocator.free(tool.function_name);
            allocator.free(tool.executable_abs);
            allocator.free(tool.description);
        }
        allocator.free(out);
    }
    for (tools) |tool| {
        const function_name = try allocator.dupe(u8, tool.function_name);
        errdefer allocator.free(function_name);
        const executable_abs = try allocator.dupe(u8, tool.executable_abs);
        errdefer allocator.free(executable_abs);
        const description = try allocator.dupe(u8, tool.description);
        out[written] = .{
            .function_name = function_name,
            .executable_abs = executable_abs,
            .description = description,
        };
        written += 1;
    }
    return out;
}

fn freeDynamicToolSpecs(allocator: std.mem.Allocator) void {
    if (!g_dynamic_tool_specs_owned) return;
    freeDynamicToolSpecsSlice(allocator, g_dynamic_tool_specs);
    g_dynamic_tool_specs = &.{};
    g_dynamic_tool_specs_owned = false;
}

fn freeDynamicBinaryTools(allocator: std.mem.Allocator) void {
    if (!g_dynamic_binary_tools_owned) return;
    freeOwnedDynamicBinaryTools(allocator, g_dynamic_binary_tools);
    g_dynamic_binary_tools = &.{};
    g_dynamic_binary_tools_owned = false;
}

const DynamicToolSnapshots = struct {
    specs: []ai_chat_protocol.DynamicToolSpec,
    runtime: []ai_chat_types.DynamicBinaryTool,
};

fn loadDynamicToolSnapshots(allocator: std.mem.Allocator) !DynamicToolSnapshots {
    const tools_root = try platform_dirs.toolsDir(allocator);
    defer allocator.free(tools_root);

    const installed = try tool_registry.scanInstalledTools(allocator, tools_root);
    defer tool_registry.freeInstalledTools(allocator, installed);

    const specs = try tool_registry.dynamicSpecsFromInstalled(allocator, installed);
    errdefer tool_registry.freeDynamicSpecs(allocator, specs);
    const runtime = try tool_registry.dynamicRuntimeFromInstalled(allocator, installed);
    return .{ .specs = specs, .runtime = runtime };
}

pub fn reloadDynamicToolSpecs(allocator: std.mem.Allocator) void {
    freeDynamicToolSpecs(allocator);
    freeDynamicBinaryTools(allocator);
    const snapshots = loadDynamicToolSnapshots(allocator) catch {
        g_dynamic_tool_specs = &.{};
        g_dynamic_tool_specs_owned = false;
        g_dynamic_binary_tools = &.{};
        g_dynamic_binary_tools_owned = false;
        return;
    };
    g_dynamic_tool_specs = snapshots.specs;
    g_dynamic_tool_specs_owned = g_dynamic_tool_specs.len != 0;
    g_dynamic_binary_tools = snapshots.runtime;
    g_dynamic_binary_tools_owned = g_dynamic_binary_tools.len != 0;
}

pub fn configureAgent(settings: AgentSettings) void {
    g_agent_mutex.lock();
    defer g_agent_mutex.unlock();
    g_agent_settings = settings;
}

/// Load the private agent-access rules once at startup. Safe to call repeatedly
/// (loads only the first time). Never fails the app: on any error the guard
/// simply stays inactive.
pub fn loadAccessRules(allocator: std.mem.Allocator) void {
    g_agent_mutex.lock();
    const already = g_access_rules_storage != null;
    g_agent_mutex.unlock();
    if (already) return;

    const home = resolveHomeDir(allocator) orelse "";
    defer if (home.len != 0) allocator.free(home);
    const path = platform_dirs.pathInConfigDir(allocator, "agent-access.local") catch return;
    defer allocator.free(path);
    const rules = ai_agent_access.loadRules(allocator, path, home) catch return;

    g_agent_mutex.lock();
    defer g_agent_mutex.unlock();
    if (g_access_rules_storage != null) {
        var unused = rules;
        unused.deinit();
        return;
    }
    g_access_rules_storage = rules;
    g_access_rules = &g_access_rules_storage.?;
}

pub fn deinitAccessRules() void {
    g_agent_mutex.lock();
    defer g_agent_mutex.unlock();
    g_access_rules = null;
    g_agent_settings.access_rules = null;
    if (g_access_rules_storage) |*rules| {
        rules.deinit();
        g_access_rules_storage = null;
    }
}

/// Set the persistent default working directory (from config). Empty clears it.
/// Copies into a static buffer; oversized paths are truncated.
pub fn setDefaultWorkingDir(path: []const u8) void {
    g_agent_mutex.lock();
    defer g_agent_mutex.unlock();
    const n = @min(path.len, g_default_working_dir_buf.len);
    @memcpy(g_default_working_dir_buf[0..n], path[0..n]);
    g_default_working_dir_len = n;
}

pub fn defaultWorkingDir() ?[]const u8 {
    g_agent_mutex.lock();
    defer g_agent_mutex.unlock();
    if (g_default_working_dir_len == 0) return null;
    return g_default_working_dir_buf[0..g_default_working_dir_len];
}

fn resolveHomeDir(allocator: std.mem.Allocator) ?[]u8 {
    if (std.process.getEnvVarOwned(allocator, "HOME")) |v| {
        return v;
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |v| {
        return v;
    } else |_| {}
    return null;
}

fn expandTilde(allocator: std.mem.Allocator, path: []const u8, home: ?[]const u8) ![]u8 {
    if (path.len >= 1 and path[0] == '~') {
        if (home) |h| {
            if (path.len == 1) return allocator.dupe(u8, h);
            if (path[1] == '/' or path[1] == '\\') return std.fmt.allocPrint(allocator, "{s}{s}", .{ h, path[1..] });
        }
    }
    return allocator.dupe(u8, path);
}

pub fn setToolHost(host: ?ToolHost) void {
    g_tool_host = host;
}

pub fn currentAgentSettings() AgentSettings {
    g_agent_mutex.lock();
    defer g_agent_mutex.unlock();
    var s = g_agent_settings;
    s.access_rules = g_access_rules;
    if (g_default_working_dir_len > 0) s.working_dir = g_default_working_dir_buf[0..g_default_working_dir_len];
    s.dynamic_tools = g_dynamic_tool_specs;
    s.dynamic_binary_tools = g_dynamic_binary_tools;
    return s;
}

fn applyPermissionArg(arg: []const u8) void {
    const trimmed = std.mem.trim(u8, arg, " \t\r\n");
    if (trimmed.len == 0) return; // no arg = status-only (output already emitted by slashCommandOutput)
    if (AgentPermission.parse(trimmed)) |p| {
        var s = currentAgentSettings();
        s.permission = p;
        configureAgent(s);
    }
}

fn currentToolHost() ?ToolHost {
    return g_tool_host;
}

const SlashCommand = ai_chat_composer.SlashCommand;
const SkillInvocation = ai_chat_composer.SkillInvocation;
const ComposerSuggestionPrefix = ai_chat_composer.ComposerSuggestionPrefix;
const ComposerCompletionTrigger = ai_chat_composer.ComposerCompletionTrigger;
pub const ComposerSuggestionKind = ai_chat_composer.ComposerSuggestionKind;
pub const ComposerSuggestion = ai_chat_composer.ComposerSuggestion;
pub const SlashCommandSuggestion = ai_chat_composer.SlashCommandSuggestion;
const parseSlashCommand = ai_chat_composer.parseSlashCommand;
const composerSuggestionPrefix = ai_chat_composer.composerSuggestionPrefix;
const slashCommandSuggestionPrefix = ai_chat_composer.slashCommandSuggestionPrefix;
const suggestionReplacementText = ai_chat_composer.suggestionReplacementText;
const parseSkillInvocation = ai_chat_composer.parseSkillInvocation;
const slash_command_entries = ai_chat_composer.slash_command_entries;
pub const slashCommandSuggestionCountForInput = ai_chat_composer.slashCommandSuggestionCountForInput;
pub const slashCommandSuggestionAtForInput = ai_chat_composer.slashCommandSuggestionAtForInput;
pub const composerSuggestionCountForInput = ai_chat_composer.composerSuggestionCountForInput;
pub const composerSuggestionAtForInput = ai_chat_composer.composerSuggestionAtForInput;

fn slashCommandOutput(allocator: std.mem.Allocator, command: SlashCommand) ![]u8 {
    return switch (command) {
        .commands => ai_chat_skills.slashCommandListOutput(allocator),
        .reload_skills => allocator.dupe(u8, "Skills will be re-read from disk on the next skill call."),
        .reload_commands => allocator.dupe(u8, "Custom commands will be re-read from the commands directory."),
        .clear => allocator.dupe(u8, "Cleared the conversation context."),
        .rewind_picker => allocator.dupe(u8, "No previous user messages to rewind."),
        .resume_session => allocator.dupe(u8, "Opening saved conversation history..."),
        .permission => permissionStatusOutput(allocator),
        .cwd => allocator.dupe(u8, "Working directory updated."),
        .export_markdown => allocator.dupe(u8, "Exporting the conversation as Markdown..."),
        .distill => allocator.dupe(u8, "Use /distill [topic] to preview a reusable skill candidate."),
        .unknown => allocator.dupe(u8, "Unknown command. Use /commands to list commands."),
        .skills => ai_chat_skills.listSkillsForDisplay(allocator),
        // .loop and .watch suppress output and emit their own messages via
        // runLoopCommandLocked; this path is never reached.
        .loop, .watch => allocator.dupe(u8, ""),
        // .remember, .memory, .forget suppress output and emit their own messages;
        // this path is never reached, but the arm is required for exhaustiveness.
        .remember, .memory, .forget => allocator.dupe(u8, ""),
        // .model_switch suppresses output and defers to the picker / by-name path;
        // this path is never reached, but the arm is required for exhaustiveness.
        .model_switch => allocator.dupe(u8, ""),
    };
}

fn previewPrompt(p: []const u8) []const u8 {
    return if (p.len > 48) p[0..48] else p;
}

const LoopTaskListScope = enum { session, all };

fn taskOwnerLabel(v: ai_loop_store.TaskView) []const u8 {
    return if (v.title.len > 0) v.title else v.session_id;
}

fn loopErrorText(err: ai_loop_schedule.ParseError, kind: ai_loop_schedule.TaskKind) []const u8 {
    return switch (err) {
        error.MissingArgs => if (kind == .loop)
            "Usage: /loop <interval> <count> <prompt>; /loop all; /loop stop <id>|all"
        else
            "Usage: /watch <HH:MM | YYYY-MM-DD HH:MM> <prompt>; /watch all; /watch stop <id>|all",
        error.BadInterval => "Bad interval. Use a number + s/m/h/d, e.g. 30m, 5h.",
        error.BadCount => "Count must be a positive integer.",
        error.BadTime => "Bad time. Use HH:MM or YYYY-MM-DD HH:MM (24h).",
        error.PastTime => "That time is already in the past.",
        error.EmptyPrompt => "Add the prompt text after the schedule.",
    };
}

fn permissionStatusOutput(allocator: std.mem.Allocator) ![]u8 {
    const current = currentAgentSettings().permission;
    return std.fmt.allocPrint(allocator, "Agent permission is '{s}'. Use /permission ask, /permission auto, or /permission full to change it.", .{current.name()});
}

pub fn agentPermission() AgentPermission {
    return currentAgentSettings().permission;
}

pub const Session = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    messages: std.ArrayListUnmanaged(Message) = .empty,
    session_id_buf: [64]u8 = undefined,
    session_id_len: usize = 0,
    input_buf: [INPUT_PROMPT_MAX_BYTES]u8 = undefined,
    input_len: usize = 0,
    input_cursor: usize = 0,
    input_scroll_row: usize = 0,
    input_scroll_follow_cursor: bool = true,
    input_select_all: bool = false,
    composer_history_active: bool = false,
    composer_history_selected: usize = 0,
    composer_history_draft_buf: [INPUT_PROMPT_MAX_BYTES]u8 = undefined,
    composer_history_draft_len: usize = 0,
    composer_history_draft_cursor: usize = 0,
    suggestion_selected: usize = 0,
    skill_suggestions: []skill_registry.SkillMeta = &.{},
    skill_suggestions_loaded: bool = false,
    skill_suggestions_owned: bool = false,
    custom_commands: []command_registry.CustomCommand = &.{},
    custom_command_suggestions: []SlashCommandSuggestion = &.{},
    transcript_select_all: bool = false,
    transcript_selection: ?TranscriptSelection = null,
    // 双击 ESC 回溯选择器（rewind picker）。
    // last_esc_ms 为上一次 ESC 的时间戳（0 = 无）；空闲时若两次 ESC 间隔
    // <= DOUBLE_ESC_WINDOW_MS 则打开选择器。rewind_selected 是回溯点序号
    // （0 = 最早的用户消息，count-1 = 最近一条）。now_ms_override 为测试时钟。
    rewind_open: bool = false,
    rewind_selected: usize = 0,
    last_esc_ms: i64 = 0,
    now_ms_override: ?i64 = null,
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
    protocol: ApiProtocol = .chat_completions,
    system_prompt_buf: [SYSTEM_PROMPT_MAX_BYTES]u8 = undefined,
    system_prompt_len: usize = 0,
    thinking_enabled: bool = true,
    reasoning_effort_buf: [16]u8 = undefined,
    reasoning_effort_len: usize = 0,
    stream: bool = false,
    max_tokens: u32 = 8192,
    agent_enabled: bool = false,
    vision_enabled: bool = false,
    // base64 images pasted into the composer, awaiting the next user message.
    pending_images: std.ArrayListUnmanaged(ai_chat_protocol.ImageBlock) = .empty,
    created_at_ms: i64 = 0,
    updated_at_ms: i64 = 0,
    history_on_change: ?HistoryChangeHook = null,
    request_inflight: bool = false,
    request_stopping: bool = false,
    request_thread: ?std.Thread = null,
    title_thread: ?std.Thread = null,
    pending_weixin_reply_context: ?WeixinReplyContext = null,
    distill_candidate: ?ai_skill_distill.Candidate = null,
    distill_suggestion_pending: bool = false,
    distill_last_suggested_turn_count: usize = 0,
    distill_inflight: bool = false,
    auto_title_attempted: bool = false,
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scroll_px: f32 = 0,
    scrollbar_show_time: i64 = 0,
    approval_mutex: std.Thread.Mutex = .{},
    approval_cond: std.Thread.Condition = .{},
    approval_pending: bool = false,
    approval_resolved: bool = false,
    approval_allowed: bool = false,
    approval_tool_buf: [64]u8 = undefined,
    approval_tool_len: usize = 0,
    approval_command_buf: [1024]u8 = undefined,
    approval_command_len: usize = 0,
    approval_reason_buf: [256]u8 = undefined,
    approval_reason_len: usize = 0,
    // Pending `ask_user` question. Independent of the approval slot (separate
    // mutex/cond so the two never cross-wake) because a question carries a
    // variable-length, owned option list rather than fixed buffers.
    question_mutex: std.Thread.Mutex = .{},
    question_cond: std.Thread.Condition = .{},
    question_pending: bool = false,
    question_resolved: bool = false,
    /// Set when the wait was broken by a stop/close rather than a real answer.
    question_cancelled: bool = false,
    question_text: []u8 = &.{}, // owned
    question_options: []QuestionOption = &.{}, // owned (each label/description owned)
    question_answer: ?[]u8 = null, // owned; valid until the next askUser/deinit
    question_answer_is_custom: bool = false,
    question_selected_index: usize = 0,
    /// Copilot mode: when true, requests pre-target the bound surface and exec
    /// tools fall back to it when the model omits surface_id (Issue #98).
    copilot: bool = false,
    bound_surface_id_buf: [16]u8 = undefined,
    bound_surface_id_len: usize = 0,
    working_dir_buf: [WORKING_DIR_MAX_BYTES]u8 = undefined,
    working_dir_len: usize = 0,
    summary_thread: ?std.Thread = null,
    pending_model_switch_name_buf: [128]u8 = undefined,
    pending_model_switch_name_len: usize = 0,

    pub const RequestState = struct {
        inflight: bool,
        stopping: bool,
    };

    pub fn reasoningEffort(self: *const Session) []const u8 {
        return self.reasoning_effort_buf[0..self.reasoning_effort_len];
    }

    /// Per-conversation working-dir override, or null when unset.
    pub fn workingDirOverride(self: *const Session) ?[]const u8 {
        if (self.working_dir_len == 0) return null;
        return self.working_dir_buf[0..self.working_dir_len];
    }

    fn effectiveWorkingDirLocked(self: *Session) ?[]const u8 {
        if (self.working_dir_len > 0) return self.working_dir_buf[0..self.working_dir_len];
        return defaultWorkingDir();
    }

    pub fn apiProtocolName(self: *const Session) []const u8 {
        return self.protocol.name();
    }

    pub fn sessionId(self: *const Session) []const u8 {
        return self.session_id_buf[0..self.session_id_len];
    }

    pub fn setHistoryChangeHook(self: *Session, hook: ?HistoryChangeHook) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.history_on_change = hook;
    }

    pub fn setBoundSurface(self: *Session, surface_id: []const u8) void {
        const n = @min(surface_id.len, self.bound_surface_id_buf.len);
        @memcpy(self.bound_surface_id_buf[0..n], surface_id[0..n]);
        self.bound_surface_id_len = n;
    }

    pub fn boundSurfaceId(self: *const Session) []const u8 {
        return self.bound_surface_id_buf[0..self.bound_surface_id_len];
    }

    pub fn pendingImageCount(self: *const Session) usize {
        return self.pending_images.items.len;
    }

    /// Copy a base64 image + media type into the pending-attachment list. Both
    /// inputs are duplicated; the session owns the stored copies.
    pub fn addPendingImage(self: *Session, data_b64: []const u8, media_type: []const u8) !void {
        const data = try self.allocator.dupe(u8, data_b64);
        errdefer self.allocator.free(data);
        const media = try self.allocator.dupe(u8, media_type);
        errdefer self.allocator.free(media);
        try self.pending_images.append(self.allocator, .{ .data_b64 = data, .media_type = media });
    }

    /// Free every pending image and release the backing storage.
    pub fn clearPendingImages(self: *Session) void {
        for (self.pending_images.items) |img| img.deinit(self.allocator);
        self.pending_images.clearAndFree(self.allocator);
    }

    /// Hand the pending images to the caller as an owned slice, leaving the list
    /// empty. Returns null when there are none.
    pub fn takePendingImages(self: *Session) ?[]ai_chat_protocol.ImageBlock {
        if (self.pending_images.items.len == 0) return null;
        return self.pending_images.toOwnedSlice(self.allocator) catch null;
    }

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        base_url: []const u8,
        api_key: []const u8,
        model_name: []const u8,
        system_prompt: []const u8,
        thinking: []const u8,
        reasoning_effort: []const u8,
        stream_val: []const u8,
        agent_val: []const u8,
    ) !*Session {
        return initWithProtocol(
            allocator,
            name,
            base_url,
            api_key,
            model_name,
            DEFAULT_PROTOCOL,
            system_prompt,
            thinking,
            reasoning_effort,
            stream_val,
            agent_val,
        );
    }

    pub fn initWithProtocol(
        allocator: std.mem.Allocator,
        name: []const u8,
        base_url: []const u8,
        api_key: []const u8,
        model_name: []const u8,
        protocol: []const u8,
        system_prompt: []const u8,
        thinking: []const u8,
        reasoning_effort: []const u8,
        stream_val: []const u8,
        agent_val: []const u8,
    ) !*Session {
        return initWithVision(
            allocator,
            name,
            base_url,
            api_key,
            model_name,
            protocol,
            system_prompt,
            thinking,
            reasoning_effort,
            stream_val,
            agent_val,
            DEFAULT_VISION,
        );
    }

    pub fn initWithVision(
        allocator: std.mem.Allocator,
        name: []const u8,
        base_url: []const u8,
        api_key: []const u8,
        model_name: []const u8,
        protocol: []const u8,
        system_prompt: []const u8,
        thinking: []const u8,
        reasoning_effort: []const u8,
        stream_val: []const u8,
        agent_val: []const u8,
        vision_val: []const u8,
    ) !*Session {
        const session = try allocator.create(Session);
        session.* = .{
            .allocator = allocator,
        };
        session.assignSessionId();
        session.created_at_ms = std.time.milliTimestamp();
        session.updated_at_ms = session.created_at_ms;
        session.copyTitle(if (name.len > 0) name else DEFAULT_NAME);
        session.copyBaseUrl(if (base_url.len > 0) base_url else DEFAULT_BASE_URL);
        session.copyModel(if (model_name.len > 0) model_name else DEFAULT_MODEL);
        session.protocol = ApiProtocol.parse(protocol);
        if (session.protocol == .chat_completions and isAnthropicBaseUrl(session.baseUrl())) {
            session.protocol = .anthropic;
        }
        session.copySystemPrompt(if (system_prompt.len > 0) system_prompt else DEFAULT_SYSTEM_PROMPT);
        session.thinking_enabled = !std.mem.eql(u8, thinking, "disabled");
        session.copyReasoningEffort(if (reasoning_effort.len > 0) reasoning_effort else DEFAULT_REASONING_EFFORT);
        session.stream = std.mem.eql(u8, stream_val, "true");
        session.agent_enabled = std.mem.eql(u8, agent_val, "true") or std.mem.eql(u8, agent_val, "enabled");
        session.vision_enabled = parseVisionEnabled(vision_val);
        session.copyApiKey(api_key);
        if (session.api_key_len == 0 and isDeepSeekBaseUrl(session.baseUrl())) {
            if (std.process.getEnvVarOwned(allocator, "DEEPSEEK_API_KEY")) |env_key| {
                defer allocator.free(env_key);
                session.copyApiKey(env_key);
            } else |_| {}
        }
        session.setStatus("Ready");
        // Load custom commands from disk last, after every settings buffer is
        // populated. Best-effort: a missing commands dir leaves the list empty.
        session.reloadCustomCommands();
        return session;
    }

    pub fn initFromHistoryRecord(allocator: std.mem.Allocator, record: agent_history.SessionRecord) !*Session {
        const session = try initWithProtocol(
            allocator,
            record.title,
            record.base_url,
            record.api_key,
            record.model,
            record.protocol,
            record.system_prompt,
            if (record.thinking_enabled) "enabled" else "disabled",
            record.reasoning_effort,
            if (record.stream) "true" else "false",
            if (record.agent_enabled) "true" else "false",
        );
        errdefer session.deinit();

        session.mutex.lock();
        defer session.mutex.unlock();
        if (record.session_id.len > 0) session.copySessionId(record.session_id);
        session.max_tokens = record.max_tokens;
        session.vision_enabled = record.vision_enabled;
        session.copilot = record.copilot;
        session.created_at_ms = record.created_at;
        session.updated_at_ms = record.updated_at;
        for (record.messages) |msg| {
            var cloned_msg = Message{
                .role = switch (msg.role) {
                    .user => .user,
                    .assistant => .assistant,
                    .tool => .tool,
                },
                .content = try allocator.dupe(u8, msg.content),
            };
            errdefer cloned_msg.deinit(allocator);

            cloned_msg.reasoning = if (msg.reasoning) |reasoning| try allocator.dupe(u8, reasoning) else null;
            cloned_msg.usage_footer = if (msg.usage_footer) |footer| try allocator.dupe(u8, footer) else null;
            cloned_msg.tool_call_id = if (msg.tool_call_id) |id| try allocator.dupe(u8, id) else null;
            cloned_msg.tool_name = if (msg.tool_name) |name| try allocator.dupe(u8, name) else null;
            cloned_msg.replay_to_model = msg.replay_to_model;

            try session.messages.append(allocator, cloned_msg);
        }
        // A restored session that already has an assistant reply has passed its
        // first-turn window; never re-title it. (A half-finished session with no
        // assistant reply keeps auto_title_attempted=false and is still default-
        // titled, so it can be named after its next completed turn.)
        for (session.messages.items) |restored| {
            if (restored.role == .assistant) {
                session.auto_title_attempted = true;
                break;
            }
        }
        return session;
    }

    pub fn deinit(self: *Session) void {
        self.closing.store(true, .release);
        self.approval_cond.broadcast();
        self.question_cond.broadcast();
        if (self.request_thread) |thread| {
            thread.join();
            self.request_thread = null;
        }
        if (self.title_thread) |thread| {
            thread.join();
            self.title_thread = null;
        }
        if (self.summary_thread) |thread| {
            thread.join();
            self.summary_thread = null;
        }
        for (self.messages.items) |msg| {
            msg.deinit(self.allocator);
        }
        self.messages.deinit(self.allocator);
        self.clearPendingImages();
        self.freeSkillSuggestions();
        self.freeCustomCommandSuggestions();
        command_registry.freeCommandList(self.allocator, self.custom_commands);
        if (self.pending_weixin_reply_context) |*ctx| ctx.deinit(self.allocator);
        if (self.distill_candidate) |*candidate| candidate.deinit(self.allocator);
        self.freeQuestionPayloadLocked();
        self.freeQuestionAnswerLocked();
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

    pub fn missingApiKey(self: *const Session) bool {
        return self.api_key_len == 0;
    }

    /// Stash the `/model <name>` argument so the app-layer trigger can read it
    /// after the mutex unlocks. Empty arg => open the picker.
    fn setPendingModelSwitchNameLocked(self: *Session, name: []const u8) void {
        self.pending_model_switch_name_len = @min(name.len, self.pending_model_switch_name_buf.len);
        @memcpy(self.pending_model_switch_name_buf[0..self.pending_model_switch_name_len], name[0..self.pending_model_switch_name_len]);
    }

    /// Read + clear the pending `/model` name. Returns a slice into the buffer
    /// valid until the next mutate; copy if you need to keep it.
    pub fn takePendingModelSwitchName(self: *Session) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const out = self.pending_model_switch_name_buf[0..self.pending_model_switch_name_len];
        self.pending_model_switch_name_len = 0;
        return out;
    }

    pub fn thinkingConfigValue(self: *const Session) []const u8 {
        return if (self.thinking_enabled) "enabled" else "disabled";
    }

    pub fn streamConfigValue(self: *const Session) []const u8 {
        return if (self.stream) "true" else "false";
    }

    pub fn maxTokens(self: *const Session) u32 {
        return self.max_tokens;
    }

    pub fn setMaxTokens(self: *Session, value: u32) void {
        self.max_tokens = value;
    }

    pub fn agentConfigValue(self: *const Session) []const u8 {
        return if (self.agent_enabled) "true" else "false";
    }

    pub fn visionConfigValue(self: *const Session) []const u8 {
        return if (self.vision_enabled) "on" else "off";
    }

    pub fn input(self: *const Session) []const u8 {
        return self.input_buf[0..self.input_len];
    }

    pub fn inputCursor(self: *Session) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.input_cursor;
    }

    fn customCommandSuggestions(self: *Session) []const SlashCommandSuggestion {
        return self.custom_command_suggestions;
    }

    pub fn slashCommandSuggestionCount(self: *Session) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return slashCommandSuggestionCountForInput(self.input(), self.input_cursor, self.customCommandSuggestions());
    }

    pub fn slashCommandSuggestionAt(self: *Session, index: usize) ?SlashCommandSuggestion {
        self.mutex.lock();
        defer self.mutex.unlock();
        return slashCommandSuggestionAtForInput(self.input(), self.input_cursor, index, self.customCommandSuggestions());
    }

    pub fn slashCommandSuggestionSelectedIndex(self: *Session) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = slashCommandSuggestionCountForInput(self.input(), self.input_cursor, self.customCommandSuggestions());
        if (count == 0) return 0;
        return @min(self.suggestion_selected, count - 1);
    }

    pub fn composerSuggestionCount(self: *Session) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ensureSkillSuggestionsForInputLocked();
        return composerSuggestionCountForInput(self.input(), self.input_cursor, self.skill_suggestions, self.customCommandSuggestions());
    }

    pub fn composerSuggestionAt(self: *Session, index: usize) ?ComposerSuggestion {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ensureSkillSuggestionsForInputLocked();
        return composerSuggestionAtForInput(self.input(), self.input_cursor, self.skill_suggestions, self.customCommandSuggestions(), index);
    }

    fn loadSkillSuggestionsFromRoots(self: *Session, root_paths: []const []const u8) !void {
        const suggestions = try ai_chat_skills.loadSkillSuggestionListFromRoots(self.allocator, root_paths);
        errdefer {
            ai_chat_skills.freeOwnedSkillMetaList(self.allocator, suggestions);
            self.allocator.free(suggestions);
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        self.replaceSkillSuggestionsLocked(suggestions);
    }

    fn ensureSkillSuggestionsForInputLocked(self: *Session) void {
        const prefix = composerSuggestionPrefix(self.input(), self.input_cursor) orelse return;
        if (prefix.kind != .skill or self.skill_suggestions_loaded) return;

        const roots = ai_chat_skills.defaultSkillRootPaths(self.allocator) catch {
            self.skill_suggestions_loaded = true;
            return;
        };
        defer ai_chat_skills.freeSkillRootPaths(self.allocator, roots);

        const suggestions = ai_chat_skills.loadSkillSuggestionListFromRoots(self.allocator, roots) catch {
            self.skill_suggestions_loaded = true;
            return;
        };
        self.replaceSkillSuggestionsLocked(suggestions);
    }

    fn replaceSkillSuggestionsLocked(self: *Session, suggestions: []skill_registry.SkillMeta) void {
        self.freeSkillSuggestions();
        self.skill_suggestions = suggestions;
        self.skill_suggestions_loaded = true;
        self.skill_suggestions_owned = true;
        self.suggestion_selected = 0;
    }

    fn freeSkillSuggestions(self: *Session) void {
        if (self.skill_suggestions_owned) {
            ai_chat_skills.freeOwnedSkillMetaList(self.allocator, self.skill_suggestions);
            self.allocator.free(self.skill_suggestions);
        }
        self.skill_suggestions = &.{};
        self.skill_suggestions_loaded = false;
        self.skill_suggestions_owned = false;
    }

    /// Public entry point to drop cached skill suggestions so they are re-read
    /// from disk on next use. Unlike `freeSkillSuggestions` (a locked helper),
    /// this acquires the session mutex itself — callers (e.g. the UI thread
    /// after a skill update) must NOT hold it.
    pub fn reloadSkillSuggestions(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.freeSkillSuggestions();
    }

    /// Rescans the command root directories, validates each command's action and
    /// name, and replaces `self.custom_commands`. Best-effort: missing dirs or
    /// allocation failures leave the session usable (possibly with no commands).
    pub fn reloadCustomCommands(self: *Session) void {
        const roots = ai_chat_skills.defaultCommandRootPaths(self.allocator) catch return;
        defer ai_chat_skills.freeSkillRootPaths(self.allocator, roots);
        var merged: std.ArrayListUnmanaged(command_registry.CustomCommand) = .empty;
        for (roots) |root| {
            var dir = ai_chat_skills.openDirectoryPath(root) catch continue;
            defer dir.close();
            const cmds = command_registry.listCommands(self.allocator, dir, "") catch continue;
            defer self.allocator.free(cmds); // free the slice; item ownership moves to `merged` or is deinit'd below
            for (cmds) |cmd| {
                var c = cmd;
                if (c.action) |av| if (ai_chat_skills.knownActionFromName(av) == null) {
                    c.deinit(self.allocator);
                    continue;
                };
                // Dedup ONLY against built-ins + commands already merged in THIS reload.
                // Do NOT check self.custom_commands (it is the old list being replaced).
                if (ai_chat_skills.isBuiltinCommandName(c.name) or ai_chat_skills.hasName(merged.items, c.name)) {
                    c.deinit(self.allocator);
                    continue;
                }
                merged.append(self.allocator, c) catch {
                    c.deinit(self.allocator);
                    break;
                };
            }
        }
        command_registry.freeCommandList(self.allocator, self.custom_commands);
        self.custom_commands = merged.toOwnedSlice(self.allocator) catch &.{};
        self.rebuildCustomCommandSuggestions();
    }

    /// Rebuilds the composer suggestion cache from `self.custom_commands`. Each
    /// suggestion OWNS both its `/`-prefixed command string and its description
    /// dupe (so it doesn't borrow into `custom_commands`, avoiding lifetime/order
    /// hazards). Best-effort: any allocation failure falls back to `&.{}`.
    fn rebuildCustomCommandSuggestions(self: *Session) void {
        self.freeCustomCommandSuggestions();
        if (self.custom_commands.len == 0) return;
        const suggestions = self.allocator.alloc(SlashCommandSuggestion, self.custom_commands.len) catch return;
        var built: usize = 0;
        for (self.custom_commands) |cmd| {
            const command = std.fmt.allocPrint(self.allocator, "/{s}", .{cmd.name}) catch break;
            const description = self.allocator.dupe(u8, cmd.description) catch {
                self.allocator.free(command);
                break;
            };
            suggestions[built] = .{ .command = command, .description = description };
            built += 1;
        }
        if (built == self.custom_commands.len) {
            self.custom_command_suggestions = suggestions;
            return;
        }
        // Allocation failure mid-build: free everything and fall back to empty.
        for (suggestions[0..built]) |s| {
            self.allocator.free(@constCast(s.command));
            self.allocator.free(@constCast(s.description));
        }
        self.allocator.free(suggestions);
    }

    fn freeCustomCommandSuggestions(self: *Session) void {
        for (self.custom_command_suggestions) |s| {
            self.allocator.free(@constCast(s.command));
            self.allocator.free(@constCast(s.description));
        }
        self.allocator.free(self.custom_command_suggestions);
        self.custom_command_suggestions = &.{};
    }

    pub fn status(self: *const Session) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    pub fn requestState(self: *Session) RequestState {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .inflight = self.request_inflight,
            .stopping = self.request_stopping,
        };
    }

    pub fn setTitle(self: *Session, title_text: []const u8) void {
        var history_change: ?PendingHistoryChange = null;
        self.mutex.lock();
        self.copyTitle(title_text);
        history_change = self.captureHistoryChangeLocked();
        self.mutex.unlock();
        self.notifyHistoryChange(history_change);
    }

    /// Set the title only if it is still the default name. Returns true if it
    /// changed. Used by auto-title so a concurrent manual rename always wins.
    pub fn setTitleIfDefault(self: *Session, title_text: []const u8) bool {
        var history_change: ?PendingHistoryChange = null;
        self.mutex.lock();
        if (!std.mem.eql(u8, self.title_buf[0..self.title_len], DEFAULT_NAME)) {
            self.mutex.unlock();
            return false;
        }
        self.copyTitle(title_text);
        history_change = self.captureHistoryChangeLocked();
        self.mutex.unlock();
        self.notifyHistoryChange(history_change);
        return true;
    }

    pub fn toHistoryRecord(self: *Session, allocator: std.mem.Allocator) !agent_history.SessionRecord {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.toHistoryRecordLocked(allocator);
    }

    /// True iff this session has at least one message that would be written to the
    /// history store. Used to skip persisting/snapshotting never-chatted Copilot
    /// sidebars.
    pub fn shouldPersistCopilot(self: *Session) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.messages.items) |msg| {
            if (msg.persist_to_history) return true;
        }
        return false;
    }

    pub fn allocMarkdownExport(self: *Session, allocator: std.mem.Allocator, mode: MarkdownExportMode) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.allocMarkdownExportLocked(allocator, mode);
    }

    pub fn handleChar(self: *Session, codepoint: u21) void {
        if (codepoint == 'y' or codepoint == 'Y') {
            if (self.resolveApproval(true)) return;
        }
        if (codepoint == 'n' or codepoint == 'N') {
            if (self.resolveApproval(false)) return;
        }
        if (codepoint < 0x20 or codepoint == 0x7f) return;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &buf) catch return;

        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearComposerHistoryNavigationLocked();
        if (self.input_select_all) {
            self.input_len = 0;
            self.input_cursor = 0;
            self.input_scroll_row = 0;
            self.input_scroll_follow_cursor = true;
            self.input_select_all = false;
            self.suggestion_selected = 0;
        }
        self.transcript_select_all = false;
        self.transcript_selection = null;
        self.insertInputBytesLocked(buf[0..len]);
        self.ensureSkillSuggestionsForInputLocked();
    }

    pub fn appendInputText(self: *Session, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearComposerHistoryNavigationLocked();
        if (self.input_select_all) {
            self.input_len = 0;
            self.input_cursor = 0;
            self.input_scroll_row = 0;
            self.input_scroll_follow_cursor = true;
            self.input_select_all = false;
            self.suggestion_selected = 0;
        }
        self.transcript_select_all = false;
        self.transcript_selection = null;
        self.insertInputBytesLocked(text);
        self.ensureSkillSuggestionsForInputLocked();
    }

    /// If the composer is selected (select-all) and non-empty, return a copy of
    /// the input text and clear the composer. Returns null otherwise (e.g. when
    /// only a read-only transcript selection is active).
    pub fn cutInputSelection(self: *Session, allocator: std.mem.Allocator) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.input_select_all or self.input_len == 0) return null;
        const text = try allocator.dupe(u8, self.input_buf[0..self.input_len]);
        self.clearComposerHistoryNavigationLocked();
        self.input_len = 0;
        self.input_cursor = 0;
        self.input_scroll_row = 0;
        self.input_scroll_follow_cursor = true;
        self.input_select_all = false;
        self.suggestion_selected = 0;
        self.ensureSkillSuggestionsForInputLocked();
        return text;
    }

    pub fn applyRemoteInput(self: *Session, data: []const u8) void {
        var text_start: usize = 0;
        var i: usize = 0;
        while (i < data.len) {
            const ch = data[i];
            const is_control = ch == '\r' or ch == '\n' or ch == 0x1b or ch == 0x7f or ch == 0x08;
            if (!is_control) {
                i += 1;
                continue;
            }

            if (i > text_start) self.appendInputText(data[text_start..i]);
            switch (ch) {
                '\r', '\n' => self.submit(),
                0x1b => {
                    self.stopRequest();
                    if (i + 1 < data.len and data[i + 1] == '[') {
                        i += 2;
                        while (i < data.len and !std.ascii.isAlphabetic(data[i])) : (i += 1) {}
                    }
                },
                0x7f, 0x08 => self.backspaceInput(),
                else => {},
            }
            i += 1;
            text_start = i;
        }
        if (text_start < data.len) self.appendInputText(data[text_start..]);
    }

    /// Inject a scheduled prompt as if the user typed + submitted it. Returns
    /// false (skipped, nothing sent) if a request is already inflight. Clears any
    /// half-typed composer text first so the scheduled prompt is sent verbatim.
    /// Caller must run this on the UI thread (mirrors applyRemoteInput).
    pub fn submitScheduledPrompt(self: *Session, text: []const u8) bool {
        self.mutex.lock();
        if (self.request_inflight) {
            self.mutex.unlock();
            return false;
        }
        self.input_len = 0;
        self.input_cursor = 0;
        self.input_scroll_row = 0;
        self.input_scroll_follow_cursor = true;
        self.input_select_all = false;
        self.mutex.unlock();
        self.appendInputText(text);
        self.submit();
        return true;
    }

    /// WeChat delivers complete messages, not keystrokes: the whole payload is
    /// one prompt (embedded newlines are content, unlike applyRemoteInput where
    /// each one submits); only the trailing CR/LF byte-stream submit convention
    /// is stripped. Returns false (busy) without touching the composer when a
    /// request is already inflight, so the poller reports it to the sender
    /// instead of silently swallowing the message.
    pub fn applyWeixinInput(self: *Session, data: []const u8, ctx: weixin_types.ReplyContext) bool {
        self.mutex.lock();
        if (self.request_inflight) {
            self.mutex.unlock();
            return false;
        }
        if (self.pending_weixin_reply_context) |*old| old.deinit(self.allocator);
        self.pending_weixin_reply_context = WeixinReplyContext.init(self.allocator, ctx) catch null;
        self.mutex.unlock();
        if (self.submitScheduledPrompt(std.mem.trimRight(u8, data, "\r\n"))) return true;
        // Lost the race with a concurrently started request: drop the stale
        // context so a later local prompt cannot inherit this WeChat target.
        self.mutex.lock();
        self.clearPendingWeixinReplyContextLocked();
        self.mutex.unlock();
        return false;
    }

    fn clearPendingWeixinReplyContextLocked(self: *Session) void {
        if (self.pending_weixin_reply_context) |*ctx| ctx.deinit(self.allocator);
        self.pending_weixin_reply_context = null;
    }

    pub fn handleKey(self: *Session, ev: input_key.KeyEvent) void {
        self.handleKeyWithWrapCols(ev, std.math.maxInt(usize));
    }

    pub fn handleKeyWithWrapCols(self: *Session, ev: input_key.KeyEvent, max_cols: usize) void {
        if (self.handleApprovalKey(ev)) return;

        if (self.rewind_open) {
            switch (ev.key) {
                .arrow_up => self.moveRewindSelection(1),
                .arrow_down => self.moveRewindSelection(-1),
                .enter => self.confirmRewind(),
                else => self.closeRewindPicker(), // Esc 及其它键一律关闭
            }
            return;
        }

        if (ev.ctrl and !ev.alt and ev.key == .key_a) {
            self.selectAll();
            return;
        }
        if (ev.ctrl and !ev.alt and ev.key == .key_u) {
            self.mutex.lock();
            self.clearComposerHistoryNavigationLocked();
            self.input_len = 0;
            self.input_cursor = 0;
            self.input_scroll_row = 0;
            self.input_scroll_follow_cursor = true;
            self.suggestion_selected = 0;
            self.clearSelectionLocked();
            self.mutex.unlock();
            return;
        }
        if (ev.ctrl and !ev.alt and ev.key == .key_l) {
            self.clearMessages();
            return;
        }

        switch (ev.key) {
            .backspace => self.backspaceInput(),
            .delete => self.deleteInput(),
            .arrow_left => self.moveInputCursorLeft(),
            .arrow_right => self.moveInputCursorRight(),
            .arrow_up => if (!self.moveComposerSuggestionSelection(-1)) {
                if (!self.navigateComposerHistory(max_cols, -1)) self.moveInputCursorVertical(max_cols, -1);
            },
            .arrow_down => if (!self.moveComposerSuggestionSelection(1)) {
                if (!self.navigateComposerHistory(max_cols, 1)) self.moveInputCursorVertical(max_cols, 1);
            },
            .home => self.moveInputCursorHome(),
            .end => self.moveInputCursorEnd(),
            .tab => _ = self.completeComposerSuggestion(.tab),
            .escape => {
                if (self.dismissDistillSuggestion()) return;
                const now = self.now_ms_override orelse std.time.milliTimestamp();
                if (self.request_inflight) {
                    // 生成中：仅停止，不参与双击；停止后变空闲再双击才进选择器。
                    self.stopRequest();
                    self.last_esc_ms = 0;
                } else if (self.hasSelection()) {
                    // 有选区：单次 ESC 先清选区（保持现有手感），且不计入双击计时——
                    // 清选区之后需要重新双击才进选择器。
                    self.clearSelection();
                    self.last_esc_ms = 0;
                } else if (self.last_esc_ms != 0 and
                    now - self.last_esc_ms <= DOUBLE_ESC_WINDOW_MS and
                    self.rewindPointCount() > 0)
                {
                    self.last_esc_ms = 0;
                    self.openRewindPicker();
                } else {
                    // 无选区的单次 ESC：记录时间以备双击。
                    self.last_esc_ms = now;
                }
            },
            .enter => {
                if (ev.shift) {
                    self.appendInputText("\n");
                } else {
                    if (self.acceptDistillSuggestion()) return;
                    if (!self.completeComposerSuggestion(.enter)) self.submit();
                }
            },
            else => {},
        }
    }

    pub fn stopRequest(self: *Session) void {
        self.stop_requested.store(true, .release);

        self.approval_mutex.lock();
        if (self.approval_pending and !self.approval_resolved) {
            self.approval_allowed = false;
            self.approval_resolved = true;
            self.approval_pending = false;
            self.approval_cond.signal();
        }
        self.approval_mutex.unlock();

        self.question_mutex.lock();
        if (self.question_pending and !self.question_resolved) {
            self.question_cancelled = true;
            self.question_resolved = true;
            self.question_pending = false;
            self.question_cond.signal();
        }
        self.question_mutex.unlock();

        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.request_inflight) {
            self.stop_requested.store(false, .release);
            self.request_stopping = false;
            return;
        }
        self.request_stopping = true;
        self.setStatusLocked("Stopping...");
    }

    pub fn selectAll(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.input_select_all = self.input_len > 0;
        self.transcript_select_all = !self.input_select_all and self.messages.items.len > 0;
        self.transcript_selection = null;
    }

    pub fn clearSelection(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearSelectionLocked();
    }

    /// True when the composer or transcript has an active selection that Esc
    /// should clear before any higher-level dismiss (e.g. closing a panel).
    pub fn hasSelection(self: *Session) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.input_select_all or self.transcript_select_all or self.transcript_selection != null;
    }

    pub fn beginTranscriptSelection(self: *Session, message_index: usize, byte_offset: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (message_index >= self.messages.items.len) {
            self.clearSelectionLocked();
            return;
        }
        const msg = self.messages.items[message_index];
        if (msg.role != .assistant or msg.content.len == 0) {
            self.clearSelectionLocked();
            return;
        }
        // byte_offset is a display-text offset (see markdown_text.allocDisplayText);
        // it is already a valid boundary. Do not clamp against raw msg.content,
        // whose length differs from the display text. The copy path re-clamps.
        const offset = byte_offset;
        self.input_select_all = false;
        self.transcript_select_all = false;
        self.transcript_selection = .{
            .message_index = message_index,
            .anchor = offset,
            .cursor = offset,
        };
    }

    pub fn updateTranscriptSelection(self: *Session, message_index: usize, byte_offset: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var selection = self.transcript_selection orelse return;
        if (selection.message_index != message_index or message_index >= self.messages.items.len) return;
        const msg = self.messages.items[message_index];
        if (msg.role != .assistant) return;
        selection.cursor = byte_offset; // display-text offset; copy path re-clamps
        self.transcript_selection = selection;
    }

    pub fn finishTranscriptSelection(self: *Session) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const selection = self.transcript_selection orelse return false;
        if (selection.range() == null) {
            self.transcript_selection = null;
            return false;
        }
        return true;
    }

    pub fn allocClipboardText(self: *Session, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.input_select_all and self.input_len > 0) {
            return allocator.dupe(u8, self.input());
        }
        if (self.allocTranscriptSelectionTextLocked(allocator)) |selected| {
            return selected;
        } else |err| switch (err) {
            error.NoSelection => {},
            else => return err,
        }
        if (self.messages.items.len > 0) {
            return self.allocTranscriptClipboardTextLocked(allocator);
        }
        if (self.input_len > 0) {
            return allocator.dupe(u8, self.input());
        }
        return allocator.dupe(u8, "");
    }

    pub fn allocRemoteSnapshot(self: *Session, allocator: std.mem.Allocator) ![]u8 {
        // Capture any pending approval under approval_mutex BEFORE taking
        // self.mutex (sequential locks, never nested — no reverse ordering
        // exists, so this cannot deadlock). A resolution racing the gap between
        // the two locks costs at most one extra Approval snapshot, which the
        // remote consumer's once-per-episode announcer already de-dupes.
        var cap_tool_buf: [64]u8 = undefined;
        var cap_cmd_buf: [1024]u8 = undefined;
        var cap_tool: []const u8 = "";
        var cap_command: []const u8 = "";
        {
            self.approval_mutex.lock();
            defer self.approval_mutex.unlock();
            if (self.approval_pending and !self.approval_resolved) {
                const tl = self.approval_tool_len;
                @memcpy(cap_tool_buf[0..tl], self.approval_tool_buf[0..tl]);
                cap_tool = cap_tool_buf[0..tl];
                const cl = self.approval_command_len;
                @memcpy(cap_cmd_buf[0..cl], self.approval_command_buf[0..cl]);
                cap_command = cap_cmd_buf[0..cl];
            }
        }

        // Capture any pending ask_user question the same way as the approval
        // above: under its own mutex, into an owned formatted blob, BEFORE taking
        // self.mutex. Numbered options are language-neutral; the WeChat layer adds
        // the Chinese wrapper when it pushes.
        var question_section: ?[]u8 = null;
        defer if (question_section) |qs| allocator.free(qs);
        {
            self.question_mutex.lock();
            defer self.question_mutex.unlock();
            if (self.question_pending and !self.question_resolved) {
                var qbuf: std.ArrayListUnmanaged(u8) = .empty;
                errdefer qbuf.deinit(allocator);
                try qbuf.appendSlice(allocator, self.question_text);
                for (self.question_options, 0..) |opt, i| {
                    try qbuf.writer(allocator).print("\n{d}. {s}", .{ i + 1, opt.label });
                    if (opt.description.len != 0) {
                        try qbuf.appendSlice(allocator, " — ");
                        try qbuf.appendSlice(allocator, opt.description);
                    }
                }
                question_section = try qbuf.toOwnedSlice(allocator);
            }
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try appendLimitedSection(allocator, &out, "Model", self.model(), REMOTE_SNAPSHOT_MAX_BYTES);
        try appendLimitedSection(allocator, &out, "Status", self.status(), REMOTE_SNAPSHOT_MAX_BYTES);

        if (cap_tool.len != 0) {
            var approval_text: std.ArrayListUnmanaged(u8) = .empty;
            defer approval_text.deinit(allocator);
            try approval_text.appendSlice(allocator, cap_tool);
            if (cap_command.len != 0) {
                try approval_text.append(allocator, '\n');
                try approval_text.appendSlice(allocator, cap_command);
            }
            try appendLimitedSection(allocator, &out, "Approval", approval_text.items, REMOTE_SNAPSHOT_MAX_BYTES);
        }

        if (question_section) |qs| {
            try appendLimitedSection(allocator, &out, "Question", qs, REMOTE_SNAPSHOT_MAX_BYTES);
        }

        var sections: std.ArrayListUnmanaged(RemoteSnapshotSection) = .empty;
        defer sections.deinit(allocator);
        var tool_summaries: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (tool_summaries.items) |summary| allocator.free(summary);
            tool_summaries.deinit(allocator);
        }
        for (self.messages.items) |msg| {
            if (msg.role == .tool) {
                const summary = try allocRemoteToolSummary(allocator, msg);
                var summary_owned = true;
                errdefer if (summary_owned) allocator.free(summary);
                try sections.append(allocator, .{ .label = msg.role.label(), .text = summary, .priority = true });
                try tool_summaries.append(allocator, summary);
                summary_owned = false;
            } else {
                try sections.append(allocator, .{ .label = msg.role.label(), .text = msg.content, .priority = true });
            }
            // Reasoning and the usage footer are auxiliary: useful for the web
            // mirror, but the remote reply detector only needs the message bodies.
            // Mark them low-priority so a huge reasoning block can never evict the
            // latest assistant answer from the byte budget (issue #118).
            if (msg.reasoning) |reasoning| {
                if (reasoning.len > 0) try sections.append(allocator, .{ .label = "Reasoning", .text = reasoning, .priority = false });
            }
            if (msg.usage_footer) |footer| {
                if (footer.len > 0) try sections.append(allocator, .{ .label = "Usage", .text = footer, .priority = false });
            }
        }
        try appendRecentLimitedSections(allocator, &out, sections.items, REMOTE_SNAPSHOT_MAX_BYTES);
        if (out.items.len == 0) try out.appendSlice(allocator, "No messages yet.");
        return out.toOwnedSlice(allocator);
    }

    pub fn allocMessageClipboardText(self: *Session, allocator: std.mem.Allocator, message_index: usize) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (message_index >= self.messages.items.len) return allocator.dupe(u8, "");
        return allocator.dupe(u8, self.messages.items[message_index].content);
    }

    pub fn toggleToolMessageCollapsed(self: *Session, message_index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (message_index >= self.messages.items.len) return;
        var msg = &self.messages.items[message_index];
        if (msg.role != .tool and !msg.is_context_summary) return;
        msg.content_collapsed = !msg.content_collapsed;
        msg.content_auto_expand = false;
    }

    pub fn toggleReasoningCollapsed(self: *Session, message_index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (message_index >= self.messages.items.len) return;
        var msg = &self.messages.items[message_index];
        const reasoning = msg.reasoning orelse return;
        if (reasoning.len == 0) return;
        msg.reasoning_collapsed = !msg.reasoning_collapsed;
        msg.reasoning_auto_expand = false;
    }

    pub fn approvalView(self: *Session) ?ApprovalView {
        self.approval_mutex.lock();
        defer self.approval_mutex.unlock();
        if (!self.approval_pending or self.approval_resolved) return null;
        return .{
            .tool = self.approval_tool_buf[0..self.approval_tool_len],
            .command = self.approval_command_buf[0..self.approval_command_len],
            .reason = self.approval_reason_buf[0..self.approval_reason_len],
        };
    }

    fn handleApprovalKey(self: *Session, ev: input_key.KeyEvent) bool {
        const approve = ev.key == .enter or ev.key == .key_y;
        const reject = ev.key == .escape or ev.key == .key_n;
        if (!approve and !reject) return false;
        return self.resolveApproval(approve);
    }

    fn resolveApproval(self: *Session, approve: bool) bool {
        self.approval_mutex.lock();
        defer self.approval_mutex.unlock();
        if (!self.approval_pending or self.approval_resolved) return false;
        self.approval_allowed = approve;
        self.approval_resolved = true;
        self.approval_pending = false;
        self.approval_cond.signal();
        return true;
    }

    /// Resolve a pending approval from a remote driver (e.g. the WeChat bridge),
    /// mirroring the local handleApprovalKey path. Returns true if there was a
    /// pending approval to resolve.
    pub fn resolveApprovalExternal(self: *Session, approve: bool) bool {
        return self.resolveApproval(approve);
    }

    pub fn requestApproval(self: *Session, tool: []const u8, command: []const u8, reason: []const u8) bool {
        if (self.stop_requested.load(.acquire)) return false;
        self.approval_mutex.lock();
        self.copyApprovalLocked(tool, command, reason);
        self.approval_pending = true;
        self.approval_resolved = false;
        self.approval_allowed = false;
        self.approval_mutex.unlock();

        self.setStatus("Approval needed");

        self.approval_mutex.lock();
        defer self.approval_mutex.unlock();
        while (!self.approval_resolved and !self.closing.load(.acquire) and !self.stop_requested.load(.acquire)) {
            self.approval_cond.wait(&self.approval_mutex);
        }
        const allowed = self.approval_resolved and self.approval_allowed and !self.closing.load(.acquire) and !self.stop_requested.load(.acquire);
        self.approval_pending = false;
        self.approval_resolved = false;
        self.approval_allowed = false;
        return allowed;
    }

    /// Snapshot of the pending question for the UI / WeChat push. Borrowed slices
    /// are valid only while holding nothing across the next mutate — copy if kept.
    pub fn questionView(self: *Session) ?QuestionView {
        self.question_mutex.lock();
        defer self.question_mutex.unlock();
        if (!self.question_pending or self.question_resolved) return null;
        return .{ .question = self.question_text, .options = self.question_options };
    }

    /// Resolve a pending question by option index. Out-of-range index is a no-op
    /// that returns false (the question stays pending).
    pub fn resolveQuestionOption(self: *Session, index: usize) bool {
        self.question_mutex.lock();
        defer self.question_mutex.unlock();
        if (!self.question_pending or self.question_resolved) return false;
        if (index >= self.question_options.len) return false;
        self.question_selected_index = index;
        self.question_answer_is_custom = false;
        self.question_resolved = true;
        self.question_pending = false;
        self.question_cond.signal();
        return true;
    }

    /// Resolve a pending question with a free-text custom answer. Returns false
    /// if no question is pending or the answer could not be copied (OOM), leaving
    /// the question pending so the caller can retry.
    pub fn resolveQuestionCustom(self: *Session, text: []const u8) bool {
        self.question_mutex.lock();
        defer self.question_mutex.unlock();
        if (!self.question_pending or self.question_resolved) return false;
        const copy = self.allocator.dupe(u8, text) catch return false;
        self.freeQuestionAnswerLocked();
        self.question_answer = copy;
        self.question_answer_is_custom = true;
        self.question_resolved = true;
        self.question_pending = false;
        self.question_cond.signal();
        return true;
    }

    /// Present `question` + `options` and block the calling (worker) thread until
    /// the user answers via the Copilot card or WeChat, or the request is stopped.
    /// Mirrors `requestApproval`. The returned `.custom` slice borrows Session
    /// memory valid until the next `askUser` call.
    pub fn askUser(self: *Session, question: []const u8, options: []const QuestionOption) AskResult {
        if (self.stop_requested.load(.acquire)) return .cancelled;

        self.question_mutex.lock();
        if (!self.copyQuestionLocked(question, options)) {
            self.question_mutex.unlock();
            self.setStatus("Out of memory");
            return .cancelled;
        }
        self.question_pending = true;
        self.question_resolved = false;
        self.question_cancelled = false;
        self.question_answer_is_custom = false;
        self.question_mutex.unlock();

        self.setStatus("Waiting for your answer");

        self.question_mutex.lock();
        defer self.question_mutex.unlock();
        while (!self.question_resolved and !self.closing.load(.acquire)) {
            self.question_cond.wait(&self.question_mutex);
        }
        const cancelled = self.question_cancelled or self.closing.load(.acquire) or !self.question_resolved;
        const result: AskResult = if (cancelled)
            .cancelled
        else if (self.question_answer_is_custom)
            .{ .custom = self.question_answer.? }
        else
            .{ .option_index = self.question_selected_index };
        self.question_pending = false;
        self.question_resolved = false;
        self.freeQuestionPayloadLocked();
        return result;
    }

    fn copyQuestionLocked(self: *Session, question: []const u8, options: []const QuestionOption) bool {
        self.freeQuestionPayloadLocked();
        self.freeQuestionAnswerLocked();
        const text = self.allocator.dupe(u8, question) catch return false;
        const list = self.allocator.alloc(QuestionOption, options.len) catch {
            self.allocator.free(text);
            return false;
        };
        var filled: usize = 0;
        for (options, 0..) |opt, i| {
            const label = self.allocator.dupe(u8, opt.label) catch {
                freeOptionPrefix(self.allocator, list[0..filled]);
                self.allocator.free(list);
                self.allocator.free(text);
                return false;
            };
            const description = self.allocator.dupe(u8, opt.description) catch {
                self.allocator.free(label);
                freeOptionPrefix(self.allocator, list[0..filled]);
                self.allocator.free(list);
                self.allocator.free(text);
                return false;
            };
            list[i] = .{ .label = label, .description = description };
            filled = i + 1;
        }
        self.question_text = text;
        self.question_options = list;
        return true;
    }

    fn freeQuestionPayloadLocked(self: *Session) void {
        if (self.question_text.len > 0) {
            self.allocator.free(self.question_text);
            self.question_text = &.{};
        }
        freeOptionPrefix(self.allocator, self.question_options);
        if (self.question_options.len > 0) {
            self.allocator.free(self.question_options);
            self.question_options = &.{};
        }
    }

    fn freeQuestionAnswerLocked(self: *Session) void {
        if (self.question_answer) |answer| {
            self.allocator.free(answer);
            self.question_answer = null;
        }
    }

    fn freeOptionPrefix(allocator: std.mem.Allocator, options: []QuestionOption) void {
        for (options) |opt| {
            allocator.free(opt.label);
            allocator.free(opt.description);
        }
    }

    fn canUseDistillSuggestionLocked(self: *Session) bool {
        return self.distill_suggestion_pending and
            self.input_len == 0 and
            !self.input_select_all and
            !self.transcript_select_all and
            self.transcript_selection == null;
    }

    fn acceptDistillSuggestion(self: *Session) bool {
        self.mutex.lock();
        const ok = self.canUseDistillSuggestionLocked();
        self.mutex.unlock();
        if (!ok) return false;
        self.startDistillRequest("");
        return true;
    }

    fn dismissDistillSuggestion(self: *Session) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.canUseDistillSuggestionLocked()) return false;
        self.distill_suggestion_pending = false;
        self.last_esc_ms = 0;
        self.appendLocalToolMessageLocked("Distill suggestion ignored.") catch {
            self.setStatusLocked("Out of memory");
            return true;
        };
        self.setStatusLocked("Ready");
        return true;
    }

    fn copyApprovalLocked(self: *Session, tool: []const u8, command: []const u8, reason: []const u8) void {
        self.approval_tool_len = @min(tool.len, self.approval_tool_buf.len);
        @memcpy(self.approval_tool_buf[0..self.approval_tool_len], tool[0..self.approval_tool_len]);
        self.approval_command_len = @min(command.len, self.approval_command_buf.len);
        @memcpy(self.approval_command_buf[0..self.approval_command_len], command[0..self.approval_command_len]);
        self.approval_reason_len = @min(reason.len, self.approval_reason_buf.len);
        @memcpy(self.approval_reason_buf[0..self.approval_reason_len], reason[0..self.approval_reason_len]);
    }

    fn appendLocalToolMessageLocked(self: *Session, text: []const u8) !void {
        const content = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(content);
        try self.messages.append(self.allocator, .{
            .role = .tool,
            .content = content,
            .replay_to_model = false,
            .persist_to_history = false,
            .content_collapsed = false,
            .content_auto_expand = false,
        });
        self.scroll_px = 1_000_000;
    }

    /// Thread-safe wrapper used by the tool layer (worker thread) to post a
    /// transcript note such as a diff. Swallows OOM (best-effort UI message).
    pub fn appendLocalToolMessage(self: *Session, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.appendLocalToolMessageLocked(text) catch {};
    }

    fn clearDistillCandidateLocked(self: *Session) void {
        if (self.distill_candidate) |*candidate| candidate.deinit(self.allocator);
        self.distill_candidate = null;
    }

    fn submitDistillCommand(self: *Session, arg: []const u8) void {
        const parsed = ai_skill_distill.parseCommandArgs(arg);
        switch (parsed.action) {
            .start => self.startDistillRequest(parsed.topic),
            .confirm => self.confirmDistillCandidate(),
            .cancel => self.cancelDistillCandidate(),
        }
    }

    /// Map a whole-string digit in `1..=n` to a zero-based option index. Mirrors
    /// the WeChat `question_reply.classify` digit rule so the Copilot composer and
    /// the WeChat reply select options identically.
    fn digitOption(text: []const u8, n: usize) ?usize {
        if (text.len == 0 or n == 0) return null;
        for (text) |c| if (!std.ascii.isDigit(c)) return null;
        const v = std.fmt.parseInt(usize, text, 10) catch return null;
        if (v >= 1 and v <= n) return v - 1;
        return null;
    }

    /// Called with self.mutex held. If an ask_user question is pending, consume
    /// the composer text as the answer (a digit in range selects that option,
    /// anything else is a custom answer) and return true so submit() does not
    /// start a new turn. An empty composer is swallowed (the question stays
    /// pending) rather than starting a turn under the blocked worker.
    fn tryAnswerPendingQuestionLocked(self: *Session) bool {
        self.question_mutex.lock();
        const pending = self.question_pending and !self.question_resolved;
        const n = self.question_options.len;
        self.question_mutex.unlock();
        if (!pending) return false;

        const text = std.mem.trim(u8, self.input(), " \t\r\n");
        if (text.len != 0) {
            if (digitOption(text, n)) |idx| {
                _ = self.resolveQuestionOption(idx);
            } else {
                _ = self.resolveQuestionCustom(text);
            }
        }
        self.clearComposerHistoryNavigationLocked();
        self.input_len = 0;
        self.input_cursor = 0;
        self.input_scroll_row = 0;
        self.input_scroll_follow_cursor = true;
        self.suggestion_selected = 0;
        self.clearSelectionLocked();
        return true;
    }

    pub fn submit(self: *Session) void {
        var history_change: ?PendingHistoryChange = null;
        self.mutex.lock();
        if (self.tryAnswerPendingQuestionLocked()) {
            self.mutex.unlock();
            return;
        }
        if (self.request_thread) |thread| {
            if (self.request_inflight) {
                self.clearPendingWeixinReplyContextLocked();
                self.mutex.unlock();
                return;
            }
            self.request_thread = null;
            self.mutex.unlock();
            thread.join();
            self.mutex.lock();
        }

        var prompt_raw = std.mem.trim(u8, self.input(), " \t\r\n");
        if (prompt_raw.len == 0) {
            self.clearPendingWeixinReplyContextLocked();
            self.mutex.unlock();
            return;
        }

        const tok_end = ai_chat_composer.slashCommandTokenEnd(prompt_raw);
        const first_tok = prompt_raw[0..tok_end];
        const arg = std.mem.trim(u8, prompt_raw[tok_end..], " \t\r\n");

        // 1) Built-in command (with optional argument), exact first-token match.
        if (ai_chat_composer.exactBuiltinCommand(first_tok)) |command| {
            if (command == .distill) {
                self.clearPendingWeixinReplyContextLocked();
                self.mutex.unlock();
                self.submitDistillCommand(arg);
                return;
            }
            const r = self.runBuiltinCommandLocked(command, arg);
            self.clearPendingWeixinReplyContextLocked();
            self.mutex.unlock();
            self.notifyHistoryChange(r.history_change);
            fireDeferredAction(self, r.deferred);
            return;
        }
        // 2) Custom command, matched by first token.
        if (ai_chat_composer.matchCustomCommandIndex(first_tok, self.customCommandSuggestions())) |idx| {
            const cmd = self.custom_commands[idx];
            if (cmd.action) |av| {
                if (ai_chat_skills.knownActionFromName(av)) |builtin_command| {
                    const r = self.runBuiltinCommandLocked(builtin_command, arg);
                    self.clearPendingWeixinReplyContextLocked();
                    self.mutex.unlock();
                    self.notifyHistoryChange(r.history_change);
                    fireDeferredAction(self, r.deferred);
                    return;
                }
            }
            // prompt template: submit the body as the prompt. Submit path uses prompt_raw,
            // so REBIND it (cmd.body is owned by custom_commands, stable under the lock).
            prompt_raw = cmd.body;
        } else if (arg.len == 0) {
            // legacy: a no-arg unknown slash like "/help" still shows "Unknown command".
            if (parseSlashCommand(prompt_raw)) |command| {
                const r = self.runBuiltinCommandLocked(command, "");
                self.clearPendingWeixinReplyContextLocked();
                self.mutex.unlock();
                self.notifyHistoryChange(r.history_change);
                fireDeferredAction(self, r.deferred);
                return;
            }
        }
        // otherwise (e.g. "/help me", "/usr/bin path", or a rebound template body): fall through.

        if (ai_chat_composer.parseWebCommand(first_tok)) |web_cmd| {
            self.clearPendingWeixinReplyContextLocked();
            self.mutex.unlock();
            switch (web_cmd) {
                .websearch => self.startWebSearchRequest(arg),
                .webread => self.startWebReadRequest(arg),
                .pubmed => self.startPubMedRequest(arg),
            }
            return;
        }

        if (self.api_key_len == 0) {
            self.setStatusLocked("Missing API key. Edit the Copilot profile or set DEEPSEEK_API_KEY.");
            self.clearPendingWeixinReplyContextLocked();
            self.mutex.unlock();
            return;
        }

        const message_start = self.messages.items.len;
        const invocation = parseSkillInvocation(prompt_raw);
        var skill_preload_content: ?[]u8 = null;
        if (invocation) |parsed| {
            skill_preload_content = ai_chat_skills.loadSkillPreloadContent(self.allocator, parsed.skill_name) catch {
                self.setStatusLocked("Could not load skill");
                self.clearPendingWeixinReplyContextLocked();
                self.mutex.unlock();
                return;
            };
        }

        const prompt_for_history = if (invocation) |parsed|
            if (skill_preload_content != null) parsed.prompt else prompt_raw
        else
            prompt_raw;
        const prompt = self.allocator.dupe(u8, prompt_for_history) catch {
            if (skill_preload_content) |content| self.allocator.free(content);
            self.setStatusLocked("Out of memory");
            self.clearPendingWeixinReplyContextLocked();
            self.mutex.unlock();
            return;
        };
        var prompt_model_context: ?[]u8 = null;
        if (self.pending_weixin_reply_context) |ctx| {
            if (ctx.model_context.len != 0) {
                prompt_model_context = self.allocator.dupe(u8, ctx.model_context) catch {
                    if (skill_preload_content) |content| self.allocator.free(content);
                    self.allocator.free(prompt);
                    self.setStatusLocked("Out of memory");
                    self.clearPendingWeixinReplyContextLocked();
                    self.mutex.unlock();
                    return;
                };
            }
        }
        // Hand any pasted images to this user turn. They are re-sent on every
        // subsequent request for the life of the session (multi-turn vision).
        const user_images = self.takePendingImages();
        self.messages.append(self.allocator, .{ .role = .user, .content = prompt, .model_context = prompt_model_context, .images = user_images }) catch {
            if (skill_preload_content) |content| self.allocator.free(content);
            self.allocator.free(prompt);
            if (prompt_model_context) |ctx| self.allocator.free(ctx);
            if (user_images) |imgs| {
                for (imgs) |img| img.deinit(self.allocator);
                self.allocator.free(imgs);
            }
            self.setStatusLocked("Out of memory");
            self.clearPendingWeixinReplyContextLocked();
            self.mutex.unlock();
            return;
        };
        prompt_model_context = null;

        var skill_preload_appended = false;
        if (invocation) |parsed| if (skill_preload_content) |skill_content| {
            const tool_call_id = std.fmt.allocPrint(self.allocator, "skill-preload-{s}", .{parsed.skill_name}) catch {
                self.allocator.free(skill_content);
                var user_msg = self.messages.pop().?;
                user_msg.deinit(self.allocator);
                self.setStatusLocked("Out of memory");
                self.clearPendingWeixinReplyContextLocked();
                self.mutex.unlock();
                return;
            };
            const tool_name = self.allocator.dupe(u8, "skill_info") catch {
                self.allocator.free(tool_call_id);
                self.allocator.free(skill_content);
                var user_msg = self.messages.pop().?;
                user_msg.deinit(self.allocator);
                self.setStatusLocked("Out of memory");
                self.clearPendingWeixinReplyContextLocked();
                self.mutex.unlock();
                return;
            };
            skill_preload_content = null;
            self.messages.append(self.allocator, .{
                .role = .tool,
                .content = skill_content,
                .tool_call_id = tool_call_id,
                .tool_name = tool_name,
                .replay_to_model = true,
                .content_collapsed = true,
                .content_auto_expand = false,
            }) catch {
                self.allocator.free(tool_name);
                self.allocator.free(tool_call_id);
                self.allocator.free(skill_content);
                var user_msg = self.messages.pop().?;
                user_msg.deinit(self.allocator);
                self.setStatusLocked("Out of memory");
                self.clearPendingWeixinReplyContextLocked();
                self.mutex.unlock();
                return;
            };
            skill_preload_appended = true;
        };

        if (!skill_preload_appended) {
            history_change = self.captureHistoryChangeLocked();
            self.clearSubmittedInputLocked();
            self.scroll_px = 1_000_000;
        }

        const request = self.buildRequestLocked() catch {
            if (skill_preload_appended) {
                self.rollbackMessagesFromLocked(message_start);
                self.setStatusLocked("Could not prepare request");
                self.clearPendingWeixinReplyContextLocked();
                self.mutex.unlock();
                return;
            }
            self.setStatusLocked("Could not prepare request");
            self.clearPendingWeixinReplyContextLocked();
            self.mutex.unlock();
            self.notifyHistoryChange(history_change);
            return;
        };

        self.stop_requested.store(false, .release);
        self.request_stopping = false;
        self.request_inflight = true;
        self.setStatusLocked("Thinking...");
        self.mutex.unlock();
        if (!skill_preload_appended) self.notifyHistoryChange(history_change);

        const thread = std.Thread.spawn(.{}, ai_chat_request.requestThreadMain, .{request}) catch {
            request.deinit();
            self.mutex.lock();
            self.request_inflight = false;
            if (skill_preload_appended) {
                self.rollbackMessagesFromLocked(message_start);
            }
            self.setStatusLocked("Failed to start request thread");
            self.mutex.unlock();
            return;
        };

        self.mutex.lock();
        self.request_thread = thread;
        if (skill_preload_appended) {
            self.clearSubmittedInputLocked();
            self.scroll_px = 1_000_000;
            history_change = self.captureHistoryChangeLocked();
        }
        self.mutex.unlock();
        if (skill_preload_appended) self.notifyHistoryChange(history_change);
    }

    /// Handle `/cwd`. Assumes self.mutex is held. Appends its own tool message
    /// (the caller suppresses the generic slash output).
    fn applyCwdArgLocked(self: *Session, arg: []const u8) void {
        switch (ai_chat_composer.parseCwdArg(arg)) {
            .show => {
                if (self.effectiveWorkingDirLocked()) |w| {
                    const msg = std.fmt.allocPrint(self.allocator, "Working directory: {s}", .{w}) catch return;
                    defer self.allocator.free(msg);
                    self.appendLocalToolMessageLocked(msg) catch {};
                } else {
                    self.appendLocalToolMessageLocked("Working directory: (unset). Use /cwd <path> to set one.") catch {};
                }
            },
            .reset => {
                self.working_dir_len = 0;
                self.appendLocalToolMessageLocked("Working directory override cleared; using the default.") catch {};
            },
            .set => |path| {
                const home = resolveHomeDir(self.allocator);
                defer if (home) |h| self.allocator.free(h);
                const expanded = expandTilde(self.allocator, path, home) catch return;
                defer self.allocator.free(expanded);
                const abs = std.fs.cwd().realpathAlloc(self.allocator, expanded) catch {
                    const m = std.fmt.allocPrint(self.allocator, "No such directory: {s}", .{path}) catch return;
                    defer self.allocator.free(m);
                    self.appendLocalToolMessageLocked(m) catch {};
                    return;
                };
                defer self.allocator.free(abs);
                var dir = std.fs.openDirAbsolute(abs, .{}) catch {
                    const m = std.fmt.allocPrint(self.allocator, "Not a directory: {s}", .{path}) catch return;
                    defer self.allocator.free(m);
                    self.appendLocalToolMessageLocked(m) catch {};
                    return;
                };
                dir.close();
                if (abs.len > self.working_dir_buf.len) {
                    self.appendLocalToolMessageLocked("Path too long for the working directory.") catch {};
                    return;
                }
                @memcpy(self.working_dir_buf[0..abs.len], abs);
                self.working_dir_len = abs.len;
                const m = std.fmt.allocPrint(self.allocator, "Working directory set to {s} for this conversation.", .{abs}) catch return;
                defer self.allocator.free(m);
                self.appendLocalToolMessageLocked(m) catch {};
            },
        }
        self.clearSubmittedInputLocked();
        self.setStatusLocked("Ready");
    }

    /// Append a memory-command result line and return the composer to Ready.
    fn emitMemoryResultLocked(self: *Session, msg: []const u8) void {
        self.appendLocalToolMessageLocked(msg) catch {};
        self.clearSubmittedInputLocked();
        self.setStatusLocked("Ready");
    }

    /// When the memory system is disabled, emit a notice and report true so the
    /// command stops. Honors the `ai-memory-enabled` config switch.
    fn memoryDisabledLocked(self: *Session) bool {
        if (currentAgentSettings().memory_enabled) return false;
        self.emitMemoryResultLocked("Memory is disabled. Set ai-memory-enabled = true in the config to use it.");
        return true;
    }

    fn applyRememberLocked(self: *Session, arg: []const u8) void {
        if (self.memoryDisabledLocked()) return;
        const text = std.mem.trim(u8, arg, " \t\r\n");
        if (text.len == 0) return self.emitMemoryResultLocked("Usage: /remember <fact>");
        const wd = self.effectiveWorkingDirLocked();
        const tier: agent_memory.Tier = if (wd != null and wd.?.len > 0) .project else .global;
        var date_buf: [10]u8 = undefined;
        const today = agent_memory.todayDate(&date_buf);
        const base_slug = agent_memory.slugify(self.allocator, text, today) catch return self.emitMemoryResultLocked("Could not save memory.");
        defer self.allocator.free(base_slug);
        // Resolve a non-colliding slug in the target tier so /remember never
        // silently overwrites a different fact that slugified to the same base.
        const dir = (switch (tier) {
            .global => agent_memory.globalDir(self.allocator),
            .project => agent_memory.projectDir(self.allocator, wd.?),
        }) catch return self.emitMemoryResultLocked("Could not save memory.");
        defer self.allocator.free(dir);
        const slug = agent_memory.uniqueSlugInDir(self.allocator, dir, base_slug) catch return self.emitMemoryResultLocked("Could not save memory.");
        defer self.allocator.free(slug);
        const desc = agent_memory.truncateUtf8(text, 80);
        const msg = agent_memory.saveMemory(self.allocator, tier, wd, slug, desc, .user, text) catch return self.emitMemoryResultLocked("Could not save memory.");
        defer self.allocator.free(msg);
        self.emitMemoryResultLocked(msg);
    }

    fn applyMemoryListLocked(self: *Session) void {
        if (self.memoryDisabledLocked()) return;
        const wd = self.effectiveWorkingDirLocked() orelse "";
        const msg = agent_memory.listForDisplay(self.allocator, wd) catch return self.emitMemoryResultLocked("Could not list memories.");
        defer self.allocator.free(msg);
        self.emitMemoryResultLocked(msg);
    }

    fn applyForgetLocked(self: *Session, arg: []const u8) void {
        if (self.memoryDisabledLocked()) return;
        const name = std.mem.trim(u8, arg, " \t\r\n");
        if (name.len == 0) return self.emitMemoryResultLocked("Usage: /forget <name>");
        const wd = self.effectiveWorkingDirLocked() orelse "";
        const msg = agent_memory.deleteMemory(self.allocator, wd, name, null) catch return self.emitMemoryResultLocked("Could not delete memory.");
        defer self.allocator.free(msg);
        self.emitMemoryResultLocked(msg);
    }

    /// Runs a built-in slash command's side-effects and appends its output as a
    /// tool message. Assumes self.mutex is held. Returns the captured history
    /// change (non-null only for /clear) plus any action the caller must fire
    /// AFTER unlocking (`/resume`, `/export` — see fireDeferredAction).
    fn runBuiltinCommandLocked(self: *Session, command: SlashCommand, arg: []const u8) BuiltinResult {
        var result: BuiltinResult = .{};
        switch (command) {
            .clear => result.history_change = self.clearMessagesLocked(),
            .reload_commands => self.reloadCustomCommands(),
            .reload_skills => self.freeSkillSuggestions(),
            .rewind_picker => {
                const count = self.rewindPointCountLocked();
                self.clearSubmittedInputLocked();
                self.last_esc_ms = 0;
                if (count > 0) {
                    self.rewind_selected = count - 1;
                    self.rewind_open = true;
                    self.setStatusLocked("Ready");
                    result.suppress_output = true;
                }
            },
            .permission => applyPermissionArg(arg),
            .cwd => {
                self.applyCwdArgLocked(arg);
                result.suppress_output = true;
            },
            .resume_session => result.deferred = if (self.copilot)
                .copilot_conversation_picker
            else
                .resume_picker,
            .export_markdown => result.deferred = .{
                .export_markdown = if (std.mem.eql(u8, std.mem.trim(u8, arg, " \t\r\n"), "full")) .full else .clean,
            },
            .loop => self.runLoopCommandLocked(.loop, arg, &result),
            .watch => self.runLoopCommandLocked(.watch, arg, &result),
            .remember => {
                self.applyRememberLocked(arg);
                result.suppress_output = true;
            },
            .memory => {
                self.applyMemoryListLocked();
                result.suppress_output = true;
            },
            .forget => {
                self.applyForgetLocked(arg);
                result.suppress_output = true;
            },
            .model_switch => {
                self.setPendingModelSwitchNameLocked(arg);
                result.deferred = .model_switch_picker;
                self.clearSubmittedInputLocked();
                self.setStatusLocked("Ready");
                result.suppress_output = true;
            },
            else => {},
        }
        if (result.suppress_output) return result;
        const output = slashCommandOutput(self.allocator, command) catch {
            self.setStatusLocked("Could not run command");
            return result;
        };
        defer self.allocator.free(output);
        self.appendLocalToolMessageLocked(output) catch {
            self.setStatusLocked("Out of memory");
            return result;
        };
        self.clearSubmittedInputLocked();
        self.setStatusLocked("Ready");
        return result;
    }

    fn runLoopCommandLocked(self: *Session, kind: ai_loop_schedule.TaskKind, arg: []const u8, result: *BuiltinResult) void {
        result.suppress_output = true;
        const store = ai_loop_store.active() orelse {
            self.emitLoopMessageLocked("Scheduler is not available.");
            return;
        };
        const trimmed = std.mem.trim(u8, arg, " \t\r\n");
        const now_ms = std.time.milliTimestamp();
        const offset_s = @import("ai_history_time.zig").localOffsetSeconds();
        const ctx = ai_loop_store.SessionCtx{
            .session_id = self.sessionId(),
            .model = self.model(),
            .title = self.title(),
        };

        if (trimmed.len == 0) {
            self.listLoopTasksLocked(store, kind, .session);
            return;
        }
        if (std.mem.eql(u8, trimmed, "all")) {
            if (!self.copilot) {
                self.emitLoopMessageLocked("Global scheduled task listing is only available in Copilot.");
                return;
            }
            self.listLoopTasksLocked(store, kind, .all);
            return;
        }
        if (std.mem.startsWith(u8, trimmed, "stop")) {
            const rest = std.mem.trim(u8, trimmed["stop".len..], " \t\r\n");
            if (std.mem.eql(u8, rest, "all")) {
                const n = store.stopAll(ctx.session_id, kind);
                var buf: [64]u8 = undefined;
                self.emitLoopMessageLocked(std.fmt.bufPrint(&buf, "Cancelled {d} task(s).", .{n}) catch "Cancelled tasks.");
            } else {
                const id = std.fmt.parseInt(u32, rest, 10) catch {
                    self.emitLoopMessageLocked("Usage: stop <id> | stop all");
                    return;
                };
                var ok = store.stop(ctx.session_id, id);
                if (!ok and self.copilot) ok = store.stopById(id);
                self.emitLoopMessageLocked(if (ok) "Task cancelled." else "No such task.");
            }
            return;
        }

        const info = switch (kind) {
            .loop => store.registerLoop(trimmed, ctx, now_ms, offset_s),
            .watch => store.registerWatch(trimmed, ctx, now_ms, offset_s),
        } catch |err| switch (err) {
            error.OutOfMemory => {
                self.emitLoopMessageLocked("Out of memory.");
                return;
            },
            else => |parse_err| {
                self.emitLoopMessageLocked(loopErrorText(parse_err, kind));
                return;
            },
        };
        self.emitRegisterConfirmationLocked(info);
    }

    fn listLoopTasksLocked(self: *Session, store: *ai_loop_store.Store, kind: ai_loop_schedule.TaskKind, scope: LoopTaskListScope) void {
        const views = switch (scope) {
            .session => store.snapshotForSession(self.allocator, self.sessionId(), kind),
            .all => store.snapshotAll(self.allocator, kind),
        } catch {
            self.emitLoopMessageLocked("Out of memory.");
            return;
        };
        defer ai_loop_store.freeSnapshot(self.allocator, views);
        if (views.len == 0) {
            self.emitLoopMessageLocked(if (kind == .loop) "No active loop tasks." else "No active watch tasks.");
            return;
        }
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);
        for (views) |v| {
            const owner = taskOwnerLabel(v);
            if (kind == .loop) {
                const iv = ai_loop_schedule.formatInterval(v.interval_ms);
                if (scope == .all) {
                    w.print("#{d}  [{s}]  every {d}{c}  remaining {d}  \u{2192} {s}\n", .{
                        v.id, owner, iv.value, iv.unit, v.remaining, previewPrompt(v.prompt),
                    }) catch return;
                } else {
                    w.print("#{d}  every {d}{c}  remaining {d}  \u{2192} {s}\n", .{
                        v.id, iv.value, iv.unit, v.remaining, previewPrompt(v.prompt),
                    }) catch return;
                }
            } else if (v.daily) {
                if (scope == .all) {
                    w.print("#{d}  [{s}]  daily {d:0>2}:{d:0>2}  \u{2192} {s}\n", .{
                        v.id, owner, @divTrunc(v.tod_minutes, 60), @mod(v.tod_minutes, 60), previewPrompt(v.prompt),
                    }) catch return;
                } else {
                    w.print("#{d}  daily {d:0>2}:{d:0>2}  \u{2192} {s}\n", .{
                        v.id, @divTrunc(v.tod_minutes, 60), @mod(v.tod_minutes, 60), previewPrompt(v.prompt),
                    }) catch return;
                }
            } else {
                if (scope == .all) {
                    w.print("#{d}  [{s}]  once  \u{2192} {s}\n", .{ v.id, owner, previewPrompt(v.prompt) }) catch return;
                } else {
                    w.print("#{d}  once  \u{2192} {s}\n", .{ v.id, previewPrompt(v.prompt) }) catch return;
                }
            }
        }
        self.emitLoopMessageLocked(buf.items);
    }

    fn emitRegisterConfirmationLocked(self: *Session, info: ai_loop_store.RegisterInfo) void {
        var buf: [160]u8 = undefined;
        const msg = switch (info.kind) {
            .loop => blk: {
                const iv = ai_loop_schedule.formatInterval(info.interval_ms);
                break :blk std.fmt.bufPrint(&buf, "Created loop task #{d}: every {d}{c}, {d} times.", .{
                    info.id, iv.value, iv.unit, info.remaining,
                }) catch "Created loop task.";
            },
            .watch => if (info.daily)
                std.fmt.bufPrint(&buf, "Created watch task #{d} (daily).", .{info.id}) catch "Created watch task."
            else
                std.fmt.bufPrint(&buf, "Created watch task #{d} (one-shot).", .{info.id}) catch "Created watch task.",
        };
        self.emitLoopMessageLocked(msg);
    }

    fn emitLoopMessageLocked(self: *Session, text: []const u8) void {
        self.appendLocalToolMessageLocked(text) catch {
            self.setStatusLocked("Out of memory");
            return;
        };
        self.clearSubmittedInputLocked();
        self.setStatusLocked("Ready");
    }

    fn cancelDistillCandidate(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearDistillCandidateLocked();
        self.distill_suggestion_pending = false;
        self.clearSubmittedInputLocked();
        self.appendLocalToolMessageLocked("Distill candidate discarded.") catch {
            self.setStatusLocked("Out of memory");
            return;
        };
        self.setStatusLocked("Ready");
    }

    fn confirmDistillCandidate(self: *Session) void {
        var candidate: ?ai_skill_distill.Candidate = null;
        self.mutex.lock();
        if (self.distill_candidate) |existing| {
            candidate = existing;
            self.distill_candidate = null;
            self.distill_suggestion_pending = false;
            self.clearSubmittedInputLocked();
        } else {
            self.distill_suggestion_pending = false;
            self.clearSubmittedInputLocked();
            self.appendLocalToolMessageLocked("No distill candidate is waiting for confirmation.") catch {
                self.setStatusLocked("Out of memory");
                self.mutex.unlock();
                return;
            };
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        }
        self.mutex.unlock();

        var moved = candidate.?;
        defer moved.deinit(self.allocator);
        var saved = ai_chat_skills.saveDistilledCandidate(self.allocator, moved) catch |err| {
            const text = switch (err) {
                error.SkillAlreadyExists => std.fmt.allocPrint(
                    self.allocator,
                    "A skill named ${s} already exists. Use /distill with a more specific topic or remove the old skill first.",
                    .{moved.name},
                ),
                else => std.fmt.allocPrint(self.allocator, "Could not save distilled skill: {}.", .{err}),
            } catch null;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (text) |msg| {
                defer self.allocator.free(msg);
                self.appendLocalToolMessageLocked(msg) catch self.setStatusLocked("Out of memory");
            } else {
                self.setStatusLocked("Out of memory");
            }
            self.setStatusLocked("Ready");
            return;
        };
        defer saved.deinit(self.allocator);

        const text = std.fmt.allocPrint(
            self.allocator,
            "Distilled skill: ${s}\nSaved to: {s}",
            .{ saved.skill_name, saved.skill_path },
        ) catch null;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (text) |msg| {
            defer self.allocator.free(msg);
            self.appendLocalToolMessageLocked(msg) catch self.setStatusLocked("Out of memory");
        } else {
            self.setStatusLocked("Out of memory");
            return;
        }
        self.freeSkillSuggestions();
        self.setStatusLocked("Ready");
    }

    fn startDistillRequest(self: *Session, topic: []const u8) void {
        self.mutex.lock();
        if (self.request_thread) |thread| {
            if (self.request_inflight) {
                self.distill_suggestion_pending = false;
                self.clearSubmittedInputLocked();
                self.appendLocalToolMessageLocked("Wait for the current AI request to finish before distilling.") catch {
                    self.setStatusLocked("Out of memory");
                    self.mutex.unlock();
                    return;
                };
                self.setStatusLocked("Ready");
                self.mutex.unlock();
                return;
            }
            self.request_thread = null;
            self.mutex.unlock();
            thread.join();
            self.mutex.lock();
        }
        if (self.api_key_len == 0) {
            self.distill_suggestion_pending = false;
            self.clearSubmittedInputLocked();
            self.setStatusLocked("Missing API key. Edit the AI Chat profile or set DEEPSEEK_API_KEY.");
            self.mutex.unlock();
            return;
        }

        self.clearDistillCandidateLocked();
        self.distill_suggestion_pending = false;
        const request = self.buildDistillRequestLocked(topic) catch |err| {
            self.clearSubmittedInputLocked();
            const text = switch (err) {
                error.NotEnoughContext => "Not enough reusable context to distill yet.",
                else => "Could not prepare distill request.",
            };
            self.appendLocalToolMessageLocked(text) catch self.setStatusLocked("Out of memory");
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        };

        self.clearSubmittedInputLocked();
        self.stop_requested.store(false, .release);
        self.request_stopping = false;
        self.request_inflight = true;
        self.distill_inflight = true;
        self.appendLocalToolMessageLocked("Distilling a reusable skill candidate.") catch {
            request.deinit();
            self.request_inflight = false;
            self.distill_inflight = false;
            self.setStatusLocked("Out of memory");
            self.mutex.unlock();
            return;
        };
        self.setStatusLocked("Distilling skill.");
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, ai_chat_request.distillThreadMain, .{request}) catch {
            request.deinit();
            self.mutex.lock();
            self.request_inflight = false;
            self.distill_inflight = false;
            self.appendLocalToolMessageLocked("Failed to start distill request thread.") catch self.setStatusLocked("Out of memory");
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        };

        self.mutex.lock();
        self.request_thread = thread;
        self.mutex.unlock();
    }

    /// Run a `$websearch <query>` command on a background thread. Mirrors
    /// `startDistillRequest`: reuses `request_thread`/`request_inflight` so the
    /// existing submit-guard and `deinit` join cover lifetime. Called AFTER the
    /// caller has unlocked `self.mutex`.
    fn startWebSearchRequest(self: *Session, query_in: []const u8) void {
        self.mutex.lock();
        if (self.request_thread) |thread| {
            if (self.request_inflight) {
                self.clearSubmittedInputLocked();
                self.appendLocalToolMessageLocked("Wait for the current request to finish.") catch {};
                self.setStatusLocked("Ready");
                self.mutex.unlock();
                return;
            }
            self.request_thread = null;
            self.mutex.unlock();
            thread.join();
            self.mutex.lock();
        }

        const query = std.mem.trim(u8, query_in, " \t\r\n");
        if (query.len == 0) {
            self.clearSubmittedInputLocked();
            self.appendLocalToolMessageLocked("Usage: $websearch <query>") catch self.setStatusLocked("Out of memory");
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        }
        if (!web_search.jinaApiKeySet()) {
            self.clearSubmittedInputLocked();
            self.appendLocalToolMessageLocked("Jina API key not set — add `jina-api-key = <key>` to your WispTerm config.") catch self.setStatusLocked("Out of memory");
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        }

        const req = WebSearchRequest.create(self.allocator, self, query) catch {
            self.clearSubmittedInputLocked();
            self.appendLocalToolMessageLocked("Out of memory.") catch {};
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        };
        self.clearSubmittedInputLocked();
        self.stop_requested.store(false, .release);
        self.request_stopping = false;
        self.request_inflight = true;
        self.setStatusLocked("Searching the web…");
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, ai_chat_request.webSearchThreadMain, .{req}) catch {
            req.deinit();
            self.mutex.lock();
            self.request_inflight = false;
            self.appendLocalToolMessageLocked("Failed to start web search thread.") catch {};
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        };
        self.mutex.lock();
        self.request_thread = thread;
        self.mutex.unlock();
    }

    /// Run a `$webread <target>` command on a background thread. Mirrors
    /// `startWebSearchRequest` but does not require a Jina key (anonymous read is
    /// allowed). Called AFTER the caller has unlocked `self.mutex`.
    fn startWebReadRequest(self: *Session, target_in: []const u8) void {
        self.mutex.lock();
        if (self.request_thread) |thread| {
            if (self.request_inflight) {
                self.clearSubmittedInputLocked();
                self.appendLocalToolMessageLocked("Wait for the current request to finish.") catch {};
                self.setStatusLocked("Ready");
                self.mutex.unlock();
                return;
            }
            self.request_thread = null;
            self.mutex.unlock();
            thread.join();
            self.mutex.lock();
        }

        const target = std.mem.trim(u8, target_in, " \t\r\n");
        if (target.len == 0) {
            self.clearSubmittedInputLocked();
            self.appendLocalToolMessageLocked("Usage: $webread <url | file path>") catch self.setStatusLocked("Out of memory");
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        }

        const wd = self.effectiveWorkingDirLocked() orelse "";
        const req = WebReadRequest.create(self.allocator, self, target, wd) catch {
            self.clearSubmittedInputLocked();
            self.appendLocalToolMessageLocked("Out of memory.") catch {};
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        };
        self.clearSubmittedInputLocked();
        self.stop_requested.store(false, .release);
        self.request_stopping = false;
        self.request_inflight = true;
        self.setStatusLocked("Reading…");
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, ai_chat_request.webReadThreadMain, .{req}) catch {
            req.deinit();
            self.mutex.lock();
            self.request_inflight = false;
            self.appendLocalToolMessageLocked("Failed to start web read thread.") catch {};
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        };
        self.mutex.lock();
        self.request_thread = thread;
        self.mutex.unlock();
    }

    /// Run a `$pubmed <query>` command on a background thread. Mirrors
    /// `startWebSearchRequest` but needs no API key (NCBI is anonymous). Called
    /// AFTER the caller has unlocked `self.mutex`.
    fn startPubMedRequest(self: *Session, query_in: []const u8) void {
        self.mutex.lock();
        if (self.request_thread) |thread| {
            if (self.request_inflight) {
                self.clearSubmittedInputLocked();
                self.appendLocalToolMessageLocked("Wait for the current request to finish.") catch {};
                self.setStatusLocked("Ready");
                self.mutex.unlock();
                return;
            }
            self.request_thread = null;
            self.mutex.unlock();
            thread.join();
            self.mutex.lock();
        }

        const query = std.mem.trim(u8, query_in, " \t\r\n");
        if (query.len == 0) {
            self.clearSubmittedInputLocked();
            self.appendLocalToolMessageLocked("Usage: $pubmed <query>") catch self.setStatusLocked("Out of memory");
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        }

        const req = WebPubMedRequest.create(self.allocator, self, query) catch {
            self.clearSubmittedInputLocked();
            self.appendLocalToolMessageLocked("Out of memory.") catch {};
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        };
        self.clearSubmittedInputLocked();
        self.stop_requested.store(false, .release);
        self.request_stopping = false;
        self.request_inflight = true;
        self.setStatusLocked("Searching PubMed…");
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, ai_chat_request.pubMedThreadMain, .{req}) catch {
            req.deinit();
            self.mutex.lock();
            self.request_inflight = false;
            self.appendLocalToolMessageLocked("Failed to start PubMed search thread.") catch {};
            self.setStatusLocked("Ready");
            self.mutex.unlock();
            return;
        };
        self.mutex.lock();
        self.request_thread = thread;
        self.mutex.unlock();
    }

    /// Assumes self.mutex is held. Returns the captured history change for the
    /// caller to notify after unlocking.
    fn clearMessagesLocked(self: *Session) ?PendingHistoryChange {
        for (self.messages.items) |msg| msg.deinit(self.allocator);
        self.messages.clearRetainingCapacity();
        self.scroll_px = 0;
        self.suggestion_selected = 0;
        self.clearSelectionLocked();
        self.setStatusLocked("Cleared");
        return self.captureHistoryChangeLocked();
    }

    fn clearMessages(self: *Session) void {
        self.mutex.lock();
        if (self.request_inflight) {
            self.mutex.unlock();
            return;
        }
        const history_change = self.clearMessagesLocked();
        self.mutex.unlock();
        self.notifyHistoryChange(history_change);
    }

    pub fn scrollBy(self: *Session, delta_px: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.scroll_px = @max(0.0, self.scroll_px + delta_px);
        self.scrollbar_show_time = std.time.milliTimestamp();
    }

    pub fn scrollToPx(self: *Session, px: f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.scroll_px = @max(0.0, px);
        self.scrollbar_show_time = std.time.milliTimestamp();
    }

    pub fn inputScrollRow(self: *Session) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.input_scroll_row;
    }

    pub fn scrollInputRows(self: *Session, delta_rows: i32, max_cols_raw: usize, visible_rows_raw: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const before = self.input_scroll_row;
        const max_row = self.maxInputScrollRowLocked(max_cols_raw, visible_rows_raw);
        var next = @min(self.input_scroll_row, max_row);
        if (delta_rows < 0) {
            const amount: usize = @intCast(-delta_rows);
            next -|= amount;
        } else if (delta_rows > 0) {
            const amount: usize = @intCast(delta_rows);
            next = @min(max_row, next +| amount);
        }
        self.input_scroll_row = next;
        if (before != next) self.input_scroll_follow_cursor = false;
        return before != next;
    }

    pub fn setInputScrollRow(self: *Session, row: usize, max_cols_raw: usize, visible_rows_raw: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const before = self.input_scroll_row;
        const max_row = self.maxInputScrollRowLocked(max_cols_raw, visible_rows_raw);
        self.input_scroll_row = @min(row, max_row);
        if (max_row > 0) self.input_scroll_follow_cursor = false;
        return before != self.input_scroll_row;
    }

    fn backspaceInput(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearComposerHistoryNavigationLocked();
        if (self.input_select_all) {
            self.input_len = 0;
            self.input_cursor = 0;
            self.input_scroll_row = 0;
            self.input_scroll_follow_cursor = true;
            self.suggestion_selected = 0;
            self.clearSelectionLocked();
            return;
        }
        self.transcript_select_all = false;
        self.transcript_selection = null;
        self.clampInputCursorLocked();
        if (self.input_cursor == 0) return;
        const start = previousUtf8Boundary(self.input(), self.input_cursor);
        self.deleteInputRangeLocked(start, self.input_cursor);
        self.input_cursor = start;
        self.input_scroll_follow_cursor = true;
    }

    fn deleteInput(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearComposerHistoryNavigationLocked();
        if (self.input_select_all) {
            self.input_len = 0;
            self.input_cursor = 0;
            self.input_scroll_row = 0;
            self.input_scroll_follow_cursor = true;
            self.suggestion_selected = 0;
            self.clearSelectionLocked();
            return;
        }
        self.transcript_select_all = false;
        self.transcript_selection = null;
        self.clampInputCursorLocked();
        if (self.input_cursor >= self.input_len) return;
        const end = nextUtf8Boundary(self.input(), self.input_cursor);
        self.deleteInputRangeLocked(self.input_cursor, end);
        self.input_scroll_follow_cursor = true;
    }

    fn moveInputCursorLeft(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearSelectionLocked();
        self.input_cursor = previousUtf8Boundary(self.input(), self.input_cursor);
        self.input_scroll_follow_cursor = true;
        self.suggestion_selected = 0;
    }

    fn moveInputCursorRight(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearSelectionLocked();
        self.input_cursor = nextUtf8Boundary(self.input(), self.input_cursor);
        self.input_scroll_follow_cursor = true;
        self.suggestion_selected = 0;
    }

    fn moveInputCursorHome(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearSelectionLocked();
        self.input_cursor = 0;
        self.input_scroll_follow_cursor = true;
        self.suggestion_selected = 0;
    }

    fn moveInputCursorEnd(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearSelectionLocked();
        self.input_cursor = self.input_len;
        self.input_scroll_follow_cursor = true;
        self.suggestion_selected = 0;
    }

    fn moveInputCursorVertical(self: *Session, max_cols_raw: usize, delta: i32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearSelectionLocked();
        self.clampInputCursorLocked();

        const text = self.input();
        const max_cols = @max(@as(usize, 1), max_cols_raw);
        const current = visualCursorPosition(text, self.input_cursor, max_cols);
        if (delta < 0 and current.row == 0) return;
        const target_row = if (delta < 0) current.row - 1 else current.row + 1;
        self.input_cursor = byteOffsetForVisualPosition(text, target_row, current.col, max_cols) orelse return;
        self.input_scroll_follow_cursor = true;
        self.suggestion_selected = 0;
    }

    fn navigateComposerHistory(self: *Session, max_cols_raw: usize, delta: i32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const prompt_count = self.composerHistoryPromptCountLocked();
        if (prompt_count == 0 or delta == 0) return false;
        self.clampInputCursorLocked();

        const max_cols = @max(@as(usize, 1), max_cols_raw);
        const text = self.input();
        const current = visualCursorPosition(text, self.input_cursor, max_cols);
        const rows = inputWrappedLineCount(text, max_cols);

        if (delta < 0) {
            if (current.row != 0) return false;
            if (!self.composer_history_active) {
                self.saveComposerHistoryDraftLocked();
                self.composer_history_active = true;
                self.composer_history_selected = prompt_count - 1;
            } else if (self.composer_history_selected > 0) {
                self.composer_history_selected -= 1;
            }
            return self.restoreComposerHistoryPromptLocked(self.composer_history_selected);
        }

        if (current.row + 1 < rows or !self.composer_history_active) return false;
        if (self.composer_history_selected + 1 < prompt_count) {
            self.composer_history_selected += 1;
            return self.restoreComposerHistoryPromptLocked(self.composer_history_selected);
        }

        self.restoreComposerHistoryDraftLocked();
        self.clearComposerHistoryNavigationLocked();
        return true;
    }

    fn moveComposerSuggestionSelection(self: *Session, delta: i32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ensureSkillSuggestionsForInputLocked();

        const count = composerSuggestionCountForInput(self.input(), self.input_cursor, self.skill_suggestions, self.customCommandSuggestions());
        if (count == 0) return false;
        const current = @min(self.suggestion_selected, count - 1);
        self.suggestion_selected = if (delta < 0)
            if (current == 0) count - 1 else current - 1
        else if (delta > 0)
            (current + 1) % count
        else
            current;
        self.clearSelectionLocked();
        return true;
    }

    fn completeComposerSuggestion(self: *Session, trigger: ComposerCompletionTrigger) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ensureSkillSuggestionsForInputLocked();

        const prefix = composerSuggestionPrefix(self.input(), self.input_cursor) orelse return false;
        const count = composerSuggestionCountForInput(self.input(), self.input_cursor, self.skill_suggestions, self.customCommandSuggestions());
        if (count == 0) return false;
        const selected = @min(self.suggestion_selected, count - 1);
        const suggestion = composerSuggestionAtForInput(self.input(), self.input_cursor, self.skill_suggestions, self.customCommandSuggestions(), selected) orelse return false;
        if (trigger == .enter and suggestion.kind == .slash_command and std.mem.eql(u8, prefix.prefix, suggestion.text)) {
            return false;
        }

        var replacement_buf: [256]u8 = undefined;
        const replacement = suggestionReplacementText(&replacement_buf, suggestion, self.input()[prefix.token_end..]) orelse return false;
        const suffix_len = self.input_len - prefix.token_end;
        if (replacement.len + suffix_len > self.input_buf.len) return false;

        self.clearComposerHistoryNavigationLocked();
        if (replacement.len > prefix.token_end) {
            std.mem.copyBackwards(
                u8,
                self.input_buf[replacement.len .. replacement.len + suffix_len],
                self.input_buf[prefix.token_end..self.input_len],
            );
        } else if (replacement.len < prefix.token_end) {
            std.mem.copyForwards(
                u8,
                self.input_buf[replacement.len .. replacement.len + suffix_len],
                self.input_buf[prefix.token_end..self.input_len],
            );
        }
        @memcpy(self.input_buf[0..replacement.len], replacement);
        self.input_len = replacement.len + suffix_len;
        self.input_cursor = replacement.len;
        self.input_scroll_follow_cursor = true;
        self.suggestion_selected = 0;
        self.clearSelectionLocked();
        return true;
    }

    fn insertInputBytesLocked(self: *Session, text: []const u8) void {
        self.clampInputCursorLocked();
        var len = @min(text.len, self.input_buf.len - self.input_len);
        while (len > 0 and len < text.len and (text[len] & 0xC0) == 0x80) {
            len -= 1;
        }
        if (len == 0) return;
        if (self.input_cursor < self.input_len) {
            std.mem.copyBackwards(
                u8,
                self.input_buf[self.input_cursor + len .. self.input_len + len],
                self.input_buf[self.input_cursor..self.input_len],
            );
        }
        @memcpy(self.input_buf[self.input_cursor..][0..len], text[0..len]);
        self.input_len += len;
        self.input_cursor += len;
        self.input_scroll_follow_cursor = true;
        self.suggestion_selected = 0;
    }

    fn deleteInputRangeLocked(self: *Session, start: usize, end: usize) void {
        if (start >= end or end > self.input_len) return;
        const removed = end - start;
        if (end < self.input_len) {
            std.mem.copyForwards(
                u8,
                self.input_buf[start .. self.input_len - removed],
                self.input_buf[end..self.input_len],
            );
        }
        self.input_len -= removed;
        if (self.input_cursor > self.input_len) self.input_cursor = self.input_len;
        self.suggestion_selected = 0;
    }

    fn clampInputCursorLocked(self: *Session) void {
        if (self.input_cursor > self.input_len) self.input_cursor = self.input_len;
        while (self.input_cursor > 0 and self.input_cursor < self.input_len and (self.input_buf[self.input_cursor] & 0xC0) == 0x80) {
            self.input_cursor -= 1;
        }
    }

    fn maxInputScrollRowLocked(self: *Session, max_cols_raw: usize, visible_rows_raw: usize) usize {
        const rows = inputWrappedLineCount(self.input(), max_cols_raw);
        const visible_rows = @max(@as(usize, 1), visible_rows_raw);
        return if (rows > visible_rows) rows - visible_rows else 0;
    }

    fn clearSelectionLocked(self: *Session) void {
        self.input_select_all = false;
        self.transcript_select_all = false;
        self.transcript_selection = null;
    }

    fn clearSubmittedInputLocked(self: *Session) void {
        self.clearComposerHistoryNavigationLocked();
        self.input_len = 0;
        self.input_cursor = 0;
        self.input_scroll_row = 0;
        self.input_scroll_follow_cursor = true;
        self.suggestion_selected = 0;
        self.clearSelectionLocked();
    }

    /// 用 text 覆盖输入框内容，光标置于末尾。纯缓冲区操作、无 IO。
    fn setInputTextLocked(self: *Session, text: []const u8) void {
        self.clearComposerHistoryNavigationLocked();
        self.replaceInputTextLocked(text);
    }

    fn replaceInputTextLocked(self: *Session, text: []const u8) void {
        self.input_len = 0;
        self.input_cursor = 0;
        self.input_scroll_row = 0;
        self.input_scroll_follow_cursor = true;
        self.suggestion_selected = 0;
        self.clearSelectionLocked();
        self.insertInputBytesLocked(text);
    }

    fn clearComposerHistoryNavigationLocked(self: *Session) void {
        self.composer_history_active = false;
        self.composer_history_selected = 0;
        self.composer_history_draft_len = 0;
        self.composer_history_draft_cursor = 0;
    }

    fn saveComposerHistoryDraftLocked(self: *Session) void {
        const len = @min(self.input_len, self.composer_history_draft_buf.len);
        if (len > 0) @memcpy(self.composer_history_draft_buf[0..len], self.input_buf[0..len]);
        self.composer_history_draft_len = len;
        self.composer_history_draft_cursor = @min(self.input_cursor, len);
    }

    fn restoreComposerHistoryDraftLocked(self: *Session) void {
        const draft = self.composer_history_draft_buf[0..self.composer_history_draft_len];
        const cursor = self.composer_history_draft_cursor;
        self.replaceInputTextLocked(draft);
        self.input_cursor = @min(cursor, self.input_len);
        self.clampInputCursorLocked();
        self.input_scroll_follow_cursor = true;
    }

    fn composerHistoryPromptCountLocked(self: *Session) usize {
        var n: usize = 0;
        for (self.messages.items) |msg| {
            if (msg.role == .user) n += 1;
        }
        return n;
    }

    fn composerHistoryPromptMessageIndexLocked(self: *Session, n: usize) usize {
        var seen: usize = 0;
        for (self.messages.items, 0..) |msg, i| {
            if (msg.role == .user) {
                if (seen == n) return i;
                seen += 1;
            }
        }
        return self.messages.items.len;
    }

    fn restoreComposerHistoryPromptLocked(self: *Session, selected: usize) bool {
        const idx = self.composerHistoryPromptMessageIndexLocked(selected);
        if (idx >= self.messages.items.len) return false;
        self.replaceInputTextLocked(self.messages.items[idx].content);
        return true;
    }

    /// 打开回溯选择器：仅在空闲且至少有一个回溯点时；默认选中最近一条。
    pub fn openRewindPicker(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.request_inflight) return;
        const count = self.rewindPointCountLocked();
        if (count == 0) return;
        self.clearSelectionLocked();
        self.rewind_selected = count - 1;
        self.rewind_open = true;
    }

    pub fn closeRewindPicker(self: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.rewind_open = false;
    }

    /// 在 [0, count) 内移动选中项，到边界停住（不回绕）。
    pub fn moveRewindSelection(self: *Session, delta: i32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.rewind_open) return;
        const count = self.rewindPointCountLocked();
        if (count == 0) {
            self.rewind_open = false;
            return;
        }
        const cur: i64 = @intCast(@min(self.rewind_selected, count - 1));
        var next = cur + delta;
        if (next < 0) next = 0;
        const max_i: i64 = @intCast(count - 1);
        if (next > max_i) next = max_i;
        self.rewind_selected = @intCast(next);
    }

    /// 确认回溯：把对话回退到选中用户消息之前，将其文本回填输入框，删除该
    /// 消息及其后所有消息，关闭选择器并同步历史。仅空闲时有效。
    pub fn confirmRewind(self: *Session) void {
        var history_change: ?PendingHistoryChange = null;
        self.mutex.lock();
        if (self.request_inflight or !self.rewind_open) {
            self.mutex.unlock();
            return;
        }
        const count = self.rewindPointCountLocked();
        if (count == 0) {
            self.rewind_open = false;
            self.mutex.unlock();
            return;
        }
        const sel = @min(self.rewind_selected, count - 1);
        const idx = self.rewindPointMessageIndexLocked(sel);
        if (idx >= self.messages.items.len) {
            self.rewind_open = false;
            self.mutex.unlock();
            return;
        }
        // insertInputBytesLocked 会立即把字节拷入 input_buf，随后 rollback 才释放
        // messages[idx]，两块缓冲区不重叠，安全。
        self.setInputTextLocked(self.messages.items[idx].content);
        self.rollbackMessagesFromLocked(idx);
        self.rewind_open = false;
        self.scroll_px = 1_000_000;
        history_change = self.captureHistoryChangeLocked();
        self.mutex.unlock();
        self.notifyHistoryChange(history_change);
    }

    fn rollbackMessagesFromLocked(self: *Session, start: usize) void {
        while (self.messages.items.len > start) {
            var msg = self.messages.pop().?;
            msg.deinit(self.allocator);
        }
    }

    /// 对话中 role == .user 的消息条数（回溯点数量）。持锁内部版本。
    fn rewindPointCountLocked(self: *Session) usize {
        var n: usize = 0;
        for (self.messages.items) |msg| {
            if (msg.role == .user) n += 1;
        }
        return n;
    }

    /// 供 ESC handler（未持锁）调用：自行加锁返回回溯点数量。
    pub fn rewindPointCount(self: *Session) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.rewindPointCountLocked();
    }

    /// 第 n 个回溯点在 messages 中的索引（n 为 0-based 用户消息序号）。
    /// 调用方需保证 n < rewindPointCountLocked()。找不到返回 messages.items.len。
    fn rewindPointMessageIndexLocked(self: *Session, n: usize) usize {
        var seen: usize = 0;
        for (self.messages.items, 0..) |msg, i| {
            if (msg.role == .user) {
                if (seen == n) return i;
                seen += 1;
            }
        }
        return self.messages.items.len;
    }

    fn collapseAutoExpandedDetailsLocked(self: *Session) void {
        for (self.messages.items) |*msg| {
            if (msg.role == .tool and msg.content_auto_expand) {
                msg.content_collapsed = true;
                msg.content_auto_expand = false;
            }
            if (msg.reasoning_auto_expand) {
                msg.reasoning_collapsed = true;
                msg.reasoning_auto_expand = false;
            }
        }
    }

    fn allocTranscriptClipboardTextLocked(self: *Session, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        for (self.messages.items) |msg| {
            try appendClipboardSection(allocator, &out, msg.role.label(), msg.content);
            if (msg.reasoning) |reasoning| {
                if (reasoning.len > 0) try appendClipboardSection(allocator, &out, "Reasoning", reasoning);
            }
            if (msg.usage_footer) |footer| {
                if (footer.len > 0) try appendClipboardSection(allocator, &out, "Usage", footer);
            }
        }
        return out.toOwnedSlice(allocator);
    }

    fn allocMarkdownExportLocked(self: *Session, allocator: std.mem.Allocator, mode: MarkdownExportMode) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try appendMarkdownDocumentHeader(allocator, &out, self.title(), self.model(), self.sessionId(), mode == .full);
        switch (mode) {
            .full => try self.appendFullMarkdownExportLocked(allocator, &out),
            .clean => try self.appendCleanMarkdownExportLocked(allocator, &out),
        }

        if (out.items.len == 0) try out.appendSlice(allocator, "# WispTerm Copilot\n\nNo messages yet.\n");
        return out.toOwnedSlice(allocator);
    }

    fn appendFullMarkdownExportLocked(self: *Session, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        if (self.messages.items.len == 0) {
            try out.appendSlice(allocator, "No messages yet.\n");
            return;
        }

        for (self.messages.items) |msg| {
            const heading = if (msg.role == .tool and msg.tool_name != null and msg.tool_name.?.len > 0)
                "Tool"
            else
                msg.role.label();
            try appendMarkdownSection(allocator, out, heading, msg.content);

            if (msg.reasoning) |reasoning| {
                if (reasoning.len > 0) try appendMarkdownCodeSection(allocator, out, "Thinking", reasoning);
            }
            if (msg.usage_footer) |footer| {
                if (footer.len > 0) try appendMarkdownCodeSection(allocator, out, "Usage", footer);
            }
        }
    }

    fn appendCleanMarkdownExportLocked(self: *Session, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        var user_count: usize = 0;
        for (self.messages.items) |msg| {
            if (msg.role == .user and msg.content.len > 0) user_count += 1;
        }

        try out.appendSlice(allocator, "## User Input\n\n");
        if (user_count == 0) {
            try out.appendSlice(allocator, "No user input yet.\n\n");
        } else {
            var seen: usize = 0;
            for (self.messages.items) |msg| {
                if (msg.role != .user or msg.content.len == 0) continue;
                if (user_count > 1) {
                    try out.writer(allocator).print("### {d}\n\n", .{seen + 1});
                }
                try appendMarkdownBody(allocator, out, msg.content);
                seen += 1;
                try out.appendSlice(allocator, "\n");
            }
        }

        try out.appendSlice(allocator, "## Final Result\n\n");
        if (latestAssistantContent(self.messages.items)) |content| {
            try appendMarkdownBody(allocator, out, content);
            try out.append(allocator, '\n');
        } else {
            try out.appendSlice(allocator, "No assistant result yet.\n");
        }
    }

    fn allocTranscriptSelectionTextLocked(self: *Session, allocator: std.mem.Allocator) (error{NoSelection} || std.mem.Allocator.Error)![]u8 {
        const selection = self.transcript_selection orelse return error.NoSelection;
        const range = selection.range() orelse return error.NoSelection;
        if (selection.message_index >= self.messages.items.len) return error.NoSelection;
        const msg = self.messages.items[selection.message_index];
        if (msg.role != .assistant) return error.NoSelection;
        const display = try markdown_text.allocDisplayText(allocator, msg.content);
        defer allocator.free(display);
        const start = clampUtf8Boundary(display, @min(range.start, display.len));
        const end = clampUtf8Boundary(display, @min(range.end, display.len));
        if (start >= end) return error.NoSelection;
        return allocator.dupe(u8, display[start..end]);
    }

    /// Convert the session's visible message history into owned RequestMessages.
    /// Tool replays expand into a durable assistant tool_use + tool result pair;
    /// user image attachments are deep-cloned so the request owns its own copies.
    /// `copilot_target_idx`/`copilot_ctx` append a terminal snapshot to the last
    /// user message (copilot mode); pass null/null for a plain chat.
    fn buildRequestMessagesLocked(self: *Session, copilot_target_idx: ?usize, copilot_ctx: ?[]const u8) ![]RequestMessage {
        var visible_count: usize = 0;
        for (self.messages.items) |msg| {
            if (msg.role != .tool) {
                visible_count += 1;
            } else if (msg.replay_to_model) {
                const id = msg.tool_call_id orelse continue;
                const name = msg.tool_name orelse continue;
                if (id.len == 0 or name.len == 0) continue;
                visible_count += 2;
            }
        }

        const messages = try self.allocator.alloc(RequestMessage, visible_count);
        errdefer self.allocator.free(messages);

        var written: usize = 0;
        errdefer {
            for (messages[0..written]) |msg| msg.deinit(self.allocator);
        }

        for (self.messages.items, 0..) |msg, idx| {
            if (msg.role == .tool) {
                if (!msg.replay_to_model) continue;
                const id = msg.tool_call_id orelse continue;
                const name = msg.tool_name orelse continue;
                if (id.len == 0 or name.len == 0) continue;

                messages[written] = try ai_chat_request.durableToolAssistantRequestMessage(self.allocator, id, name);
                written += 1;
                messages[written] = try ai_chat_request.requestMessageWithClonedFields(self.allocator, .tool, msg.content, null, id, null, null);
                written += 1;
                continue;
            }

            const append_copilot_ctx = copilot_target_idx != null and idx == copilot_target_idx.? and copilot_ctx != null;
            const model_ctx = msg.model_context;
            var request_content: []const u8 = msg.content;
            var combined_owned: ?[]u8 = null;
            defer if (combined_owned) |combined| self.allocator.free(combined);

            if (model_ctx != null and append_copilot_ctx) {
                combined_owned = try std.fmt.allocPrint(self.allocator, "{s}\n\n{s}\n\n{s}", .{ msg.content, model_ctx.?, copilot_ctx.? });
                request_content = combined_owned.?;
            } else if (model_ctx != null) {
                combined_owned = try std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ msg.content, model_ctx.? });
                request_content = combined_owned.?;
            } else if (append_copilot_ctx) {
                combined_owned = try std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ msg.content, copilot_ctx.? });
                request_content = combined_owned.?;
            }

            messages[written] = try ai_chat_request.requestMessageWithClonedFields(self.allocator, msg.role, request_content, msg.reasoning, null, null, msg.images);
            written += 1;
        }

        return messages;
    }

    fn allocDistillTurnsLocked(self: *Session) ![]ai_skill_distill.DistillTurn {
        const turns = try self.allocator.alloc(ai_skill_distill.DistillTurn, self.messages.items.len);
        for (self.messages.items, 0..) |msg, idx| {
            turns[idx] = .{
                .role = switch (msg.role) {
                    .user => .user,
                    .assistant => .assistant,
                    .tool => .tool,
                },
                .content = msg.content,
                .replay_to_model = msg.replay_to_model,
            };
        }
        return turns;
    }

    fn buildDistillRequestLocked(self: *Session, topic: []const u8) !*ChatRequest {
        const turns = try self.allocDistillTurnsLocked();
        defer self.allocator.free(turns);

        const prompt = try ai_skill_distill.buildDistillUserPrompt(self.allocator, topic, turns);
        defer self.allocator.free(prompt);

        const messages = try self.allocator.alloc(RequestMessage, 1);
        var message_initialized = false;
        errdefer {
            if (message_initialized) messages[0].deinit(self.allocator);
            self.allocator.free(messages);
        }
        messages[0] = try ai_chat_request.requestMessageWithClonedFields(self.allocator, .user, prompt, null, null, null, null);
        message_initialized = true;

        const base_url = try self.allocator.dupe(u8, self.baseUrl());
        errdefer self.allocator.free(base_url);
        const api_key = try self.allocator.dupe(u8, self.apiKey());
        errdefer self.allocator.free(api_key);
        const model_name = try self.allocator.dupe(u8, self.model());
        errdefer self.allocator.free(model_name);
        const system_prompt = try self.allocator.dupe(u8, ai_skill_distill.distiller_system_prompt);
        errdefer self.allocator.free(system_prompt);
        const reasoning_effort = try self.allocator.dupe(u8, self.reasoningEffort());
        errdefer self.allocator.free(reasoning_effort);

        const req = try self.allocator.create(ChatRequest);
        errdefer self.allocator.destroy(req);
        req.* = .{
            .allocator = self.allocator,
            .session = self,
            .base_url = base_url,
            .api_key = api_key,
            .model = model_name,
            .protocol = self.protocol,
            .system_prompt = system_prompt,
            .messages = messages,
            .thinking_enabled = self.thinking_enabled,
            .reasoning_effort = reasoning_effort,
            .stream = false,
            .max_tokens = self.max_tokens,
            .agent_enabled = false,
            .copilot = false,
            .tool_host = null,
            .tool_snapshot = null,
            .weixin_reply_context = null,
            .started_ms = std.time.milliTimestamp(),
        };
        message_initialized = false;
        return req;
    }

    fn maybeAppendDistillSuggestionLocked(self: *Session) void {
        // Gated by config `ai-distill-suggest` (off by default): when disabled the
        // Copilot never auto-appends the "distill this into a skill?" prompt.
        if (!currentAgentSettings().distill_suggest_enabled) return;
        const turns = self.allocDistillTurnsLocked() catch return;
        defer self.allocator.free(turns);
        const should = ai_skill_distill.shouldSuggest(.{
            .turns = turns,
            .pending_candidate = self.distill_candidate != null,
            .suggestion_pending = self.distill_suggestion_pending,
            .last_suggested_turn_count = self.distill_last_suggested_turn_count,
        });
        if (!should) return;
        self.appendLocalToolMessageLocked(
            "This task looks reusable. Distill it into a skill?\nPress Enter to preview /distill, or Esc to ignore.",
        ) catch return;
        self.distill_suggestion_pending = true;
        self.distill_last_suggested_turn_count = turns.len;
    }

    fn buildRequestLocked(self: *Session) !*ChatRequest {
        const req = try self.allocator.create(ChatRequest);
        errdefer self.allocator.destroy(req);

        const settings = currentAgentSettings();
        const agent_enabled = self.agent_enabled or settings.enabled;
        const tool_host = if (agent_enabled) currentToolHost() else null;
        var tool_snapshot: ?ToolSnapshot = null;
        errdefer if (tool_snapshot) |snapshot| snapshot.deinit(self.allocator);
        if (tool_host) |host| {
            // The tab model is thread-local to the UI thread. Capture the agent
            // view before spawning the request worker so tools do not read an
            // empty thread-local copy from the background thread.
            tool_snapshot = host.collectSnapshot(host.ctx, self.allocator) catch null;
        }

        var weixin_ctx: ?WeixinReplyContext = null;
        errdefer if (weixin_ctx) |*ctx| ctx.deinit(self.allocator);
        if (self.pending_weixin_reply_context) |ctx| {
            weixin_ctx = try ctx.clone(self.allocator);
            self.clearPendingWeixinReplyContextLocked();
        }

        // Each copilot user message carries a lightweight snapshot of the bound
        // terminal (cwd + recent output). Append it to the latest user message
        // rather than emitting a separate trailing message, which would break the
        // role-alternation requirement of the Anthropic protocol.
        var copilot_ctx: ?[]u8 = null;
        defer if (copilot_ctx) |c| self.allocator.free(c);
        var copilot_target_idx: ?usize = null;
        if (self.copilot and self.bound_surface_id_len > 0) {
            if (tool_snapshot) |snap| {
                if (ai_chat_tools.findSurface(snap, self.boundSurfaceId())) |surface| {
                    copilot_ctx = ai_chat_tools.buildCopilotContext(self.allocator, surface.cwd, surface.snapshot) catch null;
                    if (copilot_ctx != null) {
                        // index of the LAST user message in self.messages
                        var k: usize = self.messages.items.len;
                        while (k > 0) {
                            k -= 1;
                            if (self.messages.items[k].role == .user) {
                                copilot_target_idx = k;
                                break;
                            }
                        }
                    }
                }
            }
        }

        const messages = try self.buildRequestMessagesLocked(copilot_target_idx, copilot_ctx);
        errdefer {
            for (messages) |msg| msg.deinit(self.allocator);
            self.allocator.free(messages);
        }

        const base_url = try self.allocator.dupe(u8, self.baseUrl());
        var base_url_owned = true;
        errdefer if (base_url_owned) self.allocator.free(base_url);
        const api_key = try self.allocator.dupe(u8, self.apiKey());
        var api_key_owned = true;
        errdefer if (api_key_owned) self.allocator.free(api_key);
        const model_name = try self.allocator.dupe(u8, self.model());
        var model_owned = true;
        errdefer if (model_owned) self.allocator.free(model_name);
        const working_dir = self.effectiveWorkingDirLocked() orelse "";
        const system_prompt = try composeSystemPromptWithMemory(self.allocator, self.systemPrompt(), settings.memory_enabled, working_dir);
        var system_prompt_owned = true;
        errdefer if (system_prompt_owned) self.allocator.free(system_prompt);
        const reasoning_effort = try self.allocator.dupe(u8, self.reasoningEffort());
        var reasoning_effort_owned = true;
        errdefer if (reasoning_effort_owned) self.allocator.free(reasoning_effort);

        var subagent_profile = resolveSubagentProfileForRequest(self.allocator, agent_enabled);
        errdefer if (subagent_profile) |profile| profile.deinit(self.allocator);
        const dynamic_tools = try cloneDynamicToolSpecs(self.allocator, settings.dynamic_tools);
        var dynamic_tools_owned = true;
        errdefer if (dynamic_tools_owned) freeOwnedDynamicToolSpecs(self.allocator, dynamic_tools);
        const dynamic_binary_tools = try cloneDynamicBinaryTools(self.allocator, settings.dynamic_binary_tools);
        var dynamic_binary_tools_owned = true;
        errdefer if (dynamic_binary_tools_owned) freeOwnedDynamicBinaryTools(self.allocator, dynamic_binary_tools);

        req.* = .{
            .allocator = self.allocator,
            .session = self,
            .base_url = base_url,
            .api_key = api_key,
            .model = model_name,
            .protocol = self.protocol,
            .system_prompt = system_prompt,
            .messages = messages,
            .thinking_enabled = self.thinking_enabled,
            .reasoning_effort = reasoning_effort,
            .stream = self.stream and !agent_enabled and self.protocol != .anthropic,
            .max_tokens = self.max_tokens,
            .agent_enabled = agent_enabled,
            .memory_enabled = settings.memory_enabled,
            .dynamic_tools = dynamic_tools,
            .dynamic_binary_tools = dynamic_binary_tools,
            .copilot = self.copilot,
            .tool_host = tool_host,
            .tool_snapshot = tool_snapshot,
            .weixin_reply_context = weixin_ctx,
            .started_ms = std.time.milliTimestamp(),
            .subagent_profile = subagent_profile,
        };
        base_url_owned = false;
        api_key_owned = false;
        model_owned = false;
        system_prompt_owned = false;
        reasoning_effort_owned = false;
        weixin_ctx = null;
        subagent_profile = null;
        dynamic_tools_owned = false;
        dynamic_binary_tools_owned = false;
        if (self.copilot and self.bound_surface_id_len > 0) {
            // Inline the write-context seed directly on ChatRequest (the field
            // layout is identical to ToolContext; setWriteContext in
            // ai_chat_tools operates on ToolContext).
            const bound_id = self.boundSurfaceId();
            const len = @min(bound_id.len, req.write_context_surface_id.len);
            @memcpy(req.write_context_surface_id[0..len], bound_id[0..len]);
            req.write_context_surface_id_len = len;
        }
        return req;
    }

    fn toHistoryRecordLocked(self: *Session, allocator: std.mem.Allocator) !agent_history.SessionRecord {
        var persist_count: usize = 0;
        for (self.messages.items) |msg| {
            if (msg.persist_to_history) persist_count += 1;
        }

        const messages = try allocator.alloc(agent_history.MessageRecord, persist_count);
        var initialized: usize = 0;
        errdefer {
            while (initialized > 0) {
                initialized -= 1;
                agent_history.freeOwnedMessage(allocator, &messages[initialized]);
            }
            allocator.free(messages);
        }

        for (self.messages.items) |msg| {
            if (!msg.persist_to_history) continue;

            var record_msg = agent_history.MessageRecord{
                .role = switch (msg.role) {
                    .user => .user,
                    .assistant => .assistant,
                    .tool => .tool,
                },
                .content = try allocator.dupe(u8, msg.content),
            };
            errdefer agent_history.freeOwnedMessage(allocator, &record_msg);

            record_msg.reasoning = if (msg.reasoning) |reasoning| try allocator.dupe(u8, reasoning) else null;
            record_msg.usage_footer = if (msg.usage_footer) |footer| try allocator.dupe(u8, footer) else null;
            record_msg.tool_call_id = if (msg.tool_call_id) |id| try allocator.dupe(u8, id) else null;
            record_msg.tool_name = if (msg.tool_name) |name| try allocator.dupe(u8, name) else null;
            record_msg.replay_to_model = msg.replay_to_model;

            messages[initialized] = record_msg;
            initialized += 1;
        }

        const session_id = try allocator.dupe(u8, self.sessionId());
        errdefer allocator.free(session_id);
        const session_title = try allocator.dupe(u8, self.title());
        errdefer allocator.free(session_title);
        const base_url = try allocator.dupe(u8, self.baseUrl());
        errdefer allocator.free(base_url);
        const api_key = try allocator.dupe(u8, self.apiKey());
        errdefer allocator.free(api_key);
        const model_name = try allocator.dupe(u8, self.model());
        errdefer allocator.free(model_name);
        const protocol = try allocator.dupe(u8, self.apiProtocolName());
        errdefer allocator.free(protocol);
        const system_prompt = try allocator.dupe(u8, self.systemPrompt());
        errdefer allocator.free(system_prompt);
        const reasoning_effort = try allocator.dupe(u8, self.reasoningEffort());
        errdefer allocator.free(reasoning_effort);

        return .{
            .session_id = session_id,
            .title = session_title,
            .base_url = base_url,
            .api_key = api_key,
            .model = model_name,
            .protocol = protocol,
            .system_prompt = system_prompt,
            .thinking_enabled = self.thinking_enabled,
            .reasoning_effort = reasoning_effort,
            .stream = self.stream,
            .max_tokens = self.max_tokens,
            .agent_enabled = self.agent_enabled,
            .vision_enabled = self.vision_enabled,
            .copilot = self.copilot,
            .created_at = self.created_at_ms,
            .updated_at = self.updated_at_ms,
            .messages = messages,
        };
    }

    fn captureHistoryChangeLocked(self: *Session) ?PendingHistoryChange {
        self.updated_at_ms = std.time.milliTimestamp();
        const hook = self.history_on_change orelse return null;
        const record = self.toHistoryRecordLocked(self.allocator) catch return null;
        return .{
            .hook = hook,
            .event = .{
                .allocator = self.allocator,
                .record = record,
            },
        };
    }

    fn notifyHistoryChange(_: *Session, change: ?PendingHistoryChange) void {
        if (change) |pending| pending.hook(pending.event);
    }

    fn assignSessionId(self: *Session) void {
        const counter = g_session_id_counter.fetchAdd(1, .monotonic);
        const text = std.fmt.bufPrint(&self.session_id_buf, "session-{d}-{d}", .{ std.time.milliTimestamp(), counter }) catch {
            self.copySessionId("session");
            return;
        };
        self.session_id_len = text.len;
    }

    fn copySessionId(self: *Session, value: []const u8) void {
        self.session_id_len = @min(value.len, self.session_id_buf.len);
        @memcpy(self.session_id_buf[0..self.session_id_len], value[0..self.session_id_len]);
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

    fn copyReasoningEffort(self: *Session, value: []const u8) void {
        self.reasoning_effort_len = @min(value.len, self.reasoning_effort_buf.len);
        @memcpy(self.reasoning_effort_buf[0..self.reasoning_effort_len], value[0..self.reasoning_effort_len]);
    }

    fn setStatus(self: *Session, value: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.setStatusLocked(value);
    }

    fn setCompletionStatusLocked(self: *Session, started_ms: i64, usage: ?ApiUsage) void {
        if (started_ms <= 0 and usage == null) {
            self.setStatusLocked("Ready");
            return;
        }

        var buf: [32]u8 = undefined;
        const elapsed_ms: i64 = if (started_ms > 0) @max(@as(i64, 0), std.time.milliTimestamp() - started_ms) else 0;
        const secs: i64 = @divTrunc(elapsed_ms, 1000);
        const tenths: i64 = @divTrunc(@mod(elapsed_ms, 1000), 100);
        const text = if (started_ms > 0)
            std.fmt.bufPrint(&buf, "Done in {d}.{d}s", .{ secs, tenths }) catch "Ready"
        else
            "Done";
        self.setStatusLocked(text);
    }

    fn setStatusLocked(self: *Session, value: []const u8) void {
        self.status_len = @min(value.len, self.status_buf.len);
        @memcpy(self.status_buf[0..self.status_len], value[0..self.status_len]);
    }
};

/// Returns base prompt, or base + memory index block when memory is enabled.
/// Best-effort: any memory error degrades to just the base prompt. Caller owns.
fn composeSystemPromptWithMemory(
    allocator: std.mem.Allocator,
    base: []const u8,
    memory_enabled: bool,
    working_dir: []const u8,
) ![]u8 {
    if (!memory_enabled) return allocator.dupe(u8, base);
    const block = agent_memory.buildInjectionBlock(allocator, working_dir) catch return allocator.dupe(u8, base);
    defer allocator.free(block);
    if (block.len == 0) return allocator.dupe(u8, base);
    return std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ base, block });
}

fn allocUsageFooter(allocator: std.mem.Allocator, started_ms: i64, usage: ?ApiUsage) !?[]u8 {
    const u = usage orelse return null;
    var buf: [160]u8 = undefined;
    const text = if (started_ms > 0) blk: {
        const elapsed_ms: i64 = @max(@as(i64, 0), std.time.milliTimestamp() - started_ms);
        const secs: i64 = @divTrunc(elapsed_ms, 1000);
        const tenths: i64 = @divTrunc(@mod(elapsed_ms, 1000), 100);
        break :blk std.fmt.bufPrint(
            &buf,
            "time {d}.{d}s | total {d} | input {d} | output {d} | cache {d}/{d}",
            .{ secs, tenths, u.total_tokens, u.prompt_tokens, u.completion_tokens, u.prompt_cache_hit_tokens, u.prompt_cache_miss_tokens },
        ) catch "usage unavailable";
    } else std.fmt.bufPrint(
        &buf,
        "total {d} | input {d} | output {d} | cache {d}/{d}",
        .{ u.total_tokens, u.prompt_tokens, u.completion_tokens, u.prompt_cache_hit_tokens, u.prompt_cache_miss_tokens },
    ) catch "usage unavailable";
    return try allocator.dupe(u8, text);
}

const VisualCursor = ai_chat_input_text.VisualCursor;
const clampUtf8Boundary = ai_chat_input_text.clampUtf8Boundary;
const previousUtf8Boundary = ai_chat_input_text.previousUtf8Boundary;
const nextUtf8Boundary = ai_chat_input_text.nextUtf8Boundary;
const visualCursorPosition = ai_chat_input_text.visualCursorPosition;
const visualRowAt = ai_chat_input_text.visualRowAt;
const byteOffsetForVisualPosition = ai_chat_input_text.byteOffsetForVisualPosition;
pub const inputWrappedLineCount = ai_chat_input_text.inputWrappedLineCount;

// Markdown export helpers — defined in ai_chat_markdown.zig (pure leaf, no Session).
const appendClipboardSection = ai_chat_markdown.appendClipboardSection;
const appendMarkdownDocumentHeader = ai_chat_markdown.appendMarkdownDocumentHeader;
const appendMarkdownSection = ai_chat_markdown.appendMarkdownSection;
const appendMarkdownCodeSection = ai_chat_markdown.appendMarkdownCodeSection;
const appendMarkdownBody = ai_chat_markdown.appendMarkdownBody;

fn latestAssistantContent(messages: []const Message) ?[]const u8 {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        const msg = messages[i];
        if (msg.role == .assistant and msg.content.len > 0) return msg.content;
    }
    return null;
}

fn appendLimitedSection(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    label: []const u8,
    text: []const u8,
    max_bytes: usize,
) !void {
    if (out.items.len >= max_bytes) return;
    if (out.items.len > 0) try out.appendSlice(allocator, "\r\n\r\n");
    try out.appendSlice(allocator, label);
    try out.appendSlice(allocator, ":\r\n");
    if (out.items.len >= max_bytes) return;

    const remaining = max_bytes - out.items.len;
    const take = @min(text.len, remaining);
    try out.appendSlice(allocator, text[0..take]);
    if (take < text.len and out.items.len + 18 <= max_bytes) {
        try out.appendSlice(allocator, "\r\n...[truncated]");
    }
}

const RemoteSnapshotSection = struct {
    label: []const u8,
    text: []const u8,
    /// High-priority sections (message bodies) are budgeted before low-priority
    /// auxiliary sections (reasoning, usage), so bulky reasoning can never push
    /// the latest answer out of the snapshot.
    priority: bool = true,
};

/// Appends the most recent sections that fit in `max_bytes`, in two priority
/// passes. Pass one reserves budget for message bodies newest-first, always
/// keeping the newest body (truncated if it alone overflows). Pass two fills any
/// remaining budget with auxiliary sections (reasoning/usage), also newest-first.
/// Sections are emitted in their original order. This guarantees the latest
/// assistant answer survives even when an earlier-walked reasoning block is huge.
fn appendRecentLimitedSections(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    sections: []const RemoteSnapshotSection,
    max_bytes: usize,
) !void {
    if (sections.len == 0 or out.items.len >= max_bytes) return;

    const included = try allocator.alloc(bool, sections.len);
    defer allocator.free(included);
    @memset(included, false);

    // Model + Status are always emitted first, so every section here pays the
    // 4-byte separator; the per-section cost is therefore position-independent.
    var used = out.items.len;

    // Pass 1: message bodies, newest-first. Always include the newest body so
    // the reply detector and the user can always see the latest answer; if it
    // alone overflows, appendLimitedSection truncates it.
    var newest_body_seen = false;
    var i = sections.len;
    while (i > 0) : (i -= 1) {
        const section = sections[i - 1];
        if (!section.priority) continue;
        const cost = remoteSnapshotSectionCost(section.label, section.text);
        if (!newest_body_seen) {
            included[i - 1] = true;
            used = @min(used + cost, max_bytes);
            newest_body_seen = true;
        } else if (used + cost <= max_bytes) {
            included[i - 1] = true;
            used += cost;
        }
    }

    // Pass 2: auxiliary sections (reasoning/usage), newest-first, best effort.
    i = sections.len;
    while (i > 0) : (i -= 1) {
        const section = sections[i - 1];
        if (section.priority) continue;
        const cost = remoteSnapshotSectionCost(section.label, section.text);
        if (used + cost <= max_bytes) {
            included[i - 1] = true;
            used += cost;
        }
    }

    for (sections, 0..) |section, idx| {
        if (included[idx]) try appendLimitedSection(allocator, out, section.label, section.text, max_bytes);
    }
}

fn remoteSnapshotSectionCost(label: []const u8, text: []const u8) usize {
    return "\r\n\r\n".len + label.len + ":\r\n".len + text.len;
}

fn allocRemoteToolSummary(allocator: std.mem.Allocator, msg: Message) ![]u8 {
    if (msg.tool_name) |name| {
        if (name.len > 0) {
            return std.fmt.allocPrint(allocator, "{s} completed. Output omitted in remote chat.", .{name});
        }
    }

    const trimmed = std.mem.trim(u8, msg.content, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 160) {
        return allocator.dupe(u8, "Tool activity. Output omitted in remote chat.");
    }
    return allocator.dupe(u8, trimmed);
}

// requestThreadMain has moved to ai_chat_request.zig.

pub fn requestCancelled(request: *const ChatRequest) bool {
    return request.session.closing.load(.acquire) or request.session.stop_requested.load(.acquire);
}

pub fn sessionCancelled(session: *Session) bool {
    return session.closing.load(.acquire) or session.stop_requested.load(.acquire);
}

pub fn finishStoppedRequest(session: *Session) void {
    if (session.closing.load(.acquire)) return;
    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.closing.load(.acquire)) return;
    session.request_inflight = false;
    session.distill_inflight = false;
    session.request_stopping = false;
    session.stop_requested.store(false, .release);
    session.collapseAutoExpandedDetailsLocked();
    session.setStatusLocked("Stopped");
}

/// Clean a raw model title response and apply it to the session, but only if the
/// title is still the default (a manual rename in the meantime always wins) and
/// the session is not closing.
pub fn applyGeneratedTitle(session: *Session, raw: []const u8) void {
    if (session.closing.load(.acquire)) return;
    var buf: [ai_chat_title.max_title_bytes]u8 = undefined;
    const cleaned = ai_chat_title.cleanTitle(raw, &buf) orelse return;
    _ = session.setTitleIfDefault(cleaned);
}

/// Swap the live session to a different provider/model (session-only; does not
/// touch the global default). Then, if there is prior conversation, kick off a
/// background summary against the NEW model. The session's system prompt /
/// persona is intentionally left unchanged.
pub fn applyProviderProfile(
    session: *Session,
    base_url: []const u8,
    api_key: []const u8,
    model_name: []const u8,
    protocol_str: []const u8,
    thinking_str: []const u8,
    reasoning_effort: []const u8,
    max_tokens: u32,
    vision_str: []const u8,
) void {
    // Join any prior summary worker before starting a new switch, so its thread
    // handle isn't lost (it would otherwise leak and could race deinit / UAF the
    // session). Taken out under the lock, joined OUTSIDE it to avoid deadlocking
    // against the worker's own applySummaryResult (which locks the same mutex).
    session.mutex.lock();
    const prior_summary = session.summary_thread;
    session.summary_thread = null;
    session.mutex.unlock();
    if (prior_summary) |t| t.join();

    var sreq: ?*SummaryRequest = null;
    session.mutex.lock();
    locked: {
        // Capture the OLD model name BEFORE swapping, for the summary card marker.
        var old_model_buf: [128]u8 = undefined;
        const old_model_len = @min(session.model().len, old_model_buf.len);
        @memcpy(old_model_buf[0..old_model_len], session.model()[0..old_model_len]);
        const old_model = old_model_buf[0..old_model_len];

        session.copyBaseUrl(base_url);
        session.copyApiKey(api_key);
        session.copyModel(model_name);
        session.protocol = ApiProtocol.parse(protocol_str);
        session.thinking_enabled = !std.mem.eql(u8, thinking_str, "disabled");
        session.copyReasoningEffort(reasoning_effort);
        session.max_tokens = max_tokens;
        session.vision_enabled = std.mem.eql(u8, vision_str, "on") or std.mem.eql(u8, vision_str, "enabled") or std.mem.eql(u8, vision_str, "true");

        // Build the summary snapshot from the messages that exist now.
        const boundary = session.messages.items.len;
        const turns = session.allocator.alloc(ai_model_switch.TurnMessage, boundary) catch break :locked;
        defer session.allocator.free(turns);
        for (session.messages.items, 0..) |m, i| turns[i] = .{ .role = m.role, .content = m.content };
        if (!ai_model_switch.shouldSummarize(turns)) {
            session.setStatusLocked("Model switched");
            break :locked;
        }
        sreq = buildSummaryRequestLocked(session, turns, boundary, old_model) catch break :locked;
        session.setStatusLocked("Summarizing previous context…");
    }
    session.mutex.unlock();

    const req = sreq orelse return;
    const thread = std.Thread.spawn(.{}, ai_chat_request.summaryThreadMain, .{req}) catch {
        req.deinit();
        session.mutex.lock();
        session.setStatusLocked("Ready");
        session.mutex.unlock();
        return;
    };
    session.mutex.lock();
    session.summary_thread = thread;
    session.mutex.unlock();
}

fn buildSummaryRequestLocked(session: *Session, turns: []const ai_model_switch.TurnMessage, boundary: usize, from_model: []const u8) !*SummaryRequest {
    const allocator = session.allocator;
    const req = try allocator.create(ChatRequest);
    errdefer allocator.destroy(req);

    const base_url = try allocator.dupe(u8, session.baseUrl());
    errdefer allocator.free(base_url);
    const api_key = try allocator.dupe(u8, session.apiKey());
    errdefer allocator.free(api_key);
    const model = try allocator.dupe(u8, session.model());
    errdefer allocator.free(model);
    const system_prompt = try allocator.dupe(u8, ai_model_switch.system_prompt);
    errdefer allocator.free(system_prompt);
    const reasoning_effort = try allocator.dupe(u8, "low");
    errdefer allocator.free(reasoning_effort);

    const user_content = try ai_model_switch.buildSummaryUserContent(allocator, turns);
    errdefer allocator.free(user_content);

    const messages = try allocator.alloc(RequestMessage, 1);
    errdefer allocator.free(messages);
    messages[0] = .{ .role = .user, .content = user_content };

    req.* = .{
        .allocator = allocator,
        .session = session,
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
        .protocol = session.protocol,
        .system_prompt = system_prompt,
        .messages = messages,
        .thinking_enabled = false,
        .reasoning_effort = reasoning_effort,
        .stream = false,
        .max_tokens = 1024,
        .agent_enabled = false,
        .copilot = false,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
    };

    const sreq = try allocator.create(SummaryRequest);
    sreq.* = .{ .allocator = allocator, .req = req, .boundary = boundary };
    sreq.setFromModel(from_model);
    return sreq;
}

/// Apply a completed summary: replace messages[0..boundary] with one collapsible
/// "上文摘要" card (role .user, is_context_summary), preserving messages[boundary..].
/// Runs under the mutex; safe even if a request is in flight because each request
/// snapshots its messages under the mutex at start.
pub fn applySummaryResult(session: *Session, summary: []const u8, boundary: usize, from_model: []const u8) void {
    if (session.closing.load(.acquire)) return;
    const allocator = session.allocator;
    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
    if (session.closing.load(.acquire)) return;
    if (boundary > session.messages.items.len) {
        session.setStatusLocked("Ready");
        return; // stale (e.g. /clear happened) — keep raw history
    }
    const content = ai_model_switch.composeCardContent(allocator, from_model, summary) catch {
        session.setStatusLocked("Ready");
        return;
    };
    var new_list: std.ArrayListUnmanaged(Message) = .empty;
    new_list.append(allocator, .{
        .role = .user,
        .content = content,
        .is_context_summary = true,
        .content_collapsed = true,
        .persist_to_history = true,
    }) catch {
        allocator.free(content);
        session.setStatusLocked("Ready");
        return;
    };
    new_list.appendSlice(allocator, session.messages.items[boundary..]) catch {
        // OOM: free the summary we just made, keep raw history intact.
        new_list.items[0].deinit(allocator);
        new_list.deinit(allocator);
        session.setStatusLocked("Ready");
        return;
    };
    // Free only the collapsed pre-switch messages; tail structs were copied by
    // value into new_list (pointer ownership moved).
    for (session.messages.items[0..boundary]) |m| m.deinit(allocator);
    session.messages.deinit(allocator);
    session.messages = new_list;
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Context summarized");
    history_change = session.captureHistoryChangeLocked();
}

/// Summary request failed (e.g. the new model is also overloaded): keep the full
/// raw history, just clear the in-progress status.
pub fn failSummaryResult(session: *Session) void {
    if (session.closing.load(.acquire)) return;
    session.mutex.lock();
    defer session.mutex.unlock();
    session.setStatusLocked("Summary unavailable — kept full history");
}

/// Build a standalone, tool-free, non-streaming ChatRequest for title
/// generation, reusing the session's endpoint/key/model/protocol. Must be
/// called with `session.mutex` held (reads session config + first turn).
/// Caller owns the returned request and must `req.deinit()` it.
fn buildTitleRequestLocked(session: *Session, turn: ai_chat_title.FirstTurn) !*ChatRequest {
    const allocator = session.allocator;
    const req = try allocator.create(ChatRequest);
    errdefer allocator.destroy(req);

    const base_url = try allocator.dupe(u8, session.baseUrl());
    errdefer allocator.free(base_url);
    const api_key = try allocator.dupe(u8, session.apiKey());
    errdefer allocator.free(api_key);
    const model = try allocator.dupe(u8, session.model());
    errdefer allocator.free(model);
    const system_prompt = try allocator.dupe(u8, ai_chat_title.system_prompt);
    errdefer allocator.free(system_prompt);
    const reasoning_effort = try allocator.dupe(u8, "low");
    errdefer allocator.free(reasoning_effort);

    const user_content = try ai_chat_title.buildUserContent(allocator, turn);
    errdefer allocator.free(user_content);

    const messages = try allocator.alloc(RequestMessage, 1);
    errdefer allocator.free(messages);
    // ownership of user_content moves into messages[0]; freed by req.deinit()
    messages[0] = .{ .role = .user, .content = user_content };

    req.* = .{
        .allocator = allocator,
        .session = session,
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
        .protocol = session.protocol,
        .system_prompt = system_prompt,
        .messages = messages,
        .thinking_enabled = false,
        .reasoning_effort = reasoning_effort,
        .stream = false,
        .max_tokens = 64,
        .agent_enabled = false,
        .copilot = false,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
    };
    return req;
}

// titleThreadMain has moved to ai_chat_request.zig.

/// After a completed turn, generate a title in the background if the gate
/// passes. Called from the request worker (`requestThreadMain`) with no lock
/// held. The worker thread that calls this is `session.request_thread`, which
/// `deinit` joins before it joins `title_thread`, so storing the handle here
/// races neither deinit nor the title worker.
pub fn maybeAutoTitle(session: *Session) void {
    if (session.closing.load(.acquire)) return;
    const allocator = session.allocator;

    session.mutex.lock();
    var spawned_req: ?*ChatRequest = null;
    locked: {
        const turns = allocator.alloc(ai_chat_title.TurnMessage, session.messages.items.len) catch break :locked;
        defer allocator.free(turns);
        for (session.messages.items, 0..) |m, i| {
            turns[i] = .{ .role = m.role, .content = m.content };
        }
        const turn = ai_chat_title.extractFirstTurn(turns);
        const gate = ai_chat_title.TitleGate{
            .attempted = session.auto_title_attempted,
            .has_api_key = session.api_key_len > 0,
            .title = session.title_buf[0..session.title_len],
            .default_name = DEFAULT_NAME,
        };
        if (!ai_chat_title.shouldAutoTitle(gate, turn)) break :locked;

        const req = buildTitleRequestLocked(session, turn.?) catch break :locked;
        session.auto_title_attempted = true;
        spawned_req = req;
    }
    session.mutex.unlock();

    const req = spawned_req orelse return;
    const thread = std.Thread.spawn(.{}, ai_chat_request.titleThreadMain, .{req}) catch {
        req.deinit();
        return;
    };
    session.mutex.lock();
    session.title_thread = thread;
    session.mutex.unlock();
}

// runAgentRequest, cloneRequestMessage, cloneToolCalls, assistantToolCallMessage,
// requestMessageWithClonedFields, durableToolAssistantRequestMessage have moved
// to ai_chat_request.zig.

pub fn appendAssistantResult(session: *Session, result: ApiResult, started_ms: i64) void {
    const allocator = session.allocator;
    if (session.closing.load(.acquire)) return;
    if (session.stop_requested.load(.acquire)) {
        finishStoppedRequest(session);
        return;
    }

    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
    if (session.closing.load(.acquire)) return;
    if (session.stop_requested.load(.acquire)) {
        session.request_inflight = false;
        session.request_stopping = false;
        session.stop_requested.store(false, .release);
        session.setStatusLocked("Stopped");
        return;
    }

    const content = allocator.dupe(u8, result.content) catch {
        session.request_inflight = false;
        session.collapseAutoExpandedDetailsLocked();
        session.setStatusLocked("Out of memory");
        return;
    };
    var usage_footer = allocUsageFooter(allocator, started_ms, result.usage) catch null;
    var reasoning_copy: ?[]u8 = null;
    if (result.reasoning) |reasoning| {
        reasoning_copy = allocator.dupe(u8, reasoning) catch null;
    }
    const reasoning_visible = if (reasoning_copy) |r| r.len > 0 else false;
    session.messages.append(allocator, .{
        .role = .assistant,
        .content = content,
        .reasoning = reasoning_copy,
        .usage_footer = usage_footer,
        .reasoning_collapsed = reasoning_visible,
        .reasoning_auto_expand = false,
    }) catch {
        allocator.free(content);
        if (reasoning_copy) |r| allocator.free(r);
        if (usage_footer) |footer| allocator.free(footer);
        session.request_inflight = false;
        session.collapseAutoExpandedDetailsLocked();
        session.setStatusLocked("Out of memory");
        return;
    };
    usage_footer = null;
    session.request_inflight = false;
    session.distill_inflight = false;
    session.collapseAutoExpandedDetailsLocked();
    session.scroll_px = 1_000_000;
    session.setCompletionStatusLocked(started_ms, result.usage);
    session.maybeAppendDistillSuggestionLocked();
    history_change = session.captureHistoryChangeLocked();
}

/// Append a `$websearch` result (or error text) as a local tool message and
/// finish the in-flight request. Called from the web-search worker thread with
/// no lock held. Mirrors the closing-guarded shape of `appendAssistantResult`.
pub fn appendWebSearchResult(session: *Session, text: []const u8) void {
    if (session.closing.load(.acquire)) return;
    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.closing.load(.acquire)) return;
    session.appendLocalToolMessageLocked(text) catch {
        session.request_inflight = false;
        session.setStatusLocked("Out of memory");
        return;
    };
    session.request_inflight = false;
    session.setStatusLocked("Ready");
}

pub fn applyDistillCandidate(session: *Session, candidate: *ai_skill_distill.Candidate) void {
    const allocator = session.allocator;
    const root = ai_chat_skills.defaultWritableSkillRootPath(allocator) catch |err| {
        candidate.deinit(allocator);
        failDistillRequest(session, err);
        return;
    };
    defer allocator.free(root);
    const save_path = std.fs.path.join(allocator, &.{ root, candidate.name, "SKILL.md" }) catch |err| {
        candidate.deinit(allocator);
        failDistillRequest(session, err);
        return;
    };
    defer allocator.free(save_path);
    const preview = ai_skill_distill.renderPreviewMarkdown(allocator, candidate.*, save_path) catch |err| {
        candidate.deinit(allocator);
        failDistillRequest(session, err);
        return;
    };
    defer allocator.free(preview);

    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.closing.load(.acquire) or session.stop_requested.load(.acquire)) {
        candidate.deinit(allocator);
        session.request_inflight = false;
        session.request_stopping = false;
        session.distill_inflight = false;
        session.stop_requested.store(false, .release);
        session.setStatusLocked("Stopped");
        return;
    }

    session.clearDistillCandidateLocked();
    session.distill_candidate = candidate.*;
    candidate.* = undefined;
    session.distill_suggestion_pending = false;
    session.request_inflight = false;
    session.request_stopping = false;
    session.distill_inflight = false;
    session.appendLocalToolMessageLocked(preview) catch {
        session.clearDistillCandidateLocked();
        session.setStatusLocked("Out of memory");
        return;
    };
    session.setStatusLocked("Distill preview ready");
}

pub fn failDistillRequest(session: *Session, err: anyerror) void {
    const allocator = session.allocator;
    const text = std.fmt.allocPrint(allocator, "Could not distill this conversation: {}.", .{err}) catch null;
    defer if (text) |msg| allocator.free(msg);

    session.mutex.lock();
    defer session.mutex.unlock();
    session.request_inflight = false;
    session.request_stopping = false;
    session.distill_inflight = false;
    session.stop_requested.store(false, .release);
    session.clearDistillCandidateLocked();
    if (text) |msg| {
        session.appendLocalToolMessageLocked(msg) catch {
            session.setStatusLocked("Out of memory");
            return;
        };
    }
    session.setStatusLocked("Ready");
}

pub fn appendProgressMessage(session: *Session, text: []const u8) !void {
    if (sessionCancelled(session)) return error.Canceled;
    const allocator = session.allocator;
    const content = try allocator.dupe(u8, text);
    errdefer allocator.free(content);

    session.mutex.lock();
    defer session.mutex.unlock();
    if (sessionCancelled(session)) return error.Canceled;
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = content,
        .reasoning = null,
        .persist_to_history = false,
        .content_collapsed = false,
        .content_auto_expand = true,
    });
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Running tools...");
}

pub fn appendReplayableToolMessage(
    session: *Session,
    tool_call_id: []const u8,
    tool_name: []const u8,
    text: []const u8,
) !void {
    if (sessionCancelled(session)) return error.Canceled;
    const allocator = session.allocator;
    const content = try allocator.dupe(u8, text);
    var content_owned = true;
    errdefer if (content_owned) allocator.free(content);
    const id = try allocator.dupe(u8, tool_call_id);
    var id_owned = true;
    errdefer if (id_owned) allocator.free(id);
    const name = try allocator.dupe(u8, tool_name);
    var name_owned = true;
    errdefer if (name_owned) allocator.free(name);

    var msg = Message{
        .role = .tool,
        .content = content,
        .tool_call_id = id,
        .tool_name = name,
        .replay_to_model = true,
        .content_collapsed = true,
        .content_auto_expand = false,
    };
    content_owned = false;
    id_owned = false;
    name_owned = false;
    var msg_owned = true;
    errdefer if (msg_owned) msg.deinit(allocator);

    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
    if (sessionCancelled(session)) return error.Canceled;
    try session.messages.append(allocator, msg);
    msg_owned = false;
    history_change = session.captureHistoryChangeLocked();
}

pub fn beginAssistantStream(session: *Session) !usize {
    const allocator = session.allocator;
    if (sessionCancelled(session)) return error.Canceled;

    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
    if (sessionCancelled(session)) return error.Canceled;

    const content = try allocator.dupe(u8, "");
    errdefer allocator.free(content);
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = content,
        .reasoning = null,
        .reasoning_collapsed = false,
        .reasoning_auto_expand = true,
    });
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Streaming...");
    history_change = session.captureHistoryChangeLocked();
    return session.messages.items.len - 1;
}

fn appendAssistantStreamDelta(session: *Session, message_idx: usize, content_delta: []const u8, reasoning_delta: []const u8) !void {
    if (content_delta.len == 0 and reasoning_delta.len == 0) return;
    const allocator = session.allocator;
    if (sessionCancelled(session)) return;

    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
    if (sessionCancelled(session)) return;
    if (message_idx >= session.messages.items.len) return error.StreamMessageMissing;

    var msg = &session.messages.items[message_idx];
    if (content_delta.len > 0) {
        const old_len = msg.content.len;
        msg.content = try allocator.realloc(msg.content, old_len + content_delta.len);
        @memcpy(msg.content[old_len..], content_delta);
    }
    if (reasoning_delta.len > 0) {
        if (msg.reasoning) |old_reasoning| {
            const old_len = old_reasoning.len;
            const resized = try allocator.realloc(old_reasoning, old_len + reasoning_delta.len);
            @memcpy(resized[old_len..], reasoning_delta);
            msg.reasoning = resized;
        } else {
            msg.reasoning = try allocator.dupe(u8, reasoning_delta);
        }
    }
    session.scroll_px = 1_000_000;
    session.setStatusLocked("Streaming...");
    history_change = session.captureHistoryChangeLocked();
}

pub fn finishAssistantStream(session: *Session, message_idx: usize, started_ms: i64, usage: ?ApiUsage) void {
    if (session.closing.load(.acquire)) return;
    if (session.stop_requested.load(.acquire)) {
        finishStoppedRequest(session);
        return;
    }

    var history_change: ?PendingHistoryChange = null;
    session.mutex.lock();
    defer {
        session.mutex.unlock();
        session.notifyHistoryChange(history_change);
    }
    if (session.closing.load(.acquire)) return;
    if (session.stop_requested.load(.acquire)) {
        session.request_inflight = false;
        session.distill_inflight = false;
        session.request_stopping = false;
        session.stop_requested.store(false, .release);
        session.setStatusLocked("Stopped");
        return;
    }
    if (message_idx < session.messages.items.len) {
        const msg = &session.messages.items[message_idx];
        if (msg.content.len == 0 and msg.reasoning == null) {
            msg.content = session.allocator.realloc(msg.content, "No response".len) catch msg.content;
            if (msg.content.len == "No response".len) @memcpy(msg.content, "No response");
        }
        if (allocUsageFooter(session.allocator, started_ms, usage) catch null) |footer| {
            if (msg.usage_footer) |old_footer| session.allocator.free(old_footer);
            msg.usage_footer = footer;
        }
        history_change = session.captureHistoryChangeLocked();
    }
    session.request_inflight = false;
    session.distill_inflight = false;
    session.collapseAutoExpandedDetailsLocked();
    session.scroll_px = 1_000_000;
    session.setCompletionStatusLocked(started_ms, usage);
    session.maybeAppendDistillSuggestionLocked();
}

pub fn failAssistantStream(session: *Session, message_idx: ?usize, text: []const u8) void {
    if (session.stop_requested.load(.acquire)) {
        finishStoppedRequest(session);
        return;
    }
    if (message_idx) |idx| {
        appendAssistantStreamDelta(session, idx, text, "") catch {};
        finishAssistantStream(session, idx, 0, null);
        return;
    }

    appendAssistantResult(session, .{ .content = @constCast(text) }, 0);
}

// runChatRequest, runChatRequestForMessages, runChatRequestStreaming,
// buildRequestJson, buildRequestJsonForMessages, and the ToolContext seam
// adapters (toolApprove, toolCancelled, toolContextFromRequest, executeToolCall)
// have moved to ai_chat_request.zig.

// Protocol aliases still referenced internally (e.g. in tests).
const apiEndpoint = ai_chat_protocol.apiEndpoint;
const chatEndpoint = ai_chat_protocol.chatEndpoint;
const isDeepSeekBaseUrl = ai_chat_protocol.isDeepSeekBaseUrl;
const isAnthropicBaseUrl = ai_chat_protocol.isAnthropicBaseUrl;

// ---------------------------------------------------------------------------
// Local helpers for tests that remain in ai_chat.zig and use ChatRequest.
// ---------------------------------------------------------------------------

// setWriteContext: operates on ChatRequest directly (field layout identical to ToolContext).
fn setWriteContext(request: *ChatRequest, surface_id: []const u8) void {
    const len = @min(surface_id.len, request.write_context_surface_id.len);
    @memcpy(request.write_context_surface_id[0..len], surface_id[0..len]);
    request.write_context_surface_id_len = len;
}

// wslSessionExecTool: the "wsl_session_exec refuses..." test in ai_chat.zig
// constructs a ChatRequest + calls wslSessionExecTool directly.  Delegates to
// ai_chat_request.executeToolCall so the write-back is handled there.
fn wslSessionExecTool(request: *ChatRequest, surface_id: []const u8, command: []const u8, timeout_ms: u32) ![]u8 {
    _ = surface_id;
    const args_json = try std.fmt.allocPrint(
        request.allocator,
        "{{\"surface_id\":\"{s}\",\"command\":\"{s}\",\"timeout_ms\":{d}}}",
        .{ request.write_context_surface_id[0..request.write_context_surface_id_len], command, timeout_ms },
    );
    defer request.allocator.free(args_json);
    return ai_chat_request.executeToolCall(request, .{
        .id = @constCast(""),
        .name = @constCast("wsl_session_exec"),
        .arguments = args_json,
    });
}

// All tool implementations are in ai_chat_tools.zig.
// The block that was here (executeToolCall body, parseArgs, jsonStringArg, ... isWordChar)
// has been removed and lives in src/ai_chat_tools.zig instead.

// Response parsing delegates to ai_chat_protocol
const parseApiResponse = ai_chat_protocol.parseApiResponse;
const parseApiErrorResult = ai_chat_protocol.parseApiErrorResult;
const parseApiUsage = ai_chat_protocol.parseApiUsage;
const jsonStringValue = ai_chat_protocol.jsonStringValue;
pub fn applyApiStreamLineToSession(
    allocator: std.mem.Allocator,
    session: *Session,
    message_idx: usize,
    line_raw: []const u8,
    usage_out: *?ApiUsage,
) !bool {
    const line = std.mem.trim(u8, line_raw, " \t\r");
    if (!std.mem.startsWith(u8, line, "data:")) return false;

    const data = std.mem.trim(u8, line["data:".len..], " \t");
    if (data.len == 0) return false;
    if (std.mem.eql(u8, data, "[DONE]")) return true;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch return false;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return false;
    const obj = root.object;
    if (parseApiUsage(root)) |usage| usage_out.* = usage;

    if (try parseApiErrorResult(allocator, root)) |result| {
        defer result.deinit(allocator);
        try appendAssistantStreamDelta(session, message_idx, result.content, "");
        return true;
    }

    if (jsonStringValue(obj.get("type"))) |event_type| {
        if (std.mem.eql(u8, event_type, "response.output_text.delta")) {
            const content_delta = jsonStringValue(obj.get("delta")) orelse "";
            try appendAssistantStreamDelta(session, message_idx, content_delta, "");
            return false;
        }
        if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or
            std.mem.eql(u8, event_type, "response.reasoning_text.delta"))
        {
            const reasoning_delta = jsonStringValue(obj.get("delta")) orelse "";
            try appendAssistantStreamDelta(session, message_idx, "", reasoning_delta);
            return false;
        }
        if (std.mem.eql(u8, event_type, "response.completed")) {
            if (obj.get("response")) |response_value| {
                if (parseApiUsage(response_value)) |usage| usage_out.* = usage;
            }
            return true;
        }
        if (std.mem.eql(u8, event_type, "response.failed")) {
            if (obj.get("response")) |response_value| {
                if (try parseApiErrorResult(allocator, response_value)) |result| {
                    defer result.deinit(allocator);
                    try appendAssistantStreamDelta(session, message_idx, result.content, "");
                    return true;
                }
            }
            try appendAssistantStreamDelta(session, message_idx, "API returned an error", "");
            return true;
        }
    }

    if (obj.get("error")) |_| {
        try appendAssistantStreamDelta(session, message_idx, "API returned an error", "");
        return true;
    }

    const choices_value = obj.get("choices") orelse return false;
    if (choices_value != .array or choices_value.array.items.len == 0) return false;
    const choice = choices_value.array.items[0];
    if (choice != .object) return false;
    const delta_value = choice.object.get("delta") orelse return false;
    if (delta_value != .object) return false;

    const content_delta = if (delta_value.object.get("content")) |content_value|
        if (content_value == .string) content_value.string else ""
    else
        "";
    const reasoning_delta = if (delta_value.object.get("reasoning_content")) |reasoning_value|
        if (reasoning_value == .string) reasoning_value.string else ""
    else
        "";
    try appendAssistantStreamDelta(session, message_idx, content_delta, reasoning_delta);
    return false;
}

const TestHistoryHookCapture = struct {
    event: ?HistoryChangeEvent = null,
    calls: usize = 0,

    fn deinit(self: *TestHistoryHookCapture) void {
        if (self.event) |*event| {
            event.deinit();
            self.event = null;
        }
        self.calls = 0;
    }
};

var g_test_history_hook_capture: ?*TestHistoryHookCapture = null;

fn testHistoryHookCaptureCallback(event: HistoryChangeEvent) void {
    var owned = event;
    const capture = g_test_history_hook_capture orelse {
        owned.deinit();
        return;
    };
    if (capture.event) |*previous| {
        previous.deinit();
    }
    capture.event = owned;
    capture.calls += 1;
}

test "ai chat parses explicit dollar skill invocation" {
    const parsed = parseSkillInvocation("$pdf summarize this file").?;
    try std.testing.expectEqualStrings("pdf", parsed.skill_name);
    try std.testing.expectEqualStrings("summarize this file", parsed.prompt);

    try std.testing.expect(parseSkillInvocation("normal prompt") == null);
    try std.testing.expect(parseSkillInvocation("$ missing") == null);
}

test "ai chat avoids obvious dollar skill false positives" {
    try std.testing.expect(parseSkillInvocation("$100 budget") == null);
    try std.testing.expect(parseSkillInvocation("$PATH is broken") == null);
    try std.testing.expect(parseSkillInvocation("$env:PATH is broken") == null);
}

test "ai chat recognizes local slash commands" {
    try std.testing.expect(parseSlashCommand("/skills").? == .skills);
    try std.testing.expect(parseSlashCommand("/commands").? == .commands);
    try std.testing.expect(parseSlashCommand("/reload-skills").? == .reload_skills);
    try std.testing.expect(parseSlashCommand("/unknown").? == .unknown);
    try std.testing.expect(parseSlashCommand("hello") == null);
}

test "ai chat avoids slash command false positives" {
    try std.testing.expect(parseSlashCommand("/api") == null);
    try std.testing.expect(parseSlashCommand("/usr/bin") == null);
    try std.testing.expect(parseSlashCommand("/help me") == null);
}

test "ai chat slash command suggestions show and filter from input" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("/");

    // A bare "/" shows every built-in command. Tie the count to the registry so
    // it can't go stale when commands are added (it did: /cwd, /loop, /watch).
    try std.testing.expectEqual(slash_command_entries.len, session.slashCommandSuggestionCount());
    try std.testing.expectEqualStrings("/skills", session.slashCommandSuggestionAt(0).?.command);

    // "/c" filters to /commands, /clear, /cwd.
    session.appendInputText("c");
    try std.testing.expectEqual(@as(usize, 3), session.slashCommandSuggestionCount());
    try std.testing.expectEqualStrings("/commands", session.slashCommandSuggestionAt(0).?.command);
}

test "ai chat slash command suggestions include rewind" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("/rew");

    try std.testing.expectEqual(@as(usize, 1), session.slashCommandSuggestionCount());
    try std.testing.expectEqualStrings("/rewind", session.slashCommandSuggestionAt(0).?.command);
}

test "ai chat slash suggestions include cached custom commands" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    // Cache owns both strings, mirroring rebuildCustomCommandSuggestions; deinit
    // path is exercised via freeCustomCommandSuggestions below.
    const suggestions = try allocator.alloc(SlashCommandSuggestion, 1);
    suggestions[0] = .{
        .command = try allocator.dupe(u8, "/review"),
        .description = try allocator.dupe(u8, "review diff"),
    };
    session.custom_command_suggestions = suggestions;

    try std.testing.expectEqual(@as(usize, 1), session.customCommandSuggestions().len);

    session.appendInputText("/rev");
    // No built-in matches "/rev", so the custom command is the only suggestion.
    try std.testing.expectEqual(@as(usize, 1), session.slashCommandSuggestionCount());
    try std.testing.expectEqualStrings("/review", session.slashCommandSuggestionAt(0).?.command);

    session.freeCustomCommandSuggestions();
    try std.testing.expectEqual(@as(usize, 0), session.customCommandSuggestions().len);
}

test "ai chat slash command suggestions use arrows and tab completion" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("/");

    session.handleKey(.{ .key = input_key.Key.arrow_down });
    try std.testing.expectEqual(@as(usize, 1), session.slashCommandSuggestionSelectedIndex());

    session.handleKey(.{ .key = input_key.Key.tab });
    try std.testing.expectEqualStrings("/commands", session.input());
    try std.testing.expectEqual(@as(usize, "/commands".len), session.inputCursor());
}

test "slashCommandOutput covers new lifecycle commands" {
    const a = std.testing.allocator;
    inline for (.{
        .{ SlashCommand.clear, "Cleared" },
        .{ SlashCommand.reload_commands, "commands" },
        .{ SlashCommand.permission, "permission" },
        .{ SlashCommand.export_markdown, "Export" },
        .{ SlashCommand.resume_session, "history" },
    }) |case| {
        const out = try slashCommandOutput(a, case[0]);
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, case[1]) != null);
    }
}

test "ai chat enter completes selected slash suggestion before command submit" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("/");

    session.handleKey(.{ .key = input_key.Key.arrow_down });
    session.handleKey(.{ .key = input_key.Key.enter });

    try std.testing.expectEqualStrings("/commands", session.input());
    try std.testing.expectEqual(@as(usize, 0), session.messages.items.len);

    session.handleKey(.{ .key = input_key.Key.enter });

    try std.testing.expectEqualStrings("", session.input());
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    try std.testing.expectEqual(Role.tool, session.messages.items[0].role);

    for (session.messages.items) |msg| msg.deinit(allocator);
    session.messages.deinit(allocator);
}

test "ai chat enter submits slash commands instead of completing suggestions" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("/commands");

    session.handleKey(.{ .key = input_key.Key.enter });

    try std.testing.expectEqualStrings("", session.input());
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    try std.testing.expectEqual(Role.tool, session.messages.items[0].role);
    try std.testing.expect(std.mem.indexOf(u8, session.messages.items[0].content, "/commands - list slash commands") != null);

    for (session.messages.items) |msg| msg.deinit(allocator);
    session.messages.deinit(allocator);
}

test "/rewind via submit opens picker without adding transcript noise" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "first prompt") });
    try session.messages.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "first reply") });
    session.appendInputText("/rewind");

    session.submit();

    try std.testing.expect(session.rewind_open);
    try std.testing.expectEqual(@as(usize, 0), session.rewind_selected);
    try std.testing.expectEqualStrings("", session.input());
    try std.testing.expectEqual(@as(usize, 2), session.messages.items.len);
}

test "/clear via submit empties the transcript and shows confirmation" {
    const a = std.testing.allocator;
    var session = try Session.init(a, "chat", "https://api.example.com", "key", "m1", "sys", "false", "", "false", "false");
    defer session.deinit();
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "old message") });
    session.appendInputText("/clear");
    session.submit();
    // /clear empties then appends a single confirmation tool message
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    try std.testing.expect(std.mem.indexOf(u8, session.messages.items[0].content, "Cleared") != null);
}

var test_export_mode: ?MarkdownExportMode = null;
fn testExportHook(mode: MarkdownExportMode) void {
    test_export_mode = mode;
}

test "/export via submit fires the export trigger with parsed mode" {
    const a = std.testing.allocator;
    setMarkdownExportTrigger(testExportHook);
    defer setMarkdownExportTrigger(null);
    var session = try Session.init(a, "chat", "https://api.example.com", "key", "m1", "sys", "false", "", "false", "false");
    defer session.deinit();
    test_export_mode = null;
    session.appendInputText("/export full");
    session.submit();
    try std.testing.expectEqual(MarkdownExportMode.full, test_export_mode.?);
    test_export_mode = null;
    session.appendInputText("/export");
    session.submit();
    try std.testing.expectEqual(MarkdownExportMode.clean, test_export_mode.?);
}

test "/resume defers to copilot picker for copilot sessions, external resume otherwise" {
    const allocator = std.testing.allocator;
    const copilot = try Session.init(allocator, "Copilot", "https://x", "k", "m", "s", "disabled", "low", "true", "true");
    defer copilot.deinit();
    copilot.copilot = true;
    {
        copilot.mutex.lock();
        defer copilot.mutex.unlock();
        const r = copilot.runBuiltinCommandLocked(.resume_session, "");
        try std.testing.expectEqual(
            @as(std.meta.Tag(DeferredAction), .copilot_conversation_picker),
            std.meta.activeTag(r.deferred),
        );
    }

    const tabchat = try Session.init(allocator, "Chat", "https://x", "k", "m", "s", "disabled", "low", "true", "true");
    defer tabchat.deinit();
    {
        tabchat.mutex.lock();
        defer tabchat.mutex.unlock();
        const r = tabchat.runBuiltinCommandLocked(.resume_session, "");
        try std.testing.expectEqual(
            @as(std.meta.Tag(DeferredAction), .resume_picker),
            std.meta.activeTag(r.deferred),
        );
    }
}

test "ai chat dollar skill suggestions filter and enter completes with trailing space" {
    const allocator = std.testing.allocator;
    const root = ".zig-cache/skill-suggestion-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};

    try std.fs.cwd().makePath(root ++ "/skills/pdf");
    try std.fs.cwd().writeFile(.{
        .sub_path = root ++ "/skills/pdf/SKILL.md",
        .data = "---\nname: pdf\ndescription: Work with PDF files.\n---\n# PDF\n",
    });

    const session = try Session.init(
        allocator,
        "Test",
        DEFAULT_BASE_URL,
        "key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        DEFAULT_THINKING,
        DEFAULT_REASONING_EFFORT,
        DEFAULT_STREAM,
        "true",
    );
    defer session.deinit();

    try session.loadSkillSuggestionsFromRoots(&.{root ++ "/skills"});
    session.appendInputText("$p");

    // "$p" matches both the reserved "$pubmed" command and the installed "pdf" skill.
    try std.testing.expectEqual(@as(usize, 2), session.composerSuggestionCount());
    // Reserved commands come first; index 0 = pubmed, index 1 = pdf skill.
    const suggestion = session.composerSuggestionAt(1).?;
    try std.testing.expectEqual(ComposerSuggestionKind.skill, suggestion.kind);
    try std.testing.expectEqualStrings("pdf", suggestion.text);

    // Navigate down once to select the "pdf" skill (index 1) and then confirm.
    session.handleKey(.{ .key = input_key.Key.arrow_down });
    session.handleKey(.{ .key = input_key.Key.enter });

    try std.testing.expectEqualStrings("$pdf ", session.input());
    try std.testing.expectEqual(@as(usize, "$pdf ".len), session.inputCursor());
    try std.testing.expectEqual(@as(usize, 0), session.messages.items.len);
}

const WeixinAttachmentCapture = struct {
    called: bool = false,
    kind: weixin_types.AttachmentKind = .file,
    path: []const u8 = "",
    display_name: []const u8 = "",
    to_user_id: []const u8 = "",
    context_token: []const u8 = "",
    path_buf: [512]u8 = undefined,
    display_name_buf: [256]u8 = undefined,
    to_user_id_buf: [256]u8 = undefined,
    context_token_buf: [256]u8 = undefined,

    fn copyField(buf: []u8, value: []const u8) []const u8 {
        const n = @min(buf.len, value.len);
        @memcpy(buf[0..n], value[0..n]);
        return buf[0..n];
    }

    fn send(
        ctx: *anyopaque,
        kind: weixin_types.AttachmentKind,
        path: []const u8,
        display_name: []const u8,
        to_user_id: []const u8,
        context_token: []const u8,
    ) anyerror!void {
        const self: *WeixinAttachmentCapture = @ptrCast(@alignCast(ctx));
        self.called = true;
        self.kind = kind;
        self.path = copyField(&self.path_buf, path);
        self.display_name = copyField(&self.display_name_buf, display_name);
        self.to_user_id = copyField(&self.to_user_id_buf, to_user_id);
        self.context_token = copyField(&self.context_token_buf, context_token);
    }
};

fn testWeixinSender(capture: *WeixinAttachmentCapture) weixin_types.AttachmentSender {
    return .{ .ctx = capture, .send_attachment = WeixinAttachmentCapture.send };
}

test "weixin_send_attachment without reply context returns a clear tool result" {
    var session = try Session.init(
        std.testing.allocator,
        "test",
        "https://api.example",
        "key",
        "model",
        "prompt",
        "enabled",
        "medium",
        "false",
        "true",
    );
    defer session.deinit();

    const request = try std.testing.allocator.create(ChatRequest);
    request.* = .{
        .allocator = std.testing.allocator,
        .session = session,
        .base_url = try std.testing.allocator.dupe(u8, "https://api.example"),
        .api_key = try std.testing.allocator.dupe(u8, "key"),
        .model = try std.testing.allocator.dupe(u8, "model"),
        .system_prompt = try std.testing.allocator.dupe(u8, "prompt"),
        .messages = &.{},
        .thinking_enabled = false,
        .reasoning_effort = try std.testing.allocator.dupe(u8, "medium"),
        .stream = false,
        .agent_enabled = true,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
    };
    defer request.deinit();

    var call = ToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_1"),
        .name = try std.testing.allocator.dupe(u8, "weixin_send_attachment"),
        .arguments = try std.testing.allocator.dupe(u8, "{\"kind\":\"image\",\"path\":\"C:\\\\tmp\\\\plot.png\"}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try ai_chat_request.executeToolCall(request, call);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("No active Weixin reply context; cannot send attachment.", result);
}

test "weixin_send_attachment calls the active Weixin sender" {
    var capture = WeixinAttachmentCapture{};
    var session = try Session.init(
        std.testing.allocator,
        "test",
        "https://api.example",
        "key",
        "model",
        "prompt",
        "enabled",
        "medium",
        "false",
        "true",
    );
    defer session.deinit();

    const request = try std.testing.allocator.create(ChatRequest);
    request.* = .{
        .allocator = std.testing.allocator,
        .session = session,
        .base_url = try std.testing.allocator.dupe(u8, "https://api.example"),
        .api_key = try std.testing.allocator.dupe(u8, "key"),
        .model = try std.testing.allocator.dupe(u8, "model"),
        .system_prompt = try std.testing.allocator.dupe(u8, "prompt"),
        .messages = &.{},
        .thinking_enabled = false,
        .reasoning_effort = try std.testing.allocator.dupe(u8, "medium"),
        .stream = false,
        .agent_enabled = true,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
        .weixin_reply_context = try WeixinReplyContext.init(std.testing.allocator, .{
            .sender = testWeixinSender(&capture),
            .to_user_id = "wx-user",
            .context_token = "ctx-1",
        }),
    };
    defer request.deinit();

    var call = ToolCall{
        .id = try std.testing.allocator.dupe(u8, "call_1"),
        .name = try std.testing.allocator.dupe(u8, "weixin_send_attachment"),
        .arguments = try std.testing.allocator.dupe(u8, "{\"kind\":\"file\",\"path\":\"C:\\\\tmp\\\\report.pdf\",\"display_name\":\"report.pdf\"}"),
    };
    defer call.deinit(std.testing.allocator);

    const result = try ai_chat_request.executeToolCall(request, call);
    defer std.testing.allocator.free(result);

    try std.testing.expect(capture.called);
    try std.testing.expectEqual(weixin_types.AttachmentKind.file, capture.kind);
    try std.testing.expectEqualStrings("C:\\tmp\\report.pdf", capture.path);
    try std.testing.expectEqualStrings("report.pdf", capture.display_name);
    try std.testing.expectEqualStrings("wx-user", capture.to_user_id);
    try std.testing.expectEqualStrings("ctx-1", capture.context_token);
    try std.testing.expectEqualStrings("Sent file to Weixin: report.pdf", result);
}

test "ai_chat: session serializes to history record" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "History Test",
        "https://api.example.com",
        "secret",
        "model-a",
        "system",
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    session.mutex.lock();
    try session.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "hello") });
    session.mutex.unlock();

    var record = try session.toHistoryRecord(allocator);
    defer agent_history.freeOwnedRecord(allocator, &record);

    try std.testing.expect(record.agent_enabled);
    try std.testing.expectEqualStrings(DEFAULT_PROTOCOL, record.protocol);
    try std.testing.expectEqual(@as(usize, 1), record.messages.len);
    try std.testing.expectEqualStrings("hello", record.messages[0].content);
}

test "ai_chat: anthropic base url auto-detects the anthropic protocol" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Anthropic Test",
        "https://api.anthropic.com",
        "secret",
        "claude-3-5-sonnet",
        "system",
        "enabled",
        "high",
        "false",
        "false",
    );
    defer session.deinit();
    try std.testing.expectEqual(ApiProtocol.anthropic, session.protocol);
}

test "ai_chat: non-anthropic base url keeps chat_completions protocol" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "OpenAI Test",
        "https://api.openai.com/v1",
        "secret",
        "gpt-4o",
        "system",
        "enabled",
        "high",
        "false",
        "false",
    );
    defer session.deinit();
    try std.testing.expectEqual(ApiProtocol.chat_completions, session.protocol);
}

test "ai_chat: response protocol survives history record round trip" {
    const allocator = std.testing.allocator;
    const session = try Session.initWithProtocol(
        allocator,
        "Responses Test",
        "https://api.openai.com/v1",
        "secret",
        "gpt-5",
        "responses",
        "system",
        "enabled",
        "high",
        "false",
        "false",
    );
    defer session.deinit();

    var record = try session.toHistoryRecord(allocator);
    defer agent_history.freeOwnedRecord(allocator, &record);

    try std.testing.expectEqualStrings("responses", record.protocol);

    const restored = try Session.initFromHistoryRecord(allocator, record);
    defer restored.deinit();

    try std.testing.expectEqualStrings("responses", restored.apiProtocolName());
}

test "ai_chat: session preserves max_tokens through a history record round trip" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "chat",
        "https://api.anthropic.com",
        "key",
        "claude-x",
        "sys",
        "false",
        "",
        "false",
        "false",
    );
    defer session.deinit();

    try std.testing.expectEqual(@as(u32, 8192), session.max_tokens); // default

    session.setMaxTokens(4096);

    var record = try session.toHistoryRecord(allocator);
    defer agent_history.freeOwnedRecord(allocator, &record);
    try std.testing.expectEqual(@as(u32, 4096), record.max_tokens);

    const restored = try Session.initFromHistoryRecord(allocator, record);
    defer restored.deinit();
    try std.testing.expectEqual(@as(u32, 4096), restored.max_tokens);
}

test "ai_chat: session loads from history record" {
    const allocator = std.testing.allocator;
    var record = try agent_history.cloneRecord(allocator, .{
        .session_id = "session-1",
        .title = "Saved",
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = "model-a",
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 2,
        .messages = &.{
            .{ .role = .user, .content = "hello", .reasoning = null, .usage_footer = null },
        },
    });
    defer agent_history.freeOwnedRecord(allocator, &record);

    const session = try Session.initFromHistoryRecord(allocator, record);
    defer session.deinit();

    try std.testing.expectEqualStrings("session-1", session.sessionId());
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
}

test "ai_chat: loading history record cleans up partial message clone on allocation failure" {
    const allocator = std.testing.allocator;
    var record = try agent_history.cloneRecord(allocator, .{
        .session_id = "session-tool",
        .title = "Saved",
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = "model-a",
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 2,
        .messages = &.{
            .{
                .role = .tool,
                .content = "# Skill: pdf",
                .reasoning = "reason",
                .usage_footer = "usage",
                .tool_call_id = "skill-preload-pdf",
                .tool_name = "skill_info",
                .replay_to_model = true,
            },
        },
    });
    defer agent_history.freeOwnedRecord(allocator, &record);

    var saw_oom = false;
    var fail_index: usize = 0;
    while (fail_index < 128) : (fail_index += 1) {
        var failing_allocator = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = fail_index,
        });

        const result = Session.initFromHistoryRecord(failing_allocator.allocator(), record);
        if (result) |session| {
            session.deinit();
            if (!failing_allocator.has_induced_failure) break;
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => return err,
        }
    }

    try std.testing.expect(saw_oom);
}

test "ai_chat: serializing history record cleans up partial message clone on allocation failure" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "History Test",
        "https://api.example.com",
        "secret",
        "model-a",
        "system",
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    session.mutex.lock();
    defer session.mutex.unlock();
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "# Skill: pdf"),
        .reasoning = try allocator.dupe(u8, "reason"),
        .usage_footer = try allocator.dupe(u8, "usage"),
        .tool_call_id = try allocator.dupe(u8, "skill-preload-pdf"),
        .tool_name = try allocator.dupe(u8, "skill_info"),
        .replay_to_model = true,
    });

    var saw_oom = false;
    var fail_index: usize = 0;
    while (fail_index < 128) : (fail_index += 1) {
        var failing_allocator = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = fail_index,
        });

        const result = session.toHistoryRecordLocked(failing_allocator.allocator());
        if (result) |record| {
            var owned_record = record;
            agent_history.freeOwnedRecord(failing_allocator.allocator(), &owned_record);
            if (!failing_allocator.has_induced_failure) break;
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => return err,
        }
    }

    try std.testing.expect(saw_oom);
}

test "ai_chat: progress tool messages are ui-only history" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Progress",
        "https://api.example.com",
        "secret",
        "model-a",
        "system",
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    var capture = TestHistoryHookCapture{};
    defer capture.deinit();
    g_test_history_hook_capture = &capture;
    defer g_test_history_hook_capture = null;

    session.setHistoryChangeHook(testHistoryHookCaptureCallback);
    try appendProgressMessage(session, "running tool");

    try std.testing.expectEqual(@as(usize, 0), capture.calls);
    try std.testing.expect(capture.event == null);
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    try std.testing.expect(!session.messages.items[0].persist_to_history);

    session.mutex.lock();
    defer session.mutex.unlock();
    var record = try session.toHistoryRecordLocked(allocator);
    defer agent_history.freeOwnedRecord(allocator, &record);

    try std.testing.expectEqual(@as(usize, 0), record.messages.len);
}

test "ai_chat: replayable skill tool messages emit history snapshots" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Skill Tool",
        "https://api.example.com",
        "secret",
        "model-a",
        "system",
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    var capture = TestHistoryHookCapture{};
    defer capture.deinit();
    g_test_history_hook_capture = &capture;
    defer g_test_history_hook_capture = null;

    session.setHistoryChangeHook(testHistoryHookCaptureCallback);
    try appendReplayableToolMessage(session, "call-1", "skill_info", "# Skill: pdf");

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.event != null);
    try std.testing.expectEqual(@as(usize, 1), capture.event.?.record.messages.len);
    const message = capture.event.?.record.messages[0];
    try std.testing.expectEqual(.tool, message.role);
    try std.testing.expectEqualStrings("# Skill: pdf", message.content);
    try std.testing.expectEqualStrings("call-1", message.tool_call_id.?);
    try std.testing.expectEqualStrings("skill_info", message.tool_name.?);
    try std.testing.expect(message.replay_to_model);

    capture.deinit();
    try std.testing.expect(capture.event == null);
}

test "ai_chat: setTitle emits history hook snapshot" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Before",
        "https://api.example.com",
        "secret",
        "model-a",
        "system",
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    var capture = TestHistoryHookCapture{};
    defer capture.deinit();
    g_test_history_hook_capture = &capture;
    defer g_test_history_hook_capture = null;

    session.setHistoryChangeHook(testHistoryHookCaptureCallback);
    session.setTitle("After");

    try std.testing.expectEqual(@as(usize, 1), capture.calls);
    try std.testing.expect(capture.event != null);
    try std.testing.expectEqualStrings("After", capture.event.?.record.title);
    try std.testing.expectEqualStrings("After", session.title());
}

test "ai_chat: initFromHistoryRecord marks auto_title_attempted when assistant present" {
    const allocator = std.testing.allocator;
    var msgs = [_]agent_history.MessageRecord{
        .{ .role = .user, .content = "hi" },
        .{ .role = .assistant, .content = "hello" },
    };
    const record = agent_history.SessionRecord{
        .session_id = "sess-1",
        .title = "Restored Chat",
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = "model-a",
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = false,
        .created_at = 0,
        .updated_at = 0,
        .messages = &msgs,
    };
    const session = try Session.initFromHistoryRecord(allocator, record);
    defer session.deinit();
    try std.testing.expect(session.auto_title_attempted);
}

test "ai_chat: fresh session has auto_title_attempted=false" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        DEFAULT_NAME,
        "https://api.example.com",
        "secret",
        "model-a",
        "system",
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();
    try std.testing.expect(!session.auto_title_attempted);
}

test "ai_chat: applyGeneratedTitle cleans and sets title when still default" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        DEFAULT_NAME,
        "https://api.example.com",
        "secret",
        "model-a",
        "system",
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();
    applyGeneratedTitle(session, "  \"Deploy the App\"  \nignored second line ");
    try std.testing.expectEqualStrings("Deploy the App", session.title());
}

test "ai_chat: applyGeneratedTitle leaves a renamed title untouched" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "My Custom Name",
        "https://api.example.com",
        "secret",
        "model-a",
        "system",
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();
    applyGeneratedTitle(session, "Generated Title");
    try std.testing.expectEqualStrings("My Custom Name", session.title());
}

test "ai_chat: applyGeneratedTitle ignores empty model output" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        DEFAULT_NAME,
        "https://api.example.com",
        "secret",
        "model-a",
        "system",
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();
    applyGeneratedTitle(session, "   \n  ");
    try std.testing.expectEqualStrings(DEFAULT_NAME, session.title());
}

test "ai chat endpoint normalization" {
    const allocator = std.testing.allocator;
    const endpoint = try chatEndpoint(allocator, "https://api.deepseek.com/");
    defer allocator.free(endpoint);
    try std.testing.expectEqualStrings("https://api.deepseek.com/chat/completions", endpoint);
}

test "ai chat responses endpoint normalization" {
    const allocator = std.testing.allocator;
    const endpoint = try apiEndpoint(allocator, "https://api.openai.com/v1/", .responses);
    defer allocator.free(endpoint);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/responses", endpoint);

    const explicit = try apiEndpoint(allocator, "https://chatgpt.com/backend-api/codex/responses/", .responses);
    defer allocator.free(explicit);
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", explicit);
}

test "ai chat default system prompt comes from platform agent prompt" {
    // Length budget: the system prompt ships on every AI API call, so this guards
    // against silent bloat. The Windows variant is the longest (it adds the WSL
    // tool guidance); keep headroom above it for future additions.
    try std.testing.expect(DEFAULT_SYSTEM_PROMPT.len < 4000);
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "wispterm_docs") != null);
    try std.testing.expectEqualStrings(platform_agent_prompt.defaultSystemPrompt, DEFAULT_SYSTEM_PROMPT);
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "uv") != null);
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "Python") != null);
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, platform_process.localCommandToolName()) != null);
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "terminal_list") != null);
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "terminal_context") != null);
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "terminal_select") != null);
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "ssh_session_exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "ssh_profile_save") != null);
    if (platform_pty_command.wslSessionToolsEnabled()) {
        try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "wsl_session_exec") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "wsl_session_exec") == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "terminal_repl_exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "Codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "Claude Code") != null);
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "shell commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "uv --version") != null);
}

test "copilot prompt keeps tool guidance and adds the binding clause" {
    try std.testing.expect(std.mem.indexOf(u8, COPILOT_SYSTEM_PROMPT, "CURRENTLY FOCUSED") != null);
    try std.testing.expect(std.mem.indexOf(u8, COPILOT_SYSTEM_PROMPT, "ssh_session_exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, COPILOT_SYSTEM_PROMPT, "terminal_context") != null);
    try std.testing.expect(std.mem.indexOf(u8, COPILOT_SYSTEM_PROMPT, "terminal_select") != null);
}

test "default system prompt mentions subagent delegation" {
    try std.testing.expect(std.mem.indexOf(u8, DEFAULT_SYSTEM_PROMPT, "`subagent`") != null);
}

test "subagent system prompt is self-contained researcher guidance" {
    const prompt = platform_agent_prompt.subagentSystemPrompt;
    try std.testing.expect(std.mem.indexOf(u8, prompt, "research subagent") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "final report") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "websearch") != null);
    try std.testing.expect(prompt.len < 1200);
}

test "ai chat empty profile system prompt uses full embedded default" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Test",
        DEFAULT_BASE_URL,
        "key",
        DEFAULT_MODEL,
        "",
        DEFAULT_THINKING,
        DEFAULT_REASONING_EFFORT,
        DEFAULT_STREAM,
        DEFAULT_AGENT,
    );
    defer session.deinit();

    try std.testing.expectEqualStrings(DEFAULT_SYSTEM_PROMPT, session.systemPrompt());
}

// The following tests live in ai_chat_request.zig (no Session private calls):
//   "ai chat request json includes deepseek thinking mode"
//   "ai chat agent request json includes tool schemas"
//   "ai chat responses request json uses input and response tool schemas"
//   "ai chat request json replays assistant reasoning content"
//   "ai chat request json adds thinking fallback for assistant tool calls without reasoning"
//   "ai chat request json replaces invalid utf8 bytes"
//   "ai chat streaming request asks provider to include usage"

test "ai chat parses OpenAI tool calls" {
    const allocator = std.testing.allocator;
    const body =
        \\{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","type":"function","function":{"name":"terminal_list","arguments":"{}"}}]}}]}
    ;
    const result = try parseApiResponse(allocator, body, .chat_completions);
    defer result.deinit(allocator);
    try std.testing.expect(result.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1", result.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("terminal_list", result.tool_calls.?[0].name);
    try std.testing.expectEqualStrings("{}", result.tool_calls.?[0].arguments);
}

test "ai chat parses token usage from OpenAI responses" {
    const allocator = std.testing.allocator;
    const body =
        \\{"usage":{"prompt_tokens":12,"completion_tokens":34,"prompt_cache_hit_tokens":5,"prompt_cache_miss_tokens":7,"total_tokens":46},"choices":[{"message":{"role":"assistant","content":"done"}}]}
    ;
    const result = try parseApiResponse(allocator, body, .chat_completions);
    defer result.deinit(allocator);
    try std.testing.expect(result.usage != null);
    try std.testing.expectEqual(@as(u64, 12), result.usage.?.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 34), result.usage.?.completion_tokens);
    try std.testing.expectEqual(@as(u64, 5), result.usage.?.prompt_cache_hit_tokens);
    try std.testing.expectEqual(@as(u64, 7), result.usage.?.prompt_cache_miss_tokens);
    try std.testing.expectEqual(@as(u64, 46), result.usage.?.total_tokens);
}

test "ai chat parses Responses API output text tool calls and usage" {
    const allocator = std.testing.allocator;
    const body =
        \\{"usage":{"input_tokens":20,"output_tokens":8,"total_tokens":28,"input_tokens_details":{"cached_tokens":6}},"output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"checked"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"done"}]},{"type":"function_call","call_id":"call_1","name":"terminal_list","arguments":"{}"}]}
    ;
    const result = try parseApiResponse(allocator, body, .responses);
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("done", result.content);
    try std.testing.expect(result.reasoning != null);
    try std.testing.expectEqualStrings("checked", result.reasoning.?);
    try std.testing.expect(result.tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), result.tool_calls.?.len);
    try std.testing.expectEqualStrings("call_1", result.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("terminal_list", result.tool_calls.?[0].name);
    try std.testing.expectEqualStrings("{}", result.tool_calls.?[0].arguments);
    try std.testing.expect(result.usage != null);
    try std.testing.expectEqual(@as(u64, 20), result.usage.?.prompt_tokens);
    try std.testing.expectEqual(@as(u64, 8), result.usage.?.completion_tokens);
    try std.testing.expectEqual(@as(u64, 6), result.usage.?.prompt_cache_hit_tokens);
    try std.testing.expectEqual(@as(u64, 14), result.usage.?.prompt_cache_miss_tokens);
    try std.testing.expectEqual(@as(u64, 28), result.usage.?.total_tokens);
}

test "ai chat usage footer includes time token and cache fields" {
    const footer = try allocUsageFooter(std.testing.allocator, std.time.milliTimestamp() - 2300, .{
        .prompt_tokens = 12,
        .completion_tokens = 34,
        .prompt_cache_hit_tokens = 5,
        .prompt_cache_miss_tokens = 7,
        .total_tokens = 46,
    });
    defer if (footer) |text| std.testing.allocator.free(text);
    try std.testing.expect(footer != null);
    try std.testing.expect(std.mem.indexOf(u8, footer.?, "time 2.") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer.?, "total 46") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer.?, "input 12") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer.?, "output 34") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer.?, "cache 5/7") != null);
}

test "ai chat completion status stays compact while usage is message footer" {
    var session = Session{ .allocator = std.testing.allocator };
    session.setCompletionStatusLocked(std.time.milliTimestamp() - 2300, .{
        .prompt_tokens = 12,
        .completion_tokens = 34,
        .total_tokens = 46,
    });
    try std.testing.expect(std.mem.indexOf(u8, session.status(), "Done in 2.") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.status(), "tok") == null);
}

test "ai chat appends usage footer to completed assistant message" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    appendAssistantResult(&session, .{
        .content = @constCast("done"),
        .usage = .{
            .prompt_tokens = 12,
            .completion_tokens = 34,
            .prompt_cache_hit_tokens = 5,
            .prompt_cache_miss_tokens = 7,
            .total_tokens = 46,
        },
    }, std.time.milliTimestamp() - 2300);

    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    try std.testing.expect(session.messages.items[0].usage_footer != null);
    const footer = session.messages.items[0].usage_footer.?;
    try std.testing.expect(std.mem.indexOf(u8, footer, "total 46") != null);
    try std.testing.expect(std.mem.indexOf(u8, footer, "cache 5/7") != null);
}

// "ai chat streaming request asks provider to include usage" and
// "copilot session pre-targets the bound surface in its request" have moved
// to ai_chat_request.zig.

// Local test stub host for the wsl_session_exec test below.
const CopilotTestHost = struct {
    fn collectSnapshot(_: *anyopaque, allocator: std.mem.Allocator) anyerror!ToolSnapshot {
        const surfaces = try allocator.alloc(ToolSurface, 1);
        errdefer allocator.free(surfaces);
        surfaces[0] = .{
            .id = try allocator.dupe(u8, "surface-1"),
            .title = try allocator.dupe(u8, "shell"),
            .cwd = try allocator.dupe(u8, "/home/tester/work"),
            .snapshot = try allocator.dupe(u8, "$ ls\n"),
            .tab_index = 0,
            .focused = true,
            .is_ssh = false,
            .is_wsl = false,
            .ptr = undefined,
        };
        return .{ .surfaces = surfaces, .active_tab = 0 };
    }
    fn unsupportedSurfaceSnapshot(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: *anyopaque) anyerror![]u8 {
        return error.Unsupported;
    }
    fn unsupportedWrite(_: *anyopaque, _: []const u8, _: *anyopaque, _: []const u8) bool {
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

    var ctx_sentinel: u8 = 0;

    fn host() ToolHost {
        return .{
            .ctx = @ptrCast(&ctx_sentinel),
            .collectSnapshot = collectSnapshot,
            .surfaceSnapshot = unsupportedSurfaceSnapshot,
            .writeSurface = unsupportedWrite,
            .spawnTab = unsupportedSpawn,
            .closeTab = unsupportedClose,
            .saveSshProfile = unsupportedSaveSsh,
            .connectSshProfile = unsupportedConnectSsh,
        };
    }
};

test "wsl_session_exec refuses to paste shell wrapper into Claude Code" {
    const allocator = std.testing.allocator;
    const saved_settings = currentAgentSettings();
    defer configureAgent(saved_settings);
    configureAgent(.{ .enabled = true, .permission = .full });
    const session = try Session.init(allocator, "test", "", "", "", "", "", "", "", "");
    defer session.deinit();

    var surfaces = try allocator.alloc(ToolSurface, 1);
    surfaces[0] = .{
        .id = try allocator.dupe(u8, "surface-claude"),
        .title = try allocator.dupe(u8, "\xe2\x9c\xbb Claude Code"),
        .cwd = try allocator.dupe(u8, "/home/xzg"),
        .snapshot = try allocator.dupe(u8, "Claude Code v2.1.159\n> "),
        .tab_index = 2,
        .focused = true,
        .is_ssh = false,
        .is_wsl = true,
        .agent_app = .claude_code,
        .agent_state = .running,
        .agent_confidence = 82,
        .ptr = @ptrFromInt(1),
    };
    const snapshot = ToolSnapshot{ .surfaces = surfaces, .active_tab = 2 };
    defer snapshot.deinit(allocator);

    var messages = [_]RequestMessage{};
    var request = ChatRequest{
        .allocator = allocator,
        .session = session,
        .base_url = @constCast(""),
        .api_key = @constCast(""),
        .model = @constCast(""),
        .system_prompt = @constCast(""),
        .messages = messages[0..],
        .thinking_enabled = false,
        .reasoning_effort = @constCast(""),
        .stream = false,
        .agent_enabled = true,
        .tool_host = CopilotTestHost.host(),
        .tool_snapshot = snapshot,
        .started_ms = 0,
    };
    setWriteContext(&request, "surface-claude");

    const result = try wslSessionExecTool(&request, "surface-claude", "which claude", 1000);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Refusing to run WSL shell command") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "terminal_repl_exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "repl=claude_code") != null);
}

test "ai chat ctrl a selects input and replacement clears selection" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("hello");
    session.handleKey(.{ .key = input_key.Key.key_a, .ctrl = true });
    try std.testing.expect(session.input_select_all);

    const copied = try session.allocClipboardText(allocator);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("hello", copied);

    session.handleChar('x');
    try std.testing.expect(!session.input_select_all);
    try std.testing.expectEqualStrings("x", session.input());
}

test "ai chat pending image add, count, and clear" {
    const allocator = std.testing.allocator;
    const session = try Session.init(allocator, "test", "", "", "", "", "", "", "", "");
    defer session.deinit();
    try std.testing.expectEqual(@as(usize, 0), session.pendingImageCount());
    try session.addPendingImage("QUJD", "image/png");
    try session.addPendingImage("RUZH", "image/png");
    try std.testing.expectEqual(@as(usize, 2), session.pendingImageCount());
    session.clearPendingImages();
    try std.testing.expectEqual(@as(usize, 0), session.pendingImageCount());
}

test "ai chat takePendingImages transfers ownership and clears the pending list" {
    const allocator = std.testing.allocator;
    const session = try Session.init(allocator, "test", "", "", "", "", "", "", "", "");
    defer session.deinit();
    try session.addPendingImage("QUJD", "image/png");
    const taken = session.takePendingImages().?;
    defer {
        for (taken) |img| img.deinit(allocator);
        allocator.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 0), session.pendingImageCount());
    try std.testing.expectEqual(@as(usize, 1), taken.len);
    try std.testing.expectEqualStrings("QUJD", taken[0].data_b64);
    try std.testing.expect(session.takePendingImages() == null);
}

test "ai chat vision flag parses from the profile vision string" {
    const allocator = std.testing.allocator;
    const off = try Session.init(allocator, "t", "", "", "", "", "", "", "", "");
    defer off.deinit();
    try std.testing.expect(!off.vision_enabled);
    const on = try Session.initWithVision(allocator, "t", "", "", "", "", "", "", "", "", "", "on");
    defer on.deinit();
    try std.testing.expect(on.vision_enabled);
}

test "ai chat buildRequestMessages clones user image blocks into the request" {
    const allocator = std.testing.allocator;
    const session = try Session.init(allocator, "test", "", "", "", "", "", "", "", "");
    defer session.deinit();

    const images = try allocator.alloc(ImageBlock, 1);
    images[0] = .{
        .data_b64 = try allocator.dupe(u8, "QUJD"),
        .media_type = try allocator.dupe(u8, "image/png"),
    };
    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "look"),
        .images = images,
    });

    const reqs = try session.buildRequestMessagesLocked(null, null);
    defer {
        for (reqs) |m| m.deinit(allocator);
        allocator.free(reqs);
    }
    try std.testing.expectEqual(@as(usize, 1), reqs.len);
    try std.testing.expect(reqs[0].images != null);
    try std.testing.expectEqual(@as(usize, 1), reqs[0].images.?.len);
    try std.testing.expectEqualStrings("QUJD", reqs[0].images.?[0].data_b64);
    // Deep clone: the request owns separate buffers from the session message.
    try std.testing.expect(reqs[0].images.?[0].data_b64.ptr != images[0].data_b64.ptr);
}

test "ai chat model context is request-only and hidden from visible history" {
    const allocator = std.testing.allocator;
    const session = try Session.init(allocator, "test", "", "", "", "", "", "", "", "");
    defer session.deinit();

    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "用户通过微信发送了文件：a.pdf"),
        .model_context = try allocator.dupe(u8, "本地文件路径：/work/weixin_inbound/a.pdf"),
    });

    const reqs = try session.buildRequestMessagesLocked(null, null);
    defer {
        for (reqs) |m| m.deinit(allocator);
        allocator.free(reqs);
    }
    try std.testing.expectEqual(@as(usize, 1), reqs.len);
    try std.testing.expect(std.mem.indexOf(u8, session.messages.items[0].content, "/work/") == null);
    try std.testing.expect(std.mem.indexOf(u8, reqs[0].content, "用户通过微信发送了文件：a.pdf") != null);
    try std.testing.expect(std.mem.indexOf(u8, reqs[0].content, "/work/weixin_inbound/a.pdf") != null);

    var record = try session.toHistoryRecord(allocator);
    defer agent_history.freeOwnedRecord(allocator, &record);
    try std.testing.expectEqual(@as(usize, 1), record.messages.len);
    try std.testing.expectEqualStrings("用户通过微信发送了文件：a.pdf", record.messages[0].content);
}

test "ai chat input cursor supports insertion and deletion in the middle" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("hello");
    try std.testing.expectEqual(@as(usize, 5), session.inputCursor());

    session.handleKey(.{ .key = input_key.Key.arrow_left });
    session.handleKey(.{ .key = input_key.Key.arrow_left });
    try std.testing.expectEqual(@as(usize, 3), session.inputCursor());

    session.handleChar('X');
    try std.testing.expectEqualStrings("helXlo", session.input());
    try std.testing.expectEqual(@as(usize, 4), session.inputCursor());

    session.handleKey(.{ .key = input_key.Key.backspace });
    try std.testing.expectEqualStrings("hello", session.input());
    try std.testing.expectEqual(@as(usize, 3), session.inputCursor());

    session.handleKey(.{ .key = input_key.Key.delete });
    try std.testing.expectEqualStrings("helo", session.input());
    try std.testing.expectEqual(@as(usize, 3), session.inputCursor());
}

test "ai chat input handles platform-neutral key events" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("hello");

    session.handleKey(.{ .key = input_key.Key.arrow_left });
    session.handleKey(.{ .key = input_key.Key.backspace });

    try std.testing.expectEqualStrings("helo", session.input());
    try std.testing.expectEqual(@as(usize, 3), session.inputCursor());
}

test "ai chat input accepts prompts longer than the old 8 KiB limit" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };

    const prompt = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(prompt);
    @memset(prompt, 'a');

    session.appendInputText(prompt);

    try std.testing.expectEqual(prompt.len, session.input().len);
    try std.testing.expectEqualStrings(prompt, session.input());
    try std.testing.expectEqual(prompt.len, session.inputCursor());
}

test "ai chat input cursor moves by utf8 codepoint boundaries" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("你a");
    session.handleKey(.{ .key = input_key.Key.arrow_left });
    try std.testing.expectEqual(@as(usize, 3), session.inputCursor());
    session.handleKey(.{ .key = input_key.Key.backspace });
    try std.testing.expectEqualStrings("a", session.input());
    try std.testing.expectEqual(@as(usize, 0), session.inputCursor());
}

test "ai chat input cursor moves vertically across explicit lines" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("abc\ndefg\nhi");

    session.handleKey(.{ .key = input_key.Key.home });
    session.handleKey(.{ .key = input_key.Key.arrow_down });
    try std.testing.expectEqual(@as(usize, 4), session.inputCursor());

    session.handleKey(.{ .key = input_key.Key.arrow_right });
    session.handleKey(.{ .key = input_key.Key.arrow_right });
    try std.testing.expectEqual(@as(usize, 6), session.inputCursor());

    session.handleKey(.{ .key = input_key.Key.arrow_down });
    try std.testing.expectEqual(@as(usize, 11), session.inputCursor());

    session.handleKey(.{ .key = input_key.Key.arrow_up });
    try std.testing.expectEqual(@as(usize, 6), session.inputCursor());
}

test "ai chat input cursor moves vertically across wrapped rows" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    session.appendInputText("abcdefghijkl");
    session.handleKey(.{ .key = input_key.Key.home });
    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_down }, 5);
    try std.testing.expectEqual(@as(usize, 5), session.inputCursor());

    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_right }, 5);
    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_right }, 5);
    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_down }, 5);
    try std.testing.expectEqual(@as(usize, 12), session.inputCursor());

    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_up }, 5);
    try std.testing.expectEqual(@as(usize, 7), session.inputCursor());
}

test "ai chat composer history recalls prompts at visual boundaries" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }
    try session.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "first prompt") });
    try session.messages.append(allocator, .{ .role = .assistant, .content = try allocator.dupe(u8, "first reply") });
    try session.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "second prompt") });

    session.appendInputText("draft");
    session.handleKey(.{ .key = input_key.Key.home });
    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_up }, 80);
    try std.testing.expectEqualStrings("second prompt", session.input());
    try std.testing.expectEqual(@as(usize, "second prompt".len), session.inputCursor());

    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_up }, 80);
    try std.testing.expectEqualStrings("first prompt", session.input());
    try std.testing.expectEqual(@as(usize, "first prompt".len), session.inputCursor());

    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_down }, 80);
    try std.testing.expectEqualStrings("second prompt", session.input());

    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_down }, 80);
    try std.testing.expectEqualStrings("draft", session.input());
    try std.testing.expectEqual(@as(usize, 0), session.inputCursor());
}

test "ai chat composer history preserves multiline vertical editing" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }
    try session.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "previous prompt") });

    session.appendInputText("abc\ndefg\nhi");
    session.handleKey(.{ .key = input_key.Key.home });
    session.handleKey(.{ .key = input_key.Key.arrow_down });
    try std.testing.expectEqual(@as(usize, 4), session.inputCursor());

    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_up }, 80);
    try std.testing.expectEqualStrings("abc\ndefg\nhi", session.input());
    try std.testing.expectEqual(@as(usize, 0), session.inputCursor());

    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_up }, 80);
    try std.testing.expectEqualStrings("previous prompt", session.input());
}

test "ai chat composer history exits after editing recalled prompt" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }
    try session.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "old prompt") });

    session.appendInputText("draft");
    session.handleKey(.{ .key = input_key.Key.home });
    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_up }, 80);
    try std.testing.expectEqualStrings("old prompt", session.input());

    session.handleChar('!');
    try std.testing.expectEqualStrings("old prompt!", session.input());

    session.handleKey(.{ .key = input_key.Key.home });
    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_down }, 80);
    try std.testing.expectEqualStrings("old prompt!", session.input());
}

test "ai chat composer wrapped row count grows with explicit lines and wrapping" {
    try std.testing.expectEqual(@as(usize, 1), inputWrappedLineCount("", 12));
    try std.testing.expectEqual(@as(usize, 2), inputWrappedLineCount("hello\nworld", 12));
    try std.testing.expectEqual(@as(usize, 3), inputWrappedLineCount("abcdefghijkl", 5));
}

test "ai chat input scroll clamps to wrapped rows" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Test",
        DEFAULT_BASE_URL,
        "key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        DEFAULT_THINKING,
        DEFAULT_REASONING_EFFORT,
        DEFAULT_STREAM,
        "false",
    );
    defer session.deinit();

    session.appendInputText("abcdefghijkl");

    try std.testing.expect(session.scrollInputRows(10, 5, 1));
    try std.testing.expectEqual(@as(usize, 2), session.inputScrollRow());

    try std.testing.expect(session.scrollInputRows(-1, 5, 1));
    try std.testing.expectEqual(@as(usize, 1), session.inputScrollRow());

    try std.testing.expect(session.scrollInputRows(10, 5, 3));
    try std.testing.expectEqual(@as(usize, 0), session.inputScrollRow());
    try std.testing.expect(!session.scrollInputRows(10, 5, 3));
}

test "ai chat manual input scroll pauses cursor following until cursor moves" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Test",
        DEFAULT_BASE_URL,
        "key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        DEFAULT_THINKING,
        DEFAULT_REASONING_EFFORT,
        DEFAULT_STREAM,
        "false",
    );
    defer session.deinit();

    session.appendInputText("abcdefghijkl");
    try std.testing.expect(session.input_scroll_follow_cursor);

    _ = session.scrollInputRows(1, 5, 1);
    try std.testing.expect(!session.input_scroll_follow_cursor);

    session.handleKeyWithWrapCols(.{ .key = input_key.Key.arrow_right }, 5);
    try std.testing.expect(session.input_scroll_follow_cursor);
}

test "ai chat remote snapshot omits local draft input" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "DeepSeek",
        DEFAULT_BASE_URL,
        "key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        DEFAULT_THINKING,
        DEFAULT_REASONING_EFFORT,
        DEFAULT_STREAM,
        DEFAULT_AGENT,
    );
    defer session.deinit();

    session.appendInputText("local draft only");
    const snapshot = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "local draft only") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Draft") == null);
}

test "ai chat remote snapshot keeps latest messages after large tool output" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "DeepSeek",
        DEFAULT_BASE_URL,
        "key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        DEFAULT_THINKING,
        DEFAULT_REASONING_EFFORT,
        DEFAULT_STREAM,
        DEFAULT_AGENT,
    );
    defer session.deinit();

    const large_tool_output = try allocator.alloc(u8, REMOTE_SNAPSHOT_MAX_BYTES + 1024);
    @memset(large_tool_output, 'x');
    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "latest user message"),
    });
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = large_tool_output,
        .tool_name = try allocator.dupe(u8, "terminal_repl_exec"),
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "latest assistant reply"),
    });

    const snapshot = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "latest user message") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "latest assistant reply") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "terminal_repl_exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx") == null);
}

test "ai chat remote snapshot keeps final answer when reasoning is huge (issue 118)" {
    // A reasoning-heavy turn (e.g. GLM thinking) on a large context once evicted
    // the final assistant answer from the byte budget, so the weixin reply
    // detector never saw the answer and never reported the turn done.
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }
    session.setStatusLocked("Done in 280.9s");

    const big_reasoning = try allocator.alloc(u8, REMOTE_SNAPSHOT_MAX_BYTES + 4096);
    @memset(big_reasoning, 'r');
    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "explain the captain model"),
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "FINAL_ANSWER_MARKER the captain model is ..."),
        .reasoning = big_reasoning,
    });

    const snapshot = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(snapshot);

    // The answer body survives; the oversized reasoning is dropped, not the answer.
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "FINAL_ANSWER_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Done in 280.9s") != null);
}

test "ai chat remote snapshot still includes reasoning when it fits" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "status?"),
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "all good"),
        .reasoning = try allocator.dupe(u8, "checked the state first"),
    });

    const snapshot = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "all good") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "checked the state first") != null);
}

test "ai chat remote snapshot includes a pending approval section" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }
    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "clean up"),
    });

    const tool = "terminal_repl_exec";
    const command = "rm -rf /tmp/x";
    @memcpy(session.approval_tool_buf[0..tool.len], tool);
    session.approval_tool_len = tool.len;
    @memcpy(session.approval_command_buf[0..command.len], command);
    session.approval_command_len = command.len;
    session.approval_pending = true;
    session.approval_resolved = false;

    const with = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(with);
    try std.testing.expect(std.mem.indexOf(u8, with, "Approval:") != null);
    try std.testing.expect(std.mem.indexOf(u8, with, "terminal_repl_exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, with, "rm -rf /tmp/x") != null);

    // Once resolved, the section disappears.
    try std.testing.expect(session.resolveApprovalExternal(true));
    const without = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(without);
    try std.testing.expect(std.mem.indexOf(u8, without, "Approval:") == null);
}

test "ai chat remote snapshot approval section omits the command line when empty" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    const tool = "weather_lookup";
    @memcpy(session.approval_tool_buf[0..tool.len], tool);
    session.approval_tool_len = tool.len;
    session.approval_command_len = 0; // no command argument
    session.approval_pending = true;
    session.approval_resolved = false;

    const snapshot = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(snapshot);
    // The tool-only approval still emits a section naming the tool, with no
    // trailing command line (the `\n<command>` branch is skipped).
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Approval:\r\nweather_lookup") != null);
}

test "ai chat remote snapshot emits a Question section with numbered options" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    session.question_text = @constCast("Which database?");
    var opts = [_]QuestionOption{
        .{ .label = "Postgres", .description = "prod default" },
        .{ .label = "SQLite" },
    };
    session.question_options = &opts;
    session.question_pending = true;
    session.question_resolved = false;

    const with = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(with);
    try std.testing.expect(std.mem.indexOf(u8, with, "Question:") != null);
    try std.testing.expect(std.mem.indexOf(u8, with, "Which database?") != null);
    try std.testing.expect(std.mem.indexOf(u8, with, "1. Postgres — prod default") != null);
    try std.testing.expect(std.mem.indexOf(u8, with, "2. SQLite") != null);

    // Once resolved, the section disappears.
    session.question_pending = false;
    const without = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(without);
    try std.testing.expect(std.mem.indexOf(u8, without, "Question:") == null);
}

test "ai chat clipboard text exports transcript when input is empty" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "status?"),
        .reasoning = null,
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "ready"),
        .reasoning = try allocator.dupe(u8, "checked state"),
    });

    session.handleKey(.{ .key = input_key.Key.key_a, .ctrl = true });
    try std.testing.expect(session.transcript_select_all);

    const copied = try session.allocClipboardText(allocator);
    defer allocator.free(copied);
    try std.testing.expect(std.mem.indexOf(u8, copied, "You:\r\nstatus?") != null);
    try std.testing.expect(std.mem.indexOf(u8, copied, "AI:\r\nready") != null);
    try std.testing.expect(std.mem.indexOf(u8, copied, "Reasoning:\r\nchecked state") != null);
}

test "ai chat clipboard text prefers selected assistant answer range" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "alpha beta gamma"),
    });

    session.beginTranscriptSelection(0, 6);
    session.updateTranscriptSelection(0, 10);

    const copied = try session.allocClipboardText(allocator);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("beta", copied);

    session.clearSelection();
    try std.testing.expect(session.transcript_selection == null);
}

test "ai chat transcript selection clamps to utf8 boundaries" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "你好吗"),
    });

    session.beginTranscriptSelection(0, 1);
    session.updateTranscriptSelection(0, 8);

    const copied = try session.allocClipboardText(allocator);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("你好", copied);
}

test "ai chat transcript selection copies cleaned markdown text" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "**生成的完整 `Markdown`**"),
    });

    // Display text is "生成的完整 Markdown\n"; select the whole visible run.
    session.beginTranscriptSelection(0, 0);
    session.updateTranscriptSelection(0, "生成的完整 Markdown".len);

    const copied = try session.allocClipboardText(allocator);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("生成的完整 Markdown", copied);
}

test "ai chat transcript selection over table is not truncated to raw length" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "a|b|c\n-|-|-\nd|e|f"),
    });

    // Raw content is 17 bytes; the cleaned display text
    // "a | b | c\nd | e | f\n" is 20 bytes (borderless table: each '|' → " | ").
    // Selecting the whole thing must not truncate the selection to the raw length.
    session.beginTranscriptSelection(0, 0);
    session.updateTranscriptSelection(0, 20);

    const copied = try session.allocClipboardText(allocator);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("a | b | c\nd | e | f\n", copied);
}

test "ai chat message clipboard exports one bubble" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "first"),
        .reasoning = null,
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "second"),
        .reasoning = try allocator.dupe(u8, "not part of the bubble"),
    });

    const copied = try session.allocMessageClipboardText(allocator, 1);
    defer allocator.free(copied);
    try std.testing.expectEqualStrings("second", copied);
}

test "ai chat Markdown export includes full transcript details" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }
    session.copyTitle("Chat Export");
    session.copyModel("model-x");
    session.copySessionId("session-export");

    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "status?"),
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "ready"),
        .reasoning = try allocator.dupe(u8, "checked state"),
        .usage_footer = try allocator.dupe(u8, "total 3"),
    });

    const markdown = try session.allocMarkdownExport(allocator, .full);
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "# Chat Export") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## You\n\nstatus?") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## AI\n\nready") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Thinking") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "checked state") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Usage") != null);
}

test "ai chat clean Markdown export keeps user inputs and final answer only" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }
    session.copyTitle("Clean Export");
    session.copyModel("model-hidden");
    session.copySessionId("session-hidden");

    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "first prompt"),
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "intermediate answer"),
        .reasoning = try allocator.dupe(u8, "hidden thinking"),
    });
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "tool output"),
    });
    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "second prompt"),
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "final answer"),
        .usage_footer = try allocator.dupe(u8, "total 9"),
    });

    const markdown = try session.allocMarkdownExport(allocator, .clean);
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "first prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "second prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "final answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "intermediate answer") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "hidden thinking") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "tool output") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "total 9") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "model-hidden") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "session-hidden") == null);
}

test "ai chat stop request suppresses late assistant result" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    session.request_inflight = true;
    session.stopRequest();
    try std.testing.expect(session.request_stopping);
    try std.testing.expectEqualStrings("Stopping...", session.status());

    appendAssistantResult(&session, .{ .content = @constCast("late result") }, 0);
    try std.testing.expect(!session.request_inflight);
    try std.testing.expect(!session.request_stopping);
    try std.testing.expect(!session.stop_requested.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), session.messages.items.len);
    try std.testing.expectEqualStrings("Stopped", session.status());
}

test "ai chat escape stops in-flight request" {
    var session = Session{ .allocator = std.testing.allocator };
    session.request_inflight = true;

    session.handleKey(.{ .key = input_key.Key.escape });

    try std.testing.expect(session.request_stopping);
    try std.testing.expect(session.stop_requested.load(.acquire));
    try std.testing.expectEqualStrings("Stopping...", session.status());
}

fn testDistillCandidate(allocator: std.mem.Allocator) !ai_skill_distill.Candidate {
    return .{
        .name = try allocator.dupe(u8, "ssh-transfer"),
        .description = try allocator.dupe(u8, "Diagnose SSH transfer failures."),
        .body = try allocator.dupe(u8, "# Steps\n\nRun checks."),
        .source_summary = try allocator.dupe(u8, "Derived from test conversation."),
    };
}

test "ai chat distill cancel clears pending candidate" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        if (session.distill_candidate) |*candidate| candidate.deinit(a);
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    session.distill_candidate = try testDistillCandidate(a);
    session.appendInputText("/distill cancel");

    session.submit();

    try std.testing.expect(session.distill_candidate == null);
    try std.testing.expectEqualStrings("", session.input());
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, session.messages.items[0].content, 1, "discarded"));
}

test "ai chat distill confirm without candidate is local only" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        if (session.distill_candidate) |*candidate| candidate.deinit(a);
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    session.appendInputText("/沉淀 确认");

    session.submit();

    try std.testing.expect(!session.request_inflight);
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, session.messages.items[0].content, 1, "No distill candidate"));
}

test "ai chat appends automatic distill suggestion after tool-heavy result" {
    const a = std.testing.allocator;
    configureAgent(.{ .distill_suggest_enabled = true });
    defer configureAgent(.{});
    var session = Session{ .allocator = a };
    defer {
        if (session.distill_candidate) |*candidate| candidate.deinit(a);
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "fix this") });
    try session.messages.append(a, .{ .role = .tool, .content = try a.dupe(u8, "running exec one"), .persist_to_history = false });
    try session.messages.append(a, .{ .role = .tool, .content = try a.dupe(u8, "running exec two"), .persist_to_history = false });
    session.request_inflight = true;

    appendAssistantResult(&session, .{ .content = @constCast("done") }, 0);

    try std.testing.expect(session.distill_suggestion_pending);
    try std.testing.expectEqual(@as(usize, 5), session.messages.items.len);
    try std.testing.expectEqual(Role.tool, session.messages.items[4].role);
    try std.testing.expect(!session.messages.items[4].persist_to_history);
    try std.testing.expect(std.mem.containsAtLeast(u8, session.messages.items[4].content, 1, "Distill it into a skill"));
}

test "ai chat skips automatic distill suggestion when disabled" {
    const a = std.testing.allocator;
    // Default: ai-distill-suggest is off, so the prompt must not auto-appear
    // even after a tool-heavy turn that the heuristic would otherwise flag.
    configureAgent(.{});
    defer configureAgent(.{});
    var session = Session{ .allocator = a };
    defer {
        if (session.distill_candidate) |*candidate| candidate.deinit(a);
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "fix this") });
    try session.messages.append(a, .{ .role = .tool, .content = try a.dupe(u8, "running exec one"), .persist_to_history = false });
    try session.messages.append(a, .{ .role = .tool, .content = try a.dupe(u8, "running exec two"), .persist_to_history = false });
    session.request_inflight = true;

    appendAssistantResult(&session, .{ .content = @constCast("done") }, 0);

    try std.testing.expect(!session.distill_suggestion_pending);
    // Only the appended assistant message — no extra distill-suggestion tool row.
    try std.testing.expectEqual(@as(usize, 4), session.messages.items.len);
    try std.testing.expectEqual(Role.assistant, session.messages.items[3].role);
}

test "ai chat escape dismisses pending distill suggestion before rewind" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        if (session.distill_candidate) |*candidate| candidate.deinit(a);
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "hi") });
    session.distill_suggestion_pending = true;
    session.now_ms_override = 1000;

    session.handleKey(.{ .key = input_key.Key.escape });

    try std.testing.expect(!session.distill_suggestion_pending);
    try std.testing.expect(!session.rewind_open);
    try std.testing.expectEqual(@as(i64, 0), session.last_esc_ms);
}

test "ai chat enter on pending distill suggestion requires api key and does not send chat" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        if (session.distill_candidate) |*candidate| candidate.deinit(a);
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "fix this") });
    try session.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, "done") });
    session.distill_suggestion_pending = true;

    session.handleKey(.{ .key = input_key.Key.enter });

    try std.testing.expect(!session.request_inflight);
    try std.testing.expect(!session.distill_suggestion_pending);
    try std.testing.expectEqualStrings("Missing API key. Edit the AI Chat profile or set DEEPSEEK_API_KEY.", session.status());
}

test "ai chat rewind point count and index map user messages" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "first") });
    try session.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, "reply-1") });
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "second") });

    try std.testing.expectEqual(@as(usize, 2), session.rewindPointCount());

    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 0), session.rewindPointMessageIndexLocked(0));
    try std.testing.expectEqual(@as(usize, 2), session.rewindPointMessageIndexLocked(1));
}

test "ai chat rewind open requires idle and points" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }

    // 无回溯点：不打开。
    session.openRewindPicker();
    try std.testing.expect(!session.rewind_open);

    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "one") });
    try session.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, "r1") });
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "two") });

    // 生成中：不打开。
    session.request_inflight = true;
    session.openRewindPicker();
    try std.testing.expect(!session.rewind_open);

    // 空闲：打开，默认选中最近一条（序号 count-1）。
    session.request_inflight = false;
    session.openRewindPicker();
    try std.testing.expect(session.rewind_open);
    try std.testing.expectEqual(@as(usize, 1), session.rewind_selected);
}

test "ai chat rewind move selection clamps" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "one") });
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "two") });
    session.openRewindPicker(); // selected = 1
    session.moveRewindSelection(1); // clamp at top
    try std.testing.expectEqual(@as(usize, 1), session.rewind_selected);
    session.moveRewindSelection(-1);
    try std.testing.expectEqual(@as(usize, 0), session.rewind_selected);
    session.moveRewindSelection(-1); // clamp at 0
    try std.testing.expectEqual(@as(usize, 0), session.rewind_selected);
}

test "ai chat confirm rewind truncates and restores composer" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "first prompt") });
    try session.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, "first reply") });
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "second prompt") });
    try session.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, "partial") });

    session.openRewindPicker(); // selected = 1 (最近一条 "second prompt", idx 2)
    session.confirmRewind();

    // 删除 idx 2 及之后：仅剩前两条。
    try std.testing.expectEqual(@as(usize, 2), session.messages.items.len);
    try std.testing.expect(!session.rewind_open);
    try std.testing.expectEqualStrings("second prompt", session.input());

    // 回退到更早一条。
    session.openRewindPicker(); // 现在 count = 1, selected = 0 (idx 0)
    session.moveRewindSelection(-1);
    session.confirmRewind();
    try std.testing.expectEqual(@as(usize, 0), session.messages.items.len);
    try std.testing.expectEqualStrings("first prompt", session.input());
}

test "ai chat request state exposes in-flight stop status for remote layout" {
    var session = Session{ .allocator = std.testing.allocator };
    session.request_inflight = true;
    session.request_stopping = true;

    const state = session.requestState();
    try std.testing.expect(state.inflight);
    try std.testing.expect(state.stopping);
}

test "ai chat collapse helper only closes auto-expanded details" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "running terminal_repl_exec {\"input\":\"ls\"}"),
        .content_collapsed = false,
        .content_auto_expand = true,
    });
    try session.messages.append(allocator, .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "done"),
        .reasoning = try allocator.dupe(u8, "inspect the filesystem first"),
        .reasoning_collapsed = false,
        .reasoning_auto_expand = true,
    });
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "manual"),
        .content_collapsed = false,
        .content_auto_expand = false,
    });

    session.mutex.lock();
    session.collapseAutoExpandedDetailsLocked();
    session.mutex.unlock();

    try std.testing.expect(session.messages.items[0].content_collapsed);
    try std.testing.expect(!session.messages.items[0].content_auto_expand);
    try std.testing.expect(session.messages.items[1].reasoning_collapsed);
    try std.testing.expect(!session.messages.items[1].reasoning_auto_expand);
    try std.testing.expect(!session.messages.items[2].content_collapsed);
}

test "ai chat cut input returns text and clears when selected" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }

    session.appendInputText("hello world");
    session.selectAll(); // sets input_select_all when input is non-empty

    const cut = try session.cutInputSelection(allocator);
    defer if (cut) |c| allocator.free(c);
    try std.testing.expect(cut != null);
    try std.testing.expectEqualStrings("hello world", cut.?);
    try std.testing.expectEqual(@as(usize, 0), session.input_len);

    const cut_again = try session.cutInputSelection(allocator);
    try std.testing.expect(cut_again == null);
}

test "clearMessages empties transcript but keeps settings" {
    const a = std.testing.allocator;
    var session = try Session.init(a, "chat", "https://api.example.com", "key", "m1", "sys", "disabled", "", "false", "false");
    defer session.deinit();
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "hi") });
    try std.testing.expect(session.messages.items.len > 0);

    session.clearMessages();
    try std.testing.expectEqual(@as(usize, 0), session.messages.items.len);
    try std.testing.expectEqualStrings("sys", session.systemPrompt());
    try std.testing.expectEqualStrings("m1", session.model());
}

test "/permission accepts ask auto and full modes" {
    const saved = currentAgentSettings();
    defer configureAgent(saved); // restore global state for other tests
    configureAgent(.{ .permission = .confirm });
    applyPermissionArg("auto");
    try std.testing.expectEqual(AgentPermission.auto, currentAgentSettings().permission);
    applyPermissionArg("full");
    try std.testing.expectEqual(AgentPermission.full, currentAgentSettings().permission);
    applyPermissionArg("ask");
    try std.testing.expectEqual(AgentPermission.confirm, currentAgentSettings().permission);
    applyPermissionArg("bogus"); // invalid → no change
    try std.testing.expectEqual(AgentPermission.confirm, currentAgentSettings().permission);
}

test "ai chat double esc opens rewind picker when idle" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "hi") });

    session.now_ms_override = 1000;
    session.handleKey(.{ .key = input_key.Key.escape }); // 第一次：记录时间
    try std.testing.expect(!session.rewind_open);

    session.now_ms_override = 1000 + DOUBLE_ESC_WINDOW_MS; // 窗口内
    session.handleKey(.{ .key = input_key.Key.escape });
    try std.testing.expect(session.rewind_open);
}

test "ai chat slow double esc does not open rewind picker" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "hi") });

    session.now_ms_override = 1000;
    session.handleKey(.{ .key = input_key.Key.escape });
    session.now_ms_override = 1000 + DOUBLE_ESC_WINDOW_MS + 1; // 超窗口
    session.handleKey(.{ .key = input_key.Key.escape });
    try std.testing.expect(!session.rewind_open);
}

test "ai chat esc during generation only stops and does not open picker" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "hi") });
    session.request_inflight = true;

    session.now_ms_override = 1000;
    session.handleKey(.{ .key = input_key.Key.escape });
    session.now_ms_override = 1100;
    session.handleKey(.{ .key = input_key.Key.escape });
    try std.testing.expect(!session.rewind_open);
    try std.testing.expect(session.request_stopping);
}

// The picker renders recent prompts first, so Down moves visually down to older
// prompts and Up moves visually up toward newer prompts.
test "ai chat rewind picker arrow and enter via handleKey" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "alpha") });
    try session.messages.append(a, .{ .role = .assistant, .content = try a.dupe(u8, "ra") });
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "beta") });

    session.openRewindPicker(); // selected = 1 ("beta")
    session.handleKey(.{ .key = input_key.Key.arrow_down }); // visually down -> 0 ("alpha")
    try std.testing.expectEqual(@as(usize, 0), session.rewind_selected);
    session.handleKey(.{ .key = input_key.Key.enter });
    try std.testing.expect(!session.rewind_open);
    try std.testing.expectEqual(@as(usize, 0), session.messages.items.len);
    try std.testing.expectEqualStrings("alpha", session.input());
}

test "ai chat rewind picker esc closes without change" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "keep") });
    session.openRewindPicker();
    session.handleKey(.{ .key = input_key.Key.escape });
    try std.testing.expect(!session.rewind_open);
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
}

// 清选区是独立动作、不计入双击计时：ESC 清选区后需要重新双击才开选择器。
test "ai chat esc clearing selection does not prime rewind double-tap" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "hi") });
    session.transcript_select_all = true; // 制造一个选区

    session.now_ms_override = 1000;
    session.handleKey(.{ .key = input_key.Key.escape }); // 清选区，不计时
    try std.testing.expect(!session.transcript_select_all);
    try std.testing.expectEqual(@as(i64, 0), session.last_esc_ms);

    session.now_ms_override = 1100;
    session.handleKey(.{ .key = input_key.Key.escape }); // 仅 arming，不开
    try std.testing.expect(!session.rewind_open);

    session.now_ms_override = 1200;
    session.handleKey(.{ .key = input_key.Key.escape }); // 窗口内 → 打开
    try std.testing.expect(session.rewind_open);
}

// 生成中的 ESC 不作为双击起点：停止后变空闲，需要重新双击才开选择器。
test "ai chat double esc after stop opens rewind picker" {
    const a = std.testing.allocator;
    var session = Session{ .allocator = a };
    defer {
        for (session.messages.items) |msg| msg.deinit(a);
        session.messages.deinit(a);
    }
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "hi") });

    session.request_inflight = true;
    session.now_ms_override = 1000;
    session.handleKey(.{ .key = input_key.Key.escape }); // 停止；last_esc_ms 归零
    try std.testing.expectEqual(@as(i64, 0), session.last_esc_ms);

    session.request_inflight = false; // 模拟已停止变空闲
    session.now_ms_override = 1100;
    session.handleKey(.{ .key = input_key.Key.escape }); // arming，不开
    try std.testing.expect(!session.rewind_open);
    session.now_ms_override = 1200;
    session.handleKey(.{ .key = input_key.Key.escape }); // 窗口内 → 打开
    try std.testing.expect(session.rewind_open);
}

// ---------------------------------------------------------------------------
// Request-layer tests that need private Session methods (buildRequestLocked,
// assignSessionId, copyTitle, copyBaseUrl, copyApiKey, copyModel,
// copySystemPrompt, copyReasoningEffort).  They are co-located here so those
// methods can remain private.  The request-serialization helpers they exercise
// (buildRequestJson / buildRequestJsonForMessages) are pub on ai_chat_request.
// ---------------------------------------------------------------------------

test "ai chat agent request json includes stable skill_info tool schema" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Test",
        DEFAULT_BASE_URL,
        "test-key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    session.mutex.lock();
    try session.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "hello") });
    const request = try session.buildRequestLocked();
    session.mutex.unlock();
    defer request.deinit();

    const json = try ai_chat_request.buildRequestJson(allocator, request);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"skill_info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "skill_name") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pdf") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\u0070df") == null);
}

test "ai chat session request owns dynamic tool specs snapshot" {
    const allocator = std.testing.allocator;
    const saved_settings = currentAgentSettings();
    const saved_dynamic_specs = g_dynamic_tool_specs;
    const saved_dynamic_specs_owned = g_dynamic_tool_specs_owned;
    defer {
        configureAgent(saved_settings);
        g_dynamic_tool_specs = saved_dynamic_specs;
        g_dynamic_tool_specs_owned = saved_dynamic_specs_owned;
    }

    const name = try allocator.dupe(u8, "agent_docx_review");
    defer allocator.free(name);
    const description = try allocator.dupe(u8, "Use for DOCX tracked-change review.");
    defer allocator.free(description);
    var specs = [_]ai_chat_protocol.DynamicToolSpec{.{
        .name = name,
        .description = description,
    }};
    setDynamicToolSpecsForTest(specs[0..]);
    configureAgent(.{ .enabled = true });

    const session = try Session.init(
        allocator,
        "Test",
        DEFAULT_BASE_URL,
        "test-key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    session.mutex.lock();
    try session.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "hello") });
    const request = try session.buildRequestLocked();
    session.mutex.unlock();
    defer request.deinit();

    @memcpy(name, "agent_xlsx_review");
    setDynamicToolSpecsForTest(&.{});

    const json = try ai_chat_request.buildRequestJson(allocator, request);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"agent_docx_review\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"agent_xlsx_review\"") == null);
}

test "ai chat session request owns dynamic binary runtime snapshot" {
    const allocator = std.testing.allocator;
    const saved_settings = currentAgentSettings();
    const saved_dynamic_runtime = g_dynamic_binary_tools;
    const saved_dynamic_runtime_owned = g_dynamic_binary_tools_owned;
    defer {
        configureAgent(saved_settings);
        g_dynamic_binary_tools = saved_dynamic_runtime;
        g_dynamic_binary_tools_owned = saved_dynamic_runtime_owned;
    }

    const function_name = try allocator.dupe(u8, "fake_tool");
    defer allocator.free(function_name);
    const executable_text = if (builtin.os.tag == .windows) "cmd.exe" else "/bin/echo";
    const executable_abs = try allocator.dupe(u8, executable_text);
    defer allocator.free(executable_abs);
    const description = try allocator.dupe(u8, "Echo test");
    defer allocator.free(description);
    var runtime = [_]ai_chat_types.DynamicBinaryTool{.{
        .function_name = function_name,
        .executable_abs = executable_abs,
        .description = description,
    }};
    setDynamicBinaryToolsForTest(runtime[0..]);
    configureAgent(.{ .enabled = true, .permission = .full });

    const session = try Session.init(
        allocator,
        "Test",
        DEFAULT_BASE_URL,
        "test-key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    session.mutex.lock();
    try session.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "hello") });
    const request = try session.buildRequestLocked();
    session.mutex.unlock();
    defer request.deinit();

    @memcpy(function_name, "gone_tool");
    setDynamicBinaryToolsForTest(&.{});

    try std.testing.expectEqual(@as(usize, 1), request.dynamic_binary_tools.len);
    try std.testing.expectEqualStrings("fake_tool", request.dynamic_binary_tools[0].function_name);
    try std.testing.expectEqualStrings(executable_text, request.dynamic_binary_tools[0].executable_abs);
}

const CopilotBoundSnapshotTestHost = struct {
    fn collectSnapshot(_: *anyopaque, allocator: std.mem.Allocator) anyerror!ai_chat_types.ToolSnapshot {
        const surfaces = try allocator.alloc(ai_chat_types.ToolSurface, 1);
        errdefer allocator.free(surfaces);
        surfaces[0] = .{
            .id = try allocator.dupe(u8, "surface-1"),
            .title = try allocator.dupe(u8, "shell"),
            .cwd = try allocator.dupe(u8, "/home/tester/work"),
            .snapshot = try allocator.dupe(u8, "$ ls\nalpha.txt\nbeta.txt\n$ cat beta.txt\nUNIQUE_OUTPUT_LINE\n"),
            .tab_index = 0,
            .focused = true,
            .is_ssh = false,
            .is_wsl = false,
            .ptr = undefined,
        };
        return .{ .surfaces = surfaces, .active_tab = 0 };
    }
    fn unsupportedSurfaceSnapshot(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: *anyopaque) anyerror![]u8 {
        return error.Unsupported;
    }
    fn unsupportedWrite(_: *anyopaque, _: []const u8, _: *anyopaque, _: []const u8) bool {
        return false;
    }
    fn unsupportedSpawn(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: ?[]const u8) anyerror!ai_chat_types.ToolSurface {
        return error.Unsupported;
    }
    fn unsupportedClose(_: *anyopaque, _: std.mem.Allocator, _: ?usize, _: ?[]const u8, _: ?[]const u8) anyerror!ai_chat_types.ToolClosedTab {
        return error.Unsupported;
    }
    fn unsupportedSaveSsh(_: *anyopaque, _: std.mem.Allocator, _: ai_chat_types.SshProfileSaveArgs) anyerror!ai_chat_types.SavedSshProfile {
        return error.Unsupported;
    }
    fn unsupportedConnectSsh(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!ai_chat_types.ToolSurface {
        return error.Unsupported;
    }

    var ctx_sentinel: u8 = 0;

    fn host() ai_chat_types.ToolHost {
        return .{
            .ctx = @ptrCast(&ctx_sentinel),
            .collectSnapshot = collectSnapshot,
            .surfaceSnapshot = unsupportedSurfaceSnapshot,
            .writeSurface = unsupportedWrite,
            .spawnTab = unsupportedSpawn,
            .closeTab = unsupportedClose,
            .saveSshProfile = unsupportedSaveSsh,
            .connectSshProfile = unsupportedConnectSsh,
        };
    }
};

test "copilot request appends bound-terminal snapshot to latest user message" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Test",
        DEFAULT_BASE_URL,
        "test-key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    session.copilot = true;
    session.setBoundSurface("surface-1");

    setToolHost(CopilotBoundSnapshotTestHost.host());
    defer setToolHost(null);

    session.mutex.lock();
    try session.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "what files are here?") });
    const request = try session.buildRequestLocked();
    session.mutex.unlock();
    defer request.deinit();

    try std.testing.expect(request.messages.len == 1);
    const user_content = request.messages[0].content;
    // Original user text is preserved.
    try std.testing.expect(std.mem.indexOf(u8, user_content, "what files are here?") != null);
    // Snapshot block is appended: cwd + recent output line.
    try std.testing.expect(std.mem.indexOf(u8, user_content, "cwd: /home/tester/work") != null);
    try std.testing.expect(std.mem.indexOf(u8, user_content, "UNIQUE_OUTPUT_LINE") != null);
}

test "ai chat request json replays durable tool messages and skips progress tools" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Test",
        DEFAULT_BASE_URL,
        "test-key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    session.mutex.lock();
    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "Use the skill."),
    });
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "# Skill: pdf"),
        .tool_call_id = try allocator.dupe(u8, "skill-preload-pdf"),
        .tool_name = try allocator.dupe(u8, "skill_info"),
        .replay_to_model = true,
    });
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "running terminal_list {}"),
        .replay_to_model = false,
    });
    const request = try session.buildRequestLocked();
    session.mutex.unlock();
    defer request.deinit();

    const json = try ai_chat_request.buildRequestJsonForMessages(allocator, request, request.messages, true);
    defer allocator.free(json);

    const assistant_tool_call =
        \\{"role":"assistant","content":"","tool_calls":[{"id":"skill-preload-pdf","type":"function","function":{"name":"skill_info","arguments":"{}"}}],"reasoning_content":"Tool call is required before answering."}
    ;
    const tool_result =
        \\{"role":"tool","content":"# Skill: pdf","tool_call_id":"skill-preload-pdf"}
    ;
    const assistant_index = std.mem.indexOf(u8, json, assistant_tool_call) orelse return error.MissingAssistantToolCall;
    const tool_index = std.mem.indexOf(u8, json, tool_result) orelse return error.MissingToolResult;
    try std.testing.expect(assistant_index < tool_index);
    try std.testing.expect(std.mem.indexOf(u8, json, "running terminal_list") == null);
}

test "ai chat request skips replayable tool messages missing identity" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Test",
        DEFAULT_BASE_URL,
        "test-key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    session.mutex.lock();
    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "Use the skill."),
    });
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "# Skill without metadata"),
        .replay_to_model = true,
    });
    const request = try session.buildRequestLocked();
    session.mutex.unlock();
    defer request.deinit();

    try std.testing.expectEqual(@as(usize, 1), request.messages.len);

    const json = try ai_chat_request.buildRequestJsonForMessages(allocator, request, request.messages, true);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "# Skill without metadata") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"tool\"") == null);
}

test "ai chat request setup cleans scalar fields on allocation failure" {
    const allocator = std.testing.allocator;

    var saw_oom = false;
    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var failing_allocator = std.testing.FailingAllocator.init(allocator, .{
            .fail_index = fail_index,
        });

        var session = Session{ .allocator = failing_allocator.allocator() };
        session.assignSessionId();
        session.copyTitle("Test");
        session.copyBaseUrl(DEFAULT_BASE_URL);
        session.copyApiKey("test-key");
        session.copyModel(DEFAULT_MODEL);
        session.copySystemPrompt(DEFAULT_SYSTEM_PROMPT);
        session.copyReasoningEffort(DEFAULT_REASONING_EFFORT);

        const result = session.buildRequestLocked();
        if (result) |request| {
            request.deinit();
            if (!failing_allocator.has_induced_failure) break;
        } else |err| switch (err) {
            error.OutOfMemory => saw_oom = true,
            else => return err,
        }
    }

    try std.testing.expect(saw_oom);
}

test "copilot session pre-targets the bound surface in its request" {
    const session = try Session.init(
        std.testing.allocator,
        "copilot",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
        "",
    );
    defer session.deinit();
    session.copilot = true;
    session.setBoundSurface("abc123");

    const req = try session.buildRequestLocked();
    defer req.deinit();

    try std.testing.expectEqualStrings("abc123", req.write_context_surface_id[0..req.write_context_surface_id_len]);
}

test "setDefaultWorkingDir is reflected in currentAgentSettings" {
    setDefaultWorkingDir("/tmp/proj");
    defer setDefaultWorkingDir(""); // reset global state for other tests
    try std.testing.expectEqualStrings("/tmp/proj", currentAgentSettings().working_dir.?);
    setDefaultWorkingDir("");
    try std.testing.expect(currentAgentSettings().working_dir == null);
}

test "submitScheduledPrompt sets composer and reports busy state" {
    const a = std.testing.allocator;
    const session = try Session.init(a, "test", "", "", "", "", "", "", "", "");
    defer session.deinit();

    // Not inflight: returns true and submit is invoked (no agent configured, no-ops).
    const ok = session.submitScheduledPrompt("hello world");
    try std.testing.expect(ok);

    // Inflight: returns false (skip).
    session.request_inflight = true;
    const skipped = session.submitScheduledPrompt("again");
    try std.testing.expect(!skipped);
    session.request_inflight = false;
}

test "applyWeixinInput submits the whole multi-line message as one prompt" {
    const a = std.testing.allocator;
    const session = try Session.init(a, "test", "", "", "", "", "", "", "", "");
    defer session.deinit();

    var capture = WeixinAttachmentCapture{};
    const ctx = weixin_types.ReplyContext{
        .sender = testWeixinSender(&capture),
        .to_user_id = "wx-user",
        .context_token = "ctx-1",
    };

    // A WeChat message is a complete message, not a keystroke stream: embedded
    // newlines are content, only the trailing CR is the submit convention. With
    // no API key submit() stops at the missing-key gate WITHOUT consuming the
    // composer, so the composer shows exactly what the single submit sent.
    try std.testing.expect(session.applyWeixinInput("第一段\n\n第二段\r", ctx));
    try std.testing.expectEqualStrings("第一段\n\n第二段", session.input());
}

test "applyWeixinInput reports busy and leaves composer and reply context untouched" {
    const a = std.testing.allocator;
    const session = try Session.init(a, "test", "", "", "", "", "", "", "", "");
    defer session.deinit();

    var capture = WeixinAttachmentCapture{};
    const ctx = weixin_types.ReplyContext{
        .sender = testWeixinSender(&capture),
        .to_user_id = "wx-user",
        .context_token = "ctx-1",
    };

    session.appendInputText("draft");
    session.request_inflight = true;
    try std.testing.expect(!session.applyWeixinInput("新任务\r", ctx));
    session.request_inflight = false;
    try std.testing.expectEqualStrings("draft", session.input());
    try std.testing.expect(session.pending_weixin_reply_context == null);
}

test "runLoopCommandLocked creates, lists, and stops a loop task" {
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    const path = try std.fs.path.join(a, &.{ dir_path, "loop_tasks.json" });
    defer a.free(path);

    var store = ai_loop_store.Store.init(a, path);
    defer store.deinit();
    ai_loop_store.setActive(&store);
    defer ai_loop_store.clearActive();

    const session = try Session.init(a, "test", "", "", "", "", "", "", "", "");
    defer session.deinit();
    session.copySessionId("session-test");

    session.mutex.lock();
    _ = session.runBuiltinCommandLocked(.loop, "30m 3 hello");
    session.mutex.unlock();

    const snap = try store.snapshotForSession(a, "session-test", .loop);
    defer ai_loop_store.freeSnapshot(a, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqualStrings("hello", snap[0].prompt);

    session.mutex.lock();
    _ = session.runBuiltinCommandLocked(.loop, "stop 1");
    session.mutex.unlock();
    const snap2 = try store.snapshotForSession(a, "session-test", .loop);
    defer ai_loop_store.freeSnapshot(a, snap2);
    try std.testing.expectEqual(@as(usize, 0), snap2.len);
}

test "copilot loop command lists and stops tasks from other sessions" {
    const a = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    const path = try std.fs.path.join(a, &.{ dir_path, "loop_tasks.json" });
    defer a.free(path);

    var store = ai_loop_store.Store.init(a, path);
    defer store.deinit();
    ai_loop_store.setActive(&store);
    defer ai_loop_store.clearActive();

    _ = try store.registerLoop(
        "30m 3 legacy copilot task",
        .{ .session_id = "old-copilot-session", .model = "model", .title = "Old Copilot" },
        1000,
        0,
    );

    const copilot = try Session.init(a, "Copilot", "", "", "", "", "", "", "", "");
    defer copilot.deinit();
    copilot.copilot = true;
    copilot.copySessionId("new-copilot-session");

    copilot.mutex.lock();
    _ = copilot.runBuiltinCommandLocked(.loop, "all");
    copilot.mutex.unlock();

    try std.testing.expect(copilot.messages.items.len > 0);
    const list_msg = copilot.messages.items[copilot.messages.items.len - 1].content;
    try std.testing.expect(std.mem.indexOf(u8, list_msg, "legacy copilot task") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_msg, "Old Copilot") != null);

    copilot.mutex.lock();
    _ = copilot.runBuiltinCommandLocked(.loop, "stop 1");
    copilot.mutex.unlock();

    const remaining = try store.snapshotForSession(a, "old-copilot-session", .loop);
    defer ai_loop_store.freeSnapshot(a, remaining);
    try std.testing.expectEqual(@as(usize, 0), remaining.len);
}

fn testSubagentResolver(allocator: std.mem.Allocator) ?SubagentProfileOverride {
    const base_url = allocator.dupe(u8, "https://sub.example") catch return null;
    const api_key = allocator.dupe(u8, "sub-key") catch {
        allocator.free(base_url);
        return null;
    };
    const model = allocator.dupe(u8, "sub-model") catch {
        allocator.free(base_url);
        allocator.free(api_key);
        return null;
    };
    const reasoning_effort = allocator.dupe(u8, "low") catch {
        allocator.free(base_url);
        allocator.free(api_key);
        allocator.free(model);
        return null;
    };
    return .{
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
        .protocol = .chat_completions,
        .thinking_enabled = false,
        .reasoning_effort = reasoning_effort,
        .max_tokens = 4096,
    };
}

test "resolveSubagentProfileForRequest gates on resolver and agent flag" {
    const a = std.testing.allocator;
    setSubagentProfileResolver(null);
    try std.testing.expect(resolveSubagentProfileForRequest(a, true) == null);

    setSubagentProfileResolver(testSubagentResolver);
    defer setSubagentProfileResolver(null);
    try std.testing.expect(resolveSubagentProfileForRequest(a, false) == null);

    const override = resolveSubagentProfileForRequest(a, true) orelse return error.TestUnexpectedResult;
    defer override.deinit(a);
    try std.testing.expectEqualStrings("https://sub.example", override.base_url);
    try std.testing.expectEqualStrings("sub-model", override.model);
}

test "ChatRequest deinit frees the subagent profile override" {
    const a = std.testing.allocator;
    var session = try Session.init(a, "test", "https://api.example", "key", "model", "prompt", "enabled", "medium", "false", "true");
    defer session.deinit();

    const request = try a.create(ChatRequest);
    request.* = .{
        .allocator = a,
        .session = session,
        .base_url = try a.dupe(u8, "https://api.example"),
        .api_key = try a.dupe(u8, "key"),
        .model = try a.dupe(u8, "model"),
        .system_prompt = try a.dupe(u8, "prompt"),
        .messages = &.{},
        .thinking_enabled = false,
        .reasoning_effort = try a.dupe(u8, "medium"),
        .stream = false,
        .agent_enabled = true,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
        .subagent_profile = testSubagentResolver(a),
    };
    request.deinit();
    // std.testing.allocator fails the test on leak — nothing else to assert.
}

test "composeSystemPromptWithMemory appends the index block when enabled" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const dirs_mod = @import("platform/dirs.zig");
    dirs_mod.setTestConfigDirForCurrentThread(root);
    defer dirs_mod.clearTestConfigDirForCurrentThread();
    const am = @import("agent_memory.zig");
    const m = try am.saveMemory(a, .global, null, "k1", "v1", .user, "body");
    a.free(m);

    const with = try composeSystemPromptWithMemory(a, "BASE", true, "");
    defer a.free(with);
    try std.testing.expect(std.mem.startsWith(u8, with, "BASE"));
    try std.testing.expect(std.mem.indexOf(u8, with, "k1: v1") != null);

    const without = try composeSystemPromptWithMemory(a, "BASE", false, "");
    defer a.free(without);
    try std.testing.expectEqualStrings("BASE", without);
}

test "is_context_summary messages are collapsible" {
    var session = try Session.initWithVision(std.testing.allocator, "T", "https://x", "k", "m", "chat_completions", "sp", "enabled", "low", "false", "false", "false");
    defer session.deinit();
    const content = try std.testing.allocator.dupe(u8, "summary body");
    try session.messages.append(std.testing.allocator, .{
        .role = .user,
        .content = content,
        .is_context_summary = true,
        .content_collapsed = true,
    });
    try std.testing.expect(session.messages.items[0].content_collapsed);
    session.toggleToolMessageCollapsed(0);
    try std.testing.expect(!session.messages.items[0].content_collapsed);
}

test "applySummaryResult collapses pre-switch messages into one summary card" {
    var session = try Session.initWithVision(std.testing.allocator, "T", "https://x", "k", "m", "chat_completions", "sp", "enabled", "low", "false", "false", "false");
    defer session.deinit();
    inline for (.{ "u1", "a1", "u2" }) |t| {
        try session.messages.append(std.testing.allocator, .{
            .role = .user,
            .content = try std.testing.allocator.dupe(u8, t),
        });
    }
    // boundary = 2 means: collapse the first 2 messages, preserve message[2..].
    applySummaryResult(session, "SUMMARY", 2, "glm-5.2");
    try std.testing.expectEqual(@as(usize, 2), session.messages.items.len);
    try std.testing.expect(session.messages.items[0].is_context_summary);
    try std.testing.expectEqual(Role.user, session.messages.items[0].role);
    try std.testing.expect(std.mem.indexOf(u8, session.messages.items[0].content, "SUMMARY") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.messages.items[0].content, "glm-5.2") != null);
    try std.testing.expectEqualStrings("u2", session.messages.items[1].content);
}

test "applySummaryResult is a no-op when boundary exceeds message count" {
    var session = try Session.initWithVision(std.testing.allocator, "T", "https://x", "k", "m", "chat_completions", "sp", "enabled", "low", "false", "false", "false");
    defer session.deinit();
    try session.messages.append(std.testing.allocator, .{ .role = .user, .content = try std.testing.allocator.dupe(u8, "only") });
    applySummaryResult(session, "S", 5, "X"); // stale boundary (e.g. after /clear)
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    try std.testing.expectEqualStrings("only", session.messages.items[0].content);
}

const AskRunner = struct {
    session: *Session,
    question: []const u8,
    options: []const QuestionOption,
    result: AskResult = .cancelled,

    fn run(self: *AskRunner) void {
        self.result = self.session.askUser(self.question, self.options);
    }
};

fn waitForQuestion(session: *Session) void {
    while (session.questionView() == null) {
        std.Thread.yield() catch {};
    }
}

test "askUser blocks until an option is selected, then clears the question" {
    var session = try Session.init(std.testing.allocator, "chat", "https://api.example.com", "key", "m1", "sys", "false", "", "false", "false");
    defer session.deinit();

    var runner = AskRunner{ .session = session, .question = "Pick one", .options = &.{
        .{ .label = "A" },
        .{ .label = "B", .description = "bee" },
    } };
    var thread = try std.Thread.spawn(.{}, AskRunner.run, .{&runner});
    waitForQuestion(session);

    // The view reflects the pending question while blocked.
    const view = session.questionView().?;
    try std.testing.expectEqualStrings("Pick one", view.question);
    try std.testing.expectEqual(@as(usize, 2), view.options.len);
    try std.testing.expectEqualStrings("bee", view.options[1].description);

    try std.testing.expect(session.resolveQuestionOption(1));
    thread.join();

    try std.testing.expect(runner.result == .option_index);
    try std.testing.expectEqual(@as(usize, 1), runner.result.option_index);
    try std.testing.expect(session.questionView() == null); // cleared on resolve
}

test "askUser returns a free-text custom answer" {
    var session = try Session.init(std.testing.allocator, "chat", "https://api.example.com", "key", "m1", "sys", "false", "", "false", "false");
    defer session.deinit();

    var runner = AskRunner{ .session = session, .question = "Which DB?", .options = &.{
        .{ .label = "Postgres" },
        .{ .label = "SQLite" },
    } };
    var thread = try std.Thread.spawn(.{}, AskRunner.run, .{&runner});
    waitForQuestion(session);

    try std.testing.expect(session.resolveQuestionCustom("用 DuckDB"));
    thread.join();

    try std.testing.expect(runner.result == .custom);
    try std.testing.expectEqualStrings("用 DuckDB", runner.result.custom);
}

test "askUser returns cancelled when the request is stopped" {
    var session = try Session.init(std.testing.allocator, "chat", "https://api.example.com", "key", "m1", "sys", "false", "", "false", "false");
    defer session.deinit();

    var runner = AskRunner{ .session = session, .question = "Pick one", .options = &.{
        .{ .label = "A" },
        .{ .label = "B" },
    } };
    var thread = try std.Thread.spawn(.{}, AskRunner.run, .{&runner});
    waitForQuestion(session);

    session.stopRequest();
    thread.join();

    try std.testing.expect(runner.result == .cancelled);
}

test "resolveQuestionOption out of range leaves the question pending" {
    var session = try Session.init(std.testing.allocator, "chat", "https://api.example.com", "key", "m1", "sys", "false", "", "false", "false");
    defer session.deinit();

    var runner = AskRunner{ .session = session, .question = "Pick one", .options = &.{
        .{ .label = "A" },
        .{ .label = "B" },
    } };
    var thread = try std.Thread.spawn(.{}, AskRunner.run, .{&runner});
    waitForQuestion(session);

    try std.testing.expect(!session.resolveQuestionOption(5)); // beyond 2 options
    try std.testing.expect(session.questionView() != null); // still pending

    try std.testing.expect(session.resolveQuestionOption(0)); // clean up
    thread.join();
    try std.testing.expect(runner.result == .option_index);
    try std.testing.expectEqual(@as(usize, 0), runner.result.option_index);
}

test "composer submit of a digit answers a pending question as that option" {
    var session = try Session.init(std.testing.allocator, "chat", "https://api.example.com", "key", "m1", "sys", "false", "", "false", "false");
    defer session.deinit();

    var runner = AskRunner{ .session = session, .question = "Pick one", .options = &.{
        .{ .label = "A" },
        .{ .label = "B" },
    } };
    var thread = try std.Thread.spawn(.{}, AskRunner.run, .{&runner});
    waitForQuestion(session);

    session.appendInputText("2");
    session.submit();
    thread.join();

    try std.testing.expect(runner.result == .option_index);
    try std.testing.expectEqual(@as(usize, 1), runner.result.option_index);
    try std.testing.expect(session.questionView() == null);
    try std.testing.expectEqual(@as(usize, 0), session.input().len); // composer cleared
}

test "composer submit of free text answers a pending question as custom" {
    var session = try Session.init(std.testing.allocator, "chat", "https://api.example.com", "key", "m1", "sys", "false", "", "false", "false");
    defer session.deinit();

    var runner = AskRunner{ .session = session, .question = "Pick one", .options = &.{
        .{ .label = "A" },
        .{ .label = "B" },
    } };
    var thread = try std.Thread.spawn(.{}, AskRunner.run, .{&runner});
    waitForQuestion(session);

    session.appendInputText("neither, use C");
    session.submit();
    thread.join();

    try std.testing.expect(runner.result == .custom);
    try std.testing.expectEqualStrings("neither, use C", runner.result.custom);
}

test "copilot flag survives toHistoryRecord -> initFromHistoryRecord round-trip" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator, "Copilot", "https://x", "k", "m",
        "sys", "disabled", "low", "true", "true",
    );
    defer session.deinit();
    session.copilot = true;

    var record = try session.toHistoryRecord(allocator);
    defer agent_history.freeOwnedRecord(allocator, &record);
    try std.testing.expect(record.copilot);

    const restored = try Session.initFromHistoryRecord(allocator, record);
    defer restored.deinit();
    try std.testing.expect(restored.copilot);
}

test "shouldPersistCopilot is false for empty session, true after a real message" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator, "Copilot", "https://x", "k", "m",
        "sys", "disabled", "low", "true", "true",
    );
    defer session.deinit();
    try std.testing.expect(!session.shouldPersistCopilot());

    {
        session.mutex.lock();
        defer session.mutex.unlock();
        try session.messages.append(allocator, .{
            .role = .user,
            .content = try allocator.dupe(u8, "hello"),
        });
    }
    try std.testing.expect(session.shouldPersistCopilot());
}
