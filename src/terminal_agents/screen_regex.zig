//! Minimal regular-expression engine for the screen-detection manifests
//! (`screen_manifest.zig`). Pure: depends only on `std`.
//!
//! The manifests are shared verbatim with herdr, which evaluates them with the
//! Rust `regex` crate. This engine implements the subset those manifests use,
//! with the same semantics for every construct it accepts:
//!
//!   - literals, `.`, `|`, `(...)`, `(?:...)`, `*` `+` `?` `{n}` `{n,}` `{n,m}`
//!     (lazy `?` suffixes are accepted and ignored — only match/no-match is
//!     observable here)
//!   - classes `[...]` / `[^...]` with ranges and the escapes below
//!   - `\s \S \d \D \w \W`, `\p{Alphabetic}` (approximated by letter ranges)
//!   - anchors `^` `$` (plain and `(?m)` multi-line), `\A`, `\z`, `\b`, `\B`
//!   - escapes `\n \r \t \f \v \0`, `\xHH`, `\x{H..}`, `\uHHHH`, `\u{H..}`,
//!     and escaped punctuation
//!   - inline flags `(?i)`, `(?m)`, `(?s)` (and `(?flags:...)`), scoped to the
//!     enclosing group as in Rust
//!
//! Matching is a Pike VM (Thompson NFA simulation) over Unicode scalar values,
//! so it runs in O(text × program) time with no backtracking: a manifest rule
//! can never make a pane poll pathological, no matter what is on screen.
//! Unsupported syntax (lookaround, backreferences, POSIX classes, general
//! `\p{..}` properties) is rejected at compile time so a manifest that drifts
//! past this subset fails the bundled-manifest test instead of silently never
//! matching.

const std = @import("std");

pub const Error = error{
    UnsupportedSyntax,
    UnbalancedParen,
    UnterminatedClass,
    InvalidEscape,
    InvalidRepetition,
    EmptyPattern,
    PatternTooLarge,
    OutOfMemory,
};

/// Upper bound on compiled program length. Scratch for the VM is sized from
/// this so matching needs no allocation.
pub const max_program_len: usize = 2048;

const Range = struct { lo: u21, hi: u21 };

/// Named character sets that can appear standalone (`\s`) or inside a class.
const Sets = packed struct(u8) {
    space: bool = false,
    not_space: bool = false,
    digit: bool = false,
    not_digit: bool = false,
    word: bool = false,
    not_word: bool = false,
    alpha: bool = false,
    _pad: u1 = 0,
};

const Class = struct {
    ranges: []const Range,
    sets: Sets,
    negated: bool,

    fn matchesRaw(self: Class, c: u21) bool {
        for (self.ranges) |r| if (c >= r.lo and c <= r.hi) return true;
        if (self.sets.space and isSpace(c)) return true;
        if (self.sets.not_space and !isSpace(c)) return true;
        if (self.sets.digit and isDigit(c)) return true;
        if (self.sets.not_digit and !isDigit(c)) return true;
        if (self.sets.word and isWord(c)) return true;
        if (self.sets.not_word and !isWord(c)) return true;
        if (self.sets.alpha and isAlpha(c)) return true;
        return false;
    }

    fn matches(self: Class, c: u21, fold: bool) bool {
        var hit = self.matchesRaw(c);
        if (!hit and fold) {
            const lower = foldLower(c);
            const upper = foldUpper(c);
            hit = (lower != c and self.matchesRaw(lower)) or (upper != c and self.matchesRaw(upper));
        }
        return hit != self.negated;
    }
};

const Assert = enum {
    bol, // ^ without (?m): only at text start
    bol_ml, // (?m)^: text start or after '\n'
    eol, // $ without (?m): only at text end
    eol_ml, // (?m)$: text end or before '\n'
    boa, // \A
    eoa, // \z
    wordb, // \b
    nwordb, // \B
};

const Inst = union(enum) {
    char: struct { cp: u21, fold: bool },
    class: struct { idx: u32, fold: bool },
    any: bool, // payload: dotall
    split: struct { x: u32, y: u32 },
    jmp: u32,
    assert: Assert,
    match,
};

// ---------------------------------------------------------------------------
// Character predicates (Rust `regex` defaults, Unicode-aware where it matters
// for terminal text: whitespace is full White_Space; word/alpha are letter
// ranges covering Latin, Greek, Cyrillic, CJK, kana, and Hangul).
// ---------------------------------------------------------------------------

pub fn isSpace(c: u21) bool {
    return switch (c) {
        ' ', '\t', '\n', 0x0B, 0x0C, '\r', 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        0x2000...0x200A => true,
        else => false,
    };
}

fn isDigit(c: u21) bool {
    return c >= '0' and c <= '9';
}

fn isAlpha(c: u21) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z' => true,
        0xAA, 0xB5, 0xBA => true,
        0xC0...0xD6, 0xD8...0xF6, 0xF8...0x2FF => true, // Latin-1 + Extended
        0x370...0x3FF => true, // Greek
        0x400...0x4FF => true, // Cyrillic
        0x3040...0x30FF => true, // Hiragana / Katakana
        0x3400...0x4DBF, 0x4E00...0x9FFF => true, // CJK
        0xAC00...0xD7A3 => true, // Hangul
        else => false,
    };
}

fn isWord(c: u21) bool {
    return c == '_' or isDigit(c) or isAlpha(c);
}

/// Simple case folding for the scripts terminal agents print: ASCII, Latin-1,
/// Greek and Cyrillic. Returns `c` unchanged when it has no lowercase form.
fn foldLower(c: u21) u21 {
    return switch (c) {
        'A'...'Z' => c + 0x20,
        0xC0...0xD6, 0xD8...0xDE => c + 0x20,
        0x391...0x3A1, 0x3A3...0x3A9 => c + 0x20,
        0x410...0x42F => c + 0x20,
        0x400...0x40F => c + 0x50,
        else => c,
    };
}

fn foldUpper(c: u21) u21 {
    return switch (c) {
        'a'...'z' => c - 0x20,
        0xE0...0xF6, 0xF8...0xFE => c - 0x20,
        0x3B1...0x3C1, 0x3C3...0x3C9 => c - 0x20,
        0x430...0x44F => c - 0x20,
        0x450...0x45F => c - 0x50,
        else => c,
    };
}

// ---------------------------------------------------------------------------
// Parser → AST
// ---------------------------------------------------------------------------

const Flags = struct {
    fold: bool = false,
    multiline: bool = false,
    dotall: bool = false,
};

const Node = union(enum) {
    empty,
    char: struct { cp: u21, fold: bool },
    class: struct { idx: u32, fold: bool },
    any: bool,
    assert: Assert,
    concat: []const u32,
    alt: []const u32,
    repeat: struct { child: u32, min: u32, max: ?u32 },
};

const Parser = struct {
    arena: std.mem.Allocator,
    pat: []const u8,
    pos: usize = 0,
    flags: Flags = .{},
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    classes: std.ArrayListUnmanaged(Class) = .empty,

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.pat.len) self.pat[self.pos] else null;
    }

    fn peekAt(self: *Parser, off: usize) ?u8 {
        return if (self.pos + off < self.pat.len) self.pat[self.pos + off] else null;
    }

    fn push(self: *Parser, node: Node) Error!u32 {
        if (self.nodes.items.len >= max_program_len) return error.PatternTooLarge;
        try self.nodes.append(self.arena, node);
        return @intCast(self.nodes.items.len - 1);
    }

    fn pushClass(self: *Parser, class: Class) Error!u32 {
        try self.classes.append(self.arena, class);
        return @intCast(self.classes.items.len - 1);
    }

    /// Decode one UTF-8 scalar at the cursor and advance past it.
    fn nextCodepoint(self: *Parser) Error!u21 {
        const first = self.peek() orelse return error.UnsupportedSyntax;
        const len = std.unicode.utf8ByteSequenceLength(first) catch return error.UnsupportedSyntax;
        if (self.pos + len > self.pat.len) return error.UnsupportedSyntax;
        const cp = std.unicode.utf8Decode(self.pat[self.pos .. self.pos + len]) catch return error.UnsupportedSyntax;
        self.pos += len;
        return cp;
    }

    fn parseAlt(self: *Parser) Error!u32 {
        var branches: std.ArrayListUnmanaged(u32) = .empty;
        try branches.append(self.arena, try self.parseConcat());
        while (self.peek() == '|') {
            self.pos += 1;
            try branches.append(self.arena, try self.parseConcat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return self.push(.{ .alt = try branches.toOwnedSlice(self.arena) });
    }

    fn parseConcat(self: *Parser) Error!u32 {
        var items: std.ArrayListUnmanaged(u32) = .empty;
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            try items.append(self.arena, try self.parseRepeat());
        }
        if (items.items.len == 0) return self.push(.empty);
        if (items.items.len == 1) return items.items[0];
        return self.push(.{ .concat = try items.toOwnedSlice(self.arena) });
    }

    /// `{n}`, `{n,}`, `{n,m}` at the cursor. Returns null (cursor unchanged)
    /// when the brace does not open a valid counted repetition, in which case
    /// the caller treats `{` as a literal.
    fn tryCountedRepetition(self: *Parser) ?struct { min: u32, max: ?u32 } {
        var p = self.pos + 1; // past '{'
        const min_start = p;
        while (p < self.pat.len and std.ascii.isDigit(self.pat[p])) p += 1;
        if (p == min_start) return null;
        const min = std.fmt.parseInt(u32, self.pat[min_start..p], 10) catch return null;
        var max: ?u32 = min;
        if (p < self.pat.len and self.pat[p] == ',') {
            p += 1;
            const max_start = p;
            while (p < self.pat.len and std.ascii.isDigit(self.pat[p])) p += 1;
            max = if (p == max_start) null else (std.fmt.parseInt(u32, self.pat[max_start..p], 10) catch return null);
        }
        if (p >= self.pat.len or self.pat[p] != '}') return null;
        if (max) |m| if (m < min) return null;
        if (min > 1000 or (max orelse 0) > 1000) return null;
        self.pos = p + 1;
        return .{ .min = min, .max = max };
    }

    fn parseRepeat(self: *Parser) Error!u32 {
        var atom = try self.parseAtom();
        while (self.peek()) |c| {
            var min: u32 = 0;
            var max: ?u32 = null;
            switch (c) {
                '*' => self.pos += 1,
                '+' => {
                    self.pos += 1;
                    min = 1;
                },
                '?' => {
                    self.pos += 1;
                    max = 1;
                },
                '{' => {
                    const rep = self.tryCountedRepetition() orelse break;
                    min = rep.min;
                    max = rep.max;
                },
                else => break,
            }
            // Lazy suffix: irrelevant for match/no-match.
            if (self.peek() == '?') self.pos += 1;
            atom = try self.push(.{ .repeat = .{ .child = atom, .min = min, .max = max } });
        }
        return atom;
    }

    fn parseFlagGroup(self: *Parser) Error!u32 {
        // Cursor is just past "(?".
        var on = true;
        var flags = self.flags;
        while (self.peek()) |c| {
            switch (c) {
                'i' => flags.fold = on,
                'm' => flags.multiline = on,
                's' => flags.dotall = on,
                'x', 'u', 'U', 'R' => return error.UnsupportedSyntax,
                '-' => on = false,
                ':' => {
                    self.pos += 1;
                    const saved = self.flags;
                    self.flags = flags;
                    const inner = try self.parseAlt();
                    if (self.peek() != ')') return error.UnbalancedParen;
                    self.pos += 1;
                    self.flags = saved;
                    return inner;
                },
                ')' => {
                    self.pos += 1;
                    // Applies to the rest of the enclosing group.
                    self.flags = flags;
                    return self.push(.empty);
                },
                else => return error.UnsupportedSyntax,
            }
            self.pos += 1;
        }
        return error.UnbalancedParen;
    }

    fn parseAtom(self: *Parser) Error!u32 {
        const c = self.peek() orelse return error.UnsupportedSyntax;
        switch (c) {
            '(' => {
                self.pos += 1;
                if (self.peek() == '?') {
                    self.pos += 1;
                    if (self.peek()) |f| if (f == '=' or f == '!' or f == '<' or f == 'P') return error.UnsupportedSyntax;
                    return self.parseFlagGroup();
                }
                const saved = self.flags;
                const inner = try self.parseAlt();
                if (self.peek() != ')') return error.UnbalancedParen;
                self.pos += 1;
                self.flags = saved;
                return inner;
            },
            ')' => return error.UnbalancedParen,
            '[' => return self.parseClass(),
            '.' => {
                self.pos += 1;
                return self.push(.{ .any = self.flags.dotall });
            },
            '^' => {
                self.pos += 1;
                return self.push(.{ .assert = if (self.flags.multiline) .bol_ml else .bol });
            },
            '$' => {
                self.pos += 1;
                return self.push(.{ .assert = if (self.flags.multiline) .eol_ml else .eol });
            },
            '*', '+', '?' => return error.InvalidRepetition,
            '\\' => return self.parseEscapeAtom(),
            else => {
                const cp = try self.nextCodepoint();
                return self.push(.{ .char = .{ .cp = cp, .fold = self.flags.fold } });
            },
        }
    }

    fn parseEscapeAtom(self: *Parser) Error!u32 {
        self.pos += 1; // '\'
        const e = self.peek() orelse return error.InvalidEscape;
        switch (e) {
            'A' => {
                self.pos += 1;
                return self.push(.{ .assert = .boa });
            },
            'z', 'Z' => {
                self.pos += 1;
                return self.push(.{ .assert = .eoa });
            },
            'b' => {
                self.pos += 1;
                return self.push(.{ .assert = .wordb });
            },
            'B' => {
                self.pos += 1;
                return self.push(.{ .assert = .nwordb });
            },
            's', 'S', 'd', 'D', 'w', 'W', 'p', 'P' => {
                var sets: Sets = .{};
                var negated = false;
                try self.parseNamedSet(&sets, &negated);
                const idx = try self.pushClass(.{ .ranges = &.{}, .sets = sets, .negated = negated });
                return self.push(.{ .class = .{ .idx = idx, .fold = self.flags.fold } });
            },
            else => {
                const cp = try self.parseEscapedChar();
                return self.push(.{ .char = .{ .cp = cp, .fold = self.flags.fold } });
            },
        }
    }

    /// Cursor on the letter of `\s`-style escape. Sets flags; `\P{..}` and the
    /// uppercase variants become the complement.
    fn parseNamedSet(self: *Parser, sets: *Sets, negated: *bool) Error!void {
        const e = self.peek() orelse return error.InvalidEscape;
        self.pos += 1;
        switch (e) {
            's' => sets.space = true,
            'S' => sets.not_space = true,
            'd' => sets.digit = true,
            'D' => sets.not_digit = true,
            'w' => sets.word = true,
            'W' => sets.not_word = true,
            'p', 'P' => {
                if (self.peek() != '{') return error.UnsupportedSyntax;
                const start = self.pos + 1;
                const end = std.mem.indexOfScalarPos(u8, self.pat, start, '}') orelse return error.UnsupportedSyntax;
                const name = self.pat[start..end];
                self.pos = end + 1;
                if (std.mem.eql(u8, name, "Alphabetic") or std.mem.eql(u8, name, "L") or std.mem.eql(u8, name, "Letter")) {
                    sets.alpha = true;
                } else return error.UnsupportedSyntax;
                if (e == 'P') negated.* = !negated.*;
            },
            else => unreachable,
        }
    }

    /// Cursor just past '\' on a non-class escape. Returns the literal scalar.
    fn parseEscapedChar(self: *Parser) Error!u21 {
        const e = self.peek() orelse return error.InvalidEscape;
        self.pos += 1;
        switch (e) {
            'n' => return '\n',
            'r' => return '\r',
            't' => return '\t',
            'f' => return 0x0C,
            'v' => return 0x0B,
            '0' => return 0,
            'a' => return 0x07,
            'x', 'u', 'U' => {
                if (self.peek() == '{') {
                    const start = self.pos + 1;
                    const end = std.mem.indexOfScalarPos(u8, self.pat, start, '}') orelse return error.InvalidEscape;
                    const cp = std.fmt.parseInt(u21, self.pat[start..end], 16) catch return error.InvalidEscape;
                    self.pos = end + 1;
                    return cp;
                }
                const digits: usize = switch (e) {
                    'x' => 2,
                    'u' => 4,
                    else => 8,
                };
                if (self.pos + digits > self.pat.len) return error.InvalidEscape;
                const cp = std.fmt.parseInt(u21, self.pat[self.pos .. self.pos + digits], 16) catch return error.InvalidEscape;
                self.pos += digits;
                return cp;
            },
            else => {
                if (std.ascii.isAlphanumeric(e)) return error.InvalidEscape;
                // Escaped punctuation / symbol: literal. Multi-byte scalars
                // after a backslash are also taken literally.
                self.pos -= 1;
                return self.nextCodepoint();
            },
        }
    }

    fn parseClass(self: *Parser) Error!u32 {
        self.pos += 1; // '['
        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            self.pos += 1;
        }
        var ranges: std.ArrayListUnmanaged(Range) = .empty;
        var sets: Sets = .{};
        var first = true;
        while (true) {
            const c = self.peek() orelse return error.UnterminatedClass;
            if (c == ']' and !first) {
                self.pos += 1;
                break;
            }
            first = false;
            if (c == '[' and self.peekAt(1) == ':') return error.UnsupportedSyntax;
            var lo: u21 = undefined;
            if (c == '\\') {
                self.pos += 1;
                const e = self.peek() orelse return error.InvalidEscape;
                switch (e) {
                    's', 'S', 'd', 'D', 'w', 'W', 'p', 'P' => {
                        var set_negated = false;
                        try self.parseNamedSet(&sets, &set_negated);
                        if (set_negated) return error.UnsupportedSyntax;
                        continue;
                    },
                    else => lo = try self.parseEscapedChar(),
                }
            } else {
                lo = try self.nextCodepoint();
            }
            var hi = lo;
            if (self.peek() == '-' and self.peekAt(1) != null and self.peekAt(1) != ']') {
                self.pos += 1;
                if (self.peek() == '\\') {
                    self.pos += 1;
                    const e = self.peek() orelse return error.InvalidEscape;
                    switch (e) {
                        's', 'S', 'd', 'D', 'w', 'W', 'p', 'P' => return error.UnsupportedSyntax,
                        else => hi = try self.parseEscapedChar(),
                    }
                } else {
                    hi = try self.nextCodepoint();
                }
                if (hi < lo) return error.UnsupportedSyntax;
            }
            try ranges.append(self.arena, .{ .lo = lo, .hi = hi });
        }
        const idx = try self.pushClass(.{
            .ranges = try ranges.toOwnedSlice(self.arena),
            .sets = sets,
            .negated = negated,
        });
        return self.push(.{ .class = .{ .idx = idx, .fold = self.flags.fold } });
    }
};

// ---------------------------------------------------------------------------
// Compiler → program
// ---------------------------------------------------------------------------

const Compiler = struct {
    arena: std.mem.Allocator,
    nodes: []const Node,
    prog: std.ArrayListUnmanaged(Inst) = .empty,

    fn pc(self: *Compiler) u32 {
        return @intCast(self.prog.items.len);
    }

    fn emitInst(self: *Compiler, inst: Inst) Error!u32 {
        if (self.prog.items.len >= max_program_len) return error.PatternTooLarge;
        try self.prog.append(self.arena, inst);
        return @intCast(self.prog.items.len - 1);
    }

    fn emit(self: *Compiler, idx: u32) Error!void {
        switch (self.nodes[idx]) {
            .empty => {},
            .char => |c| _ = try self.emitInst(.{ .char = .{ .cp = c.cp, .fold = c.fold } }),
            .class => |c| _ = try self.emitInst(.{ .class = .{ .idx = c.idx, .fold = c.fold } }),
            .any => |dotall| _ = try self.emitInst(.{ .any = dotall }),
            .assert => |a| _ = try self.emitInst(.{ .assert = a }),
            .concat => |items| for (items) |child| try self.emit(child),
            .alt => |branches| {
                var jumps: std.ArrayListUnmanaged(u32) = .empty;
                for (branches, 0..) |branch, i| {
                    if (i + 1 == branches.len) {
                        try self.emit(branch);
                        break;
                    }
                    const split = try self.emitInst(.{ .split = .{ .x = self.pc() + 1, .y = 0 } });
                    try self.emit(branch);
                    try jumps.append(self.arena, try self.emitInst(.{ .jmp = 0 }));
                    self.prog.items[split].split.y = self.pc();
                }
                for (jumps.items) |j| self.prog.items[j].jmp = self.pc();
            },
            .repeat => |rep| {
                for (0..rep.min) |_| try self.emit(rep.child);
                if (rep.max) |max| {
                    var splits: std.ArrayListUnmanaged(u32) = .empty;
                    for (0..max - rep.min) |_| {
                        try splits.append(self.arena, try self.emitInst(.{ .split = .{ .x = self.pc() + 1, .y = 0 } }));
                        try self.emit(rep.child);
                    }
                    for (splits.items) |s| self.prog.items[s].split.y = self.pc();
                } else {
                    const loop = self.pc();
                    const split = try self.emitInst(.{ .split = .{ .x = self.pc() + 1, .y = 0 } });
                    try self.emit(rep.child);
                    _ = try self.emitInst(.{ .jmp = loop });
                    self.prog.items[split].split.y = self.pc();
                }
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub const Regex = struct {
    prog: []const Inst,
    classes: []const Class,
    /// Backing storage for `prog`, `classes`, and every class range table.
    arena: std.heap.ArenaAllocator,

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) Error!Regex {
        if (pattern.len == 0) return error.EmptyPattern;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var parser = Parser{ .arena = a, .pat = pattern };
        const root = try parser.parseAlt();
        if (parser.pos != pattern.len) return error.UnbalancedParen;

        var compiler = Compiler{ .arena = a, .nodes = parser.nodes.items };
        try compiler.emit(root);
        _ = try compiler.emitInst(.match);

        return .{
            .prog = compiler.prog.items,
            .classes = parser.classes.items,
            .arena = arena,
        };
    }

    pub fn deinit(self: *Regex) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// True when the pattern matches anywhere in `text` (unanchored search),
    /// like Rust's `Regex::is_match`.
    pub fn isMatch(self: *const Regex, text: []const u8) bool {
        var vm = Vm{ .re = self };
        return vm.run(text);
    }

    /// `Regex::is_match` applied to each line of `text` (`str::lines`
    /// semantics: split on '\n', a trailing '\r' stripped, no trailing empty
    /// line). True if any line matches.
    pub fn anyLineMatches(self: *const Regex, text: []const u8) bool {
        var it = lineIterator(text);
        while (it.next()) |line| if (self.isMatch(line)) return true;
        return false;
    }
};

/// Rust `str::lines` iterator over a byte slice.
pub const LineIterator = struct {
    rest: []const u8,
    done: bool = false,

    pub fn next(self: *LineIterator) ?[]const u8 {
        if (self.done) return null;
        if (std.mem.indexOfScalar(u8, self.rest, '\n')) |nl| {
            var line = self.rest[0..nl];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            self.rest = self.rest[nl + 1 ..];
            return line;
        }
        self.done = true;
        if (self.rest.len == 0) return null;
        var line = self.rest;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return line;
    }
};

pub fn lineIterator(text: []const u8) LineIterator {
    return .{ .rest = text };
}

const ThreadList = struct {
    pcs: [max_program_len]u32 = undefined,
    len: usize = 0,
    /// Generation stamp per pc; a pc is "in the list" when its stamp equals
    /// the list's current generation. Avoids clearing the array per step.
    mark: [max_program_len]u32 = [_]u32{0} ** max_program_len,
    gen: u32 = 1,

    fn clear(self: *ThreadList) void {
        self.len = 0;
        self.gen +%= 1;
        if (self.gen == 0) {
            @memset(&self.mark, 0);
            self.gen = 1;
        }
    }

    fn contains(self: *const ThreadList, pc: u32) bool {
        return self.mark[pc] == self.gen;
    }

    fn add(self: *ThreadList, pc: u32) void {
        self.mark[pc] = self.gen;
        self.pcs[self.len] = pc;
        self.len += 1;
    }
};

const Ctx = struct {
    prev: ?u21,
    next: ?u21,
    at_start: bool,
};

const Vm = struct {
    re: *const Regex,
    lists: [2]ThreadList = .{ .{}, .{} },
    stack: [max_program_len]u32 = undefined,

    fn assertHolds(a: Assert, ctx: Ctx) bool {
        return switch (a) {
            .bol, .boa => ctx.at_start,
            .bol_ml => ctx.at_start or ctx.prev == '\n',
            .eol, .eoa => ctx.next == null,
            .eol_ml => ctx.next == null or ctx.next == '\n',
            .wordb => wordAt(ctx.prev) != wordAt(ctx.next),
            .nwordb => wordAt(ctx.prev) == wordAt(ctx.next),
        };
    }

    fn wordAt(c: ?u21) bool {
        return if (c) |cp| isWord(cp) else false;
    }

    /// Follow epsilon edges from `start`, adding consuming instructions to
    /// `list`. Returns true if a `match` instruction is reachable.
    fn addThread(self: *Vm, list: *ThreadList, start: u32, ctx: Ctx) bool {
        var sp: usize = 0;
        self.stack[sp] = start;
        sp += 1;
        while (sp > 0) {
            sp -= 1;
            const pc = self.stack[sp];
            if (list.contains(pc)) continue;
            list.add(pc);
            switch (self.re.prog[pc]) {
                .match => return true,
                .jmp => |t| {
                    self.stack[sp] = t;
                    sp += 1;
                },
                .split => |s| {
                    // Push y first so x is explored first (order is
                    // irrelevant for is_match but keeps traces readable).
                    self.stack[sp] = s.y;
                    sp += 1;
                    self.stack[sp] = s.x;
                    sp += 1;
                },
                .assert => |a| if (assertHolds(a, ctx)) {
                    self.stack[sp] = pc + 1;
                    sp += 1;
                },
                .char, .class, .any => {},
            }
        }
        return false;
    }

    fn consumes(self: *const Vm, pc: u32, c: u21) bool {
        return switch (self.re.prog[pc]) {
            .char => |ch| if (ch.fold) foldLower(ch.cp) == foldLower(c) else ch.cp == c,
            .class => |cl| self.re.classes[cl.idx].matches(c, cl.fold),
            .any => |dotall| dotall or c != '\n',
            else => false,
        };
    }

    fn run(self: *Vm, text: []const u8) bool {
        var cur_idx: usize = 0;
        var pos: usize = 0;
        var prev: ?u21 = null;
        var cur = decodeAt(text, pos);
        self.lists[0].clear();
        self.lists[1].clear();
        while (true) {
            const clist = &self.lists[cur_idx];
            const nlist = &self.lists[cur_idx ^ 1];
            // Unanchored search: a fresh attempt may begin at every position.
            if (self.addThread(clist, 0, .{ .prev = prev, .next = if (cur) |c| c.cp else null, .at_start = pos == 0 })) return true;
            const c = cur orelse return false;
            const next_pos = pos + c.len;
            const next = decodeAt(text, next_pos);
            const next_ctx: Ctx = .{ .prev = c.cp, .next = if (next) |n| n.cp else null, .at_start = false };
            nlist.clear();
            for (clist.pcs[0..clist.len]) |pc| {
                if (self.consumes(pc, c.cp)) {
                    if (self.addThread(nlist, pc + 1, next_ctx)) return true;
                }
            }
            prev = c.cp;
            cur = next;
            pos = next_pos;
            cur_idx ^= 1;
        }
    }
};

pub const Decoded = struct { cp: u21, len: usize };

/// Case-fold `text` the way the engine folds (`(?i)`): ASCII, Latin-1, Greek
/// and Cyrillic lowercase. Caller owns the result.
pub fn foldLowerAlloc(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var pos: usize = 0;
    while (decodeAt(text, pos)) |d| : (pos += d.len) {
        const folded = foldLower(d.cp);
        if (folded == d.cp) {
            try out.appendSlice(allocator, text[pos .. pos + d.len]);
        } else {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(folded, &buf) catch unreachable;
            try out.appendSlice(allocator, buf[0..n]);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Case-insensitive substring test: `needle` must already be folded with
/// `foldLowerAlloc`; `hay` is folded on the fly. Mirrors Rust's
/// `text.to_lowercase().contains(needle_lowercase)` for the scripts the
/// engine folds.
pub fn containsFolded(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var start: usize = 0;
    while (start < hay.len) {
        var hp = start;
        var np: usize = 0;
        while (np < needle.len) {
            const h = decodeAt(hay, hp) orelse break;
            const n = decodeAt(needle, np) orelse break;
            if (foldLower(h.cp) != n.cp) break;
            hp += h.len;
            np += n.len;
        }
        if (np == needle.len) return true;
        const d = decodeAt(hay, start) orelse return false;
        start += d.len;
    }
    return false;
}

/// True when every scalar in `line` is whitespace (Rust `str::trim().is_empty()`).
pub fn isBlank(line: []const u8) bool {
    var pos: usize = 0;
    while (decodeAt(line, pos)) |d| : (pos += d.len) if (!isSpace(d.cp)) return false;
    return true;
}

/// Decode the scalar at `pos`; invalid bytes decode as U+FFFD one byte at a
/// time so matching always makes progress.
pub fn decodeAt(text: []const u8, pos: usize) ?Decoded {
    if (pos >= text.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[pos]) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (pos + len > text.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(text[pos .. pos + len]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = len };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn matches(pattern: []const u8, text: []const u8) !bool {
    var re = try Regex.compile(std.testing.allocator, pattern);
    defer re.deinit();
    return re.isMatch(text);
}

test "literals, alternation, groups, and unanchored search" {
    try std.testing.expect(try matches("abc", "xxabcxx"));
    try std.testing.expect(!try matches("abd", "xxabcxx"));
    try std.testing.expect(try matches("cat|dog", "hotdog"));
    try std.testing.expect(try matches("(?:ab)+c", "zababc"));
    try std.testing.expect(try matches("(a|b)c", "bc"));
    try std.testing.expect(!try matches("(a|b)c", "cc"));
}

test "quantifiers including counted and lazy forms" {
    try std.testing.expect(try matches("^a*$", ""));
    try std.testing.expect(try matches("^a+$", "aaa"));
    try std.testing.expect(!try matches("^a+$", ""));
    try std.testing.expect(try matches("^ab?c$", "ac"));
    try std.testing.expect(try matches("^a{3}$", "aaa"));
    try std.testing.expect(!try matches("^a{3}$", "aa"));
    try std.testing.expect(try matches("^a{2,}$", "aaaa"));
    try std.testing.expect(!try matches("^a{2,}$", "a"));
    try std.testing.expect(try matches("^a{1,3}$", "aa"));
    try std.testing.expect(!try matches("^a{1,3}$", "aaaa"));
    try std.testing.expect(try matches("^x(?:ab){0,3}y$", "xababy"));
    try std.testing.expect(try matches("^a.*?b$", "axxb"));
    try std.testing.expect(try matches("^[^\\n]*?·$", "abc·"));
    try std.testing.expect(try matches("─{3,}", "──── done"));
    try std.testing.expect(!try matches("─{3,}", "── done"));
}

test "classes, ranges, negation, and named sets" {
    try std.testing.expect(try matches("^[a-c]+$", "abc"));
    try std.testing.expect(!try matches("^[a-c]+$", "abd"));
    try std.testing.expect(try matches("^[^\\r\\n]+$", "no newline"));
    try std.testing.expect(!try matches("^[^\\r\\n]+$", "has\nnewline"));
    try std.testing.expect(try matches("^\\s+\\S$", " \t x"));
    try std.testing.expect(try matches("^\\d+$", "123"));
    try std.testing.expect(!try matches("^\\d+$", "12a"));
    try std.testing.expect(try matches("^\\w+$", "hello_1"));
    try std.testing.expect(!try matches("^\\w+$", "hello world"));
    try std.testing.expect(try matches("^[\\s·]+$", " · "));
    try std.testing.expect(try matches("^[\\x{2800}-\\x{28FF}] ", "⠋ Thinking"));
    try std.testing.expect(try matches("^[\\u2800-\\u28FF]+\\s+\\S", "⠋⠙ Thinking"));
    try std.testing.expect(try matches("^[\\x{002A}\\x{00B7}\\x{2722}]\\s", "✢ working"));
    try std.testing.expect(try matches("^⚠[\\u{fe0e}\\u{fe0f}]?(?:\\s|$)", "⚠️ careful"));
    try std.testing.expect(try matches("^⚠[\\u{fe0e}\\u{fe0f}]?(?:\\s|$)", "⚠"));
    try std.testing.expect(try matches("\\p{Alphabetic}+\\w*ing\\b", "⬡ Thinking about it"));
    try std.testing.expect(!try matches("\\p{Alphabetic}+\\w*ing\\b", "⬡ Thinkingly"));
    try std.testing.expect(try matches("[\"\\x{201C}].+[\"\\x{201D}]", "MCP server \u{201C}db\u{201D} requests"));
}

test "anchors: plain, multi-line, absolute, and word boundaries" {
    try std.testing.expect(try matches("^b", "b"));
    try std.testing.expect(!try matches("^b", "a\nb"));
    try std.testing.expect(try matches("(?m)^b", "a\nb"));
    try std.testing.expect(try matches("a$", "a"));
    try std.testing.expect(!try matches("a$", "a\nb"));
    try std.testing.expect(try matches("(?m)a$", "a\nb"));
    try std.testing.expect(!try matches("a$", "a\n"));
    try std.testing.expect(try matches("(?m)a$", "a\n"));
    try std.testing.expect(try matches("\\Ax", "xy"));
    try std.testing.expect(!try matches("\\Ax", "yx"));
    try std.testing.expect(try matches("x\\z", "yx"));
    try std.testing.expect(!try matches("x\\z", "yx\n"));
    try std.testing.expect(try matches("x\\s*\\z", "yx\n"));
    try std.testing.expect(try matches("yes\\b", "yes, proceed"));
    try std.testing.expect(!try matches("yes\\b", "yesterday"));
    try std.testing.expect(try matches("\\bAccept\\b", "❯ Accept"));
    try std.testing.expect(try matches("^$", ""));
}

test "dot and the (?s) flag" {
    try std.testing.expect(try matches("a.b", "axb"));
    try std.testing.expect(!try matches("a.b", "a\nb"));
    try std.testing.expect(try matches("(?s)a.b", "a\nb"));
    try std.testing.expect(try matches("(?s)Do\\s+you\\s+trust", "Do you\ntrust"));
}

test "case-insensitive flag, scoped to its group" {
    try std.testing.expect(try matches("(?i)esc to close\\s*$", "ESC To Close"));
    try std.testing.expect(!try matches("esc to close", "ESC To Close"));
    try std.testing.expect(try matches("(?i)^\\s*❯?\\s*yes\\b", "  ❯ Yes"));
    try std.testing.expect(try matches("(?i)[a-c]+", "ABC"));
    try std.testing.expect(try matches("(?i)[^a-c]", "d"));
    try std.testing.expect(!try matches("^(?i)[^a-c]$", "B"));
    try std.testing.expect(try matches("(?i:x)y", "Xy"));
    try std.testing.expect(!try matches("(?i:x)y", "XY"));
    try std.testing.expect(try matches("a(?i)b", "aB"));
    try std.testing.expect(!try matches("(?:a(?i)b)c", "aBC"));
    try std.testing.expect(try matches("(?i)über", "ÜBER"));
    try std.testing.expect(try matches("(?i)привет", "ПРИВЕТ"));
}

test "escapes" {
    try std.testing.expect(try matches("a\\.b", "a.b"));
    try std.testing.expect(!try matches("a\\.b", "axb"));
    try std.testing.expect(try matches("\\(\\d+[smh]\\)", "(12s)"));
    try std.testing.expect(try matches("\\[y/n\\]", "ok [y/n]"));
    try std.testing.expect(try matches("a\\tb", "a\tb"));
    try std.testing.expect(try matches("\\x41", "A"));
    try std.testing.expect(try matches("\\u2733 ", "✳ title"));
    try std.testing.expect(try matches("^\\x{2733} ", "✳ title"));
    try std.testing.expect(try matches("\\{", "{"));
    try std.testing.expect(try matches("a{", "a{")); // invalid counted repetition is literal
}

test "unsupported syntax is rejected at compile time" {
    try std.testing.expectError(error.UnsupportedSyntax, Regex.compile(std.testing.allocator, "(?=a)"));
    try std.testing.expectError(error.UnsupportedSyntax, Regex.compile(std.testing.allocator, "(?<=a)"));
    try std.testing.expectError(error.UnsupportedSyntax, Regex.compile(std.testing.allocator, "\\p{Greek}"));
    try std.testing.expectError(error.UnsupportedSyntax, Regex.compile(std.testing.allocator, "[[:alpha:]]"));
    try std.testing.expectError(error.InvalidEscape, Regex.compile(std.testing.allocator, "\\q"));
    try std.testing.expectError(error.UnbalancedParen, Regex.compile(std.testing.allocator, "(ab"));
    try std.testing.expectError(error.UnbalancedParen, Regex.compile(std.testing.allocator, "ab)"));
    try std.testing.expectError(error.UnterminatedClass, Regex.compile(std.testing.allocator, "[ab"));
    try std.testing.expectError(error.InvalidRepetition, Regex.compile(std.testing.allocator, "*a"));
    try std.testing.expectError(error.EmptyPattern, Regex.compile(std.testing.allocator, ""));
}

test "nested quantifiers stay linear (no catastrophic backtracking)" {
    // (a*)*b against a long run of 'a' with no 'b' is the classic blow-up.
    var re = try Regex.compile(std.testing.allocator, "(?:a*)*b");
    defer re.deinit();
    const text = "a" ** 4000;
    try std.testing.expect(!re.isMatch(text));
    // The codex working-state footer regex over a screen-sized input.
    var footer = try Regex.compile(
        std.testing.allocator,
        "(?m)^(?:[•◦][ \\t]+)?[^\\s›•◦■✗✓─][^\\r\\n]* \\((?:[0-9]+[hm] )*[0-9]+s(?: • [^\\r\\n]+? to interrupt)?\\)(?: · [^\\r\\n]*)?(?:\\r?\\n(?:[^•◦›■✗✓─\\r\\n][^\\r\\n]*|•[ \\t]+(?:Queued\\s+follow-up\\s+inputs|Messages\\s+to\\s+be\\s+submitted\\s+after\\s+next\\s+tool\\s+call(?:\\s+\\(press\\s+[^\\r\\n]+?\\s+to\\s+interrupt\\s+and\\s+send\\s+immediately\\))?|Messages\\s+to\\s+be\\s+submitted\\s+at\\s+end\\s+of\\s+turn)|›[⠁⠂⠄⠈⠐⠠⡀⢀][^\\r\\n]*)?)*\\s*\\z",
    );
    defer footer.deinit();
    const screen = ("some output line that is fairly long and ordinary\n" ** 60) ++ "• Working (3m 11s • esc to interrupt)\n";
    try std.testing.expect(footer.isMatch(screen));
    try std.testing.expect(!footer.isMatch(screen ++ "› next prompt\n• later response\n"));
}

test "manifest-shaped patterns behave like the Rust regex crate" {
    // claude live_turn_working
    try std.testing.expect(try matches("^\\s*[⏸⏵].*esc to interrupt(?:\\s|·|$)", "⏵ Thinking… (esc to interrupt · 12s)"));
    try std.testing.expect(try matches("^\\s*[\\x{002A}\\x{00B7}\\x{2722}\\x{2733}\\x{2736}\\x{273B}\\x{273D}]\\s+\\S.*…(?:\\s+\\(\\d+[smh](?:\\s|·)|\\s*$)", "✻ Cogitating… (12s · ↓ 1.2k tokens)"));
    // codex osc_title_working: spinner braille in the title
    try std.testing.expect(try matches("(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)", "⠋ codex"));
    try std.testing.expect(!try matches("(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)", "codex ready"));
    // codex trust_directory
    try std.testing.expect(try matches("\\A> You are in [^\\r\\n]+(?:\\r?\\n|$)", "> You are in /tmp/x\nDo you trust"));
    // qwen working timer
    try std.testing.expect(try matches("^\\s*\\(\\d+(?:m(?:\\s+\\d+s)?|s)\\s·\\sesc to cancel\\)\\s*$", "  (1m 12s · esc to cancel)"));
    // kimi moon spinner
    try std.testing.expect(try matches("^\\s*(🌕|🌖|🌗|🌘|🌑|🌒|🌓|🌔)\\s*$", " 🌗 "));
    // claude mcp elicitation
    try std.testing.expect(try matches("(?i)^\\s*MCP server [\"\\x{201C}].+[\"\\x{201D}] requests your input\\s*$", "MCP server \"db\" requests your input"));
    try std.testing.expect(try matches("^\\s*\\x{276F}?\\s*Accept\\b", "❯ Accept"));
}

test "line iterator follows Rust str::lines" {
    var it = lineIterator("a\r\nb\n\nc");
    try std.testing.expectEqualStrings("a", it.next().?);
    try std.testing.expectEqualStrings("b", it.next().?);
    try std.testing.expectEqualStrings("", it.next().?);
    try std.testing.expectEqualStrings("c", it.next().?);
    try std.testing.expect(it.next() == null);

    var trailing = lineIterator("x\n");
    try std.testing.expectEqualStrings("x", trailing.next().?);
    try std.testing.expect(trailing.next() == null);

    var empty = lineIterator("");
    try std.testing.expect(empty.next() == null);

    var re = try Regex.compile(std.testing.allocator, "^exact line$");
    defer re.deinit();
    try std.testing.expect(re.anyLineMatches("before\nexact line\nafter"));
    try std.testing.expect(!re.anyLineMatches("before\nexact line extra\nafter"));
}

test "folded contains mirrors lowercase substring search" {
    const needle = try foldLowerAlloc(std.testing.allocator, "Do You Want To Proceed?");
    defer std.testing.allocator.free(needle);
    try std.testing.expectEqualStrings("do you want to proceed?", needle);
    try std.testing.expect(containsFolded("  DO YOU WANT TO PROCEED? (y/n)", needle));
    try std.testing.expect(!containsFolded("do you want to continue?", needle));
    try std.testing.expect(containsFolded("x", ""));
    const cyr = try foldLowerAlloc(std.testing.allocator, "ПРИВЕТ");
    defer std.testing.allocator.free(cyr);
    try std.testing.expect(containsFolded("скажи привет миру", cyr));
    try std.testing.expect(isBlank(" \t\u{00A0}"));
    try std.testing.expect(!isBlank(" x "));
}

test "invalid UTF-8 never stalls matching" {
    try std.testing.expect(try matches("b", "a\xffb"));
    try std.testing.expect(!try matches("c", "a\xff\xfe"));
}
