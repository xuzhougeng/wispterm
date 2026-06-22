//! Skill Center v2 model: a local wispterm **library** of skills that the user
//! deploys to / imports from a **target = machine × software**. The library is
//! always local; the panel lists library skills and drives deploy/import through
//! a popup picker. Pure model + a concurrency-safe Session that runs the (local)
//! library scan off the UI thread. UI strings live in i18n; transfer/diff live in
//! sibling modules.
const std = @import("std");
const scan = @import("skill_scan.zig");
const install = @import("skill_install.zig");
const tool_import = @import("tool_import.zig");

/// Target software — a skills root under $HOME on the target machine. Both use
/// the same SKILL.md directory format, so a library skill deploys to either.
pub const Software = enum {
    claude,
    codex,
    pub fn rootRel(self: Software) []const u8 {
        return switch (self) {
            .claude => ".claude/skills",
            .codex => ".codex/skills",
        };
    }
};

/// A deploy/import destination: a machine × a software root.
pub const Target = struct {
    machine_id: []u8, // owned: "local", "ssh:<profile>", or "wsl"
    machine_label: []u8, // owned display name
    software: Software,
    is_local: bool,
    /// A WSL distro reached on the Windows host via `wsl.exe --exec sh -lc`.
    /// Mutually exclusive with `is_local`/SSH: a WSL target is neither local nor
    /// an SSH connection, so guards must check this before falling back to a
    /// "needs an SSH connection" error. `dupe` defaults it false; `clone`
    /// preserves it.
    is_wsl: bool = false,

    pub fn dupe(
        allocator: std.mem.Allocator,
        machine_id: []const u8,
        machine_label: []const u8,
        software: Software,
        is_local: bool,
    ) !Target {
        const id = try allocator.dupe(u8, machine_id);
        errdefer allocator.free(id);
        const label = try allocator.dupe(u8, machine_label);
        return .{ .machine_id = id, .machine_label = label, .software = software, .is_local = is_local };
    }
    pub fn clone(self: Target, allocator: std.mem.Allocator) !Target {
        var t = try dupe(allocator, self.machine_id, self.machine_label, self.software, self.is_local);
        t.is_wsl = self.is_wsl;
        return t;
    }
    /// True when reaching this target requires an SSH connection (i.e. it is a
    /// remote SSH profile, not the local host and not a WSL distro). Centralizes
    /// the picker/scan/transfer guards so a WSL target is never rejected for
    /// "no connection".
    pub fn requiresSshConn(self: Target) bool {
        return !self.is_local and !self.is_wsl;
    }
    pub fn deinit(self: *Target, allocator: std.mem.Allocator) void {
        allocator.free(self.machine_id);
        allocator.free(self.machine_label);
        self.* = undefined;
    }
};

/// One skill in the wispterm library (`<config>/skills/<name>/SKILL.md`).
pub const LibrarySkill = struct {
    name: []u8,
    rel_path: []u8, // relative to the library root, e.g. "<name>/SKILL.md"
    agg_hash: ?[]u8,
    pub fn clone(self: LibrarySkill, allocator: std.mem.Allocator) !LibrarySkill {
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const rel_path = try allocator.dupe(u8, self.rel_path);
        errdefer allocator.free(rel_path);
        const agg_hash = if (self.agg_hash) |h| try allocator.dupe(u8, h) else null;
        return .{ .name = name, .rel_path = rel_path, .agg_hash = agg_hash };
    }
    pub fn deinit(self: *LibrarySkill, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.rel_path);
        if (self.agg_hash) |h| allocator.free(h);
        self.* = undefined;
    }
};

pub fn freeLibrary(allocator: std.mem.Allocator, lib: []LibrarySkill) void {
    for (lib) |*s| s.deinit(allocator);
    allocator.free(lib);
}

pub const ToolApproval = enum {
    ask,
};

pub const ToolSkill = struct {
    name: []u8,
    executable_path: []u8,
    skill_path: ?[]u8,
    enabled: bool,
    approval: ToolApproval = .ask,

    pub fn clone(self: ToolSkill, allocator: std.mem.Allocator) !ToolSkill {
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);
        const executable_path = try allocator.dupe(u8, self.executable_path);
        errdefer allocator.free(executable_path);
        const skill_path = if (self.skill_path) |p| try allocator.dupe(u8, p) else null;
        return .{
            .name = name,
            .executable_path = executable_path,
            .skill_path = skill_path,
            .enabled = self.enabled,
            .approval = self.approval,
        };
    }

    pub fn deinit(self: *ToolSkill, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.executable_path);
        if (self.skill_path) |p| allocator.free(p);
        self.* = undefined;
    }
};

pub const LibraryEntry = union(enum) {
    prompt: LibrarySkill,
    tool: ToolSkill,

    pub fn deinit(self: *LibraryEntry, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .prompt => |*s| s.deinit(allocator),
            .tool => |*t| t.deinit(allocator),
        }
        self.* = undefined;
    }

    pub fn clone(self: LibraryEntry, allocator: std.mem.Allocator) !LibraryEntry {
        return switch (self) {
            .prompt => |s| .{ .prompt = try s.clone(allocator) },
            .tool => |t| .{ .tool = try t.clone(allocator) },
        };
    }

    pub fn name(self: LibraryEntry) []const u8 {
        return switch (self) {
            .prompt => |s| s.name,
            .tool => |t| t.name,
        };
    }
};

pub fn freeEntries(allocator: std.mem.Allocator, entries: []LibraryEntry) void {
    for (entries) |*entry| entry.deinit(allocator);
    allocator.free(entries);
}

pub fn entriesFromLibrary(allocator: std.mem.Allocator, lib: []LibrarySkill) ![]LibraryEntry {
    const entries = allocator.alloc(LibraryEntry, lib.len) catch |err| {
        freeLibrary(allocator, lib);
        return err;
    };
    for (lib, 0..) |skill, i| {
        entries[i] = .{ .prompt = skill };
    }
    allocator.free(lib); // strings moved into `entries`
    return entries;
}

/// Convert owned scan rows (from `skill_scan.scanLocation`) into a LibrarySkill
/// slice. Takes ownership of the rows' backing strings (moves them); frees the
/// rows slice itself. `provider` is ignored (v2 keys by name).
pub fn libraryFromRows(allocator: std.mem.Allocator, rows: []scan.SkillRow) ![]LibrarySkill {
    // Always consumes `rows`: on the alloc-failure path the strings haven't been
    // moved yet, so free them; on success the strings move into `out` and only
    // the rows slice is freed.
    const out = allocator.alloc(LibrarySkill, rows.len) catch |e| {
        scan.freeRows(allocator, rows);
        return e;
    };
    for (rows, 0..) |r, i| {
        out[i] = .{ .name = r.name, .rel_path = r.rel_path, .agg_hash = r.agg_hash };
    }
    allocator.free(rows); // strings moved into `out`
    return out;
}

pub const Decision = enum { direct, confirm, noop };

/// Decide what copying a skill onto a destination implies.
/// `target_present` false → `direct` (nothing to overwrite). Both hashes present
/// and equal → `noop`. Differing, or either hash unknown → `confirm`.
pub fn overwriteDecision(target_present: bool, target_hash: ?[]const u8, src_hash: ?[]const u8) Decision {
    if (!target_present) return .direct;
    const th = target_hash orelse return .confirm;
    const sh = src_hash orelse return .confirm;
    return if (std.mem.eql(u8, th, sh)) .noop else .confirm;
}

// --- Overlay state (interaction) ---

pub const Purpose = enum { deploy, import_ };
pub const Marker = enum { new_, same, differ };

/// Target picker: a flat list of "machine · software" entries to choose from.
pub const PickerState = struct {
    purpose: Purpose,
    skill_name: []u8, // library skill being deployed (deploy); "" for import
    labels: [][]u8, // owned entry labels
    targets: []Target, // parallel, owned
    sel: usize = 0,

    fn deinit(self: *PickerState, allocator: std.mem.Allocator) void {
        allocator.free(self.skill_name);
        for (self.labels) |l| allocator.free(l);
        allocator.free(self.labels);
        for (self.targets) |*t| t.deinit(allocator);
        allocator.free(self.targets);
        self.* = undefined;
    }
};

/// Import list: the chosen target's skills, marked vs the library.
pub const ImportState = struct {
    target: Target, // owned
    names: [][]u8, // owned target skill names
    markers: []Marker, // parallel
    sel: usize = 0,

    fn deinit(self: *ImportState, allocator: std.mem.Allocator) void {
        self.target.deinit(allocator);
        for (self.names) |n| allocator.free(n);
        allocator.free(self.names);
        allocator.free(self.markers);
        self.* = undefined;
    }
};

/// Pending overwrite confirmation for a deploy/import that would clobber a
/// differing same-name skill.
pub const ConfirmState = struct {
    text: []u8, // owned display message
    is_import: bool,
    target: Target, // owned
    name: []u8, // owned skill name

    fn deinit(self: *ConfirmState, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.target.deinit(allocator);
        allocator.free(self.name);
        self.* = undefined;
    }
};

/// Editable single-line URL buffer for the "install from GitHub" overlay.
pub const UrlInputState = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,

    pub fn insertSlice(self: *UrlInputState, allocator: std.mem.Allocator, bytes: []const u8) void {
        self.buf.appendSlice(allocator, bytes) catch {};
    }
    pub fn backspace(self: *UrlInputState) void {
        if (self.buf.items.len > 0) self.buf.items.len -= 1;
    }
    pub fn text(self: *const UrlInputState) []const u8 {
        return self.buf.items;
    }
    fn deinit(self: *UrlInputState, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
        self.* = undefined;
    }
};

/// Checklist of skills enumerated from a GitHub URL. Owns the resolved RepoRef
/// (with its ref filled in) and the entry list; `checked` is parallel to
/// `entries`. `sel` is the cursor row.
pub const InstallPickState = struct {
    repo: install.RepoRef,
    entries: []install.SkillEntry,
    checked: []bool,
    sel: usize = 0,

    pub fn toggle(self: *InstallPickState) void {
        if (self.sel < self.checked.len) self.checked[self.sel] = !self.checked[self.sel];
    }
    pub fn setAll(self: *InstallPickState, value: bool) void {
        for (self.checked) |*c| c.* = value;
    }
    pub fn anyChecked(self: *const InstallPickState) bool {
        for (self.checked) |c| if (c) return true;
        return false;
    }
    /// Owned clone of just the checked entries (caller frees via freeEntries).
    pub fn selectedEntries(self: *const InstallPickState, allocator: std.mem.Allocator) ![]install.SkillEntry {
        var out: std.ArrayListUnmanaged(install.SkillEntry) = .empty;
        errdefer {
            for (out.items) |*e| e.deinit(allocator);
            out.deinit(allocator);
        }
        for (self.entries, 0..) |e, i| {
            if (i < self.checked.len and self.checked[i]) try out.append(allocator, try e.clone(allocator));
        }
        return out.toOwnedSlice(allocator);
    }
    fn deinit(self: *InstallPickState, allocator: std.mem.Allocator) void {
        self.repo.deinit(allocator);
        install.freeEntries(allocator, self.entries);
        allocator.free(self.checked);
        self.* = undefined;
    }
};

/// Scrollable in-panel preview of a skill's SKILL.md (the Skill Center is a
/// non-terminal tab, so it can't host a split preview pane — it shows the text
/// in this overlay instead). `scroll` is a wrapped-line offset; the renderer
/// clamps it against the actual wrapped height each frame.
pub const TextPreviewState = struct {
    title: []u8, // owned
    content: []u8, // owned
    scroll: usize = 0,

    fn deinit(self: *TextPreviewState, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub const ToolImportConfirmState = struct {
    tool_id: []u8,
    function_name: []u8,
    source_path: []u8,
    staged_binary_path: []u8,
    warning_text: []u8,
    owns_staging_dir: bool = true,
    scroll: usize = 0,

    pub fn deinit(self: *ToolImportConfirmState, allocator: std.mem.Allocator) void {
        if (self.owns_staging_dir) tool_import.cleanupStagedBinaryPath(self.staged_binary_path);
        allocator.free(self.tool_id);
        allocator.free(self.function_name);
        allocator.free(self.source_path);
        allocator.free(self.staged_binary_path);
        allocator.free(self.warning_text);
        self.* = undefined;
    }
};

pub const ToolImportPreviewState = struct {
    tool_id: []u8,
    function_name: []u8,
    source_path: []u8,
    staged_binary_path: []u8,
    skill_md: []u8,
    doc_source: tool_import.DocSource,
    ai_review_required: bool,
    owns_staging_dir: bool = true,
    scroll: usize = 0,

    pub fn deinit(self: *ToolImportPreviewState, allocator: std.mem.Allocator) void {
        if (self.owns_staging_dir) tool_import.cleanupStagedBinaryPath(self.staged_binary_path);
        allocator.free(self.tool_id);
        allocator.free(self.function_name);
        allocator.free(self.source_path);
        allocator.free(self.staged_binary_path);
        allocator.free(self.skill_md);
        self.* = undefined;
    }
};

pub const ToolImportPreviewInit = struct {
    tool_id: []const u8,
    function_name: []const u8,
    source_path: []const u8,
    staged_binary_path: []const u8,
    skill_md: []const u8,
    doc_source: tool_import.DocSource,
    ai_review_required: bool,
};

pub const ToolImportConfirmInit = struct {
    tool_id: []const u8,
    function_name: []const u8,
    source_path: []const u8,
    staged_binary_path: []const u8,
    warning_text: []const u8,
};

pub const Overlay = union(enum) {
    none,
    picker: PickerState,
    import_list: ImportState,
    confirm: ConfirmState,
    busy: []u8, // owned message
    url_input: UrlInputState,
    install_pick: InstallPickState,
    text_preview: TextPreviewState,
    tool_import_confirm: ToolImportConfirmState,
    tool_import_preview: ToolImportPreviewState,

    pub fn deinit(self: *Overlay, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .none => {},
            .picker => |*p| p.deinit(allocator),
            .import_list => |*i| i.deinit(allocator),
            .confirm => |*c| c.deinit(allocator),
            .busy => |m| allocator.free(m),
            .text_preview => |*t| t.deinit(allocator),
            .tool_import_confirm => |*t| t.deinit(allocator),
            .tool_import_preview => |*t| t.deinit(allocator),
            .url_input => |*u| u.deinit(allocator),
            .install_pick => |*p| p.deinit(allocator),
        }
        self.* = .none;
    }
};

/// Panel state: the library list, selection, and the active overlay.
pub const PanelModel = struct {
    allocator: std.mem.Allocator,
    entries: ?[]LibraryEntry = null,
    sel_row: usize = 0,
    scroll: usize = 0,
    overlay: Overlay = .none,

    pub fn init(allocator: std.mem.Allocator) PanelModel {
        return .{ .allocator = allocator };
    }

    /// Take ownership of a fresh library list; clamp selection.
    pub fn setLibrary(self: *PanelModel, lib: []LibrarySkill) void {
        const entries = entriesFromLibrary(self.allocator, lib) catch {
            self.freeEntryList();
            self.clampSelection();
            return;
        };
        self.setEntries(entries);
    }

    /// Take ownership of a fresh mixed entry list; clamp selection.
    pub fn setEntries(self: *PanelModel, entries: []LibraryEntry) void {
        self.freeEntryList();
        self.entries = entries;
        self.clampSelection();
    }

    fn freeEntryList(self: *PanelModel) void {
        if (self.entries) |entries| {
            freeEntries(self.allocator, entries);
            self.entries = null;
        }
    }

    fn clampSelection(self: *PanelModel) void {
        const n = self.entryCount();
        if (n == 0) {
            self.sel_row = 0;
        } else if (self.sel_row >= n) {
            self.sel_row = n - 1;
        }
    }

    pub fn entryCount(self: *const PanelModel) usize {
        return if (self.entries) |entries| entries.len else 0;
    }

    pub fn selectedEntry(self: *const PanelModel) ?LibraryEntry {
        const entries = self.entries orelse return null;
        if (self.sel_row >= entries.len) return null;
        return entries[self.sel_row];
    }

    /// Selected library skill, or null.
    pub fn selected(self: *const PanelModel) ?LibrarySkill {
        const entry = self.selectedEntry() orelse return null;
        return switch (entry) {
            .prompt => |skill| skill,
            .tool => null,
        };
    }

    pub fn toggleSelectedTool(self: *PanelModel) bool {
        const entries = self.entries orelse return false;
        if (self.sel_row >= entries.len) return false;
        switch (entries[self.sel_row]) {
            .prompt => return false,
            .tool => |*tool| {
                tool.enabled = !tool.enabled;
                return true;
            },
        }
    }

    /// Replace the overlay (frees the previous one's owned data).
    pub fn setOverlay(self: *PanelModel, ov: Overlay) void {
        self.overlay.deinit(self.allocator);
        self.overlay = ov;
    }
    pub fn clearOverlay(self: *PanelModel) void {
        self.overlay.deinit(self.allocator);
    }

    pub fn takeToolImportConfirm(self: *PanelModel) ?ToolImportConfirmState {
        if (self.overlay != .tool_import_confirm) return null;
        const confirm = self.overlay.tool_import_confirm;
        self.overlay = .none;
        return confirm;
    }

    /// Open the scrollable SKILL.md preview overlay (owns copies of the strings).
    pub fn openTextPreview(self: *PanelModel, title: []const u8, content: []const u8) !void {
        const t = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(t);
        const c = try self.allocator.dupe(u8, content);
        self.setOverlay(.{ .text_preview = .{ .title = t, .content = c } });
    }

    pub fn openToolImportConfirm(self: *PanelModel, input: ToolImportConfirmInit) !void {
        const tool_id = try self.allocator.dupe(u8, input.tool_id);
        errdefer self.allocator.free(tool_id);
        const function_name = try self.allocator.dupe(u8, input.function_name);
        errdefer self.allocator.free(function_name);
        const source_path = try self.allocator.dupe(u8, input.source_path);
        errdefer self.allocator.free(source_path);
        const staged_binary_path = try self.allocator.dupe(u8, input.staged_binary_path);
        errdefer self.allocator.free(staged_binary_path);
        const warning_text = try self.allocator.dupe(u8, input.warning_text);
        self.setOverlay(.{ .tool_import_confirm = .{
            .tool_id = tool_id,
            .function_name = function_name,
            .source_path = source_path,
            .staged_binary_path = staged_binary_path,
            .warning_text = warning_text,
        } });
    }

    pub fn openToolImportPreview(self: *PanelModel, input: ToolImportPreviewInit) !void {
        const tool_id = try self.allocator.dupe(u8, input.tool_id);
        errdefer self.allocator.free(tool_id);
        const function_name = try self.allocator.dupe(u8, input.function_name);
        errdefer self.allocator.free(function_name);
        const source_path = try self.allocator.dupe(u8, input.source_path);
        errdefer self.allocator.free(source_path);
        const staged_binary_path = try self.allocator.dupe(u8, input.staged_binary_path);
        errdefer self.allocator.free(staged_binary_path);
        const skill_md = try self.allocator.dupe(u8, input.skill_md);
        self.setOverlay(.{ .tool_import_preview = .{
            .tool_id = tool_id,
            .function_name = function_name,
            .source_path = source_path,
            .staged_binary_path = staged_binary_path,
            .skill_md = skill_md,
            .doc_source = input.doc_source,
            .ai_review_required = input.ai_review_required,
        } });
    }

    pub fn isTextPreview(self: *const PanelModel) bool {
        return self.overlay == .text_preview;
    }

    /// Scroll the text preview by `delta` wrapped lines (saturating at 0; the
    /// upper bound is clamped by the renderer against the wrapped height).
    pub fn scrollTextPreview(self: *PanelModel, delta: isize) void {
        switch (self.overlay) {
            .text_preview => |*tp| {
                if (delta < 0) {
                    const d: usize = @intCast(-delta);
                    tp.scroll = if (tp.scroll > d) tp.scroll - d else 0;
                } else {
                    tp.scroll +|= @intCast(delta);
                }
            },
            .tool_import_confirm => |*tp| {
                if (delta < 0) {
                    const d: usize = @intCast(-delta);
                    tp.scroll = if (tp.scroll > d) tp.scroll - d else 0;
                } else {
                    tp.scroll +|= @intCast(delta);
                }
            },
            .tool_import_preview => |*tp| {
                if (delta < 0) {
                    const d: usize = @intCast(-delta);
                    tp.scroll = if (tp.scroll > d) tp.scroll - d else 0;
                } else {
                    tp.scroll +|= @intCast(delta);
                }
            },
            else => {},
        }
    }

    pub fn deinit(self: *PanelModel) void {
        self.overlay.deinit(self.allocator);
        self.freeEntryList();
        self.* = undefined;
    }
};

/// Owned unit of background scan work — scans the (local) library off the UI
/// thread and returns an owned `[]LibraryEntry`. `destroy` frees `ctx`.
pub const ScanWork = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque, std.mem.Allocator) anyerror![]LibraryEntry,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
};

/// Structured result of a background skill-center op, produced on the worker
/// thread and consumed on the UI thread. Owns its strings/rows; `deinit` frees
/// them. The UI thread builds overlays/toasts from this — the worker never
/// touches UI state.
pub const OpResult = union(enum) {
    /// import-scan finished: show the import list built from `rows`.
    import_scan: struct { target: Target, rows: []scan.SkillRow },
    /// deploy-scan finished: UI decides noop/direct/confirm from `rows`.
    deploy_scan: struct { target: Target, name: []u8, src_hash: ?[]u8, rows: []scan.SkillRow },
    /// transfer finished: show success/failure toast.
    transfer: struct { is_import: bool, ok: bool, err_summary: ?[]u8 },
    /// preview finished: show the fetched SKILL.md in the markdown preview panel.
    preview: struct { title: []u8, content: []u8 },
    /// install-enumerate finished: show the checklist built from `entries`.
    install_enumerate: struct { repo: install.RepoRef, entries: []install.SkillEntry, truncated: bool },
    /// install-download finished: report counts via toast.
    install_done: struct { installed: usize, overwritten: usize, failed: usize },
    tool_import_preview: ToolImportPreviewState,
    tool_import_failed: []u8,
    /// generic failure before work could run (e.g. lost connection).
    failed,

    pub fn deinit(self: *OpResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .import_scan => |*v| {
                v.target.deinit(allocator);
                scan.freeRows(allocator, v.rows);
            },
            .deploy_scan => |*v| {
                v.target.deinit(allocator);
                allocator.free(v.name);
                if (v.src_hash) |h| allocator.free(h);
                scan.freeRows(allocator, v.rows);
            },
            .transfer => |*v| {
                if (v.err_summary) |s| allocator.free(s);
            },
            .preview => |*v| {
                allocator.free(v.title);
                allocator.free(v.content);
            },
            .install_enumerate => |*v| {
                v.repo.deinit(allocator);
                install.freeEntries(allocator, v.entries);
            },
            .install_done => {},
            .tool_import_preview => |*v| v.deinit(allocator),
            .tool_import_failed => |s| allocator.free(s),
            .failed => {},
        }
        self.* = .failed;
    }
};

/// Turn a finished import scan into an `OpResult`. An unreachable source (offline,
/// auth failure, or a non-POSIX local host) becomes `.failed` so the UI shows a
/// connection error instead of an empty import list; a reachable source — even
/// with zero rows — yields `.import_scan` (a legitimately empty list). Takes
/// ownership of `outcome` (moves its rows into the result, or frees them on
/// failure) and of the already-cloned `target` (frees it on failure).
pub fn importScanResult(allocator: std.mem.Allocator, outcome: *scan.ScanOutcome, target: Target) OpResult {
    if (!outcome.reachable) {
        outcome.deinit(allocator);
        var t = target;
        t.deinit(allocator);
        return .failed;
    }
    const rows = outcome.rows;
    outcome.rows = &.{};
    return .{ .import_scan = .{ .target = target, .rows = rows } };
}

/// Owned unit of background op work. `run` returns an `OpResult` (never errors —
/// failures are encoded in the result). `destroy` frees `ctx`.
pub const OpWork = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque, std.mem.Allocator) OpResult,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
};

/// Concurrency-safe holder for the panel. `mutex` guards `model` + `status`; the
/// worker runs I/O without the lock and takes it only to publish via
/// `finishScan`; `closing` + join-on-deinit give UAF safety.
pub const Session = struct {
    allocator: std.mem.Allocator,
    model: PanelModel,
    mutex: std.Thread.Mutex = .{},
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scan_generation: u64 = 0,
    scan_thread: ?std.Thread = null,
    op_thread: ?std.Thread = null,
    op_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    op_pending: ?OpResult = null,
    op_wake: ?*const fn () void = null,
    status: []u8 = &.{}, // owned "Scanning…"/"Failed"/""

    pub fn create(allocator: std.mem.Allocator) !*Session {
        const self = try allocator.create(Session);
        self.* = .{ .allocator = allocator, .model = PanelModel.init(allocator) };
        return self;
    }

    pub fn destroy(self: *Session) void {
        const allocator = self.allocator;
        self.closing.store(true, .release);
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
        if (self.op_thread) |t| {
            t.join();
            self.op_thread = null;
        }
        if (self.op_pending) |*p| {
            p.deinit(allocator);
            self.op_pending = null;
        }
        self.model.deinit();
        if (self.status.len > 0) allocator.free(self.status);
        self.* = undefined;
        allocator.destroy(self);
    }

    fn setStatusLocked(self: *Session, text: []const u8) void {
        const next = self.allocator.dupe(u8, text) catch return;
        if (self.status.len > 0) self.allocator.free(self.status);
        self.status = next;
    }

    /// Start a background library scan. UI thread only.
    pub fn scanAsync(self: *Session, work: ScanWork) void {
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
        self.mutex.lock();
        self.scan_generation +%= 1;
        const generation = self.scan_generation;
        self.setStatusLocked("Scanning…");
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, scanThreadMain, .{ self, work, generation }) catch {
            self.mutex.lock();
            if (generation == self.scan_generation) self.setStatusLocked("Failed");
            self.mutex.unlock();
            work.destroy(work.ctx, self.allocator);
            return;
        };
        self.scan_thread = thread;
    }

    /// Publish a library scan result under the lock if current; else discard.
    /// Always consumes ownership of `entries`. Worker-thread only.
    pub fn finishScan(self: *Session, generation: u64, entries: []LibraryEntry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.closing.load(.acquire) and generation == self.scan_generation) {
            self.model.setEntries(entries);
            self.setStatusLocked("");
        } else {
            freeEntries(self.allocator, entries);
        }
    }

    pub fn publishScanFailure(self: *Session, generation: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.closing.load(.acquire) and generation == self.scan_generation) {
            self.setStatusLocked("Failed");
        }
    }

    /// Test-only: wait for an in-flight worker.
    pub fn joinForTest(self: *Session) void {
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
    }

    /// Start a background op. On ANY false return (busy, or spawn failure) the
    /// caller still owns `work` and is responsible for calling its destroy — we
    /// never destroy it here, so the caller's destroy is the single owner.
    /// Shows `busy_msg` as the visible panel status while the op runs.
    /// UI thread only.
    pub fn startOp(self: *Session, work: OpWork, wake: *const fn () void, busy_msg: []const u8) bool {
        if (self.op_thread != null and !self.op_done.load(.acquire)) {
            return false; // busy — never join-wait a possibly-slow op on the UI thread
        }
        if (self.op_thread) |t| {
            t.join(); // previous op already finished; non-blocking
            self.op_thread = null;
        }
        self.op_wake = wake;
        self.op_done.store(false, .release);

        self.mutex.lock();
        self.setStatusLocked(busy_msg); // visible "Syncing…" in the panel header
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, opThreadMain, .{ self, work }) catch {
            self.op_done.store(true, .release);
            self.mutex.lock();
            self.setStatusLocked(""); // the op never started; clear the busy status
            self.mutex.unlock();
            return false; // caller owns `work` and will destroy it (no double-free)
        };
        self.op_thread = thread;
        return true;
    }

    /// Take the published op result (if any), clearing it. UI thread only.
    pub fn takePendingOp(self: *Session) ?OpResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        const r = self.op_pending;
        self.op_pending = null;
        return r;
    }

    /// Test-only: wait for an in-flight op worker.
    pub fn joinOpForTest(self: *Session) void {
        if (self.op_thread) |t| {
            t.join();
            self.op_thread = null;
        }
    }
};

fn scanThreadMain(session: *Session, work: ScanWork, generation: u64) void {
    defer work.destroy(work.ctx, session.allocator);
    const entries = work.run(work.ctx, session.allocator) catch {
        session.publishScanFailure(generation);
        return;
    };
    session.finishScan(generation, entries);
}

fn opThreadMain(session: *Session, work: OpWork) void {
    defer work.destroy(work.ctx, session.allocator);
    var result = work.run(work.ctx, session.allocator);

    session.mutex.lock();
    const closing = session.closing.load(.acquire);
    if (closing) {
        session.mutex.unlock();
        result.deinit(session.allocator);
    } else {
        if (session.op_pending) |*p| p.deinit(session.allocator); // discard stale (shouldn't happen)
        session.op_pending = result;
        session.setStatusLocked(""); // op finished — clear the "Syncing…" status
        session.mutex.unlock();
    }
    // op_done stays unconditional so destroy/startOp see the thread as finished.
    session.op_done.store(true, .release);
    // Only wake when we actually published — waking during teardown is pointless
    // and risks the woken main loop touching a Session being destroyed.
    if (!closing) {
        if (session.op_wake) |w| w();
    }
}

// --- Tests ---

fn ownedLib(allocator: std.mem.Allocator, names: []const []const u8) ![]LibrarySkill {
    const out = try allocator.alloc(LibrarySkill, names.len);
    for (names, 0..) |n, i| {
        out[i] = .{
            .name = try allocator.dupe(u8, n),
            .rel_path = try std.fmt.allocPrint(allocator, "{s}/SKILL.md", .{n}),
            .agg_hash = try allocator.dupe(u8, "h"),
        };
    }
    return out;
}

test "skill_center: overwriteDecision" {
    try std.testing.expectEqual(Decision.direct, overwriteDecision(false, null, "h"));
    try std.testing.expectEqual(Decision.noop, overwriteDecision(true, "h", "h"));
    try std.testing.expectEqual(Decision.confirm, overwriteDecision(true, "h", "x"));
    try std.testing.expectEqual(Decision.confirm, overwriteDecision(true, null, "h"));
    try std.testing.expectEqual(Decision.confirm, overwriteDecision(true, "h", null));
}

test "skill_center: setLibrary clamps selection" {
    const a = std.testing.allocator;
    var m = PanelModel.init(a);
    defer m.deinit();
    m.setLibrary(try ownedLib(a, &.{ "x", "y", "z" }));
    m.sel_row = 2;
    try std.testing.expectEqual(@as(usize, 3), m.entryCount());
    m.setLibrary(try ownedLib(a, &.{"x"})); // shrink → clamp
    try std.testing.expectEqual(@as(usize, 0), m.sel_row);
    try std.testing.expectEqualStrings("x", m.selected().?.name);
}

test "skill_center: PanelModel holds mixed prompt and tool entries" {
    const a = std.testing.allocator;
    var entries = try a.alloc(LibraryEntry, 2);
    entries[0] = .{ .prompt = .{
        .name = try a.dupe(u8, "docs"),
        .rel_path = try a.dupe(u8, "docs/SKILL.md"),
        .agg_hash = try a.dupe(u8, "h"),
    } };
    entries[1] = .{ .tool = .{
        .name = try a.dupe(u8, "docx_review"),
        .executable_path = try a.dupe(u8, "/tmp/tools/docx_review/bin/docx-review"),
        .skill_path = try a.dupe(u8, "/tmp/tools/docx_review/SKILL.md"),
        .enabled = true,
        .approval = .ask,
    } };

    var m = PanelModel.init(a);
    defer m.deinit();
    m.setEntries(entries);

    try std.testing.expectEqual(@as(usize, 2), m.entryCount());
    try std.testing.expectEqualStrings("docs", m.selectedEntry().?.name());
    try std.testing.expectEqualStrings("docs", m.selected().?.name);
    m.sel_row = 1;
    try std.testing.expectEqualStrings("docx_review", m.selectedEntry().?.name());
    try std.testing.expectEqual(@as(?LibrarySkill, null), m.selected());
}

test "skill_center: toggleSelectedTool flips only selected tool entries" {
    const a = std.testing.allocator;
    var entries = try a.alloc(LibraryEntry, 2);
    entries[0] = .{ .prompt = .{
        .name = try a.dupe(u8, "docs"),
        .rel_path = try a.dupe(u8, "docs/SKILL.md"),
        .agg_hash = null,
    } };
    entries[1] = .{ .tool = .{
        .name = try a.dupe(u8, "docx_review"),
        .executable_path = try a.dupe(u8, "/tmp/tools/docx_review/bin/docx-review"),
        .skill_path = null,
        .enabled = false,
        .approval = .ask,
    } };

    var m = PanelModel.init(a);
    defer m.deinit();
    m.setEntries(entries);

    try std.testing.expect(!m.toggleSelectedTool());
    m.sel_row = 1;
    try std.testing.expect(m.toggleSelectedTool());
    try std.testing.expect(m.selectedEntry().?.tool.enabled);
    try std.testing.expect(m.toggleSelectedTool());
    try std.testing.expect(!m.selectedEntry().?.tool.enabled);
}

test "skill_center: setEntries and setLibrary clamp selection" {
    const a = std.testing.allocator;
    var m = PanelModel.init(a);
    defer m.deinit();
    m.setLibrary(try ownedLib(a, &.{ "a", "b", "c" }));
    m.sel_row = 2;

    var entries = try a.alloc(LibraryEntry, 1);
    entries[0] = .{ .tool = .{
        .name = try a.dupe(u8, "tool"),
        .executable_path = try a.dupe(u8, "/tmp/tool"),
        .skill_path = null,
        .enabled = true,
        .approval = .ask,
    } };
    m.setEntries(entries);
    try std.testing.expectEqual(@as(usize, 0), m.sel_row);
    try std.testing.expectEqualStrings("tool", m.selectedEntry().?.name());
    try std.testing.expectEqual(@as(?LibrarySkill, null), m.selected());

    m.setEntries(try a.alloc(LibraryEntry, 0));
    try std.testing.expectEqual(@as(usize, 0), m.entryCount());
    try std.testing.expectEqual(@as(?LibraryEntry, null), m.selectedEntry());
    try std.testing.expectEqual(@as(?LibrarySkill, null), m.selected());
}

test "skill_center: overlay set/clear frees owned data (no leak)" {
    const a = std.testing.allocator;
    var m = PanelModel.init(a);
    defer m.deinit();

    // picker overlay with owned labels + targets
    var labels = try a.alloc([]u8, 2);
    labels[0] = try a.dupe(u8, "local · Claude Code");
    labels[1] = try a.dupe(u8, "web · Codex");
    var targets = try a.alloc(Target, 2);
    targets[0] = try Target.dupe(a, "local", "local", .claude, true);
    targets[1] = try Target.dupe(a, "ssh:web", "web", .codex, false);
    m.setOverlay(.{ .picker = .{ .purpose = .deploy, .skill_name = try a.dupe(u8, "pdf"), .labels = labels, .targets = targets } });
    try std.testing.expect(m.overlay == .picker);

    // replace with a confirm overlay → picker freed
    m.setOverlay(.{ .confirm = .{
        .text = try a.dupe(u8, "overwrite?"),
        .is_import = false,
        .target = try Target.dupe(a, "ssh:web", "web", .codex, false),
        .name = try a.dupe(u8, "pdf"),
    } });
    try std.testing.expect(m.overlay == .confirm);
    m.clearOverlay();
    try std.testing.expect(m.overlay == .none);
}

test "skill_center: UrlInputState edits and frees" {
    const a = std.testing.allocator;
    var m = PanelModel.init(a);
    defer m.deinit();
    m.setOverlay(.{ .url_input = .{} });
    switch (m.overlay) {
        .url_input => |*u| {
            u.insertSlice(a, "https://github.com/o/r");
            u.backspace();
            try std.testing.expectEqualStrings("https://github.com/o/", u.text());
        },
        else => return error.WrongOverlay,
    }
    // PanelModel.deinit frees the overlay buffer; testing allocator catches leaks.
}

test "skill_center: InstallPickState toggle/setAll/selectedEntries" {
    const a = std.testing.allocator;
    var repo = try install.parseGithubUrl(a, "https://github.com/o/r/tree/main/skills");
    errdefer repo.deinit(a);
    var entries = try a.alloc(install.SkillEntry, 2);
    inline for (.{ "a", "b" }, 0..) |nm, i| {
        var files = try a.alloc([]u8, 1);
        files[0] = try std.fmt.allocPrint(a, "skills/{s}/SKILL.md", .{nm});
        entries[i] = .{ .name = try a.dupe(u8, nm), .root_path = try std.fmt.allocPrint(a, "skills/{s}", .{nm}), .files = files };
    }
    const checked = try a.alloc(bool, 2);
    checked[0] = false;
    checked[1] = false;

    var m = PanelModel.init(a);
    defer m.deinit();
    m.setOverlay(.{ .install_pick = .{ .repo = repo, .entries = entries, .checked = checked } });
    switch (m.overlay) {
        .install_pick => |*p| {
            p.sel = 1;
            p.toggle();
            try std.testing.expect(p.anyChecked());
            const sel = try p.selectedEntries(a);
            defer install.freeEntries(a, sel);
            try std.testing.expectEqual(@as(usize, 1), sel.len);
            try std.testing.expectEqualStrings("b", sel[0].name);
            p.setAll(true);
        },
        else => return error.WrongOverlay,
    }
}

test "skill_center: libraryFromRows moves ownership" {
    const a = std.testing.allocator;
    const rows = try a.alloc(scan.SkillRow, 1);
    rows[0] = .{ .provider = .claude, .name = try a.dupe(u8, "pdf"), .rel_path = try a.dupe(u8, "pdf/SKILL.md"), .agg_hash = try a.dupe(u8, "h") };
    const lib = try libraryFromRows(a, rows);
    defer freeLibrary(a, lib);
    try std.testing.expectEqual(@as(usize, 1), lib.len);
    try std.testing.expectEqualStrings("pdf", lib[0].name);
    try std.testing.expectEqualStrings("h", lib[0].agg_hash.?);
}

test "skill_center: text preview overlay opens, scrolls, and frees" {
    const a = std.testing.allocator;
    var m = PanelModel.init(a);
    defer m.deinit();

    try m.openTextPreview("pdf-tools / SKILL.md", "line1\nline2\nline3\n");
    try std.testing.expect(m.isTextPreview());
    try std.testing.expectEqual(@as(usize, 0), m.overlay.text_preview.scroll);

    m.scrollTextPreview(3);
    try std.testing.expectEqual(@as(usize, 3), m.overlay.text_preview.scroll);
    m.scrollTextPreview(-1);
    try std.testing.expectEqual(@as(usize, 2), m.overlay.text_preview.scroll);
    m.scrollTextPreview(-100); // saturates at 0
    try std.testing.expectEqual(@as(usize, 0), m.overlay.text_preview.scroll);

    // scrolling a non-preview overlay is a no-op (doesn't crash)
    m.clearOverlay();
    try std.testing.expect(!m.isTextPreview());
    m.scrollTextPreview(5);
}

test "skill_center: tool import preview overlay stores staged import" {
    const a = std.testing.allocator;
    var model = PanelModel.init(a);
    defer model.deinit();
    try model.openToolImportPreview(.{
        .tool_id = "agent_docx_review",
        .function_name = "agent_docx_review",
        .source_path = "/tmp/agent_docx_review",
        .staged_binary_path = "/tmp/stage/bin/agent_docx_review",
        .skill_md = "---\nname: agent_docx_review\n---\nDocx.",
        .doc_source = .skill_flag,
        .ai_review_required = false,
    });
    try std.testing.expect(model.overlay == .tool_import_preview);
}

test "skill_center: tool import confirm overlay stores staged import" {
    const a = std.testing.allocator;
    var model = PanelModel.init(a);
    defer model.deinit();
    try model.openToolImportConfirm(.{
        .tool_id = "agent_docx_review",
        .function_name = "agent_docx_review",
        .source_path = "/tmp/agent_docx_review",
        .staged_binary_path = "/tmp/stage/bin/agent_docx_review",
        .warning_text = "WispTerm will inspect this executable.",
    });
    try std.testing.expect(model.overlay == .tool_import_confirm);
}

const ToolImportStagePaths = struct {
    stage_root: []u8,
    staged_binary_path: []u8,
};

fn createToolImportStageForTest(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8) !ToolImportStagePaths {
    try tmp.dir.makePath("stage/bin");
    const rel = try std.fmt.allocPrint(allocator, "stage/bin/{s}", .{name});
    defer allocator.free(rel);
    try tmp.dir.writeFile(.{ .sub_path = rel, .data = "staged-bytes" });
    return .{
        .stage_root = try tmp.dir.realpathAlloc(allocator, "stage"),
        .staged_binary_path = try tmp.dir.realpathAlloc(allocator, rel),
    };
}

test "skill_center: tool import preview clearOverlay removes staged dir" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const stage = try createToolImportStageForTest(a, &tmp, "agent_docx_review");
    defer a.free(stage.stage_root);
    defer a.free(stage.staged_binary_path);

    var model = PanelModel.init(a);
    defer model.deinit();
    try model.openToolImportPreview(.{
        .tool_id = "agent_docx_review",
        .function_name = "agent_docx_review",
        .source_path = "/tmp/original/agent_docx_review",
        .staged_binary_path = stage.staged_binary_path,
        .skill_md = "---\nname: agent_docx_review\n---\nDocx.",
        .doc_source = .skill_flag,
        .ai_review_required = false,
    });
    model.clearOverlay();
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(stage.stage_root, .{}));
}

test "skill_center: tool import confirm clearOverlay removes staged dir" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const stage = try createToolImportStageForTest(a, &tmp, "agent_docx_review");
    defer a.free(stage.stage_root);
    defer a.free(stage.staged_binary_path);

    var model = PanelModel.init(a);
    defer model.deinit();
    try model.openToolImportConfirm(.{
        .tool_id = "agent_docx_review",
        .function_name = "agent_docx_review",
        .source_path = "/tmp/original/agent_docx_review",
        .staged_binary_path = stage.staged_binary_path,
        .warning_text = "Inspect this executable.",
    });
    model.clearOverlay();
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(stage.stage_root, .{}));
}

test "skill_center: taking tool import confirm preserves staged dir for caller" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const stage = try createToolImportStageForTest(a, &tmp, "agent_docx_review");
    defer a.free(stage.stage_root);
    defer a.free(stage.staged_binary_path);

    var model = PanelModel.init(a);
    defer model.deinit();
    try model.openToolImportConfirm(.{
        .tool_id = "agent_docx_review",
        .function_name = "agent_docx_review",
        .source_path = "/tmp/original/agent_docx_review",
        .staged_binary_path = stage.staged_binary_path,
        .warning_text = "Inspect this executable.",
    });

    var confirm = model.takeToolImportConfirm() orelse return error.ExpectedToolImportConfirm;
    try std.testing.expect(model.overlay == .none);
    try std.fs.accessAbsolute(stage.stage_root, .{});

    confirm.deinit(a);
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(stage.stage_root, .{}));
}

test "skill_center: tool import preview deinit removes staged dir" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const stage = try createToolImportStageForTest(a, &tmp, "agent_docx_review");
    defer a.free(stage.stage_root);
    defer a.free(stage.staged_binary_path);

    {
        var model = PanelModel.init(a);
        defer model.deinit();
        try model.openToolImportPreview(.{
            .tool_id = "agent_docx_review",
            .function_name = "agent_docx_review",
            .source_path = "/tmp/original/agent_docx_review",
            .staged_binary_path = stage.staged_binary_path,
            .skill_md = "---\nname: agent_docx_review\n---\nDocx.",
            .doc_source = .skill_flag,
            .ai_review_required = false,
        });
    }
    try std.testing.expectError(error.FileNotFound, std.fs.accessAbsolute(stage.stage_root, .{}));
}

test "skill_center: Session.finishScan publishes then discards stale (no leak)" {
    const a = std.testing.allocator;
    const session = try Session.create(a);
    defer session.destroy();

    session.scan_generation +%= 1;
    session.finishScan(session.scan_generation, try entriesFromLibrary(a, try ownedLib(a, &.{ "a", "b" })));
    try std.testing.expect(session.model.entries != null);
    try std.testing.expectEqual(@as(usize, 2), session.model.entryCount());

    session.scan_generation = 9;
    session.finishScan(3, try entriesFromLibrary(a, try ownedLib(a, &.{"stale"}))); // discarded + freed
    try std.testing.expectEqual(@as(usize, 2), session.model.entryCount());
}

const OpTestCtx = struct {
    a: std.mem.Allocator,
    result_ok: bool,
    fn run(ctx: *anyopaque, allocator: std.mem.Allocator) OpResult {
        const self: *OpTestCtx = @ptrCast(@alignCast(ctx));
        _ = allocator;
        return .{ .transfer = .{ .is_import = false, .ok = self.result_ok, .err_summary = null } };
    }
    fn destroy(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *OpTestCtx = @ptrCast(@alignCast(ctx));
        allocator.destroy(self);
    }
};

fn noopWake() void {}

test "startOp runs work and publishes a pending result" {
    const a = std.testing.allocator;
    const session = try Session.create(a);
    defer session.destroy();

    const ctx = try a.create(OpTestCtx);
    ctx.* = .{ .a = a, .result_ok = true };
    try std.testing.expect(session.startOp(.{ .ctx = ctx, .run = OpTestCtx.run, .destroy = OpTestCtx.destroy }, noopWake, "syncing"));
    session.joinOpForTest();

    var pending = session.takePendingOp() orelse return error.NoPending;
    defer pending.deinit(a);
    try std.testing.expect(pending == .transfer);
    try std.testing.expect(pending.transfer.ok);
    // consumed: a second take is empty
    try std.testing.expectEqual(@as(?OpResult, null), session.takePendingOp());
}

test "startOp rejects a second op while one is in flight" {
    const a = std.testing.allocator;
    const session = try Session.create(a);
    defer session.destroy();

    // Manually mark an op in flight without spawning real work, to test the guard.
    session.op_done.store(false, .release);
    session.op_thread = try std.Thread.spawn(.{}, struct {
        fn f() void {}
    }.f, .{});

    const ctx = try a.create(OpTestCtx);
    ctx.* = .{ .a = a, .result_ok = true };
    const accepted = session.startOp(.{ .ctx = ctx, .run = OpTestCtx.run, .destroy = OpTestCtx.destroy }, noopWake, "syncing");
    try std.testing.expect(!accepted); // busy → rejected
    // we own ctx since it was rejected; free it
    OpTestCtx.destroy(@ptrCast(ctx), a);
    // let the dummy thread be joinable at destroy
    session.op_done.store(true, .release);
}

test "Target.clone preserves the WSL discriminator" {
    const a = std.testing.allocator;
    var t = try Target.dupe(a, "wsl", "WSL", .claude, false);
    t.is_wsl = true;
    defer t.deinit(a);
    var c = try t.clone(a);
    defer c.deinit(a);
    try std.testing.expect(c.is_wsl);
    try std.testing.expectEqualStrings("wsl", c.machine_id);
    try std.testing.expect(!c.is_local);
}

test "Target.requiresSshConn is true only for non-local non-WSL targets" {
    const a = std.testing.allocator;
    var local = try Target.dupe(a, "local", "Local", .claude, true);
    defer local.deinit(a);
    try std.testing.expect(!local.requiresSshConn());

    var ssh = try Target.dupe(a, "ssh:web", "web", .codex, false);
    defer ssh.deinit(a);
    try std.testing.expect(ssh.requiresSshConn());

    var wsl = try Target.dupe(a, "wsl", "WSL", .claude, false);
    wsl.is_wsl = true;
    defer wsl.deinit(a);
    try std.testing.expect(!wsl.requiresSshConn());
}

test "importScanResult: unreachable source becomes failed (not an empty import list)" {
    const a = std.testing.allocator;
    var outcome = scan.ScanOutcome{ .reachable = false, .rows = &.{} };
    const tgt = try Target.dupe(a, "ssh:box", "box", .claude, false);
    var result = importScanResult(a, &outcome, tgt); // takes ownership of outcome + tgt
    defer result.deinit(a);
    try std.testing.expect(result == .failed);
}

test "importScanResult: reachable source carries its rows into import_scan" {
    const a = std.testing.allocator;
    const rows = try scan.parseLocationOutput(a, "pdf\tpdf/SKILL.md\tabc\n");
    var outcome = scan.ScanOutcome{ .reachable = true, .rows = rows };
    const tgt = try Target.dupe(a, "ssh:box", "box", .claude, false);
    var result = importScanResult(a, &outcome, tgt);
    defer result.deinit(a);
    try std.testing.expect(result == .import_scan);
    try std.testing.expectEqual(@as(usize, 1), result.import_scan.rows.len);
    try std.testing.expectEqualStrings("pdf", result.import_scan.rows[0].name);
}

test "importScanResult: reachable-but-empty source still opens an import list" {
    // Local targets are reachable=true even with zero skills — an empty scan must
    // open an (empty) import list, not be misread as a connection failure.
    const a = std.testing.allocator;
    var outcome = scan.ScanOutcome{ .reachable = true, .rows = &.{} };
    const tgt = try Target.dupe(a, "local", "Local", .claude, true);
    var result = importScanResult(a, &outcome, tgt);
    defer result.deinit(a);
    try std.testing.expect(result == .import_scan);
    try std.testing.expectEqual(@as(usize, 0), result.import_scan.rows.len);
}

test "OpResult.preview deinit frees title and content" {
    const a = std.testing.allocator;
    var r: OpResult = .{ .preview = .{
        .title = try a.dupe(u8, "roundtable"),
        .content = try a.dupe(u8, "# SKILL\nbody"),
    } };
    r.deinit(a); // must free both; testing allocator catches a leak
    try std.testing.expect(r == .failed); // deinit resets to .failed
}

test "skill_center: OpResult.install_enumerate deinit frees repo and entries" {
    const a = std.testing.allocator;
    var repo = try install.parseGithubUrl(a, "https://github.com/o/r/tree/main/skills");
    errdefer repo.deinit(a);
    var entries = try a.alloc(install.SkillEntry, 1);
    {
        var files = try a.alloc([]u8, 1);
        files[0] = try a.dupe(u8, "skills/foo/SKILL.md");
        entries[0] = .{ .name = try a.dupe(u8, "foo"), .root_path = try a.dupe(u8, "skills/foo"), .files = files };
    }
    var r: OpResult = .{ .install_enumerate = .{ .repo = repo, .entries = entries, .truncated = false } };
    r.deinit(a); // testing allocator catches a leak
    try std.testing.expect(r == .failed);
}

test "skill_center: OpResult.install_done deinit is a no-op" {
    const a = std.testing.allocator;
    var r: OpResult = .{ .install_done = .{ .installed = 3, .overwritten = 1, .failed = 0 } };
    r.deinit(a);
    try std.testing.expect(r == .failed);
}
