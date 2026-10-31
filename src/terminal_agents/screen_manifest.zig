//! Screen-detection manifests: classify a terminal agent's live screen as
//! idle / working / blocked from declarative rules. Pure: depends only on
//! `std` and the sibling `manifest_toml` / `screen_regex` / `detector` modules.
//!
//! The rule files under `manifests/` are herdr's (Apache-2.0, see
//! `manifests/README.md`) and are embedded verbatim, so the engine here keeps
//! herdr's semantics exactly:
//!
//!   - A manifest has `[[rules]]`; each names a `state`, a `priority`, a
//!     `region` of the input to look at, and a gate of matchers.
//!   - Gate = `contains` (case-insensitive substrings, all must hit) AND
//!     `regex` (all must match) AND `line_regex` (each must match some line)
//!     AND every `all` child AND (any `any` child, if `any` is non-empty) AND
//!     no `not` child.
//!   - Rules are evaluated in file order; the first rule with the highest
//!     priority that matches wins. A known agent with no matching rule is
//!     `idle` (the "default known-agent idle fallback").
//!   - `visible_*` flags say the matched rule saw live UI chrome, not just
//!     prompt-like text in scrollback. `skip_state_update` marks viewer /
//!     overlay screens whose state must not be trusted.
//!   - `osc_title` / `osc_progress` regions read the terminal title and the
//!     OSC 9;4 progress string instead of the screen.
//!
//! Only the viewport should be passed as `screen` (herdr reads the "live
//! bottom buffer", never the part the user scrolled to).

const std = @import("std");
const toml = @import("manifest_toml.zig");
const rx = @import("screen_regex.zig");
const detector = @import("detector.zig");

pub const App = detector.App;

/// Highest `min_engine_version` this engine accepts (herdr's current value).
pub const engine_version: u32 = 3;
const top_non_empty_lines_engine_version: u32 = 3;

const max_rules_per_manifest: usize = 128;
const max_gate_depth: usize = 8;
const max_total_gates: usize = 512;
const max_matchers_per_gate: usize = 32;
const max_total_matchers: usize = 1024;
const max_matcher_chars: usize = 512;
const max_top_region_line_count: usize = std.math.maxInt(u16);

/// Upper bound on screen lines considered per evaluation. The viewport is far
/// smaller; a longer input keeps only its last `max_lines` lines.
pub const max_lines: usize = 1024;

pub const State = enum {
    idle,
    working,
    blocked,
    unknown,

    pub fn label(self: State) []const u8 {
        return switch (self) {
            .idle => "idle",
            .working => "working",
            .blocked => "blocked",
            .unknown => "unknown",
        };
    }

    fn fromLabel(s: []const u8) ?State {
        inline for (std.meta.fields(State)) |f| {
            const st: State = @enumFromInt(f.value);
            if (std.mem.eql(u8, s, st.label())) return st;
        }
        return null;
    }
};

pub const Region = union(enum) {
    whole_recent,
    after_last_prompt_marker,
    before_current_prompt_marker,
    whole_recent_without_current_prompt_marker,
    current_prompt_block_marker,
    after_current_prompt_block_marker,
    prompt_box_body,
    above_prompt_box,
    last_non_empty_above_prompt_box,
    after_last_horizontal_rule,
    osc_title,
    osc_progress,
    bottom_lines: usize,
    bottom_non_empty_lines: usize,
    top_non_empty_lines: usize,

    /// Parse a region spec as written in a manifest (surrounding whitespace is
    /// ignored, like herdr). Null for unknown names or malformed counts.
    pub fn parse(spec_raw: []const u8) ?Region {
        const spec = std.mem.trim(u8, spec_raw, " \t\r\n");
        const names = [_]struct { name: []const u8, region: Region }{
            .{ .name = "whole_recent", .region = .whole_recent },
            .{ .name = "after_last_prompt_marker", .region = .after_last_prompt_marker },
            .{ .name = "before_current_prompt_marker", .region = .before_current_prompt_marker },
            .{ .name = "whole_recent_without_current_prompt_marker", .region = .whole_recent_without_current_prompt_marker },
            .{ .name = "current_prompt_block_marker", .region = .current_prompt_block_marker },
            .{ .name = "after_current_prompt_block_marker", .region = .after_current_prompt_block_marker },
            .{ .name = "prompt_box_body", .region = .prompt_box_body },
            .{ .name = "above_prompt_box", .region = .above_prompt_box },
            .{ .name = "last_non_empty_above_prompt_box", .region = .last_non_empty_above_prompt_box },
            .{ .name = "after_last_horizontal_rule", .region = .after_last_horizontal_rule },
            .{ .name = "osc_title", .region = .osc_title },
            .{ .name = "osc_progress", .region = .osc_progress },
        };
        for (names) |n| if (std.mem.eql(u8, spec, n.name)) return n.region;
        if (countedRegion(spec, "bottom_lines")) |n| return .{ .bottom_lines = n };
        if (countedRegion(spec, "bottom_non_empty_lines")) |n| return .{ .bottom_non_empty_lines = n };
        if (topRegionCount(spec)) |n| return .{ .top_non_empty_lines = n };
        return null;
    }

    /// `name(N)` with Rust `usize::from_str` leniency (leading zeros, `+`).
    fn countedRegion(spec: []const u8, name: []const u8) ?usize {
        if (!std.mem.startsWith(u8, spec, name)) return null;
        var rest = spec[name.len..];
        if (!std.mem.startsWith(u8, rest, "(") or !std.mem.endsWith(u8, rest, ")")) return null;
        rest = rest[1 .. rest.len - 1];
        if (std.mem.startsWith(u8, rest, "+")) rest = rest[1..];
        if (rest.len == 0) return null;
        for (rest) |c| if (!std.ascii.isDigit(c)) return null;
        return std.fmt.parseInt(usize, rest, 10) catch null;
    }

    /// `top_non_empty_lines(N)`: canonical positive decimal, no leading zero,
    /// bounded (herdr validates this one strictly).
    fn topRegionCount(spec: []const u8) ?usize {
        const name = "top_non_empty_lines";
        if (!std.mem.startsWith(u8, spec, name)) return null;
        var rest = spec[name.len..];
        if (!std.mem.startsWith(u8, rest, "(") or !std.mem.endsWith(u8, rest, ")")) return null;
        rest = rest[1 .. rest.len - 1];
        if (rest.len == 0 or rest[0] == '0') return null;
        for (rest) |c| if (!std.ascii.isDigit(c)) return null;
        const n = std.fmt.parseInt(usize, rest, 10) catch return null;
        return if (n <= max_top_region_line_count) n else null;
    }

    pub fn isTop(self: Region) bool {
        return self == .top_non_empty_lines;
    }
};

pub const Gate = struct {
    all: []const Gate = &.{},
    any: []const Gate = &.{},
    not: []const Gate = &.{},
    /// Case-folded needles.
    contains: []const []const u8 = &.{},
    regex: []const rx.Regex = &.{},
    line_regex: []const rx.Regex = &.{},

    fn matches(self: *const Gate, text: []const u8) bool {
        for (self.contains) |needle| if (!rx.containsFolded(text, needle)) return false;
        for (self.regex) |*re| if (!re.isMatch(text)) return false;
        for (self.line_regex) |*re| if (!re.anyLineMatches(text)) return false;
        for (self.all) |*g| if (!g.matches(text)) return false;
        if (self.any.len > 0) {
            var hit = false;
            for (self.any) |*g| if (g.matches(text)) {
                hit = true;
                break;
            };
            if (!hit) return false;
        }
        for (self.not) |*g| if (g.matches(text)) return false;
        return true;
    }

    fn hasPositiveMatcher(self: *const Gate) bool {
        return self.contains.len > 0 or self.regex.len > 0 or self.line_regex.len > 0 or self.all.len > 0 or self.any.len > 0;
    }

    fn hasAnyMatcher(self: *const Gate) bool {
        return self.hasPositiveMatcher() or self.not.len > 0;
    }
};

pub const Rule = struct {
    id: []const u8,
    state: ?State,
    priority: i32,
    region: Region,
    region_spec: []const u8,
    visible_idle: bool,
    visible_blocker: bool,
    visible_working: bool,
    skip_state_update: bool,
    gate: Gate,
};

pub const Input = struct {
    screen: []const u8,
    osc_title: []const u8 = "",
    osc_progress: []const u8 = "",
};

pub const Result = struct {
    state: State,
    /// Id of the winning rule; null when the known-agent idle fallback applied.
    matched_rule: ?[]const u8,
    visible_idle: bool = false,
    visible_blocker: bool = false,
    visible_working: bool = false,
    skip_state_update: bool = false,

    pub fn isFallback(self: Result) bool {
        return self.matched_rule == null;
    }
};

pub const ParseError = error{
    InvalidToml,
    UnknownField,
    MissingField,
    InvalidValue,
    InvalidRegion,
    InvalidRegex,
    EngineTooNew,
    NoRules,
    TooManyRules,
    GateTooDeep,
    TooManyGates,
    TooManyMatchers,
    MatcherTooLong,
    EmptyGate,
    SkipRuleNotNeutral,
    OutOfMemory,
};

/// Rule id (or top-level key) involved in the last `Manifest.parse` failure,
/// for diagnostics. Points into the caller's manifest text.
pub threadlocal var last_error_context: []const u8 = "";

pub const Manifest = struct {
    id: []const u8,
    version: ?[]const u8,
    min_engine_version: ?u32,
    aliases: []const []const u8,
    rules: []const Rule,
    arena: std.heap.ArenaAllocator,

    pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Manifest {
        last_error_context = "";
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var doc = toml.parse(a, text) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidToml,
        };
        // The document lives in our arena; its own arena wrapper is a no-op
        // view over the same memory, so never deinit it separately.
        _ = &doc;

        var m = Manifest{
            .id = "",
            .version = null,
            .min_engine_version = null,
            .aliases = &.{},
            .rules = &.{},
            .arena = arena,
        };
        var rules_value: ?[]const toml.Value = null;
        for (doc.root.entries) |e| {
            last_error_context = e.key;
            if (std.mem.eql(u8, e.key, "id")) {
                m.id = e.value.asString() orelse return error.InvalidValue;
            } else if (std.mem.eql(u8, e.key, "version")) {
                m.version = e.value.asString() orelse return error.InvalidValue;
            } else if (std.mem.eql(u8, e.key, "min_engine_version")) {
                const v = e.value.asInt() orelse return error.InvalidValue;
                if (v < 0 or v > std.math.maxInt(u32)) return error.InvalidValue;
                m.min_engine_version = @intCast(v);
            } else if (std.mem.eql(u8, e.key, "updated_at")) {
                _ = e.value.asString() orelse return error.InvalidValue;
            } else if (std.mem.eql(u8, e.key, "aliases")) {
                m.aliases = try stringList(a, e.value);
            } else if (std.mem.eql(u8, e.key, "rules")) {
                rules_value = e.value.asArray() orelse return error.InvalidValue;
            } else return error.UnknownField;
        }
        last_error_context = "";
        if (m.id.len == 0) return error.MissingField;
        if (m.min_engine_version) |v| if (v > engine_version) return error.EngineTooNew;
        const raw_rules = rules_value orelse return error.NoRules;
        if (raw_rules.len == 0) return error.NoRules;
        if (raw_rules.len > max_rules_per_manifest) return error.TooManyRules;

        var complexity = Complexity{};
        var rules = try a.alloc(Rule, raw_rules.len);
        for (raw_rules, 0..) |rv, i| {
            const table = rv.asTable() orelse return error.InvalidValue;
            rules[i] = try parseRule(a, table, m.min_engine_version, &complexity);
        }
        m.rules = rules;
        // `arena` was moved into `m` by value before any allocation happened
        // through `a`; both refer to the same backing state, so keep `m`'s.
        m.arena = arena;
        return m;
    }

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// True when this manifest is for `app` (by id or alias, canonical labels
    /// or process aliases).
    pub fn matchesApp(self: *const Manifest, app: App) bool {
        const label = app.label();
        if (std.mem.eql(u8, self.id, label) or detector.appFromProcessName(self.id) == app) return true;
        for (self.aliases) |alias| {
            if (std.mem.eql(u8, alias, label) or detector.appFromProcessName(alias) == app) return true;
        }
        return false;
    }

    /// Evaluate every rule and return the winner (or the idle fallback).
    pub fn evaluate(self: *const Manifest, input: Input) Result {
        var lines = Lines.collect(input.screen);
        var winner: ?*const Rule = null;
        for (self.rules) |*rule| {
            const text = regionText(input, &lines, rule.region);
            if (!rule.gate.matches(text)) continue;
            if (winner) |w| if (w.priority >= rule.priority) continue;
            winner = rule;
        }
        const rule = winner orelse return .{ .state = .idle, .matched_rule = null };
        const state = rule.state orelse .unknown;
        return .{
            .state = state,
            .matched_rule = rule.id,
            .visible_idle = rule.visible_idle and state == .idle,
            .visible_blocker = rule.visible_blocker and state == .blocked,
            .visible_working = rule.visible_working and state == .working,
            .skip_state_update = rule.skip_state_update,
        };
    }
};

const Complexity = struct {
    total_gates: usize = 0,
    total_matchers: usize = 0,
};

fn stringList(a: std.mem.Allocator, value: toml.Value) ParseError![]const []const u8 {
    const arr = value.asArray() orelse return error.InvalidValue;
    const out = try a.alloc([]const u8, arr.len);
    for (arr, 0..) |v, i| out[i] = v.asString() orelse return error.InvalidValue;
    return out;
}

fn parseRule(a: std.mem.Allocator, table: *const toml.Table, min_engine: ?u32, complexity: *Complexity) ParseError!Rule {
    var rule = Rule{
        .id = "",
        .state = null,
        .priority = 0,
        .region = .whole_recent,
        .region_spec = "whole_recent",
        .visible_idle = false,
        .visible_blocker = false,
        .visible_working = false,
        .skip_state_update = false,
        .gate = .{},
    };
    var gate_table = GateFields{};
    for (table.entries) |e| {
        if (std.mem.eql(u8, e.key, "id")) {
            rule.id = e.value.asString() orelse return error.InvalidValue;
            last_error_context = rule.id;
        } else if (std.mem.eql(u8, e.key, "state")) {
            const s = e.value.asString() orelse return error.InvalidValue;
            rule.state = State.fromLabel(s) orelse return error.InvalidValue;
        } else if (std.mem.eql(u8, e.key, "priority")) {
            const v = e.value.asInt() orelse return error.InvalidValue;
            if (v < std.math.minInt(i32) or v > std.math.maxInt(i32)) return error.InvalidValue;
            rule.priority = @intCast(v);
        } else if (std.mem.eql(u8, e.key, "region")) {
            rule.region_spec = e.value.asString() orelse return error.InvalidValue;
            rule.region = Region.parse(rule.region_spec) orelse return error.InvalidRegion;
        } else if (std.mem.eql(u8, e.key, "visible_idle")) {
            rule.visible_idle = e.value.asBool() orelse return error.InvalidValue;
        } else if (std.mem.eql(u8, e.key, "visible_blocker")) {
            rule.visible_blocker = e.value.asBool() orelse return error.InvalidValue;
        } else if (std.mem.eql(u8, e.key, "visible_working")) {
            rule.visible_working = e.value.asBool() orelse return error.InvalidValue;
        } else if (std.mem.eql(u8, e.key, "skip_state_update")) {
            rule.skip_state_update = e.value.asBool() orelse return error.InvalidValue;
        } else if (!gate_table.take(e)) return error.UnknownField;
    }
    if (std.mem.trim(u8, rule.id, " \t\r\n").len == 0) return error.MissingField;
    if (rule.skip_state_update) {
        if (rule.state != .unknown) return error.SkipRuleNotNeutral;
        if (rule.visible_idle or rule.visible_blocker or rule.visible_working) return error.SkipRuleNotNeutral;
    }
    if (rule.region.isTop()) {
        if (min_engine) |v| if (v < top_non_empty_lines_engine_version) return error.InvalidRegion;
    }
    rule.gate = try compileGate(a, gate_table, 0, complexity, .positive);
    return rule;
}

/// Raw gate fields as they appear in TOML, before compilation.
const GateFields = struct {
    all: ?toml.Value = null,
    any: ?toml.Value = null,
    not: ?toml.Value = null,
    contains: ?toml.Value = null,
    regex: ?toml.Value = null,
    line_regex: ?toml.Value = null,

    fn take(self: *GateFields, e: toml.Entry) bool {
        if (std.mem.eql(u8, e.key, "all")) {
            self.all = e.value;
        } else if (std.mem.eql(u8, e.key, "any")) {
            self.any = e.value;
        } else if (std.mem.eql(u8, e.key, "not")) {
            self.not = e.value;
        } else if (std.mem.eql(u8, e.key, "contains")) {
            self.contains = e.value;
        } else if (std.mem.eql(u8, e.key, "regex")) {
            self.regex = e.value;
        } else if (std.mem.eql(u8, e.key, "line_regex")) {
            self.line_regex = e.value;
        } else return false;
        return true;
    }

    fn fromTable(table: *const toml.Table) ParseError!GateFields {
        var fields = GateFields{};
        for (table.entries) |e| if (!fields.take(e)) return error.UnknownField;
        return fields;
    }
};

const GateKind = enum { positive, negative };

fn compileGate(a: std.mem.Allocator, fields: GateFields, depth: usize, complexity: *Complexity, kind: GateKind) ParseError!Gate {
    if (depth > max_gate_depth) return error.GateTooDeep;
    complexity.total_gates += 1;
    if (complexity.total_gates > max_total_gates) return error.TooManyGates;

    const contains_raw = if (fields.contains) |v| try stringList(a, v) else &[_][]const u8{};
    const regex_raw = if (fields.regex) |v| try stringList(a, v) else &[_][]const u8{};
    const line_regex_raw = if (fields.line_regex) |v| try stringList(a, v) else &[_][]const u8{};

    const matcher_count = contains_raw.len + regex_raw.len + line_regex_raw.len;
    if (matcher_count > max_matchers_per_gate) return error.TooManyMatchers;
    complexity.total_matchers += matcher_count;
    if (complexity.total_matchers > max_total_matchers) return error.TooManyMatchers;
    for ([_][]const []const u8{ contains_raw, regex_raw, line_regex_raw }) |list| {
        for (list) |s| if (std.unicode.utf8CountCodepoints(s) catch s.len > max_matcher_chars) return error.MatcherTooLong;
    }

    var gate = Gate{};
    const contains = try a.alloc([]const u8, contains_raw.len);
    for (contains_raw, 0..) |s, i| contains[i] = try rx.foldLowerAlloc(a, s);
    gate.contains = contains;
    gate.regex = try compileRegexes(a, regex_raw);
    gate.line_regex = try compileRegexes(a, line_regex_raw);

    gate.all = try compileGateList(a, fields.all, depth, complexity, .positive);
    gate.any = try compileGateList(a, fields.any, depth, complexity, .positive);
    gate.not = try compileGateList(a, fields.not, depth, complexity, .negative);

    switch (kind) {
        .positive => if (!gate.hasPositiveMatcher()) return error.EmptyGate,
        .negative => if (!gate.hasAnyMatcher()) return error.EmptyGate,
    }
    return gate;
}

fn compileGateList(a: std.mem.Allocator, value: ?toml.Value, depth: usize, complexity: *Complexity, kind: GateKind) ParseError![]const Gate {
    const v = value orelse return &.{};
    const arr = v.asArray() orelse return error.InvalidValue;
    const out = try a.alloc(Gate, arr.len);
    for (arr, 0..) |item, i| {
        const table = item.asTable() orelse return error.InvalidValue;
        const fields = try GateFields.fromTable(table);
        if (kind == .negative) {
            // A `not` child must contain some matcher; herdr checks this
            // before descending.
            var probe = Gate{};
            probe.contains = if (fields.contains) |c| try stringList(a, c) else &.{};
            probe.regex = &.{};
            if (!(fields.contains != null or fields.regex != null or fields.line_regex != null or fields.all != null or fields.any != null or fields.not != null)) return error.EmptyGate;
        }
        out[i] = try compileGate(a, fields, depth + 1, complexity, kind);
    }
    return out;
}

fn compileRegexes(a: std.mem.Allocator, patterns: []const []const u8) ParseError![]const rx.Regex {
    const out = try a.alloc(rx.Regex, patterns.len);
    for (patterns, 0..) |p, i| {
        out[i] = rx.Regex.compile(a, p) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidRegex,
        };
    }
    return out;
}

// ---------------------------------------------------------------------------
// Regions
// ---------------------------------------------------------------------------

const Line = struct {
    /// Byte offset of the line start in the content.
    start: usize,
    /// Line text without its '\n' and a trailing '\r' (Rust `str::lines`).
    text: []const u8,
};

/// Line table over the screen content (bounded by `max_lines`, keeping the
/// bottom of a longer input). `content` is the slice the table was built
/// from; when the input had to be truncated it is the tail that was kept.
const Lines = struct {
    content: []const u8,
    items: [max_lines]Line = undefined,
    len: usize = 0,

    fn collect(input: []const u8) Lines {
        var content = input;
        // Count lines; drop leading ones beyond the cap.
        var count: usize = 0;
        var it = rx.lineIterator(content);
        while (it.next() != null) count += 1;
        if (count > max_lines) {
            var skip = count - max_lines;
            var pos: usize = 0;
            while (skip > 0) : (skip -= 1) {
                pos = (std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len) + 1;
            }
            content = content[@min(pos, content.len)..];
        }
        var lines = Lines{ .content = content };
        var pos: usize = 0;
        var rest = rx.lineIterator(content);
        while (rest.next()) |text| {
            lines.items[lines.len] = .{ .start = pos, .text = text };
            lines.len += 1;
            pos = (std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len);
            if (pos < content.len) pos += 1;
        }
        return lines;
    }

    fn slice(self: *const Lines) []const Line {
        return self.items[0..self.len];
    }

    /// Byte offset where line `index` starts; `len` → end of content.
    fn startOf(self: *const Lines, index: usize) usize {
        if (index >= self.len) return self.content.len;
        return self.items[index].start;
    }

    fn from(self: *const Lines, index: usize) []const u8 {
        return self.content[self.startOf(index)..];
    }

    fn upTo(self: *const Lines, index: usize) []const u8 {
        return self.content[0..self.startOf(index)];
    }
};

fn regionText(input: Input, lines: *Lines, region: Region) []const u8 {
    const content = lines.content;
    return switch (region) {
        .osc_title => input.osc_title,
        .osc_progress => input.osc_progress,
        .whole_recent => content,
        .after_last_prompt_marker => afterLastPromptMarker(lines),
        .before_current_prompt_marker => beforeCurrentPromptMarker(lines),
        .whole_recent_without_current_prompt_marker => if (currentCodexPromptIndex(lines) != null) "" else content,
        .current_prompt_block_marker => currentPromptBlockMarker(lines) orelse "",
        .after_current_prompt_block_marker => afterCurrentPromptBlockMarker(lines) orelse "",
        .prompt_box_body => promptBoxBody(lines) orelse "",
        .above_prompt_box => abovePromptBox(lines),
        .last_non_empty_above_prompt_box => lastNonEmptyLine(abovePromptBox(lines)),
        .after_last_horizontal_rule => afterLastHorizontalRule(lines),
        .bottom_lines => |n| lines.from(lines.len -| n),
        .bottom_non_empty_lines => |n| bottomNonEmptyLines(lines, n),
        .top_non_empty_lines => |n| topNonEmptyLines(lines, n),
    };
}

fn bottomNonEmptyLines(lines: *const Lines, count: usize) []const u8 {
    if (count == 0) return "";
    var remaining = count;
    var start: ?usize = null;
    var i = lines.len;
    while (i > 0) {
        i -= 1;
        if (rx.isBlank(lines.items[i].text)) continue;
        start = i;
        remaining -= 1;
        if (remaining == 0) break;
    }
    const s = start orelse return "";
    return lines.from(s);
}

fn topNonEmptyLines(lines: *const Lines, count: usize) []const u8 {
    if (count == 0) return "";
    var remaining = count;
    var end: ?usize = null;
    for (lines.slice(), 0..) |line, i| {
        if (rx.isBlank(line.text)) continue;
        end = i;
        remaining -= 1;
        if (remaining == 0) break;
    }
    const e = end orelse return "";
    return lines.upTo(e + 1);
}

fn codexPromptLine(line: []const u8) bool {
    return std.mem.eql(u8, line, "›") or std.mem.startsWith(u8, line, "› ");
}

fn codexBlockMarkerLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "•") or std.mem.startsWith(u8, line, "■") or
        std.mem.startsWith(u8, line, "✗") or std.mem.startsWith(u8, line, "✓");
}

fn lastPromptIndex(lines: *const Lines) ?usize {
    var i = lines.len;
    while (i > 0) {
        i -= 1;
        if (codexPromptLine(lines.items[i].text)) return i;
    }
    return null;
}

fn afterLastPromptMarker(lines: *const Lines) []const u8 {
    const idx = lastPromptIndex(lines) orelse return lines.content;
    return lines.from(idx + 1);
}

/// The last `›` prompt line, unless a response block marker follows it (then
/// that prompt is history and there is no current prompt).
fn currentCodexPromptIndex(lines: *const Lines) ?usize {
    const idx = lastPromptIndex(lines) orelse return null;
    for (lines.slice()[idx + 1 ..]) |line| if (codexBlockMarkerLine(line.text)) return null;
    return idx;
}

fn beforeCurrentPromptMarker(lines: *const Lines) []const u8 {
    const idx = currentCodexPromptIndex(lines) orelse return lines.content;
    return lines.upTo(idx);
}

fn currentPromptBlockMarker(lines: *const Lines) ?[]const u8 {
    const idx = currentCodexPromptIndex(lines) orelse return null;
    var i = idx;
    while (i > 0) {
        i -= 1;
        if (codexBlockMarkerLine(lines.items[i].text)) return lines.items[i].text;
    }
    return null;
}

fn afterCurrentPromptBlockMarker(lines: *const Lines) ?[]const u8 {
    const idx = currentCodexPromptIndex(lines) orelse return null;
    var i = idx;
    while (i > 0) {
        i -= 1;
        if (codexBlockMarkerLine(lines.items[i].text)) return lines.from(i);
    }
    return null;
}

fn isHorizontalRule(line: []const u8) bool {
    const trimmed = trimSpace(line);
    if (trimmed.len == 0) return false;
    const bar = "─";
    var rule_chars: usize = 0;
    var pos: usize = 0;
    while (std.mem.startsWith(u8, trimmed[pos..], bar)) : (pos += bar.len) rule_chars += 1;
    if (rule_chars == 0) return false;
    const suffix = trimSpaceStart(trimmed[pos..]);
    return suffix.len == 0 or rule_chars >= 3;
}

fn trimSpaceStart(s: []const u8) []const u8 {
    var pos: usize = 0;
    while (rx.decodeAt(s, pos)) |d| : (pos += d.len) if (!rx.isSpace(d.cp)) break;
    return s[pos..];
}

fn trimSpace(s: []const u8) []const u8 {
    const head = trimSpaceStart(s);
    var end = head.len;
    while (end > 0) {
        // Walk back one scalar.
        var start = end - 1;
        while (start > 0 and (head[start] & 0xC0) == 0x80) start -= 1;
        const d = rx.decodeAt(head, start) orelse break;
        if (!rx.isSpace(d.cp)) break;
        end = start;
    }
    return head[0..end];
}

/// Index of the second horizontal rule from the bottom (the top border of a
/// prompt box drawn as rule / body / rule).
fn promptBoxTopBorderIndex(lines: *const Lines) ?usize {
    var borders: usize = 0;
    var i = lines.len;
    while (i > 0) {
        i -= 1;
        if (isHorizontalRule(lines.items[i].text)) {
            borders += 1;
            if (borders == 2) return i;
        }
    }
    return null;
}

fn promptBoxBody(lines: *const Lines) ?[]const u8 {
    const top = promptBoxTopBorderIndex(lines) orelse return null;
    const start = lines.startOf(top + 1);
    var end_index = lines.len;
    for (lines.slice()[top + 1 ..], top + 1..) |line, i| {
        if (isHorizontalRule(line.text)) {
            end_index = i;
            break;
        }
    }
    const end = lines.startOf(end_index);
    return lines.content[@min(start, lines.content.len)..@min(end, lines.content.len)];
}

fn abovePromptBox(lines: *const Lines) []const u8 {
    const top = promptBoxTopBorderIndex(lines) orelse return lines.content;
    return lines.upTo(top);
}

fn afterLastHorizontalRule(lines: *const Lines) []const u8 {
    var last_rule_end: usize = 0;
    for (lines.slice(), 0..) |line, i| {
        if (isHorizontalRule(line.text)) last_rule_end = lines.startOf(i + 1);
    }
    return lines.content[last_rule_end..];
}

fn lastNonEmptyLine(content: []const u8) []const u8 {
    var last: []const u8 = "";
    var it = rx.lineIterator(content);
    while (it.next()) |line| if (!rx.isBlank(line)) {
        last = line;
    };
    return last;
}

/// Region extraction without a manifest, for tests and diagnostics.
pub fn regionOf(input: Input, spec: []const u8) ?[]const u8 {
    const region = Region.parse(spec) orelse return null;
    var lines = Lines.collect(input.screen);
    return regionText(input, &lines, region);
}

// ---------------------------------------------------------------------------
// Bundled manifests (herdr's, embedded verbatim)
// ---------------------------------------------------------------------------

pub const Bundled = struct { app: App, name: []const u8, text: []const u8 };

pub const bundled = [_]Bundled{
    .{ .app = .amp, .name = "amp", .text = @embedFile("manifests/amp.toml") },
    .{ .app = .agy, .name = "antigravity", .text = @embedFile("manifests/antigravity.toml") },
    .{ .app = .claude_code, .name = "claude", .text = @embedFile("manifests/claude.toml") },
    .{ .app = .cline, .name = "cline", .text = @embedFile("manifests/cline.toml") },
    .{ .app = .codex, .name = "codex", .text = @embedFile("manifests/codex.toml") },
    .{ .app = .cursor, .name = "cursor", .text = @embedFile("manifests/cursor.toml") },
    .{ .app = .devin, .name = "devin", .text = @embedFile("manifests/devin.toml") },
    .{ .app = .droid, .name = "droid", .text = @embedFile("manifests/droid.toml") },
    .{ .app = .gemini, .name = "gemini", .text = @embedFile("manifests/gemini.toml") },
    .{ .app = .copilot, .name = "github-copilot", .text = @embedFile("manifests/github-copilot.toml") },
    .{ .app = .grok, .name = "grok", .text = @embedFile("manifests/grok.toml") },
    .{ .app = .hermes, .name = "hermes", .text = @embedFile("manifests/hermes.toml") },
    .{ .app = .kilo, .name = "kilo", .text = @embedFile("manifests/kilo.toml") },
    .{ .app = .kimi, .name = "kimi", .text = @embedFile("manifests/kimi.toml") },
    .{ .app = .kiro, .name = "kiro", .text = @embedFile("manifests/kiro.toml") },
    .{ .app = .letta, .name = "letta", .text = @embedFile("manifests/letta.toml") },
    .{ .app = .maki, .name = "maki", .text = @embedFile("manifests/maki.toml") },
    .{ .app = .muse, .name = "muse", .text = @embedFile("manifests/muse.toml") },
    .{ .app = .opencode, .name = "opencode", .text = @embedFile("manifests/opencode.toml") },
    .{ .app = .pi, .name = "pi", .text = @embedFile("manifests/pi.toml") },
    .{ .app = .qodercli, .name = "qodercli", .text = @embedFile("manifests/qodercli.toml") },
    .{ .app = .qwen, .name = "qwen", .text = @embedFile("manifests/qwen.toml") },
};

pub fn bundledText(app: App) ?[]const u8 {
    for (bundled) |b| if (b.app == app) return b.text;
    return null;
}

const app_count = std.meta.fields(App).len;

/// Process-lifetime cache of compiled bundled manifests, built on first use.
/// Feature-owned state: the engine is the only writer, and reads after the
/// one-time build are immutable.
var g_cache_mutex: std.Thread.Mutex = .{};
var g_cache_built: bool = false;
var g_cache: [app_count]?Manifest = [_]?Manifest{null} ** app_count;

fn buildCache() void {
    g_cache_mutex.lock();
    defer g_cache_mutex.unlock();
    if (g_cache_built) return;
    for (bundled) |b| {
        const m = Manifest.parse(std.heap.page_allocator, b.text) catch |err| {
            std.log.warn("screen manifest {s} failed to load: {s} ({s})", .{ b.name, @errorName(err), last_error_context });
            continue;
        };
        g_cache[@intFromEnum(b.app)] = m;
    }
    g_cache_built = true;
}

/// Compiled bundled manifest for `app`, or null when the app has none (or its
/// manifest failed to load, which the bundled-manifest test prevents).
pub fn bundledManifest(app: App) ?*const Manifest {
    if (!g_cache_built) buildCache();
    const slot = &g_cache[@intFromEnum(app)];
    return if (slot.*) |*m| m else null;
}

/// Classify `input` for `app` with its bundled manifest. Null when `app` has
/// no manifest. A known agent whose screen matches no rule is `idle`
/// (`Result.isFallback()`), like herdr.
pub fn detect(app: App, input: Input) ?Result {
    const m = bundledManifest(app) orelse return null;
    return m.evaluate(input);
}

// ---------------------------------------------------------------------------
// Mapping into the detector vocabulary
// ---------------------------------------------------------------------------

/// Translate a manifest result into WispTerm's `Detection` vocabulary.
/// `has_worked` tracks whether a working state was seen since the user last
/// looked: an idle screen after work is an unseen completion (`done`), an
/// idle screen before any work is plain `idle`. Returns null when the result
/// must not update the state (viewer / overlay screens).
pub fn mapToDetection(app: App, res: Result, has_worked: *bool) ?detector.Detection {
    var det = detector.Detection{ .app = app };
    switch (res.state) {
        .blocked => {
            det.state = .waiting_approval;
            det.confidence = if (res.visible_blocker) 90 else 70;
        },
        .working => {
            det.state = .running;
            det.confidence = if (res.visible_working) 90 else 70;
            has_worked.* = true;
        },
        .idle => {
            det.state = if (has_worked.*) .done else .idle;
            det.confidence = if (res.visible_idle) 90 else 50;
        },
        .unknown => {
            if (res.skip_state_update) return null;
            det.state = .none;
            det.confidence = 0;
        },
    }
    return det;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "mapToDetection turns idle-after-work into done and honors skip rules" {
    var worked = false;
    const idle = mapToDetection(.codex, .{ .state = .idle, .matched_rule = null }, &worked).?;
    try std.testing.expectEqual(detector.State.idle, idle.state);
    try std.testing.expectEqual(@as(u8, 50), idle.confidence);
    try std.testing.expect(idle.visible());

    const working = mapToDetection(.codex, .{ .state = .working, .matched_rule = "w", .visible_working = true }, &worked).?;
    try std.testing.expectEqual(detector.State.running, working.state);
    try std.testing.expect(worked);

    const done = mapToDetection(.codex, .{ .state = .idle, .matched_rule = "i", .visible_idle = true }, &worked).?;
    try std.testing.expectEqual(detector.State.done, done.state);
    try std.testing.expectEqual(@as(u8, 90), done.confidence);

    const blocked = mapToDetection(.claude_code, .{ .state = .blocked, .matched_rule = "b", .visible_blocker = true }, &worked).?;
    try std.testing.expectEqual(detector.State.waiting_approval, blocked.state);
    try std.testing.expectEqual(detector.App.claude_code, blocked.app);

    try std.testing.expect(mapToDetection(.codex, .{ .state = .unknown, .matched_rule = "viewer", .skip_state_update = true }, &worked) == null);
    const unknown = mapToDetection(.codex, .{ .state = .unknown, .matched_rule = "u" }, &worked).?;
    try std.testing.expect(!unknown.visible());
}

fn rulesManifest(comptime rules: []const u8) []const u8 {
    return "id = \"codex\"\nversion = \"1\"\nmin_engine_version = 3\n" ++ rules;
}

fn evaluateText(manifest: *const Manifest, screen: []const u8) Result {
    return manifest.evaluate(.{ .screen = screen });
}

test "known agent with no matching rule falls back to idle" {
    var m = try Manifest.parse(std.testing.allocator, rulesManifest(
        \\[[rules]]
        \\id = "working"
        \\state = "working"
        \\contains = ["active-marker"]
        \\
    ));
    defer m.deinit();
    const r = evaluateText(&m, "unmatched-marker");
    try std.testing.expectEqual(State.idle, r.state);
    try std.testing.expect(r.isFallback());
    try std.testing.expect(!r.visible_idle);
}

test "rule semantics: gates, priority ties, not, and line_regex" {
    var m = try Manifest.parse(std.testing.allocator, rulesManifest(
        \\[[rules]]
        \\id = "low_contains"
        \\state = "idle"
        \\priority = 1
        \\contains = ["match"]
        \\
        \\[[rules]]
        \\id = "high_nested_gates"
        \\state = "working"
        \\priority = 10
        \\contains = ["match"]
        \\all = [
        \\  { any = [{ regex = ["w[io]n"] }, { contains = ["fallback"] }] },
        \\]
        \\not = [
        \\  { contains = ["blocked"] },
        \\]
        \\
        \\[[rules]]
        \\id = "line_regex"
        \\state = "blocked"
        \\priority = 20
        \\line_regex = ["^exact line$"]
        \\
    ));
    defer m.deinit();
    const high = evaluateText(&m, "match win");
    try std.testing.expectEqual(State.working, high.state);
    try std.testing.expectEqualStrings("high_nested_gates", high.matched_rule.?);

    const not_gate = evaluateText(&m, "match win blocked");
    try std.testing.expectEqual(State.idle, not_gate.state);
    try std.testing.expectEqualStrings("low_contains", not_gate.matched_rule.?);

    const line = evaluateText(&m, "before\nexact line\nafter");
    try std.testing.expectEqual(State.blocked, line.state);
    try std.testing.expectEqualStrings("line_regex", line.matched_rule.?);

    // Equal priority: the earlier rule keeps the win.
    var tie = try Manifest.parse(std.testing.allocator, rulesManifest(
        \\[[rules]]
        \\id = "first"
        \\state = "working"
        \\priority = 5
        \\contains = ["x"]
        \\
        \\[[rules]]
        \\id = "second"
        \\state = "blocked"
        \\priority = 5
        \\contains = ["x"]
        \\
    ));
    defer tie.deinit();
    try std.testing.expectEqualStrings("first", evaluateText(&tie, "x").matched_rule.?);
}

test "end-anchored footer gates allow only an auxiliary tail" {
    var m = try Manifest.parse(std.testing.allocator, rulesManifest(
        \\[[rules]]
        \\id = "live_controls"
        \\state = "blocked"
        \\region = "whole_recent"
        \\regex = ['(?i)(?:^|\n)controls:\s+(?:confirm-marker|select-marker\s+navigate-marker)\s+cancel-marker[ \t]*\n---[^\n]*(?:\npanel: \d+(?:\nrow: [^\n]+)+(?:\n… \+\d+ pending)?)?(?:\n[ \t]*)*\z']
        \\
    ));
    defer m.deinit();
    const footer = "controls: select-marker navigate-marker cancel-marker";
    const tails = [_][]const u8{
        "--- name",
        "--- name\npanel: 5\nrow: active\nrow: pending\nrow: pending\nrow: pending\nrow: done\n",
        "--- name\npanel: 5\nrow: active\nrow: done\n… +3 pending",
    };
    var buf: [1024]u8 = undefined;
    for (tails) |tail| {
        const live = try std.fmt.bufPrint(&buf, "old output\n{s}\n{s}", .{ footer, tail });
        try std.testing.expectEqual(State.blocked, evaluateText(&m, live).state);
        const laters = [_][]const u8{ "new output", "prompt:", "--- next\nprompt:", "prompt: continue…", "working: processing…", "…ordinary output", "finished…", "… +2 arbitrary words" };
        for (laters) |later| {
            var buf2: [1200]u8 = undefined;
            const text = try std.fmt.bufPrint(&buf2, "{s}\n{s}", .{ live, later });
            try std.testing.expectEqual(State.idle, evaluateText(&m, text).state);
        }
    }
    const bad_tails = [_][]const u8{
        "--- name\n… +2 pending",
        "--- name\nrow: active",
        "--- name\npanel: 5",
        "--- name\npanel: 5\nrow: active\n  working: processing…",
        "--- name\npanel: 5\nrow: active\n  prompt: continue…",
    };
    for (bad_tails) |tail| {
        const text = try std.fmt.bufPrint(&buf, "{s}\n{s}", .{ footer, tail });
        try std.testing.expectEqual(State.idle, evaluateText(&m, text).state);
    }
    const good_controls = [_][]const u8{
        "controls: confirm-marker cancel-marker",
        "controls: select-marker\nnavigate-marker cancel-marker",
        "controls:\nselect-marker\nnavigate-marker\ncancel-marker",
    };
    for (good_controls) |controls| {
        const text = try std.fmt.bufPrint(&buf, "{s}\n--- name", .{controls});
        try std.testing.expectEqual(State.blocked, evaluateText(&m, text).state);
    }
    const bad_controls = [_][]const u8{
        "controls: select-marker cancel-marker",
        "controls: navigate-marker cancel-marker",
        "controls: confirm-marker",
        "controls: select-marker unrelated navigate-marker cancel-marker",
        "controls: select-marker\nprompt: navigate-marker cancel-marker",
    };
    for (bad_controls) |controls| {
        const text = try std.fmt.bufPrint(&buf, "confirm-marker navigate-marker\n{s}\n--- name", .{controls});
        try std.testing.expectEqual(State.idle, evaluateText(&m, text).state);
    }
}

test "paired alternatives require complete gates at the bottom buffer" {
    var m = try Manifest.parse(std.testing.allocator, rulesManifest(
        \\[[rules]]
        \\id = "paired"
        \\state = "blocked"
        \\region = "bottom_non_empty_lines(3)"
        \\visible_blocker = true
        \\any = [
        \\  { all = [
        \\    { contains = ["alpha heading"] },
        \\    { regex = ['alpha\s+control\s*\z'] },
        \\  ] },
        \\  { all = [
        \\    { contains = ["beta heading"] },
        \\    { regex = ['beta\s+control\s*\z'] },
        \\  ] },
        \\]
        \\
    ));
    defer m.deinit();
    for ([_][]const u8{ "alpha heading\nalpha control", "beta heading\nbeta\ncontrol" }) |text| {
        const r = evaluateText(&m, text);
        try std.testing.expectEqual(State.blocked, r.state);
        try std.testing.expect(r.visible_blocker);
    }
    for ([_][]const u8{
        "alpha heading\nbeta control",
        "beta heading\nalpha control",
        "beta control",
        "beta heading",
        "beta heading\nbeta control\nnewer content",
        "beta heading\nfiller one\nfiller two\nbeta control",
    }) |text| {
        const r = evaluateText(&m, text);
        try std.testing.expect(r.isFallback());
        try std.testing.expect(!r.visible_blocker);
    }
}

test "osc regions read their own inputs and share rule priority" {
    var m = try Manifest.parse(std.testing.allocator, rulesManifest(
        \\[[rules]]
        \\id = "screen"
        \\state = "idle"
        \\priority = 10
        \\region = "whole_recent"
        \\visible_idle = true
        \\contains = ["screen-marker"]
        \\
        \\[[rules]]
        \\id = "title"
        \\state = "working"
        \\priority = 20
        \\region = "osc_title"
        \\visible_working = true
        \\regex = ['^title-marker$']
        \\
        \\[[rules]]
        \\id = "progress"
        \\state = "blocked"
        \\priority = 30
        \\region = "osc_progress"
        \\visible_blocker = true
        \\regex = ['^progress-marker$']
        \\
    ));
    defer m.deinit();
    const cases = [_]struct { screen: []const u8, title: []const u8, progress: []const u8, state: State, rule: []const u8 }{
        .{ .screen = "screen-marker", .title = "", .progress = "", .state = .idle, .rule = "screen" },
        .{ .screen = "screen-marker", .title = "title-marker", .progress = "", .state = .working, .rule = "title" },
        .{ .screen = "screen-marker", .title = "title-marker", .progress = "progress-marker", .state = .blocked, .rule = "progress" },
        .{ .screen = "screen-marker title-marker progress-marker", .title = "", .progress = "", .state = .idle, .rule = "screen" },
    };
    for (cases) |c| {
        const r = m.evaluate(.{ .screen = c.screen, .osc_title = c.title, .osc_progress = c.progress });
        try std.testing.expectEqual(c.state, r.state);
        try std.testing.expectEqualStrings(c.rule, r.matched_rule.?);
        try std.testing.expectEqual(c.state == .idle, r.visible_idle);
        try std.testing.expectEqual(c.state == .working, r.visible_working);
        try std.testing.expectEqual(c.state == .blocked, r.visible_blocker);
    }
    const swapped = m.evaluate(.{ .screen = "", .osc_title = "progress-marker", .osc_progress = "title-marker" });
    try std.testing.expect(swapped.isFallback());
}

test "skip rules suppress the state update without visible evidence" {
    var m = try Manifest.parse(std.testing.allocator, rulesManifest(
        \\[[rules]]
        \\id = "activity"
        \\state = "working"
        \\priority = 10
        \\visible_working = true
        \\contains = ["activity-marker"]
        \\
        \\[[rules]]
        \\id = "overlay"
        \\state = "unknown"
        \\priority = 20
        \\skip_state_update = true
        \\contains = ["overlay-marker"]
        \\
    ));
    defer m.deinit();
    const r = evaluateText(&m, "activity-marker overlay-marker");
    try std.testing.expectEqual(State.unknown, r.state);
    try std.testing.expect(r.skip_state_update);
    try std.testing.expectEqualStrings("overlay", r.matched_rule.?);
    try std.testing.expect(!r.visible_idle and !r.visible_working and !r.visible_blocker);
}

test "screen regions extract structure like herdr" {
    const cases = [_]struct { screen: []const u8, spec: []const u8, expected: []const u8 }{
        .{ .screen = "old\n\nnew\n", .spec = "bottom_lines(2)", .expected = "\nnew\n" },
        .{ .screen = "before\n› input\nafter\n", .spec = "after_last_prompt_marker", .expected = "after\n" },
        .{ .screen = "before\n› input\nafter\n", .spec = "before_current_prompt_marker", .expected = "before\n" },
        .{ .screen = "before\n› input\nafter\n", .spec = "whole_recent_without_current_prompt_marker", .expected = "" },
        .{ .screen = "no marker\n", .spec = "whole_recent_without_current_prompt_marker", .expected = "no marker\n" },
        .{ .screen = "• old\n■ latest\n› input\n", .spec = "current_prompt_block_marker", .expected = "■ latest" },
        .{ .screen = "• old\n■ latest\n› input\n", .spec = "after_current_prompt_block_marker", .expected = "■ latest\n› input\n" },
        .{ .screen = "› old\n• new\n", .spec = "current_prompt_block_marker", .expected = "" },
        .{ .screen = "above\n\n───\nbody\n───\nfooter\n", .spec = "above_prompt_box", .expected = "above\n\n" },
        .{ .screen = "above\n\n───\nbody\n───\nfooter\n", .spec = "last_non_empty_above_prompt_box", .expected = "above" },
        .{ .screen = "above\n───\nbody\n───\nfooter\n", .spec = "prompt_box_body", .expected = "body\n" },
        .{ .screen = "above\n───\nbody\n───\nfooter\n", .spec = "after_last_horizontal_rule", .expected = "footer\n" },
        .{ .screen = "marker\nold\n\nmiddle\nmarker\nnew\n", .spec = "bottom_non_empty_lines(2)", .expected = "marker\nnew\n" },
        .{ .screen = "\nmarker\nold\n\nmiddle\nmarker\nnew\n", .spec = "top_non_empty_lines(2)", .expected = "\nmarker\nold\n" },
        .{ .screen = "a\nb\nc", .spec = "bottom_lines(10)", .expected = "a\nb\nc" },
        .{ .screen = "\n\n", .spec = "bottom_non_empty_lines(1)", .expected = "" },
        .{ .screen = "x", .spec = " bottom_non_empty_lines(+1) ", .expected = "x" },
        .{ .screen = "x", .spec = "osc_title", .expected = "" },
    };
    for (cases) |c| {
        const got = regionOf(.{ .screen = c.screen }, c.spec) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(c.expected, got);
    }
    try std.testing.expect(regionOf(.{ .screen = "" }, "top_non_empty_lines(0)") == null);
    try std.testing.expect(regionOf(.{ .screen = "" }, "top_non_empty_lines(01)") == null);
    try std.testing.expect(regionOf(.{ .screen = "" }, "top_non_empty_lines(+1)") == null);
    try std.testing.expect(regionOf(.{ .screen = "" }, "top_non_empty_lines(65536)") == null);
    try std.testing.expect(regionOf(.{ .screen = "" }, "after_last_promt_marker") == null);
    // A rule-only line with a long suffix is not a rule; three bars are.
    try std.testing.expect(isHorizontalRule("─── Title"));
    try std.testing.expect(!isHorizontalRule("── Title"));
    try std.testing.expect(isHorizontalRule("  ──  "));
    try std.testing.expect(!isHorizontalRule("Title ───"));
}

test "manifest validation mirrors herdr" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnknownField, Manifest.parse(a, "id = \"codex\"\n[[rules]]\nid = \"typo\"\nstate = \"working\"\ncontain = [\"Working\"]\n"));
    try std.testing.expectError(error.EmptyGate, Manifest.parse(a, "id = \"codex\"\n[[rules]]\nid = \"empty\"\nstate = \"working\"\n"));
    try std.testing.expectError(error.InvalidRegion, Manifest.parse(a, "id = \"codex\"\n[[rules]]\nid = \"bad_region\"\nstate = \"working\"\nregion = \"after_last_promt_marker\"\ncontains = [\"Working\"]\n"));
    try std.testing.expectError(error.InvalidRegex, Manifest.parse(a, "id = \"codex\"\n[[rules]]\nid = \"bad_regex\"\nstate = \"working\"\nregex = [\"[\"]\n"));
    try std.testing.expectError(error.InvalidRegex, Manifest.parse(a, "id = \"codex\"\n[[rules]]\nid = \"bad_nested\"\nstate = \"working\"\nany = [{ line_regex = [\"[\"] }]\n"));
    try std.testing.expectError(error.NoRules, Manifest.parse(a, "id = \"codex\"\n"));
    try std.testing.expectError(error.MissingField, Manifest.parse(a, "version = \"1\"\n[[rules]]\nid = \"x\"\nstate = \"idle\"\ncontains = [\"a\"]\n"));
    try std.testing.expectError(error.SkipRuleNotNeutral, Manifest.parse(a, "id = \"codex\"\n[[rules]]\nid = \"bad_skip_state\"\nstate = \"idle\"\nskip_state_update = true\ncontains = [\"menu\"]\n"));
    try std.testing.expectError(error.SkipRuleNotNeutral, Manifest.parse(a, "id = \"codex\"\n[[rules]]\nid = \"bad_skip_visible\"\nstate = \"unknown\"\nskip_state_update = true\nvisible_blocker = true\ncontains = [\"menu\"]\n"));
    try std.testing.expectError(error.EngineTooNew, Manifest.parse(a, "id = \"codex\"\nmin_engine_version = 4\n[[rules]]\nid = \"x\"\nstate = \"idle\"\ncontains = [\"a\"]\n"));
    try std.testing.expectError(error.InvalidRegion, Manifest.parse(a, "id = \"codex\"\nmin_engine_version = 2\n[[rules]]\nid = \"bg\"\nstate = \"working\"\nregion = \" top_non_empty_lines(1) \"\ncontains = [\"active\"]\n"));
    try std.testing.expectError(error.InvalidToml, Manifest.parse(a, "id = \n"));
    try std.testing.expectError(error.EmptyGate, Manifest.parse(a, "id = \"codex\"\n[[rules]]\nid = \"x\"\nstate = \"idle\"\ncontains = [\"a\"]\nnot = [{ }]\n"));

    // Too many rules.
    var many: std.ArrayListUnmanaged(u8) = .empty;
    defer many.deinit(a);
    try many.appendSlice(a, "id = \"codex\"\n");
    for (0..129) |i| try many.print(a, "[[rules]]\nid = \"rule_{d}\"\nstate = \"idle\"\ncontains = [\"ready\"]\n", .{i});
    try std.testing.expectError(error.TooManyRules, Manifest.parse(a, many.items));

    // Too deep.
    try std.testing.expectError(error.GateTooDeep, Manifest.parse(a,
        \\id = "codex"
        \\[[rules]]
        \\id = "deep"
        \\state = "idle"
        \\contains = ["ready"]
        \\all = [
        \\  { contains = ["1"], all = [
        \\    { contains = ["2"], all = [
        \\      { contains = ["3"], all = [
        \\        { contains = ["4"], all = [
        \\          { contains = ["5"], all = [
        \\            { contains = ["6"], all = [
        \\              { contains = ["7"], all = [
        \\                { contains = ["8"], all = [
        \\                  { contains = ["9"] },
        \\                ] },
        \\              ] },
        \\            ] },
        \\          ] },
        \\        ] },
        \\      ] },
        \\    ] },
        \\  ] },
        \\]
        \\
    ));

    // Too many matchers in one gate.
    var matchers: std.ArrayListUnmanaged(u8) = .empty;
    defer matchers.deinit(a);
    try matchers.appendSlice(a, "id = \"codex\"\n[[rules]]\nid = \"many\"\nstate = \"idle\"\ncontains = [");
    for (0..33) |i| try matchers.print(a, "\"m{d}\", ", .{i});
    try matchers.appendSlice(a, "]\n");
    try std.testing.expectError(error.TooManyMatchers, Manifest.parse(a, matchers.items));
}

test "every bundled manifest parses, validates, and names its agent" {
    for (bundled) |b| {
        var m = Manifest.parse(std.testing.allocator, b.text) catch |err| {
            std.debug.print("manifest {s}: {s} (context: {s})\n", .{ b.name, @errorName(err), last_error_context });
            return err;
        };
        defer m.deinit();
        try std.testing.expect(m.matchesApp(b.app));
        try std.testing.expect(m.rules.len > 0);
        try std.testing.expect(m.version != null);
    }
    // Every terminal agent has a manifest and the cache serves it.
    inline for (std.meta.fields(App)) |field| {
        const app: App = @enumFromInt(field.value);
        if (app.isTerminalAgent()) {
            try std.testing.expect(bundledText(app) != null);
            try std.testing.expect(bundledManifest(app) != null);
        } else {
            try std.testing.expect(bundledManifest(app) == null);
        }
    }
}

test "bundled claude manifest classifies real screens" {
    const permission =
        \\● Bash(cargo test)
        \\  ⎿  Running…
        \\
        \\───────────────────────────────────────
        \\ Do you want to proceed?
        \\ ❯ 1. Yes
        \\   2. Yes, and don't ask again for: cargo test
        \\   3. No
        \\
        \\ Esc to cancel · Tab to amend
        \\
    ;
    const blocked = detect(.claude_code, .{ .screen = permission }).?;
    try std.testing.expectEqual(State.blocked, blocked.state);
    try std.testing.expect(blocked.visible_blocker);

    const prompt_box =
        \\● Done. Let me know if you want changes.
        \\
        \\───────────────────────────────────────
        \\ ❯
        \\───────────────────────────────────────
        \\  ? for shortcuts
        \\
    ;
    const idle = detect(.claude_code, .{ .screen = prompt_box }).?;
    try std.testing.expectEqual(State.idle, idle.state);
    try std.testing.expect(idle.visible_idle);

    const working = detect(.claude_code, .{ .screen = "✻ Cogitating… (12s · esc to interrupt)\n", .osc_title = "⠋ Claude Code" }).?;
    try std.testing.expectEqual(State.working, working.state);
    try std.testing.expect(working.visible_working);

    // Title alone decides when the screen is quiet.
    const title_idle = detect(.claude_code, .{ .screen = "", .osc_title = "✳ wispterm" }).?;
    try std.testing.expectEqual(State.idle, title_idle.state);
    try std.testing.expect(title_idle.visible_idle);
}

test "bundled codex manifest classifies real screens" {
    const working =
        \\› fix the failing test
        \\
        \\• I'll start by running the suite.
        \\
        \\• Working (3m 11s • esc to interrupt)
        \\
    ;
    const w = detect(.codex, .{ .screen = working }).?;
    try std.testing.expectEqual(State.working, w.state);
    try std.testing.expect(w.visible_working);

    const approval =
        \\› run the tests
        \\
        \\Would you like to run the following command?
        \\  cargo test
        \\
        \\> 1. Yes, proceed (y)
        \\  2. No, and tell codex what to do differently (esc)
        \\
        \\Press enter to confirm or esc to cancel
        \\
    ;
    const b = detect(.codex, .{ .screen = approval }).?;
    try std.testing.expectEqual(State.blocked, b.state);
    try std.testing.expect(b.visible_blocker);

    const ready =
        \\OpenAI Codex (v0.135.0)
        \\model:     gpt-5.5 xhigh   /model to change
        \\directory: ~
        \\
        \\›
        \\
    ;
    const r = detect(.codex, .{ .screen = ready, .osc_title = "codex" }).?;
    try std.testing.expectEqual(State.idle, r.state);

    const title_working = detect(.codex, .{ .screen = ready, .osc_title = "⠋ codex" }).?;
    try std.testing.expectEqual(State.working, title_working.state);
}
