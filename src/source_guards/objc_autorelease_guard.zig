//! Objective-C autorelease guard. WispTerm never enters NSApplicationMain, so
//! no thread gets an outer autorelease pool that AppKit drains once per event
//! loop pass. An Objective-C message sent from an exported bridge function
//! outside an explicit `@autoreleasepool {}` therefore autoreleases into a pool
//! page that is never popped: 1.40.5 reached a 4.7 GB footprint after 1.5 days
//! almost entirely from -[NSWindow isZoomed] polled every frame (48M empty
//! NSMutableArrays plus ~1 GB of undrained pool pages). AppWindow's main loop
//! now also opens a pool per iteration (window_backend.beginLoopIteration), but
//! bridge entry points are reached from worker threads, init paths and tests
//! that loop never covers — so every entry point owns its pool.
//!
//! Rule, per `.m` bridge: a non-static C function whose body sends a message —
//! `[receiver selector ...]` directly, or by calling a static helper that sends
//! one outside its own pool — must do so lexically inside `@autoreleasepool`.
//! Methods inside `@implementation` are exempt (AppKit invokes them from event
//! dispatch, inside the pump's pool). This is a lexical scan, not a type
//! checker: property dot-syntax (`obj.prop`) is not recognised as a send.

const std = @import("std");

const Bridge = struct {
    path: []const u8,
    source: []const u8,
};

/// Every Objective-C translation unit under `src/`. The completeness test below
/// fails when a new `.m` file is added without being listed here.
const bridges = [_]Bridge{
    .{ .path = "platform/font_macos_bridge.m", .source = @embedFile("../platform/font_macos_bridge.m") },
    .{ .path = "platform/http_client_macos_bridge.m", .source = @embedFile("../platform/http_client_macos_bridge.m") },
    .{ .path = "platform/menu_macos_bridge.m", .source = @embedFile("../platform/menu_macos_bridge.m") },
    .{ .path = "platform/pdf_render_macos_bridge.m", .source = @embedFile("../platform/pdf_render_macos_bridge.m") },
    .{ .path = "platform/remote_transport_macos_bridge.m", .source = @embedFile("../platform/remote_transport_macos_bridge.m") },
    .{ .path = "platform/services_macos_bridge.m", .source = @embedFile("../platform/services_macos_bridge.m") },
    .{ .path = "platform/text_macos_bridge.m", .source = @embedFile("../platform/text_macos_bridge.m") },
    .{ .path = "platform/vault_key_macos_bridge.m", .source = @embedFile("../platform/vault_key_macos_bridge.m") },
    .{ .path = "platform/webview_macos_bridge.m", .source = @embedFile("../platform/webview_macos_bridge.m") },
    .{ .path = "platform/window_macos_bridge.m", .source = @embedFile("../platform/window_macos_bridge.m") },
    .{ .path = "renderer/gpu/metal/bridge.m", .source = @embedFile("../renderer/gpu/metal/bridge.m") },
};

/// Exported functions that autorelease into the caller's pool on purpose.
const allowed = [_][]const u8{
    // Test probe: proves window_backend.endLoopIteration drains the caller's pool.
    "wispterm_macos_test_autorelease_into_caller_pool",
};

/// Selectors that never autorelease and are legitimately sent before a pool is
/// opened (the main-thread check that gates dispatch_sync to the main queue).
const exempt_selectors = [_][]const u8{"isMainThread"};

pub const Violation = struct {
    /// Function name, sliced from the scanned source.
    function: []const u8,
    /// 1-based line of the first send/call outside a pool.
    line: usize,
    /// The offending selector, or the static helper that reaches one.
    what: []const u8,
};

const Function = struct {
    name_start: usize,
    name_end: usize,
    is_static: bool,
    /// Index of the body's `{` and its matching `}` in the scanned source.
    open: usize,
    close: usize,
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn startsWithWord(text: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, text, word)) return false;
    return text.len == word.len or !isIdent(text[word.len]);
}

fn containsWord(text: []const u8, word: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, word)) |pos| : (i = pos + 1) {
        const before_ok = pos == 0 or !isIdent(text[pos - 1]);
        const after = pos + word.len;
        const after_ok = after == text.len or !isIdent(text[after]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn blank(buf: []u8, start: usize, end: usize) void {
    for (buf[start..end]) |*b| {
        if (b.* != '\n') b.* = ' ';
    }
}

/// Copy of `src` with comments, string/char literals and preprocessor lines
/// blanked to spaces (newlines kept), so offsets and line numbers still match.
fn stripNonCode(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, src);
    var i: usize = 0;
    var line_start = true;
    while (i < src.len) {
        const c = src[i];
        if (c == '\n') {
            line_start = true;
            i += 1;
            continue;
        }
        if (line_start and (c == ' ' or c == '\t')) {
            i += 1;
            continue;
        }
        if (line_start and c == '#') {
            var j = i;
            while (j < src.len and src[j] != '\n') : (j += 1) {
                if (src[j] == '\\' and j + 1 < src.len and src[j + 1] == '\n') j += 1;
            }
            blank(out, i, j);
            i = j;
            continue;
        }
        line_start = false;
        if (std.mem.startsWith(u8, src[i..], "//")) {
            const j = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
            blank(out, i, j);
            i = j;
            continue;
        }
        if (std.mem.startsWith(u8, src[i..], "/*")) {
            const j = if (std.mem.indexOfPos(u8, src, i + 2, "*/")) |e| e + 2 else src.len;
            blank(out, i, j);
            i = j;
            continue;
        }
        if (c == '"' or c == '\'') {
            var j = i + 1;
            while (j < src.len and src[j] != c) : (j += 1) {
                if (src[j] == '\\') j += 1;
            }
            const end = @min(j + 1, src.len);
            blank(out, i, end);
            i = end;
            continue;
        }
        i += 1;
    }
    return out;
}

/// Index of the bracket closing the one at `open` (any of `([{`).
fn matchClose(code: []const u8, open: usize) usize {
    var depth: usize = 0;
    var i = open;
    while (i < code.len) : (i += 1) {
        switch (code[i]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth <= 1) return i;
                depth -= 1;
            },
            else => {},
        }
    }
    return code.len - 1;
}

/// If `code[open]` is the `[` of an Objective-C message send, return its first
/// selector keyword (sliced from `code`). Subscripts (`a[i]`, `a[i + 1]`,
/// `a[c ? x : y]`) and `@[...]` literals return null.
fn messageSelector(allocator: std.mem.Allocator, code: []const u8, open: usize) !?[]const u8 {
    if (open > 0 and code[open - 1] == '@') return null;
    const close = matchClose(code, open);

    // Top-level characters of the bracket, nested groups collapsed to their
    // closing bracket (stored as indices into `code`).
    var flat = std.ArrayList(usize).empty;
    defer flat.deinit(allocator);
    var j = open + 1;
    while (j < close) {
        switch (code[j]) {
            '(', '[', '{' => {
                const end = matchClose(code, j);
                try flat.append(allocator, end);
                j = end + 1;
            },
            else => {
                try flat.append(allocator, j);
                j += 1;
            },
        }
    }

    // A send is `<receiver> <selector>` followed by `:` or the closing `]`,
    // where the receiver ends in an identifier, `]`, or a `)` that is not the
    // leading cast of a subscript like `[(int) x]`.
    const idx = flat.items;
    var first_code: usize = 0;
    while (first_code < idx.len and isSpace(code[idx[first_code]])) first_code += 1;
    var i: usize = 0;
    while (i + 1 < idx.len) : (i += 1) {
        const c = code[idx[i]];
        const receiver_end = isIdent(c) or c == ']' or (c == ')' and i != first_code);
        if (!receiver_end or !isSpace(code[idx[i + 1]])) continue;
        var k = i + 1;
        while (k < idx.len and isSpace(code[idx[k]])) k += 1;
        if (k >= idx.len or !isIdentStart(code[idx[k]])) continue;
        const sel_start = k;
        while (k < idx.len and isIdent(code[idx[k]])) k += 1;
        const sel_end = k;
        while (k < idx.len and isSpace(code[idx[k]])) k += 1;
        if (k == idx.len or code[idx[k]] == ':') return code[idx[sel_start] .. idx[sel_end - 1] + 1];
    }
    return null;
}

/// `@protocol Foo;` / `@protocol(Foo)` are not containers ending in `@end`.
fn opensProtocolContainer(code: []const u8, at: usize) bool {
    var i = at + "@protocol".len;
    while (i < code.len and isSpace(code[i])) i += 1;
    const ident_start = i;
    while (i < code.len and isIdent(code[i])) i += 1;
    if (i == ident_start) return false;
    while (i < code.len and isSpace(code[i])) i += 1;
    return i < code.len and code[i] != ';' and code[i] != ',';
}

const Header = struct {
    name_start: usize,
    name_end: usize,
    is_static: bool,
};

/// Parse the text before a top-level `{` as a C function definition header.
/// `base` is the header's offset in the scanned source.
fn parseFunctionHeader(code: []const u8, base: usize, end_exclusive: usize) ?Header {
    const raw = code[base..end_exclusive];
    const lead = raw.len - std.mem.trimLeft(u8, raw, " \t\r\n").len;
    const header = std.mem.trim(u8, raw, " \t\r\n");
    if (header.len == 0 or header[header.len - 1] != ')') return null;
    if (std.mem.indexOfScalar(u8, header, '=') != null) return null;
    if (startsWithWord(header, "typedef")) return null;

    // The parameter list is the last balanced (...) group.
    var depth: usize = 0;
    var k: usize = header.len;
    const params_open: usize = while (k > 0) {
        k -= 1;
        switch (header[k]) {
            ')' => depth += 1,
            '(' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) break k;
            },
            else => {},
        }
    } else return null;

    var end = params_open;
    while (end > 0 and isSpace(header[end - 1])) end -= 1;
    var start = end;
    while (start > 0 and isIdent(header[start - 1])) start -= 1;
    if (start == end or !isIdentStart(header[start])) return null;
    return .{
        .name_start = base + lead + start,
        .name_end = base + lead + end,
        .is_static = containsWord(header[0..start], "static"),
    };
}

/// Top-level C function definitions, skipping `@interface`/`@implementation`/
/// `@protocol` ... `@end` containers.
fn collectFunctions(allocator: std.mem.Allocator, code: []const u8) !std.ArrayList(Function) {
    var list = std.ArrayList(Function).empty;
    errdefer list.deinit(allocator);
    var boundary: usize = 0;
    var in_container = false;
    var i: usize = 0;
    while (i < code.len) {
        const c = code[i];
        if (c == '@') {
            const rest = code[i + 1 ..];
            if (startsWithWord(rest, "end")) {
                in_container = false;
                i += "@end".len;
                boundary = i;
                continue;
            }
            if (startsWithWord(rest, "implementation") or startsWithWord(rest, "interface") or
                (startsWithWord(rest, "protocol") and opensProtocolContainer(code, i)))
            {
                in_container = true;
            }
        } else if (c == ';') {
            boundary = i + 1;
        } else if (c == '{') {
            const close = matchClose(code, i);
            if (!in_container) {
                if (parseFunctionHeader(code, boundary, i)) |h| {
                    try list.append(allocator, .{
                        .name_start = h.name_start,
                        .name_end = h.name_end,
                        .is_static = h.is_static,
                        .open = i,
                        .close = close,
                    });
                }
            }
            i = close + 1;
            boundary = i;
            continue;
        }
        i += 1;
    }
    return list;
}

const Hit = struct {
    offset: usize,
    what_start: usize,
    what_end: usize,
};

const Range = struct { open: usize, close: usize };

fn isExemptSelector(selector: []const u8) bool {
    for (exempt_selectors) |s| {
        if (std.mem.eql(u8, s, selector)) return true;
    }
    return false;
}

/// First message send — or call into a `touching` static helper — in `f`'s
/// body that is not lexically inside an `@autoreleasepool { }` block.
fn firstUnpooled(
    allocator: std.mem.Allocator,
    code: []const u8,
    funcs: []const Function,
    touching: []const bool,
    f: Function,
) !?Hit {
    var pools = std.ArrayList(Range).empty;
    defer pools.deinit(allocator);
    var search = f.open;
    while (std.mem.indexOfPos(u8, code[0..f.close], search, "@autoreleasepool")) |pos| {
        search = pos + 1;
        var b = pos + "@autoreleasepool".len;
        while (b < f.close and isSpace(code[b])) b += 1;
        if (b < f.close and code[b] == '{') try pools.append(allocator, .{ .open = b, .close = matchClose(code, b) });
    }

    var p = f.open + 1;
    while (p < f.close) {
        const c = code[p];
        if (c == '[') {
            if (try messageSelector(allocator, code, p)) |sel| {
                if (!isExemptSelector(sel) and !inRanges(pools.items, p)) {
                    const start = @intFromPtr(sel.ptr) - @intFromPtr(code.ptr);
                    return .{ .offset = p, .what_start = start, .what_end = start + sel.len };
                }
            }
            p += 1;
            continue;
        }
        if (isIdentStart(c) and !isIdent(code[p - 1])) {
            var e = p;
            while (e < f.close and isIdent(code[e])) e += 1;
            const ident = code[p..e];
            var after = e;
            while (after < f.close and isSpace(code[after])) after += 1;
            if (after < f.close and code[after] == '(' and !inRanges(pools.items, p)) {
                for (funcs, touching) |g, g_touching| {
                    if (!g_touching or g.open == f.open) continue;
                    if (std.mem.eql(u8, ident, code[g.name_start..g.name_end])) {
                        return .{ .offset = p, .what_start = p, .what_end = e };
                    }
                }
            }
            p = e;
            continue;
        }
        p += 1;
    }
    return null;
}

fn inRanges(ranges: []const Range, offset: usize) bool {
    for (ranges) |r| {
        if (offset > r.open and offset < r.close) return true;
    }
    return false;
}

/// Exported functions in one `.m` source that reach Objective-C outside a pool.
/// Slices in the result point into `source`.
pub fn findViolations(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(Violation) {
    const code = try stripNonCode(allocator, source);
    defer allocator.free(code);
    var funcs = try collectFunctions(allocator, code);
    defer funcs.deinit(allocator);

    // A static helper "touches" Objective-C when it sends (or reaches) a
    // message outside its own pool; callers then need the pool instead.
    const touching = try allocator.alloc(bool, funcs.items.len);
    defer allocator.free(touching);
    @memset(touching, false);
    var changed = true;
    while (changed) {
        changed = false;
        for (funcs.items, 0..) |f, idx| {
            if (!f.is_static or touching[idx]) continue;
            if (try firstUnpooled(allocator, code, funcs.items, touching, f) != null) {
                touching[idx] = true;
                changed = true;
            }
        }
    }

    var violations = std.ArrayList(Violation).empty;
    errdefer violations.deinit(allocator);
    for (funcs.items) |f| {
        if (f.is_static) continue;
        const hit = try firstUnpooled(allocator, code, funcs.items, touching, f) orelse continue;
        try violations.append(allocator, .{
            .function = source[f.name_start..f.name_end],
            .line = std.mem.count(u8, source[0..hit.offset], "\n") + 1,
            .what = source[hit.what_start..hit.what_end],
        });
    }
    return violations;
}

fn isAllowed(name: []const u8) bool {
    for (allowed) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

fn expectViolations(source: []const u8, expected: []const []const u8) !void {
    const gpa = std.testing.allocator;
    var violations = try findViolations(gpa, source);
    defer violations.deinit(gpa);
    try std.testing.expectEqual(expected.len, violations.items.len);
    for (expected, violations.items) |name, v| {
        try std.testing.expectEqualStrings(name, v.function);
    }
}

test "flags an exported function messaging AppKit outside @autoreleasepool" {
    try expectViolations(
        \\bool wispterm_is_zoomed(void *handle) {
        \\    WispTermMacWindowState *state = handle;
        \\    return state != NULL && [state->window isZoomed];
        \\}
        \\bool wispterm_is_key(void *handle) {
        \\    @autoreleasepool {
        \\        return [((WispTermMacWindowState *)handle)->window isKeyWindow];
        \\    }
        \\}
    , &.{"wispterm_is_zoomed"});
}

test "reports the line and selector of the first unpooled send" {
    const gpa = std.testing.allocator;
    var violations = try findViolations(gpa,
        \\void f(id w) {
        \\    if ([NSThread isMainThread]) return;
        \\    [w orderOut:nil];
        \\}
    );
    defer violations.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expectEqual(@as(usize, 3), violations.items[0].line);
    try std.testing.expectEqualStrings("orderOut", violations.items[0].what);
}

test "flags exported functions that reach AppKit through a static helper" {
    try expectViolations(
        \\static double scale(State *s) {
        \\    return [s->window backingScaleFactor];
        \\}
        \\static double pooled_scale(State *s) {
        \\    @autoreleasepool { return [s->window backingScaleFactor]; }
        \\}
        \\static double indirect(State *s) { return scale(s) * 2.0; }
        \\uint32_t dpi(void *h) { return (uint32_t)(96.0 * scale(h)); }
        \\uint32_t dpi_pooled(void *h) { @autoreleasepool { return (uint32_t)(96.0 * scale(h)); } }
        \\uint32_t dpi_safe_helper(void *h) { return (uint32_t)(96.0 * pooled_scale(h)); }
        \\uint32_t dpi_indirect(void *h) { return (uint32_t)indirect(h); }
    , &.{ "dpi", "dpi_indirect" });
}

test "accepts sends inside a pool opened in a dispatched block" {
    try expectViolations(
        \\void wispterm_zoom(void *handle) {
        \\    State *state = handle;
        \\    if (state == NULL) return;
        \\    run_on_main(^{
        \\        @autoreleasepool {
        \\            [state->window zoom:nil];
        \\        }
        \\    });
        \\}
    , &.{});
}

test "ignores subscripts, literals, comments, strings and preprocessor lines" {
    try expectViolations(
        \\#define CALL(x) [x release]
        \\int ring(State *s, size_t i) {
        \\    // [s->window isZoomed] in a comment
        \\    /* [s->window close] */
        \\    const char *t = "[s->window close]";
        \\    s->events[(s->head + s->count) % 64] = s->events[i + 1];
        \\    s->events[s->ok ? 1 : 0] = s->events[(int) i];
        \\    NSArray *a = @[s->obj];
        \\    return s->events[i].code;
        \\}
    , &.{});
}

test "ignores Objective-C methods inside @implementation containers" {
    try expectViolations(
        \\@protocol Forward;
        \\@interface Delegate : NSObject { int ivar; }
        \\@end
        \\@implementation Delegate
        \\- (void)windowDidResize:(NSNotification *)n {
        \\    [self.window isZoomed];
        \\}
        \\@end
        \\void exported(id w) { [w isZoomed]; }
    , &.{"exported"});
}

test "exported .m bridge functions send Objective-C messages only inside @autoreleasepool" {
    const gpa = std.testing.allocator;
    var failed = false;
    for (bridges) |bridge| {
        var violations = try findViolations(gpa, bridge.source);
        defer violations.deinit(gpa);
        for (violations.items) |v| {
            if (isAllowed(v.function)) continue;
            std.debug.print(
                "objc_autorelease_guard: src/{s}:{d}: {s}() reaches `{s}` outside @autoreleasepool. " ++
                    "Wrap the Objective-C part in @autoreleasepool {{ }} — WispTerm does not run under " ++
                    "NSApplicationMain, so nothing else drains what AppKit autoreleases.\n",
                .{ bridge.path, v.line, v.function, v.what },
            );
            failed = true;
        }
    }
    try std.testing.expect(!failed);
}

test "objc autorelease allowlist names only live, deliberate violations" {
    const gpa = std.testing.allocator;
    for (allowed) |name| {
        var found = false;
        for (bridges) |bridge| {
            var violations = try findViolations(gpa, bridge.source);
            defer violations.deinit(gpa);
            for (violations.items) |v| {
                if (std.mem.eql(u8, v.function, name)) found = true;
            }
        }
        if (!found) {
            std.debug.print("objc_autorelease_guard: stale allowlist entry {s}; remove it.\n", .{name});
            return error.StaleObjcAutoreleaseAllowlist;
        }
    }
}

/// `/`-separated `listed` vs a walker path (`\`-separated on Windows hosts).
fn samePath(listed: []const u8, walked: []const u8) bool {
    if (listed.len != walked.len) return false;
    for (listed, walked) |a, b| {
        const b_norm: u8 = if (b == '\\') '/' else b;
        if (a != b_norm) return false;
    }
    return true;
}

// Skips when `src/` is not reachable from the CWD (same convention as
// file_size_guard); fails only on a real `.m` file missing from `bridges`.
test "every .m bridge under src/ is scanned by the autorelease guard" {
    const gpa = std.testing.allocator;
    var dir = std.fs.cwd().openDir("src", .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    var missing = false;
    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".m")) continue;
        const listed = for (bridges) |bridge| {
            if (samePath(bridge.path, entry.path)) break true;
        } else false;
        if (!listed) {
            std.debug.print("objc_autorelease_guard: src/{s} is not listed in `bridges`.\n", .{entry.path});
            missing = true;
        }
    }
    try std.testing.expect(!missing);
}
