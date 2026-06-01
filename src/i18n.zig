//! UI 文案国际化（i18n）核心：扁平字段目录 + 当前语言。
//! 设计见 docs/superpowers/specs/2026-06-01-i18n-infrastructure-design.md
const std = @import("std");
const builtin = @import("builtin");

pub const Lang = enum { en, zh_CN };

/// 调用点直接替换的扁平文案。字段无默认值 → 任一 locale 漏填某字段编译期报错，
/// 这是「方案 A」comptime 完整性保证的落地（无需手写 assert）。
pub const Strings = struct {
    language_name: []const u8,
};

const en = Strings{
    .language_name = "English",
};

const zh_CN = Strings{
    .language_name = "中文",
};

// Set once at startup before any UI thread exists (see main.zig startup wiring).
// Not thread-safe; do not call setLang after App.init.
var current: *const Strings = &en;
var active_lang: Lang = .en;

/// 当前语言的文案表。调用点：`i18n.s().language_name`。
pub fn s() *const Strings {
    return current;
}

pub fn lang() Lang {
    return active_lang;
}

pub fn setLang(l: Lang) void {
    active_lang = l;
    current = switch (l) {
        .en => &en,
        .zh_CN => &zh_CN,
    };
}

/// config `language` 取值。auto = 跟随系统 locale。
pub const LanguageSetting = enum {
    auto,
    en,
    zh_CN,

    /// 解析 config 值；大小写/分隔符兼容；未知返回 null。
    pub fn parse(value: []const u8) ?LanguageSetting {
        var buf: [16]u8 = undefined;
        if (value.len > buf.len) return null;
        for (value, 0..) |c, i| {
            buf[i] = switch (c) {
                'A'...'Z' => c + 32, // tolower
                '_' => '-',
                else => c,
            };
        }
        const v = buf[0..value.len];
        if (std.mem.eql(u8, v, "auto")) return .auto;
        if (std.mem.eql(u8, v, "en")) return .en;
        if (std.mem.eql(u8, v, "zh-cn") or std.mem.eql(u8, v, "zh")) return .zh_CN;
        return null;
    }
};

/// 把 locale 标签（如 "zh_CN.UTF-8" / "en_US" / "zh"）映射到支持的语言。
/// 以 "zh" 开头（不分大小写）→ zh_CN；其余 → en。
pub fn langFromLocaleTag(tag: []const u8) Lang {
    if (tag.len >= 2) {
        const a = tag[0];
        const b = tag[1];
        const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
        const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
        if (la == 'z' and lb == 'h') return .zh_CN;
    }
    return .en;
}

// Windows 在 env 缺失 LANG/LC_* 时，从用户界面语言（LANGID）兜底。
// 主语言号 = LANGID & 0x3FF；LANG_CHINESE = 0x04。仅由 Windows 构建验证，
// 原生（Linux）测试不覆盖此分支。
extern "kernel32" fn GetUserDefaultUILanguage() callconv(.winapi) u16;

/// 读系统 locale 环境变量（LC_ALL → LC_MESSAGES → LANG），映射到语言。
/// 都读不到时：Windows 回落到 GetUserDefaultUILanguage，其余平台 → en。
/// 调用方提供 allocator；本函数内部释放临时串。
pub fn detectSystemLang(allocator: std.mem.Allocator) Lang {
    const vars = [_][]const u8{ "LC_ALL", "LC_MESSAGES", "LANG" };
    for (vars) |name| {
        const val = std.process.getEnvVarOwned(allocator, name) catch continue;
        defer allocator.free(val);
        if (val.len == 0) continue;
        return langFromLocaleTag(val);
    }
    if (builtin.os.tag == .windows) {
        if ((GetUserDefaultUILanguage() & 0x3ff) == 0x04) return .zh_CN; // LANG_CHINESE
    }
    return .en;
}

/// 按优先级解析最终语言：config 显式值优先；auto 跟随系统 locale；
/// 任何不可解析情形回退 en。
pub fn resolve(allocator: std.mem.Allocator, setting: LanguageSetting) Lang {
    return switch (setting) {
        .en => .en,
        .zh_CN => .zh_CN,
        .auto => detectSystemLang(allocator),
    };
}

/// 启动时调用一次：解析 config 的 language 设定并设置当前语言。
pub fn applyConfig(allocator: std.mem.Allocator, setting: LanguageSetting) void {
    setLang(resolve(allocator, setting));
}

test "setLang switches the active strings table" {
    defer setLang(.en); // 复位，避免污染其它测试
    setLang(.en);
    try std.testing.expectEqualStrings("English", s().language_name);
    try std.testing.expect(lang() == .en);
    setLang(.zh_CN);
    try std.testing.expectEqualStrings("中文", s().language_name);
    try std.testing.expect(lang() == .zh_CN);
}

test "langFromLocaleTag maps zh* to zh_CN, others to en" {
    try std.testing.expect(langFromLocaleTag("zh_CN.UTF-8") == .zh_CN);
    try std.testing.expect(langFromLocaleTag("zh") == .zh_CN);
    try std.testing.expect(langFromLocaleTag("ZH-cn") == .zh_CN);
    try std.testing.expect(langFromLocaleTag("zh_TW") == .zh_CN); // v1 唯一中文落点
    try std.testing.expect(langFromLocaleTag("en_US.UTF-8") == .en);
    try std.testing.expect(langFromLocaleTag("fr") == .en);
    try std.testing.expect(langFromLocaleTag("") == .en);
    try std.testing.expect(langFromLocaleTag("z") == .en);
}

test "LanguageSetting.parse handles aliases and invalid" {
    try std.testing.expect(LanguageSetting.parse("auto").? == .auto);
    try std.testing.expect(LanguageSetting.parse("en").? == .en);
    try std.testing.expect(LanguageSetting.parse("zh-CN").? == .zh_CN);
    try std.testing.expect(LanguageSetting.parse("zh_CN").? == .zh_CN);
    try std.testing.expect(LanguageSetting.parse("ZH").? == .zh_CN);
    try std.testing.expect(LanguageSetting.parse("de") == null);
    try std.testing.expect(LanguageSetting.parse("") == null);
}

test "resolve: explicit setting beats system; auto follows env-mapping" {
    const a = std.testing.allocator;
    try std.testing.expect(resolve(a, .en) == .en);
    try std.testing.expect(resolve(a, .zh_CN) == .zh_CN);
    // auto 取决于运行环境 env，至少应返回二者之一且不崩溃。
    const auto = resolve(a, .auto);
    try std.testing.expect(auto == .en or auto == .zh_CN);
}
