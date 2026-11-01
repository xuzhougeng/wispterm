//! TOML subset reader for the screen-detection manifests
//! (`src/terminal_agents/manifests/*.toml`). Pure: depends only on `std`.
//!
//! The manifests are shared verbatim with herdr, so this reader accepts exactly
//! what those files use and nothing more exotic: comments, `key = value`
//! pairs, basic and literal strings (single- and multi-line), integers,
//! booleans, arrays (multi-line, trailing comma), inline tables (nested, and
//! leniently allowed to span lines when they hold multi-line arrays), and
//! `[[array.of.tables]]` / `[table]` headers. Floats, dates, and dotted keys
//! are rejected. Everything is parsed into a generic tree; `screen_manifest`
//! gives it meaning.

const std = @import("std");

pub const Error = error{
    Syntax,
    Unsupported,
    OutOfMemory,
};

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    array: []const Value,
    table: *const Table,

    pub fn asString(self: Value) ?[]const u8 {
        return if (self == .string) self.string else null;
    }
    pub fn asInt(self: Value) ?i64 {
        return if (self == .integer) self.integer else null;
    }
    pub fn asBool(self: Value) ?bool {
        return if (self == .boolean) self.boolean else null;
    }
    pub fn asArray(self: Value) ?[]const Value {
        return if (self == .array) self.array else null;
    }
    pub fn asTable(self: Value) ?*const Table {
        return if (self == .table) self.table else null;
    }
};

pub const Entry = struct { key: []const u8, value: Value };

pub const Table = struct {
    entries: []const Entry,

    pub fn get(self: *const Table, key: []const u8) ?Value {
        for (self.entries) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
        return null;
    }
};

pub const Document = struct {
    root: *const Table,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Byte offset of the first error, for diagnostics. Only meaningful right
/// after `parse` fails; tests and the manifest loader read it.
pub threadlocal var last_error_pos: usize = 0;

const TableBuilder = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// `[[name]]` headers seen at this level, in first-seen order.
    array_tables: std.ArrayListUnmanaged(ArrayTableBuilder) = .empty,
};

const ArrayTableBuilder = struct {
    key: []const u8,
    tables: std.ArrayListUnmanaged(*TableBuilder) = .empty,
};

const Parser = struct {
    a: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,

    fn fail(self: *Parser, err: Error) Error {
        last_error_pos = self.pos;
        return err;
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn startsWith(self: *Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, self.src[self.pos..], s);
    }

    fn skipInlineWs(self: *Parser) void {
        while (self.peek()) |c| : (self.pos += 1) if (c != ' ' and c != '\t') break;
    }

    fn skipComment(self: *Parser) void {
        if (self.peek() == '#') {
            while (self.peek()) |c| : (self.pos += 1) if (c == '\n') break;
        }
    }

    /// Whitespace, newlines and comments — allowed inside arrays and (leniently)
    /// inline tables.
    fn skipWsNlComments(self: *Parser) void {
        while (true) {
            self.skipInlineWs();
            if (self.peek()) |c| {
                if (c == '\n' or c == '\r') {
                    self.pos += 1;
                    continue;
                }
                if (c == '#') {
                    self.skipComment();
                    continue;
                }
            }
            return;
        }
    }

    /// End of a top-level line: optional comment, then newline or EOF.
    fn expectLineEnd(self: *Parser) Error!void {
        self.skipInlineWs();
        self.skipComment();
        const c = self.peek() orelse return;
        if (c == '\r') self.pos += 1;
        if (self.peek() == '\n') {
            self.pos += 1;
            return;
        }
        return self.fail(error.Syntax);
    }

    fn parseKey(self: *Parser) Error![]const u8 {
        const c = self.peek() orelse return self.fail(error.Syntax);
        if (c == '"' or c == '\'') return self.parseString();
        const start = self.pos;
        while (self.peek()) |k| : (self.pos += 1) {
            if (!(std.ascii.isAlphanumeric(k) or k == '_' or k == '-')) break;
        }
        if (self.pos == start) return self.fail(error.Syntax);
        if (self.peek() == '.') return self.fail(error.Unsupported);
        return self.src[start..self.pos];
    }

    fn parseString(self: *Parser) Error![]const u8 {
        if (self.startsWith("'''")) return self.parseMultilineLiteral();
        if (self.startsWith("\"\"\"")) return self.parseMultilineBasic();
        const q = self.peek().?;
        self.pos += 1;
        if (q == '\'') {
            const start = self.pos;
            while (self.peek()) |c| : (self.pos += 1) {
                if (c == '\'') {
                    const s = self.src[start..self.pos];
                    self.pos += 1;
                    return s;
                }
                if (c == '\n') return self.fail(error.Syntax);
            }
            return self.fail(error.Syntax);
        }
        return self.parseBasicBody("\"", false);
    }

    fn parseMultilineLiteral(self: *Parser) Error![]const u8 {
        self.pos += 3;
        if (self.peek() == '\r') self.pos += 1;
        if (self.peek() == '\n') self.pos += 1;
        const end = std.mem.indexOfPos(u8, self.src, self.pos, "'''") orelse return self.fail(error.Syntax);
        const s = self.src[self.pos..end];
        self.pos = end + 3;
        return s;
    }

    fn parseMultilineBasic(self: *Parser) Error![]const u8 {
        self.pos += 3;
        if (self.peek() == '\r') self.pos += 1;
        if (self.peek() == '\n') self.pos += 1;
        return self.parseBasicBody("\"\"\"", true);
    }

    /// Body of a basic string up to `terminator`, decoding escapes.
    fn parseBasicBody(self: *Parser, terminator: []const u8, multiline: bool) Error![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        while (true) {
            if (self.startsWith(terminator)) {
                self.pos += terminator.len;
                return out.toOwnedSlice(self.a);
            }
            const c = self.peek() orelse return self.fail(error.Syntax);
            if (c == '\n' and !multiline) return self.fail(error.Syntax);
            if (c != '\\') {
                try out.append(self.a, c);
                self.pos += 1;
                continue;
            }
            self.pos += 1;
            const e = self.peek() orelse return self.fail(error.Syntax);
            self.pos += 1;
            switch (e) {
                'b' => try out.append(self.a, 0x08),
                't' => try out.append(self.a, '\t'),
                'n' => try out.append(self.a, '\n'),
                'f' => try out.append(self.a, 0x0C),
                'r' => try out.append(self.a, '\r'),
                '"' => try out.append(self.a, '"'),
                '\\' => try out.append(self.a, '\\'),
                'u', 'U' => {
                    const digits: usize = if (e == 'u') 4 else 8;
                    if (self.pos + digits > self.src.len) return self.fail(error.Syntax);
                    const cp = std.fmt.parseInt(u21, self.src[self.pos .. self.pos + digits], 16) catch return self.fail(error.Syntax);
                    self.pos += digits;
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch return self.fail(error.Syntax);
                    try out.appendSlice(self.a, buf[0..n]);
                },
                '\n', '\r', ' ', '\t' => {
                    // Line-ending backslash in a multi-line string trims the
                    // following whitespace and newlines.
                    if (!multiline) return self.fail(error.Syntax);
                    self.pos -= 1;
                    self.skipWsNlComments();
                },
                else => return self.fail(error.Syntax),
            }
        }
    }

    fn parseValue(self: *Parser) Error!Value {
        const c = self.peek() orelse return self.fail(error.Syntax);
        switch (c) {
            '"', '\'' => return .{ .string = try self.parseString() },
            '[' => return self.parseArray(),
            '{' => return self.parseInlineTable(),
            't' => {
                if (self.startsWith("true")) {
                    self.pos += 4;
                    return .{ .boolean = true };
                }
                return self.fail(error.Syntax);
            },
            'f' => {
                if (self.startsWith("false")) {
                    self.pos += 5;
                    return .{ .boolean = false };
                }
                return self.fail(error.Syntax);
            },
            '+', '-', '0'...'9' => return self.parseInteger(),
            else => return self.fail(error.Syntax),
        }
    }

    fn parseInteger(self: *Parser) Error!Value {
        const start = self.pos;
        if (self.peek() == '+' or self.peek() == '-') self.pos += 1;
        while (self.peek()) |d| : (self.pos += 1) if (!(std.ascii.isDigit(d) or d == '_')) break;
        if (self.peek()) |d| if (d == '.' or d == 'e' or d == 'E' or d == ':' or d == 'T') return self.fail(error.Unsupported);
        var buf: [32]u8 = undefined;
        var n: usize = 0;
        for (self.src[start..self.pos]) |d| {
            if (d == '_') continue;
            if (n >= buf.len) return self.fail(error.Syntax);
            buf[n] = d;
            n += 1;
        }
        const v = std.fmt.parseInt(i64, buf[0..n], 10) catch return self.fail(error.Syntax);
        return .{ .integer = v };
    }

    fn parseArray(self: *Parser) Error!Value {
        self.pos += 1; // '['
        var items: std.ArrayListUnmanaged(Value) = .empty;
        while (true) {
            self.skipWsNlComments();
            if (self.peek() == ']') {
                self.pos += 1;
                break;
            }
            try items.append(self.a, try self.parseValue());
            self.skipWsNlComments();
            const sep = self.peek() orelse return self.fail(error.Syntax);
            if (sep == ',') {
                self.pos += 1;
            } else if (sep != ']') return self.fail(error.Syntax);
        }
        return .{ .array = try items.toOwnedSlice(self.a) };
    }

    fn parseInlineTable(self: *Parser) Error!Value {
        self.pos += 1; // '{'
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        while (true) {
            self.skipWsNlComments();
            if (self.peek() == '}') {
                self.pos += 1;
                break;
            }
            const key = try self.parseKey();
            self.skipInlineWs();
            if (self.peek() != '=') return self.fail(error.Syntax);
            self.pos += 1;
            self.skipInlineWs();
            const value = try self.parseValue();
            try entries.append(self.a, .{ .key = key, .value = value });
            self.skipWsNlComments();
            const sep = self.peek() orelse return self.fail(error.Syntax);
            if (sep == ',') {
                self.pos += 1;
            } else if (sep != '}') return self.fail(error.Syntax);
        }
        const table = try self.a.create(Table);
        table.* = .{ .entries = try entries.toOwnedSlice(self.a) };
        return .{ .table = table };
    }

    fn parseDocument(self: *Parser) Error!*const Table {
        const root = try self.a.create(TableBuilder);
        root.* = .{};
        var current: *TableBuilder = root;
        while (true) {
            self.skipWsNlComments();
            const c = self.peek() orelse break;
            if (c == '[') {
                const is_array = self.startsWith("[[");
                self.pos += if (is_array) 2 else 1;
                self.skipInlineWs();
                const name = try self.parseKey();
                self.skipInlineWs();
                const close: []const u8 = if (is_array) "]]" else "]";
                if (!self.startsWith(close)) return self.fail(error.Syntax);
                self.pos += close.len;
                try self.expectLineEnd();
                // A standard `[name]` table is exposed as a one-element array
                // under `name`; the manifests only use `[[rules]]`.
                const table = try self.a.create(TableBuilder);
                table.* = .{};
                const builder = try self.arrayTableBuilder(root, name);
                try builder.tables.append(self.a, table);
                current = table;
                continue;
            }
            const key = try self.parseKey();
            self.skipInlineWs();
            if (self.peek() != '=') return self.fail(error.Syntax);
            self.pos += 1;
            self.skipInlineWs();
            const value = try self.parseValue();
            try self.expectLineEnd();
            try current.entries.append(self.a, .{ .key = key, .value = value });
        }
        return self.materialize(root, true);
    }

    fn arrayTableBuilder(self: *Parser, root: *TableBuilder, name: []const u8) Error!*ArrayTableBuilder {
        for (root.array_tables.items) |*b| if (std.mem.eql(u8, b.key, name)) return b;
        try root.array_tables.append(self.a, .{ .key = name });
        return &root.array_tables.items[root.array_tables.items.len - 1];
    }

    fn materialize(self: *Parser, b: *TableBuilder, is_root: bool) Error!*const Table {
        var entries: std.ArrayListUnmanaged(Entry) = .empty;
        try entries.appendSlice(self.a, b.entries.items);
        if (is_root) {
            for (b.array_tables.items) |at| {
                var tables: std.ArrayListUnmanaged(Value) = .empty;
                for (at.tables.items) |tb| try tables.append(self.a, .{ .table = try self.materialize(tb, false) });
                try entries.append(self.a, .{ .key = at.key, .value = .{ .array = try tables.toOwnedSlice(self.a) } });
            }
        }
        const table = try self.a.create(Table);
        table.* = .{ .entries = try entries.toOwnedSlice(self.a) };
        return table;
    }
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) Error!Document {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var parser = Parser{ .a = arena.allocator(), .src = text };
    const root = try parser.parseDocument();
    return .{ .root = root, .arena = arena };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "scalars, comments, and array-of-tables headers" {
    const src =
        \\# manifest
        \\id = "codex"   # trailing comment
        \\version = "2026.10.11.1"
        \\min_engine_version = 3
        \\enabled = true
        \\aliases = ["claude-code", 'lit']
        \\
        \\[[rules]]
        \\id = "first"
        \\priority = 1100
        \\
        \\[[rules]]
        \\id = "second"
        \\visible_blocker = false
        \\
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    try std.testing.expectEqualStrings("codex", doc.root.get("id").?.asString().?);
    try std.testing.expectEqual(@as(i64, 3), doc.root.get("min_engine_version").?.asInt().?);
    try std.testing.expect(doc.root.get("enabled").?.asBool().?);
    const aliases = doc.root.get("aliases").?.asArray().?;
    try std.testing.expectEqual(@as(usize, 2), aliases.len);
    try std.testing.expectEqualStrings("lit", aliases[1].asString().?);
    const rules = doc.root.get("rules").?.asArray().?;
    try std.testing.expectEqual(@as(usize, 2), rules.len);
    try std.testing.expectEqualStrings("first", rules[0].asTable().?.get("id").?.asString().?);
    try std.testing.expectEqual(@as(i64, 1100), rules[0].asTable().?.get("priority").?.asInt().?);
    try std.testing.expect(!rules[1].asTable().?.get("visible_blocker").?.asBool().?);
    try std.testing.expect(doc.root.get("missing") == null);
}

test "literal strings keep backslashes; basic strings decode escapes" {
    const src =
        \\regex = ['^\s*[\x{2800}-\x{28FF}] ', "tab\there", "q\"uote", "✳ x"]
        \\
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    const arr = doc.root.get("regex").?.asArray().?;
    try std.testing.expectEqualStrings("^\\s*[\\x{2800}-\\x{28FF}] ", arr[0].asString().?);
    try std.testing.expectEqualStrings("tab\there", arr[1].asString().?);
    try std.testing.expectEqualStrings("q\"uote", arr[2].asString().?);
    try std.testing.expectEqualStrings("✳ x", arr[3].asString().?);
}

test "nested inline tables and multi-line arrays in the manifest shape" {
    const src =
        \\[[rules]]
        \\id = "trust_directory"
        \\all = [
        \\  { any = [
        \\    { regex = ['\A> You are in'] },
        \\    { contains = ["Folder access"] },
        \\  ] },
        \\  { any = [
        \\    { contains = ["Trust and continue"] },
        \\    { all = [ { contains = ["a", "b"] }, { not = [{ contains = ["c"] }] } ] },
        \\  ] },
        \\]
        \\not = [{ regex = ['(?m)^›'] }]
        \\
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    const rule = doc.root.get("rules").?.asArray().?[0].asTable().?;
    const all = rule.get("all").?.asArray().?;
    try std.testing.expectEqual(@as(usize, 2), all.len);
    const any0 = all[0].asTable().?.get("any").?.asArray().?;
    try std.testing.expectEqualStrings("\\A> You are in", any0[0].asTable().?.get("regex").?.asArray().?[0].asString().?);
    const any1 = all[1].asTable().?.get("any").?.asArray().?;
    const inner_all = any1[1].asTable().?.get("all").?.asArray().?;
    try std.testing.expectEqualStrings("b", inner_all[0].asTable().?.get("contains").?.asArray().?[1].asString().?);
    try std.testing.expectEqualStrings("c", inner_all[1].asTable().?.get("not").?.asArray().?[0].asTable().?.get("contains").?.asArray().?[0].asString().?);
    try std.testing.expectEqualStrings("(?m)^›", rule.get("not").?.asArray().?[0].asTable().?.get("regex").?.asArray().?[0].asString().?);
}

test "multi-line strings and line-ending backslashes" {
    const src = "a = '''\nraw \\s text\n'''\nb = \"\"\"\nfirst \\\n   second\"\"\"\n";
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    try std.testing.expectEqualStrings("raw \\s text\n", doc.root.get("a").?.asString().?);
    try std.testing.expectEqualStrings("first second", doc.root.get("b").?.asString().?);
}

test "standard table headers and CRLF line endings" {
    const src = "id = \"x\"\r\n[meta]\r\nk = 1\r\n";
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    const meta = doc.root.get("meta").?.asArray().?;
    try std.testing.expectEqual(@as(i64, 1), meta[0].asTable().?.get("k").?.asInt().?);
}

test "unsupported and malformed input is rejected" {
    try std.testing.expectError(error.Unsupported, parse(std.testing.allocator, "f = 1.5\n"));
    try std.testing.expectError(error.Unsupported, parse(std.testing.allocator, "a.b = 1\n"));
    try std.testing.expectError(error.Syntax, parse(std.testing.allocator, "a = \n"));
    try std.testing.expectError(error.Syntax, parse(std.testing.allocator, "a = \"open\n"));
    try std.testing.expectError(error.Syntax, parse(std.testing.allocator, "a = [1, 2\n"));
    try std.testing.expectError(error.Syntax, parse(std.testing.allocator, "a = 1 b = 2\n"));
    try std.testing.expectError(error.Syntax, parse(std.testing.allocator, "[[rules]\n"));
    try std.testing.expectError(error.Syntax, parse(std.testing.allocator, "= 1\n"));
}
