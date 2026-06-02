const std = @import("std");
const types = @import("ai_history_types.zig");
const source_mod = @import("ai_history_source.zig");
const session_persist = @import("session_persist.zig");
const codex_provider = @import("ai_history_provider_codex.zig");
const claude_provider = @import("ai_history_provider_claude.zig");
const remote_file = @import("platform/remote_file.zig");
const ssh_connection = @import("ssh_connection.zig");
const ai_history_cache = @import("ai_history_cache.zig");

pub const LoadState = enum { idle, scanning, ready, failed };
pub const TranscriptState = enum { idle, loading, ready, failed };
pub const MAX_METADATA_FILE_BYTES = 2 * 1024 * 1024;
pub const MAX_SCAN_METADATA_FILES: usize = 256;
pub const MAX_SCAN_METADATA_BYTES: u64 = 48 * 1024 * 1024;

pub const ScanBudget = struct {
    max_files: usize = MAX_SCAN_METADATA_FILES,
    max_bytes: u64 = MAX_SCAN_METADATA_BYTES,
};

pub const CacheUpdate = struct {
    records: []ai_history_cache.CacheRecord = &.{},
    owns_record_strings: bool = false,
};

pub const FileEntry = struct {
    provider: types.ProviderId,
    path: []const u8,
    bytes: []const u8,
};

pub const ScanResult = struct {
    rows: []types.SessionMeta,
    /// true  = `rows` is the complete, canonical set (sync / non-streaming);
    ///         the finalize REPLACES the session's rows with it.
    /// false = rows were streamed to the sink already and `rows` is empty;
    ///         the finalize only sorts what is already in the session.
    authoritative: bool = true,
    warning_count: u32 = 0,
    owns_row_strings: bool = false,
    cache_update: CacheUpdate = .{},
};

/// Streaming seam: the scan worker hands batches of freshly-scanned rows to the
/// sink for live display. The sink takes ownership of `rows` (slice + row string
/// fields) regardless of the return value. Returns false when this scan
/// generation is stale or the session is closing — the worker should stop early.
pub const ScanSink = struct {
    ctx: *anyopaque,
    publish: *const fn (ctx: *anyopaque, rows: []types.SessionMeta) bool,
};

pub const ScannerHost = struct {
    ctx: *anyopaque,
    scan: *const fn (*anyopaque, std.mem.Allocator, source_mod.Source, ?ScanSink) anyerror!ScanResult,
    loadTranscript: *const fn (*anyopaque, std.mem.Allocator, types.SessionMeta) anyerror![]types.TranscriptMessage,
};

/// Owned unit of background scan work. `run` performs the blocking scan; `destroy`
/// frees the context (`ctx`). Both run on the worker thread. `ctx` must own
/// everything `run` needs and contain no pointers into threadlocal UI state.
pub const ScanWork = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque, std.mem.Allocator, source_mod.Source, ?ScanSink) anyerror!ScanResult,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
};

/// Owned unit of background transcript-load work. `run` performs the blocking
/// load; `provider` is used to publish; `destroy` frees `ctx` (which owns the
/// selected metadata copy). All run on the worker thread.
pub const TranscriptWork = struct {
    ctx: *anyopaque,
    provider: types.ProviderId,
    run: *const fn (*anyopaque, std.mem.Allocator) anyerror![]types.TranscriptMessage,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
};

pub const RemoteExecHost = struct {
    ctx: *anyopaque,
    exec: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]u8,
};

pub const LocalScannerHost = struct {
    home: []const u8,
    cache: ?ai_history_cache.CacheFile = null,

    pub fn scannerHost(self: *LocalScannerHost) ScannerHost {
        return .{
            .ctx = self,
            .scan = scan,
            .loadTranscript = loadTranscript,
        };
    }

    fn scan(ctx: *anyopaque, allocator: std.mem.Allocator, source: source_mod.Source, sink: ?ScanSink) !ScanResult {
        const self: *LocalScannerHost = @ptrCast(@alignCast(ctx));
        return try scanLocalFilesystemWithCacheSink(allocator, source, self.home, .{}, self.cache, sink);
    }

    fn loadTranscript(_: *anyopaque, allocator: std.mem.Allocator, meta: types.SessionMeta) ![]types.TranscriptMessage {
        return try loadLocalTranscript(allocator, meta);
    }
};

pub const WslScannerHost = struct {
    pub fn scannerHost(self: *WslScannerHost) ScannerHost {
        return .{
            .ctx = self,
            .scan = scan,
            .loadTranscript = loadTranscript,
        };
    }

    fn exec(_: *anyopaque, allocator: std.mem.Allocator, command: []const u8) ![]u8 {
        return remote_file.wslExec(allocator, command) orelse error.RemoteExecFailed;
    }

    fn scan(ctx: *anyopaque, allocator: std.mem.Allocator, source: source_mod.Source, sink: ?ScanSink) !ScanResult {
        const host = RemoteExecHost{ .ctx = ctx, .exec = exec };
        return try scanRemoteFilesystemSink(allocator, source, host, sink);
    }

    fn loadTranscript(ctx: *anyopaque, allocator: std.mem.Allocator, meta: types.SessionMeta) ![]types.TranscriptMessage {
        const host = RemoteExecHost{ .ctx = ctx, .exec = exec };
        return try loadRemoteTranscript(allocator, host, meta);
    }
};

pub const SshScannerHost = struct {
    conn: ssh_connection.SshConnection,

    pub fn scannerHost(self: *SshScannerHost) ScannerHost {
        return .{
            .ctx = self,
            .scan = scan,
            .loadTranscript = loadTranscript,
        };
    }

    fn exec(ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8) ![]u8 {
        const self: *SshScannerHost = @ptrCast(@alignCast(ctx));
        return try remote_file.sshExecCapture(allocator, self.conn, command);
    }

    fn scan(ctx: *anyopaque, allocator: std.mem.Allocator, source: source_mod.Source, sink: ?ScanSink) !ScanResult {
        const host = RemoteExecHost{ .ctx = ctx, .exec = exec };
        return try scanRemoteFilesystemSink(allocator, source, host, sink);
    }

    fn loadTranscript(ctx: *anyopaque, allocator: std.mem.Allocator, meta: types.SessionMeta) ![]types.TranscriptMessage {
        const host = RemoteExecHost{ .ctx = ctx, .exec = exec };
        return try loadRemoteTranscript(allocator, host, meta);
    }
};

pub const Session = struct {
    /// Allocator used for row storage. Do not change while rows are live.
    allocator: std.mem.Allocator,
    /// Borrowed when initialized with init; owned when initialized with initOwned.
    source: source_mod.Source,
    source_owned: bool = false,
    state: LoadState = .idle,
    /// Rows own duplicated SessionMeta string fields.
    rows: std.ArrayListUnmanaged(types.SessionMeta) = .empty,
    selected: usize = 0,
    list_offset: usize = 0,
    filter: [128]u8 = undefined,
    filter_len: usize = 0,
    category: types.CategoryFilter = .all,
    /// Active day filter (`null` = all dates). Combines with `category`.
    date_filter: ?types.DateKey = null,
    /// Scroll offset into the DATE navigator's day list. The renderer clamps
    /// this against the visible capacity each frame.
    date_offset: usize = 0,
    /// Local UTC offset (seconds east of UTC) used to bucket rows by local day.
    /// Defaults to 0 (UTC); the app injects the real offset at creation.
    tz_offset_seconds: i32 = 0,
    status: []const u8 = "",
    transcript_state: TranscriptState = .idle,
    transcript_status: []const u8 = "",
    transcript_provider: ?types.ProviderId = null,
    transcript: []types.TranscriptMessage = &.{},
    /// Scroll offset into the transcript preview, in wrapped visual lines. The
    /// renderer clamps this against the actual content height each frame.
    transcript_scroll: usize = 0,

    // Async scan/transcript support. `mutex` guards state/status/rows/selected/
    // list_offset/filter/filter_len/transcript*/generation fields. Workers run host
    // I/O without the lock and take it only to publish. `closing` + join-on-deinit
    // give UAF safety.
    mutex: std.Thread.Mutex = .{},
    scan_thread: ?std.Thread = null,
    transcript_thread: ?std.Thread = null,
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scan_generation: u64 = 0,
    transcript_generation: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, source: source_mod.Source) Session {
        return .{
            .allocator = allocator,
            .source = source,
        };
    }

    pub fn initOwned(allocator: std.mem.Allocator, source: source_mod.Source) !Session {
        return .{
            .allocator = allocator,
            .source = try cloneSource(allocator, source),
            .source_owned = true,
        };
    }

    pub fn deinit(self: *Session) void {
        self.closing.store(true, .release);
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
        if (self.transcript_thread) |t| {
            t.join();
            self.transcript_thread = null;
        }
        self.clearTranscript();
        freeRows(self.allocator, self.rows.items);
        self.rows.deinit(self.allocator);
        if (self.source_owned) {
            freeOwnedSource(self.allocator, &self.source);
        }
        self.* = undefined;
    }

    pub fn persistSnap(self: *const Session, allocator: std.mem.Allocator) !session_persist.AiHistorySnap {
        const source_id = try allocator.dupe(u8, self.source.id);
        errdefer allocator.free(source_id);

        const target_kind = try allocator.dupe(u8, switch (self.source.target) {
            .local => "local",
            .wsl => "wsl",
            .ssh => "ssh",
        });
        errdefer allocator.free(target_kind);

        const target_name = try allocator.dupe(u8, self.source.name);
        errdefer allocator.free(target_name);

        return .{
            .source_id = source_id,
            .target_kind = target_kind,
            .target_name = target_name,
        };
    }

    pub fn beginScan(self: *Session) void {
        self.state = .scanning;
        self.status = "Scanning";
    }

    /// Replaces rows with owned copies of `rows`. Callers may pass static or
    /// temporary metadata; Session owns its stored strings after this returns.
    pub fn replaceRows(self: *Session, rows: []const types.SessionMeta) !void {
        var next: std.ArrayListUnmanaged(types.SessionMeta) = .empty;
        errdefer {
            freeRows(self.allocator, next.items);
            next.deinit(self.allocator);
        }

        try next.ensureTotalCapacity(self.allocator, rows.len);
        for (rows) |row| {
            next.appendAssumeCapacity(try cloneMetadata(self.allocator, row));
        }
        std.mem.sort(types.SessionMeta, next.items, {}, types.lessRecent);

        // Capture the selected session id (duped) before we free the old rows.
        var selected_id_buf: ?[]u8 = null;
        defer if (selected_id_buf) |b| self.allocator.free(b);
        if (self.selectedVisible()) |sel| {
            selected_id_buf = self.allocator.dupe(u8, sel.session_id) catch null;
        }

        freeRows(self.allocator, self.rows.items);
        self.rows.deinit(self.allocator);
        self.rows = next;
        self.list_offset = 0;
        self.date_offset = 0;
        self.clearTranscript();
        self.transcript_generation +%= 1;
        self.state = .ready;
        self.status = "Ready";
        self.selected = if (selected_id_buf) |b| (self.visibleIndexOfSessionId(b) orelse 0) else 0;
    }

    pub fn scanNow(self: *Session, host: ScannerHost) !void {
        self.beginScan();
        errdefer {
            self.state = .failed;
            self.status = "Scan failed";
        }
        const result = try host.scan(host.ctx, self.allocator, self.source, null);
        defer freeScanResult(self.allocator, result);

        try self.replaceRows(result.rows);
        self.status = if (result.warning_count == 0) "Ready" else "Ready with warnings";
    }

    /// Finalize a scan. `authoritative` results replace the row set (sync / warm
    /// path); non-authoritative results were streamed already, so we only sort. If
    /// `generation` is stale or we are closing, the result is discarded. Always frees
    /// `result`. Called from the scan worker.
    pub fn finishScan(self: *Session, generation: u64, result: ScanResult) void {
        var published = false;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (!self.closing.load(.acquire) and generation == self.scan_generation) {
                if (result.authoritative) {
                    if (self.replaceRows(result.rows)) |_| {
                        self.status = if (result.warning_count == 0) "Ready" else "Ready with warnings";
                        published = true;
                    } else |_| {
                        self.state = .failed;
                        self.status = "Scan failed";
                    }
                } else {
                    self.sortRowsInPlacePreservingSelection();
                    self.state = .ready;
                    self.status = if (result.warning_count == 0) "Ready" else "Ready with warnings";
                    published = true;
                }
            }
        }
        if (published and result.cache_update.records.len > 0) {
            ai_history_cache.saveDefault(self.allocator, .{ .records = result.cache_update.records }) catch {};
        }
        freeScanResult(self.allocator, result);
    }

    /// Worker-thread entry for streaming. If `generation` is current and we are not
    /// closing, move `rows` into `self.rows` (the row structs are copied; their
    /// strings — allocated with `self.allocator` — live on, now owned by `self.rows`)
    /// and return true; the next frame shows them. Otherwise free `rows` and return
    /// false so the worker can stop early. Does not touch `self.selected`.
    pub fn appendScanRows(self: *Session, generation: u64, rows: []types.SessionMeta) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closing.load(.acquire) or generation != self.scan_generation) {
            freeRows(self.allocator, rows);
            self.allocator.free(rows);
            return false;
        }
        self.rows.appendSlice(self.allocator, rows) catch {
            // Out of memory: drop this batch but keep scanning (not stale).
            freeRows(self.allocator, rows);
            self.allocator.free(rows);
            return true;
        };
        self.allocator.free(rows); // structs moved into self.rows; free only the slice array
        self.state = .scanning;
        self.status = "Scanning";
        return true;
    }

    /// Mark the scan failed if `generation` is still current and not closing.
    pub fn publishScanFailure(self: *Session, generation: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.closing.load(.acquire) and generation == self.scan_generation) {
            self.state = .failed;
            self.status = "Scan failed";
        }
    }

    /// Start a background scan. UI-thread only. Joins any prior scan worker first
    /// (at most one in flight per session), flips to `.scanning`, bumps the
    /// generation, and spawns the worker. Returns immediately.
    pub fn scanAsync(self: *Session, work: ScanWork) void {
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
        self.mutex.lock();
        self.state = .scanning;
        self.status = "Scanning";
        self.scan_generation +%= 1;
        const generation = self.scan_generation;
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, scanThreadMain, .{ self, work, generation }) catch {
            self.mutex.lock();
            if (generation == self.scan_generation) {
                self.state = .failed;
                self.status = "Scan failed";
            }
            self.mutex.unlock();
            work.destroy(work.ctx, self.allocator);
            return;
        };
        self.scan_thread = thread;
    }

    /// Test-only: wait for in-flight workers to finish so results can be asserted
    /// deterministically. Not called in production (deinit joins instead).
    pub fn joinForTest(self: *Session) void {
        if (self.scan_thread) |t| {
            t.join();
            self.scan_thread = null;
        }
        if (self.transcript_thread) |t| {
            t.join();
            self.transcript_thread = null;
        }
    }

    pub fn loadSelectedTranscript(self: *Session, host: ScannerHost) !void {
        const selected = self.selectedVisible() orelse return error.NoSelection;
        self.clearTranscript();
        self.transcript_state = .loading;
        self.transcript_status = "Loading transcript";
        errdefer {
            self.transcript_state = .failed;
            self.transcript_status = "Transcript failed";
        }
        self.transcript = try host.loadTranscript(host.ctx, self.allocator, selected);
        self.transcript_provider = selected.provider;
        self.transcript_state = .ready;
        self.transcript_status = "Transcript ready";
    }

    /// Start a background transcript load for the currently-selected row's data,
    /// captured by the caller into `work.ctx`. UI-thread only. Clears any current
    /// transcript, flips to `.loading`, bumps the generation, spawns the worker.
    pub fn loadTranscriptAsync(self: *Session, work: TranscriptWork) void {
        if (self.transcript_thread) |t| {
            t.join();
            self.transcript_thread = null;
        }
        self.mutex.lock();
        self.clearTranscript();
        self.transcript_state = .loading;
        self.transcript_status = "Loading transcript";
        self.transcript_generation +%= 1;
        const generation = self.transcript_generation;
        self.mutex.unlock();

        const thread = std.Thread.spawn(.{}, transcriptThreadMain, .{ self, work, generation }) catch {
            self.mutex.lock();
            if (generation == self.transcript_generation) {
                self.transcript_state = .failed;
                self.transcript_status = "Transcript failed";
            }
            self.mutex.unlock();
            work.destroy(work.ctx, self.allocator);
            return;
        };
        self.transcript_thread = thread;
    }

    /// Publish transcript messages if `generation`/`provider` still current and not
    /// closing, otherwise free them. Worker-thread only.
    pub fn publishTranscript(self: *Session, generation: u64, provider: types.ProviderId, messages: []types.TranscriptMessage) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.closing.load(.acquire) and generation == self.transcript_generation) {
            self.transcript = messages;
            self.transcript_provider = provider;
            self.transcript_state = .ready;
            self.transcript_status = "Transcript ready";
        } else {
            freeTranscript(self.allocator, provider, messages);
        }
    }

    pub fn publishTranscriptFailure(self: *Session, generation: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.closing.load(.acquire) and generation == self.transcript_generation) {
            self.transcript_state = .failed;
            self.transcript_status = "Transcript failed";
        }
    }

    pub fn setFilter(self: *Session, text: []const u8) void {
        self.filter_len = @min(text.len, self.filter.len);
        @memcpy(self.filter[0..self.filter_len], text[0..self.filter_len]);
        self.selected = 0;
        self.list_offset = 0;
        self.clearTranscript();
    }

    pub fn appendFilterBytes(self: *Session, bytes: []const u8) void {
        if (bytes.len == 0 or bytes.len > self.filter.len - self.filter_len) return;
        @memcpy(self.filter[self.filter_len..][0..bytes.len], bytes);
        self.filter_len += bytes.len;
        self.selected = 0;
        self.list_offset = 0;
        self.clearTranscript();
    }

    pub fn backspaceFilter(self: *Session) void {
        if (self.filter_len == 0) return;
        self.filter_len = previousUtf8Boundary(self.filter[0..self.filter_len], self.filter_len);
        self.selected = 0;
        self.list_offset = 0;
        self.clearTranscript();
    }

    pub fn moveSelection(self: *Session, delta: isize) void {
        const count = self.visibleCount();
        if (count == 0) {
            self.selected = 0;
            self.list_offset = 0;
            self.clearTranscript();
            return;
        }
        const old = @min(self.selected, count - 1);
        const next = if (delta < 0)
            old - @min(old, @as(usize, @intCast(-delta)))
        else
            @min(count - 1, old + @as(usize, @intCast(delta)));
        if (next != self.selected) self.clearTranscript();
        self.selected = next;
    }

    pub fn selectVisibleIndex(self: *Session, index: usize) void {
        const count = self.visibleCount();
        if (count == 0) {
            self.selected = 0;
            self.list_offset = 0;
            self.clearTranscript();
            return;
        }
        const next = @min(index, count - 1);
        if (next != self.selected) self.clearTranscript();
        self.selected = next;
        if (self.list_offset > next) self.list_offset = next;
    }

    pub fn ensureSelectionVisible(self: *Session, max_visible_rows: usize) void {
        const count = self.visibleCount();
        if (count == 0 or max_visible_rows == 0) {
            self.list_offset = 0;
            return;
        }

        self.selected = @min(self.selected, count - 1);
        const window_rows = @min(max_visible_rows, count);
        if (self.selected < self.list_offset) {
            self.list_offset = self.selected;
        } else if (self.selected >= self.list_offset + window_rows) {
            self.list_offset = self.selected + 1 - window_rows;
        }

        const max_offset = count - window_rows;
        self.list_offset = @min(self.list_offset, max_offset);
    }

    pub fn listWindowStart(self: *const Session, max_visible_rows: usize) usize {
        const count = self.visibleCount();
        if (count == 0 or max_visible_rows == 0) return 0;
        const window_rows = @min(max_visible_rows, count);
        return @min(self.list_offset, count - window_rows);
    }

    pub fn clearTranscript(self: *Session) void {
        if (self.transcript_provider) |provider| {
            freeTranscript(self.allocator, provider, self.transcript);
        }
        self.transcript = &.{};
        self.transcript_provider = null;
        self.transcript_state = .idle;
        self.transcript_status = "";
        self.transcript_scroll = 0;
    }

    /// Adjust the transcript preview scroll offset by `delta` visual lines,
    /// saturating at the top. The high end is clamped by the renderer against
    /// the wrapped content height. Callers must hold `mutex`.
    pub fn scrollTranscriptBy(self: *Session, delta: isize) void {
        if (delta < 0) {
            const down: usize = @intCast(-delta);
            self.transcript_scroll -|= down;
        } else {
            self.transcript_scroll +|= @intCast(delta);
        }
    }

    pub fn rowVisible(self: *const Session, row: types.SessionMeta, query: []const u8) bool {
        const key = types.dateKeyFromMs(row.last_active_at_ms, self.tz_offset_seconds);
        return types.categoryMatches(self.category, row.provider) and
            types.dateMatches(self.date_filter, key) and
            types.metadataMatches(row, query);
    }

    pub fn visibleCount(self: *const Session) usize {
        var count: usize = 0;
        const query = self.filter[0..self.filter_len];
        for (self.rows.items) |row| {
            if (self.rowVisible(row, query)) count += 1;
        }
        return count;
    }

    /// Visible index (filter- and category-aware) of the row whose session_id
    /// == id, or null. Uses the same `rowVisible` predicate as `selectedVisible`
    /// so selection preservation matches the list the user sees.
    fn visibleIndexOfSessionId(self: *const Session, id: []const u8) ?usize {
        const query = self.filter[0..self.filter_len];
        var visible_index: usize = 0;
        for (self.rows.items) |row| {
            if (!self.rowVisible(row, query)) continue;
            if (std.mem.eql(u8, row.session_id, id)) return visible_index;
            visible_index += 1;
        }
        return null;
    }

    /// Sort rows by recency in place, keeping the current selection on the same
    /// session id. Used by the streaming finalize (rows are already in self.rows).
    fn sortRowsInPlacePreservingSelection(self: *Session) void {
        var selected_id_buf: ?[]u8 = null;
        defer if (selected_id_buf) |b| self.allocator.free(b);
        if (self.selectedVisible()) |sel| {
            selected_id_buf = self.allocator.dupe(u8, sel.session_id) catch null;
        }
        std.mem.sort(types.SessionMeta, self.rows.items, {}, types.lessRecent);
        if (selected_id_buf) |b| {
            self.selected = self.visibleIndexOfSessionId(b) orelse self.selected;
        }
    }

    /// Returns a shallow SessionMeta copy. Its string slices are borrowed from
    /// the stored rows and follow the same replacement/deinit lifetime.
    pub fn selectedVisible(self: *const Session) ?types.SessionMeta {
        const query = self.filter[0..self.filter_len];
        var visible_index: usize = 0;
        for (self.rows.items) |row| {
            if (!self.rowVisible(row, query)) continue;
            if (visible_index == self.selected) return row;
            visible_index += 1;
        }
        return null;
    }

    pub fn setCategory(self: *Session, category: types.CategoryFilter) void {
        if (self.category == category) return;
        self.category = category;
        self.selected = 0;
        self.list_offset = 0;
        self.clearTranscript();
    }

    pub fn cycleCategory(self: *Session, delta: isize) void {
        const count: isize = 3;
        const cur: isize = @intFromEnum(self.category);
        const next: usize = @intCast(@mod(cur + delta, count));
        self.setCategory(@enumFromInt(next));
    }

    pub fn setDateFilter(self: *Session, filter: ?types.DateKey) void {
        if (self.date_filter == filter) return;
        self.date_filter = filter;
        self.selected = 0;
        self.list_offset = 0;
        self.clearTranscript();
    }

    pub fn scrollDateBy(self: *Session, delta: isize) void {
        if (delta < 0) {
            self.date_offset -|= @intCast(-delta);
        } else {
            self.date_offset +|= @intCast(delta);
        }
    }

    pub fn categoryCounts(self: *const Session, query: []const u8) struct { all: usize, codex: usize, claude: usize } {
        var all: usize = 0;
        var codex: usize = 0;
        var claude: usize = 0;
        for (self.rows.items) |row| {
            if (!types.metadataMatches(row, query)) continue;
            const key = types.dateKeyFromMs(row.last_active_at_ms, self.tz_offset_seconds);
            if (!types.dateMatches(self.date_filter, key)) continue;
            all += 1;
            switch (row.provider) {
                .codex => codex += 1,
                .claude => claude += 1,
            }
        }
        return .{ .all = all, .codex = codex, .claude = claude };
    }

    /// Fill `buf` with the distinct local days present under the current
    /// category + text query (the date filter itself is NOT applied, so every
    /// day stays selectable), descending by date with per-day counts. Rows are
    /// recency-sorted, so same-day rows are contiguous and a running dedup is
    /// correct. Returns the filled prefix; stops at `buf.len`.
    pub fn buildDateBuckets(self: *const Session, buf: []types.DateBucket) []types.DateBucket {
        const query = self.filter[0..self.filter_len];
        var n: usize = 0;
        var have_last = false;
        for (self.rows.items) |row| {
            if (!types.categoryMatches(self.category, row.provider)) continue;
            if (!types.metadataMatches(row, query)) continue;
            const key = types.dateKeyFromMs(row.last_active_at_ms, self.tz_offset_seconds);
            if (key == 0) continue; // no timestamp -> only under "All dates"
            if (have_last and buf[n - 1].key == key) {
                buf[n - 1].count += 1;
                continue;
            }
            if (n >= buf.len) break;
            buf[n] = .{ .key = key, .count = 1 };
            n += 1;
            have_last = true;
        }
        return buf[0..n];
    }

    /// Count of rows under the current category + query, ignoring the date
    /// filter (the "All dates" navigator total). Includes rows with no
    /// timestamp, which appear only under "All dates".
    pub fn dateAllCount(self: *const Session) usize {
        const query = self.filter[0..self.filter_len];
        var count: usize = 0;
        for (self.rows.items) |row| {
            if (!types.categoryMatches(self.category, row.provider)) continue;
            if (!types.metadataMatches(row, query)) continue;
            count += 1;
        }
        return count;
    }
};

/// Renders the scanning status label into `buf`. Returns "Scanning…" for zero,
/// "Scanning… N" otherwise. `buf` should be at least 32 bytes; on overflow falls
/// back to the plain label.
pub fn scanningStatusLabel(buf: []u8, count: usize) []const u8 {
    if (count == 0) return "Scanning…";
    return std.fmt.bufPrint(buf, "Scanning… {d}", .{count}) catch "Scanning…";
}

const StreamCtx = struct {
    session: *Session,
    generation: u64,
    fn publish(ctx: *anyopaque, rows: []types.SessionMeta) bool {
        const self: *StreamCtx = @ptrCast(@alignCast(ctx));
        return self.session.appendScanRows(self.generation, rows);
    }
};

fn scanThreadMain(session: *Session, work: ScanWork, generation: u64) void {
    defer work.destroy(work.ctx, session.allocator);
    var stream = StreamCtx{ .session = session, .generation = generation };
    const sink = ScanSink{ .ctx = &stream, .publish = StreamCtx.publish };
    const result = work.run(work.ctx, session.allocator, session.source, sink) catch {
        session.publishScanFailure(generation);
        return;
    };
    session.finishScan(generation, result);
}

fn transcriptThreadMain(session: *Session, work: TranscriptWork, generation: u64) void {
    defer work.destroy(work.ctx, session.allocator);
    const messages = work.run(work.ctx, session.allocator) catch {
        session.publishTranscriptFailure(generation);
        return;
    };
    session.publishTranscript(generation, work.provider, messages);
}

fn previousUtf8Boundary(bytes: []const u8, from: usize) usize {
    if (from == 0) return 0;
    var idx = from - 1;
    while (idx > 0 and (bytes[idx] & 0b1100_0000) == 0b1000_0000) : (idx -= 1) {}
    return idx;
}

pub fn scanLocalFilesystem(
    allocator: std.mem.Allocator,
    source: source_mod.Source,
    home: []const u8,
) !ScanResult {
    return scanLocalFilesystemWithBudget(allocator, source, home, .{});
}

pub fn scanLocalFilesystemWithBudget(
    allocator: std.mem.Allocator,
    source: source_mod.Source,
    home: []const u8,
    budget: ScanBudget,
) !ScanResult {
    return scanLocalFilesystemWithCache(allocator, source, home, budget, null);
}

pub fn scanLocalFilesystemWithCache(
    allocator: std.mem.Allocator,
    source: source_mod.Source,
    home: []const u8,
    budget: ScanBudget,
    cache: ?ai_history_cache.CacheFile,
) !ScanResult {
    return scanLocalFilesystemWithCacheSink(allocator, source, home, budget, cache, null);
}

pub fn scanLocalFilesystemWithCacheSink(
    allocator: std.mem.Allocator,
    source: source_mod.Source,
    home: []const u8,
    budget: ScanBudget,
    cache: ?ai_history_cache.CacheFile,
    sink: ?ScanSink,
) !ScanResult {
    var scanner = LocalScan{
        .allocator = allocator,
        .source = source,
        .budget = budget,
        .cache = cache,
        .emitter = .{ .allocator = allocator, .sink = sink },
    };
    errdefer scanner.deinit();

    if (source.providers.codex) {
        if (source.codex_root_override) |root| {
            try scanner.scanProviderRoot(.codex, root);
        } else {
            var root_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (source_mod.defaultRoot(.codex, home, &root_buf)) |root| {
                try scanner.scanProviderRoot(.codex, root);
            } else {
                scanner.warning_count += 1;
            }
        }
    }
    if (source.providers.claude) {
        if (source.claude_root_override) |root| {
            try scanner.scanProviderRoot(.claude, root);
        } else {
            var root_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (source_mod.defaultRoot(.claude, home, &root_buf)) |root| {
                try scanner.scanProviderRoot(.claude, root);
            } else {
                scanner.warning_count += 1;
            }
        }
    }
    for (source.extra_roots) |root| {
        if (!providerEnabled(source, root.provider)) continue;
        try scanner.scanProviderRoot(root.provider, root.path);
    }
    try scanner.processCandidates();
    try scanner.emitter.flush();

    const rows = if (sink == null)
        try scanner.emitter.rows.toOwnedSlice(allocator)
    else
        try allocator.alloc(types.SessionMeta, 0);
    errdefer {
        freeRows(allocator, rows);
        allocator.free(rows);
    }
    const cache_update = try scanner.cache_records.toOwnedSlice(allocator);
    scanner.freeCandidates();
    return .{
        .rows = rows,
        .authoritative = (sink == null),
        .warning_count = scanner.warning_count,
        .owns_row_strings = true,
        .cache_update = .{
            .records = cache_update,
            .owns_record_strings = true,
        },
    };
}

pub fn loadLocalTranscript(allocator: std.mem.Allocator, meta: types.SessionMeta) ![]types.TranscriptMessage {
    const bytes = if (std.fs.path.isAbsolute(meta.source_path)) blk: {
        const file = try std.fs.openFileAbsolute(meta.source_path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, MAX_METADATA_FILE_BYTES);
    } else try std.fs.cwd().readFileAlloc(allocator, meta.source_path, MAX_METADATA_FILE_BYTES);
    defer allocator.free(bytes);

    return switch (meta.provider) {
        .codex => try codex_provider.parseTranscript(allocator, bytes),
        .claude => try claude_provider.parseTranscript(allocator, bytes),
    };
}

pub fn providerFindCommand(provider: types.ProviderId, root: []const u8, out: []u8) ![]const u8 {
    _ = provider;
    var quoted_buf: [1024]u8 = undefined;
    const quoted = remote_file.shellQuote(&quoted_buf, root) orelse return error.CommandTooLong;
    return std.fmt.bufPrint(out, "find {s} -type f -name '*.jsonl' -size -2048k | head -500", .{quoted}) catch error.CommandTooLong;
}

pub fn remoteCatCommand(path: []const u8, out: []u8) ![]const u8 {
    var quoted_buf: [1024]u8 = undefined;
    const quoted = remote_file.shellQuote(&quoted_buf, path) orelse return error.CommandTooLong;
    return std.fmt.bufPrint(out, "cat {s}", .{quoted}) catch error.CommandTooLong;
}

pub fn scanRemoteFilesystem(allocator: std.mem.Allocator, source: source_mod.Source, host: RemoteExecHost) !ScanResult {
    return scanRemoteFilesystemSink(allocator, source, host, null);
}

pub fn scanRemoteFilesystemSink(allocator: std.mem.Allocator, source: source_mod.Source, host: RemoteExecHost, sink: ?ScanSink) !ScanResult {
    const home_raw = try host.exec(host.ctx, allocator, remote_file.wslHomeCommand());
    defer allocator.free(home_raw);
    const home = std.mem.trim(u8, home_raw, " \t\r\n");
    if (home.len == 0) return error.NoHomeDirectory;

    var scanner = RemoteScan{
        .allocator = allocator,
        .host = host,
        .emitter = .{ .allocator = allocator, .sink = sink },
    };
    errdefer scanner.deinit();

    if (source.providers.codex) {
        if (source.codex_root_override) |root| {
            try scanner.scanProviderRoot(.codex, root);
        } else {
            var root_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (source_mod.defaultRoot(.codex, home, &root_buf)) |root| {
                try scanner.scanProviderRoot(.codex, root);
            } else {
                scanner.warning_count += 1;
            }
        }
    }
    if (source.providers.claude) {
        if (source.claude_root_override) |root| {
            try scanner.scanProviderRoot(.claude, root);
        } else {
            var root_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (source_mod.defaultRoot(.claude, home, &root_buf)) |root| {
                try scanner.scanProviderRoot(.claude, root);
            } else {
                scanner.warning_count += 1;
            }
        }
    }
    for (source.extra_roots) |root| {
        if (!providerEnabled(source, root.provider)) continue;
        try scanner.scanProviderRoot(root.provider, root.path);
    }
    try scanner.emitter.flush();

    const rows = if (sink == null)
        try scanner.emitter.rows.toOwnedSlice(allocator)
    else
        try allocator.alloc(types.SessionMeta, 0);
    return .{
        .rows = rows,
        .authoritative = (sink == null),
        .warning_count = scanner.warning_count,
        .owns_row_strings = true,
    };
}

pub fn loadRemoteTranscript(allocator: std.mem.Allocator, host: RemoteExecHost, meta: types.SessionMeta) ![]types.TranscriptMessage {
    var command_buf: [2048]u8 = undefined;
    const command = try remoteCatCommand(meta.source_path, command_buf[0..]);
    const bytes = try host.exec(host.ctx, allocator, command);
    defer allocator.free(bytes);

    return switch (meta.provider) {
        .codex => try codex_provider.parseTranscript(allocator, bytes),
        .claude => try claude_provider.parseTranscript(allocator, bytes),
    };
}

pub fn freeScanResult(allocator: std.mem.Allocator, result: ScanResult) void {
    if (result.cache_update.owns_record_strings) ai_history_cache.freeRecords(allocator, result.cache_update.records) else allocator.free(result.cache_update.records);
    if (result.owns_row_strings) freeRows(allocator, result.rows);
    allocator.free(result.rows);
}

pub fn freeTranscript(allocator: std.mem.Allocator, provider: types.ProviderId, messages: []types.TranscriptMessage) void {
    switch (provider) {
        .codex => codex_provider.freeTranscript(allocator, messages),
        .claude => claude_provider.freeTranscript(allocator, messages),
    }
}

/// Collects scanned rows. With a sink it flushes batches for live display
/// (streaming mode); without a sink it accumulates into `rows` for the final
/// ScanResult. Takes ownership of each emitted row (frees it on its own error).
const RowEmitter = struct {
    allocator: std.mem.Allocator,
    sink: ?ScanSink,
    rows: std.ArrayListUnmanaged(types.SessionMeta) = .empty,
    pending: std.ArrayListUnmanaged(types.SessionMeta) = .empty,
    aborted: bool = false,
    const BATCH = 12;

    fn emit(self: *RowEmitter, row: types.SessionMeta) !void {
        if (self.sink == null) {
            self.rows.append(self.allocator, row) catch |e| {
                freeMetadata(self.allocator, row);
                return e;
            };
            return;
        }
        self.pending.append(self.allocator, row) catch |e| {
            freeMetadata(self.allocator, row);
            return e;
        };
        if (self.pending.items.len >= BATCH) try self.flush();
    }

    fn flush(self: *RowEmitter) !void {
        if (self.pending.items.len == 0) return;
        const batch = try self.pending.toOwnedSlice(self.allocator);
        const sink = self.sink.?;
        if (!sink.publish(sink.ctx, batch)) self.aborted = true;
    }

    fn deinit(self: *RowEmitter) void {
        freeRows(self.allocator, self.rows.items);
        self.rows.deinit(self.allocator);
        freeRows(self.allocator, self.pending.items);
        self.pending.deinit(self.allocator);
    }
};

const LocalScan = struct {
    const Candidate = struct {
        provider: types.ProviderId,
        path: []const u8,
        size: u64,
        mtime: i128,
    };

    allocator: std.mem.Allocator,
    source: source_mod.Source,
    budget: ScanBudget,
    cache: ?ai_history_cache.CacheFile = null,
    emitter: RowEmitter,
    candidates: std.ArrayListUnmanaged(Candidate) = .empty,
    cache_records: std.ArrayListUnmanaged(ai_history_cache.CacheRecord) = .empty,
    warning_count: u32 = 0,

    fn deinit(self: *LocalScan) void {
        ai_history_cache.freeRecords(self.allocator, self.cache_records.items);
        self.cache_records.deinit(self.allocator);
        self.emitter.deinit();
        self.freeCandidates();
    }

    fn freeCandidates(self: *LocalScan) void {
        for (self.candidates.items) |candidate| {
            self.allocator.free(candidate.path);
        }
        self.candidates.deinit(self.allocator);
        self.candidates = .empty;
    }

    fn scanProviderRoot(self: *LocalScan, provider: types.ProviderId, root: []const u8) !void {
        var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => {
                self.warning_count += 1;
                return;
            },
        };
        defer dir.close();

        try self.walkDir(provider, root, dir);
    }

    fn walkDir(self: *LocalScan, provider: types.ProviderId, abs_path: []const u8, dir: std.fs.Dir) !void {
        var it = dir.iterate();
        while (it.next() catch {
            self.warning_count += 1;
            return;
        }) |entry| {
            switch (entry.kind) {
                .directory => {
                    const child_path = try std.fs.path.join(self.allocator, &.{ abs_path, entry.name });
                    defer self.allocator.free(child_path);

                    var child = dir.openDir(entry.name, .{ .iterate = true }) catch |err| switch (err) {
                        error.FileNotFound, error.NotDir => continue,
                        else => {
                            self.warning_count += 1;
                            continue;
                        },
                    };
                    defer child.close();
                    try self.walkDir(provider, child_path, child);
                },
                .file => {
                    if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
                    try self.collectFile(provider, abs_path, dir, entry.name);
                },
                else => {},
            }
        }
    }

    fn collectFile(self: *LocalScan, provider: types.ProviderId, abs_dir: []const u8, dir: std.fs.Dir, name: []const u8) !void {
        const stat = dir.statFile(name) catch {
            self.warning_count += 1;
            return;
        };
        if (stat.size > MAX_METADATA_FILE_BYTES) {
            self.warning_count += 1;
            return;
        }

        const source_path = try std.fs.path.join(self.allocator, &.{ abs_dir, name });
        errdefer self.allocator.free(source_path);

        try self.candidates.append(self.allocator, .{
            .provider = provider,
            .path = source_path,
            .size = stat.size,
            .mtime = stat.mtime,
        });
    }

    fn processCandidates(self: *LocalScan) !void {
        std.mem.sort(Candidate, self.candidates.items, {}, candidateMoreRecent);

        var parsed_files: usize = 0;
        var parsed_bytes: u64 = 0;
        var budget_exceeded = false;

        for (self.candidates.items) |candidate| {
            if (parsed_files >= self.budget.max_files or
                parsed_bytes + candidate.size > self.budget.max_bytes)
            {
                budget_exceeded = true;
                continue;
            }

            try self.scanCandidate(candidate);
            parsed_files += 1;
            parsed_bytes += candidate.size;
            if (self.emitter.aborted) break;
        }

        if (budget_exceeded) self.warning_count += 1;
    }

    fn scanCandidate(self: *LocalScan, candidate: Candidate) !void {
        const stamp: ai_history_cache.FileStamp = .{ .size = candidate.size, .mtime_ns = candidate.mtime };
        if (self.cache) |cache| {
            if (ai_history_cache.findRecord(cache, self.source.id, candidate.provider, candidate.path, stamp)) |record| {
                const cached_meta = try cloneMetadata(self.allocator, record.meta);
                {
                    errdefer freeMetadata(self.allocator, cached_meta);
                    try self.appendCacheRecord(candidate, record.meta);
                }
                try self.emitter.emit(cached_meta);
                return;
            }
        }

        const file = std.fs.openFileAbsolute(candidate.path, .{}) catch {
            self.warning_count += 1;
            return;
        };
        defer file.close();

        const bytes = file.readToEndAlloc(self.allocator, MAX_METADATA_FILE_BYTES) catch {
            self.warning_count += 1;
            return;
        };
        defer self.allocator.free(bytes);

        const meta = (switch (candidate.provider) {
            .codex => codex_provider.parseMetadata(self.allocator, candidate.path, bytes),
            .claude => claude_provider.parseMetadata(self.allocator, candidate.path, bytes),
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (!metadataHasUsableSignal(meta)) {
            freeMetadata(self.allocator, meta);
            self.warning_count += 1;
            return;
        }
        {
            errdefer freeMetadata(self.allocator, meta);
            try self.appendCacheRecord(candidate, meta);
        }
        try self.emitter.emit(meta);
    }

    fn appendCacheRecord(self: *LocalScan, candidate: Candidate, meta: types.SessionMeta) !void {
        const root_path = providerRootForPath(self.source, candidate.provider, candidate.path);
        const record: ai_history_cache.CacheRecord = .{
            .source_id = self.source.id,
            .provider = candidate.provider,
            .root_path = root_path,
            .source_path = candidate.path,
            .stamp = .{ .size = candidate.size, .mtime_ns = candidate.mtime },
            .meta = meta,
        };
        const cloned = try ai_history_cache.cloneRecord(self.allocator, record);
        errdefer {
            var mutable = cloned;
            ai_history_cache.freeRecord(self.allocator, &mutable);
        }
        try self.cache_records.append(self.allocator, cloned);
    }

    fn candidateMoreRecent(_: void, lhs: Candidate, rhs: Candidate) bool {
        if (lhs.mtime == rhs.mtime) return std.mem.lessThan(u8, lhs.path, rhs.path);
        return lhs.mtime > rhs.mtime;
    }
};

fn providerRootForPath(source: source_mod.Source, provider: types.ProviderId, source_path: []const u8) []const u8 {
    const explicit = switch (provider) {
        .codex => source.codex_root_override,
        .claude => source.claude_root_override,
    };
    if (explicit) |root| return root;
    for (source.extra_roots) |root| {
        if (root.provider == provider and std.mem.startsWith(u8, source_path, root.path)) return root.path;
    }
    return "";
}

const RemoteScan = struct {
    allocator: std.mem.Allocator,
    host: RemoteExecHost,
    emitter: RowEmitter,
    warning_count: u32 = 0,

    fn deinit(self: *RemoteScan) void {
        self.emitter.deinit();
    }

    fn scanProviderRoot(self: *RemoteScan, provider: types.ProviderId, root: []const u8) !void {
        var find_buf: [2048]u8 = undefined;
        const find_cmd = providerFindCommand(provider, root, find_buf[0..]) catch {
            self.warning_count += 1;
            return;
        };
        const listing = self.host.exec(self.host.ctx, self.allocator, find_cmd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.warning_count += 1;
                return;
            },
        };
        defer self.allocator.free(listing);

        var lines = std.mem.splitScalar(u8, listing, '\n');
        while (lines.next()) |line_raw| {
            const path = std.mem.trim(u8, line_raw, " \t\r\n");
            if (path.len == 0) continue;
            try self.scanPath(provider, path);
            if (self.emitter.aborted) break;
        }
    }

    fn scanPath(self: *RemoteScan, provider: types.ProviderId, path: []const u8) !void {
        var cat_buf: [2048]u8 = undefined;
        const cat_cmd = remoteCatCommand(path, cat_buf[0..]) catch {
            self.warning_count += 1;
            return;
        };
        const bytes = self.host.exec(self.host.ctx, self.allocator, cat_cmd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.warning_count += 1;
                return;
            },
        };
        defer self.allocator.free(bytes);
        if (bytes.len > MAX_METADATA_FILE_BYTES) {
            self.warning_count += 1;
            return;
        }

        const meta = (switch (provider) {
            .codex => codex_provider.parseMetadata(self.allocator, path, bytes),
            .claude => claude_provider.parseMetadata(self.allocator, path, bytes),
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (!metadataHasUsableSignal(meta)) {
            freeMetadata(self.allocator, meta);
            self.warning_count += 1;
            return;
        }

        try self.emitter.emit(meta);
    }
};

fn providerEnabled(source: source_mod.Source, provider: types.ProviderId) bool {
    return switch (provider) {
        .codex => source.providers.codex,
        .claude => source.providers.claude,
    };
}

fn metadataHasUsableSignal(meta: types.SessionMeta) bool {
    return meta.session_id.len > 0 and meta.message_count > 0;
}

pub fn cloneMetadata(allocator: std.mem.Allocator, meta: types.SessionMeta) !types.SessionMeta {
    var cloned = types.SessionMeta{
        .provider = meta.provider,
        .session_id = "",
        .title = "",
        .summary = "",
        .project_dir = "",
        .created_at_ms = meta.created_at_ms,
        .last_active_at_ms = meta.last_active_at_ms,
        .source_path = "",
        .resume_kind = meta.resume_kind,
        .message_count = meta.message_count,
        .scan_status = meta.scan_status,
    };
    errdefer freeMetadata(allocator, cloned);

    cloned.session_id = try cloneSlice(allocator, meta.session_id);
    cloned.title = try cloneSlice(allocator, meta.title);
    cloned.summary = try cloneSlice(allocator, meta.summary);
    cloned.project_dir = try cloneSlice(allocator, meta.project_dir);
    cloned.source_path = try cloneSlice(allocator, meta.source_path);

    return cloned;
}

fn freeRows(allocator: std.mem.Allocator, rows: []types.SessionMeta) void {
    for (rows) |row| freeMetadata(allocator, row);
}

pub fn freeMetadata(allocator: std.mem.Allocator, meta: types.SessionMeta) void {
    freeSlice(allocator, meta.session_id);
    freeSlice(allocator, meta.title);
    freeSlice(allocator, meta.summary);
    freeSlice(allocator, meta.project_dir);
    freeSlice(allocator, meta.source_path);
}

fn cloneSource(allocator: std.mem.Allocator, source: source_mod.Source) !source_mod.Source {
    var cloned = source_mod.Source{
        .id = "",
        .name = "",
        .target = .local,
        .providers = source.providers,
        .codex_root_override = null,
        .claude_root_override = null,
        .extra_roots = &.{},
    };
    errdefer freeOwnedSource(allocator, &cloned);

    cloned.id = try cloneSlice(allocator, source.id);
    cloned.name = try cloneSlice(allocator, source.name);
    cloned.target = switch (source.target) {
        .local => .local,
        .wsl => |target| .{ .wsl = .{ .distro = try cloneSlice(allocator, target.distro) } },
        .ssh => |target| .{ .ssh = .{ .profile_name = try cloneSlice(allocator, target.profile_name) } },
    };
    cloned.codex_root_override = try cloneOptionalSlice(allocator, source.codex_root_override);
    cloned.claude_root_override = try cloneOptionalSlice(allocator, source.claude_root_override);
    cloned.extra_roots = try cloneProviderRoots(allocator, source.extra_roots);

    return cloned;
}

fn cloneSlice(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len == 0) return "";
    return try allocator.dupe(u8, value);
}

fn cloneOptionalSlice(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |slice| try cloneSlice(allocator, slice) else null;
}

fn cloneProviderRoots(allocator: std.mem.Allocator, roots: []const source_mod.ProviderRoot) ![]const source_mod.ProviderRoot {
    if (roots.len == 0) return &.{};

    const cloned_roots = try allocator.alloc(source_mod.ProviderRoot, roots.len);
    errdefer allocator.free(cloned_roots);

    var initialized: usize = 0;
    errdefer {
        for (cloned_roots[0..initialized]) |root| {
            freeSlice(allocator, root.path);
        }
    }

    for (roots, 0..) |root, idx| {
        cloned_roots[idx] = .{
            .provider = root.provider,
            .path = try cloneSlice(allocator, root.path),
        };
        initialized += 1;
    }

    return cloned_roots;
}

fn freeOwnedSource(allocator: std.mem.Allocator, source: *source_mod.Source) void {
    freeSlice(allocator, source.id);
    freeSlice(allocator, source.name);
    switch (source.target) {
        .local => {},
        .wsl => |target| freeSlice(allocator, target.distro),
        .ssh => |target| freeSlice(allocator, target.profile_name),
    }
    if (source.codex_root_override) |value| freeSlice(allocator, value);
    if (source.claude_root_override) |value| freeSlice(allocator, value);
    for (source.extra_roots) |root| {
        freeSlice(allocator, root.path);
    }
    if (source.extra_roots.len > 0) allocator.free(source.extra_roots);
}

fn freeSlice(allocator: std.mem.Allocator, value: []const u8) void {
    if (value.len > 0) allocator.free(value);
}

const TestTranscriptHost = struct {
    pub fn scannerHost(self: *TestTranscriptHost) ScannerHost {
        return .{
            .ctx = self,
            .scan = scan,
            .loadTranscript = loadTranscript,
        };
    }

    fn scan(_: *anyopaque, allocator: std.mem.Allocator, _: source_mod.Source, _: ?ScanSink) !ScanResult {
        return .{ .rows = try allocator.alloc(types.SessionMeta, 0) };
    }

    fn loadTranscript(_: *anyopaque, allocator: std.mem.Allocator, _: types.SessionMeta) ![]types.TranscriptMessage {
        const messages = try allocator.alloc(types.TranscriptMessage, 1);
        errdefer allocator.free(messages);
        messages[0] = .{
            .role = .user,
            .content = try allocator.dupe(u8, "hello"),
        };
        return messages;
    }
};

const FakeRemoteHost = struct {
    const codex_path = "/home/me/.codex/sessions/codex-abc.jsonl";
    const claude_path = "/home/me/.claude/projects/project/claude-abc.jsonl";
    const codex_jsonl =
        \\{"type":"session_meta","id":"codex-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:00:00Z"}
        \\{"type":"response_item","role":"user","content":[{"type":"input_text","text":"Fix remote renderer"}],"timestamp":"2026-05-31T10:01:00Z"}
        \\
    ;
    const claude_jsonl =
        \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:00:00.000Z","type":"user","message":{"role":"user","content":"Fix remote tests"}}
        \\
    ;

    pub fn remoteExecHost(self: *FakeRemoteHost) RemoteExecHost {
        return .{ .ctx = self, .exec = exec };
    }

    fn exec(_: *anyopaque, allocator: std.mem.Allocator, command: []const u8) ![]u8 {
        if (std.mem.eql(u8, command, remote_file.wslHomeCommand())) {
            return try allocator.dupe(u8, "/home/me\n");
        }
        if (std.mem.eql(u8, command, "find '/home/me/.codex' -type f -name '*.jsonl' -size -2048k | head -500")) {
            return try allocator.dupe(u8, codex_path ++ "\n");
        }
        if (std.mem.eql(u8, command, "find '/home/me/.claude' -type f -name '*.jsonl' -size -2048k | head -500")) {
            return try allocator.dupe(u8, claude_path ++ "\n");
        }
        if (std.mem.eql(u8, command, "cat '" ++ codex_path ++ "'")) {
            return try allocator.dupe(u8, codex_jsonl);
        }
        if (std.mem.eql(u8, command, "cat '" ++ claude_path ++ "'")) {
            return try allocator.dupe(u8, claude_jsonl);
        }
        return error.UnexpectedCommand;
    }
};

test "ai_history_session: replacing rows sorts by last active time" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const rows = [_]types.SessionMeta{
        .{
            .provider = .codex,
            .session_id = "old",
            .title = "Old",
            .source_path = "old.jsonl",
            .resume_kind = .codex_resume,
            .last_active_at_ms = 10,
        },
        .{
            .provider = .codex,
            .session_id = "new",
            .title = "New",
            .source_path = "new.jsonl",
            .resume_kind = .codex_resume,
            .last_active_at_ms = 20,
        },
    };

    try session.replaceRows(&rows);

    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqualStrings("new", session.rows.items[0].session_id);
}

test "ai_history_session: persistSnap duplicates source identity" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local-codex", .name = "Local", .target = .local });
    defer session.deinit();

    const snap = try session.persistSnap(allocator);
    defer {
        allocator.free(snap.source_id);
        allocator.free(snap.target_kind);
        allocator.free(snap.target_name);
    }

    try std.testing.expectEqualStrings("local-codex", snap.source_id);
    try std.testing.expectEqualStrings("local", snap.target_kind);
    try std.testing.expectEqualStrings("Local", snap.target_name);
    try std.testing.expect(snap.source_id.ptr != session.source.id.ptr);
    try std.testing.expect(snap.target_name.ptr != session.source.name.ptr);
}

test "ai_history_session: initOwned clones source identity and ssh roots" {
    const allocator = std.testing.allocator;
    var id_buf = [_]u8{ 's', 's', 'h', '-', 'h', 'i', 's', 't', 'o', 'r', 'y' };
    var name_buf = [_]u8{ 'B', 'u', 'i', 'l', 'd', ' ', 'B', 'o', 'x' };
    var profile_buf = [_]u8{ 'b', 'u', 'i', 'l', 'd', 'b', 'o', 'x' };
    var codex_buf = [_]u8{ '/', 't', 'm', 'p', '/', 'c', 'o', 'd', 'e', 'x' };
    var claude_buf = [_]u8{ '/', 't', 'm', 'p', '/', 'c', 'l', 'a', 'u', 'd', 'e' };
    var extra_path_buf = [_]u8{ '/', 't', 'm', 'p', '/', 'e', 'x', 't', 'r', 'a' };
    const extra_roots = [_]source_mod.ProviderRoot{
        .{ .provider = .codex, .path = extra_path_buf[0..] },
    };

    var session = try Session.initOwned(allocator, .{
        .id = id_buf[0..],
        .name = name_buf[0..],
        .target = .{ .ssh = .{ .profile_name = profile_buf[0..] } },
        .codex_root_override = codex_buf[0..],
        .claude_root_override = claude_buf[0..],
        .extra_roots = extra_roots[0..],
    });
    defer session.deinit();

    @memset(&id_buf, 'x');
    @memset(&name_buf, 'x');
    @memset(&profile_buf, 'x');
    @memset(&codex_buf, 'x');
    @memset(&claude_buf, 'x');
    @memset(&extra_path_buf, 'x');

    try std.testing.expectEqualStrings("ssh-history", session.source.id);
    try std.testing.expectEqualStrings("Build Box", session.source.name);
    try std.testing.expectEqualStrings("buildbox", session.source.target.ssh.profile_name);
    try std.testing.expectEqualStrings("/tmp/codex", session.source.codex_root_override.?);
    try std.testing.expectEqualStrings("/tmp/claude", session.source.claude_root_override.?);
    try std.testing.expectEqual(@as(usize, 1), session.source.extra_roots.len);
    try std.testing.expectEqualStrings("/tmp/extra", session.source.extra_roots[0].path);
    try std.testing.expect(session.source.id.ptr != id_buf[0..].ptr);
    try std.testing.expect(session.source.name.ptr != name_buf[0..].ptr);
    try std.testing.expect(session.source.target.ssh.profile_name.ptr != profile_buf[0..].ptr);
    try std.testing.expect(session.source.extra_roots.ptr != extra_roots[0..].ptr);
    try std.testing.expect(session.source.extra_roots[0].path.ptr != extra_path_buf[0..].ptr);
}

test "ai_history_session: initOwned clones wsl distro" {
    const allocator = std.testing.allocator;
    var distro_buf = [_]u8{ 'U', 'b', 'u', 'n', 't', 'u' };

    var session = try Session.initOwned(allocator, .{
        .id = "wsl",
        .name = "WSL",
        .target = .{ .wsl = .{ .distro = distro_buf[0..] } },
    });
    defer session.deinit();

    @memset(&distro_buf, 'x');

    try std.testing.expectEqualStrings("Ubuntu", session.source.target.wsl.distro);
    try std.testing.expect(session.source.target.wsl.distro.ptr != distro_buf[0..].ptr);
}

test "ai_history_session: persistSnap frees partial duplicates on allocation failure" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });
    var session = Session.init(failing_allocator.allocator(), .{ .id = "local-codex", .name = "Local", .target = .local });
    defer session.deinit();

    try std.testing.expectError(error.OutOfMemory, session.persistSnap(failing_allocator.allocator()));
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "ai_history_session: metadata filter controls visible rows" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const rows = [_]types.SessionMeta{
        .{
            .provider = .codex,
            .session_id = "a",
            .title = "Renderer",
            .source_path = "a.jsonl",
            .resume_kind = .codex_resume,
        },
        .{
            .provider = .claude,
            .session_id = "b",
            .title = "Docs",
            .project_dir = "/repo/docs",
            .source_path = "b.jsonl",
            .resume_kind = .claude_resume,
        },
    };

    try session.replaceRows(&rows);
    session.setFilter("docs");

    try std.testing.expectEqual(@as(usize, 1), session.visibleCount());
    const selected = session.selectedVisible() orelse return error.ExpectedSelectedSession;
    try std.testing.expectEqualStrings("b", selected.session_id);
}

test "ai_history_session: loading selected transcript stores and clears owned messages" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const rows = [_]types.SessionMeta{
        .{
            .provider = .codex,
            .session_id = "a",
            .title = "Renderer",
            .source_path = "a.jsonl",
            .resume_kind = .codex_resume,
        },
    };
    try session.replaceRows(&rows);

    var host_state = TestTranscriptHost{};
    const host = host_state.scannerHost();
    try session.loadSelectedTranscript(host);

    try std.testing.expectEqual(TranscriptState.ready, session.transcript_state);
    try std.testing.expectEqual(types.ProviderId.codex, session.transcript_provider.?);
    try std.testing.expectEqual(@as(usize, 1), session.transcript.len);
    try std.testing.expectEqualStrings("hello", session.transcript[0].content);

    try session.replaceRows(&.{});
    try std.testing.expectEqual(TranscriptState.idle, session.transcript_state);
    try std.testing.expectEqual(@as(?types.ProviderId, null), session.transcript_provider);
    try std.testing.expectEqual(@as(usize, 0), session.transcript.len);
}

test "ai_history_session: remote provider find command quotes root" {
    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "find '/home/me/it'\\''s/.codex' -type f -name '*.jsonl' -size -2048k | head -500",
        try providerFindCommand(.codex, "/home/me/it's/.codex", &out),
    );
}

test "ai_history_session: remote scan uses fake host JSONL bytes" {
    const allocator = std.testing.allocator;
    var fake = FakeRemoteHost{};
    const result = try scanRemoteFilesystem(allocator, .{
        .id = "wsl",
        .name = "WSL",
        .target = .{ .wsl = .{} },
    }, fake.remoteExecHost());
    defer freeScanResult(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.rows.len);
    try std.testing.expectEqual(@as(u32, 0), result.warning_count);
    try std.testing.expectEqual(types.ProviderId.codex, result.rows[0].provider);
    try std.testing.expectEqualStrings("codex-abc", result.rows[0].session_id);
    try std.testing.expectEqualStrings("/home/me/project", result.rows[0].project_dir);
    try std.testing.expectEqual(types.ProviderId.claude, result.rows[1].provider);
    try std.testing.expectEqualStrings("claude-abc", result.rows[1].session_id);
}

test "ai_history_session: remote transcript loads from fake host" {
    const allocator = std.testing.allocator;
    var fake = FakeRemoteHost{};
    const meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "codex-abc",
        .title = "Remote",
        .project_dir = "/home/me/project",
        .source_path = FakeRemoteHost.codex_path,
        .resume_kind = .codex_resume,
    };
    const messages = try loadRemoteTranscript(allocator, fake.remoteExecHost(), meta);
    defer freeTranscript(allocator, .codex, messages);

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqual(types.MessageRole.user, messages[0].role);
    try std.testing.expectEqualStrings("Fix remote renderer", messages[0].content);
}

test "ai_history_session: replace rows preserves existing state on allocation failure" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 4,
    });
    var session = Session.init(failing_allocator.allocator(), .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const existing = [_]types.SessionMeta{
        .{
            .provider = .codex,
            .session_id = "kept",
            .title = "Kept",
            .source_path = "kept.jsonl",
            .resume_kind = .codex_resume,
            .last_active_at_ms = 10,
        },
    };
    try session.replaceRows(&existing);
    session.status = "Existing";

    const replacement = [_]types.SessionMeta{
        .{
            .provider = .codex,
            .session_id = "new-a",
            .title = "New A",
            .source_path = "new-a.jsonl",
            .resume_kind = .codex_resume,
            .last_active_at_ms = 30,
        },
        .{
            .provider = .codex,
            .session_id = "new-b",
            .title = "New B",
            .source_path = "new-b.jsonl",
            .resume_kind = .codex_resume,
            .last_active_at_ms = 20,
        },
    };

    try std.testing.expectError(error.OutOfMemory, session.replaceRows(&replacement));

    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), session.rows.items.len);
    try std.testing.expectEqualStrings("kept", session.rows.items[0].session_id);
    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqualStrings("Existing", session.status);
}

test "ai_history_session: selected visible returns null when selection is unavailable" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    try std.testing.expectEqual(null, session.selectedVisible());

    const rows = [_]types.SessionMeta{
        .{
            .provider = .codex,
            .session_id = "a",
            .title = "Renderer",
            .source_path = "a.jsonl",
            .resume_kind = .codex_resume,
        },
    };
    try session.replaceRows(&rows);

    session.setFilter("missing");
    try std.testing.expectEqual(@as(usize, 0), session.visibleCount());
    try std.testing.expectEqual(null, session.selectedVisible());

    session.setFilter("");
    session.selected = 1;
    try std.testing.expectEqual(@as(usize, 1), session.visibleCount());
    try std.testing.expectEqual(null, session.selectedVisible());
}

test "ai_history_session: list offset keeps selected row in rendered window" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const rows = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 4 },
        .{ .provider = .codex, .session_id = "b", .title = "B", .source_path = "b.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 3 },
        .{ .provider = .codex, .session_id = "c", .title = "C", .source_path = "c.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 2 },
        .{ .provider = .codex, .session_id = "d", .title = "D", .source_path = "d.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 1 },
    };
    try session.replaceRows(&rows);

    session.moveSelection(3);
    session.ensureSelectionVisible(2);
    try std.testing.expectEqual(@as(usize, 3), session.selected);
    try std.testing.expectEqual(@as(usize, 2), session.listWindowStart(2));

    session.moveSelection(-2);
    session.ensureSelectionVisible(2);
    try std.testing.expectEqual(@as(usize, 1), session.selected);
    try std.testing.expectEqual(@as(usize, 1), session.listWindowStart(2));

    session.setFilter("A");
    try std.testing.expectEqual(@as(usize, 0), session.listWindowStart(2));
}

test "ai_history_session: filter truncates to fixed buffer length" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    var long_filter: [130]u8 = undefined;
    @memset(&long_filter, 'x');
    long_filter[128] = 'y';
    long_filter[129] = 'z';

    session.setFilter(&long_filter);

    try std.testing.expectEqual(@as(usize, 128), session.filter_len);
    try std.testing.expectEqualSlices(u8, long_filter[0..128], session.filter[0..session.filter_len]);
}

test "ai_history_session: scan host replaces rows and marks ready" {
    const allocator = std.testing.allocator;
    var fake = struct {
        fn scan(_: *anyopaque, alloc: std.mem.Allocator, _: source_mod.Source, _: ?ScanSink) !ScanResult {
            const rows = try alloc.alloc(types.SessionMeta, 1);
            rows[0] = .{
                .provider = .codex,
                .session_id = "abc",
                .title = "A",
                .source_path = "a.jsonl",
                .resume_kind = .codex_resume,
                .last_active_at_ms = 1,
            };
            return .{ .rows = rows };
        }
        fn load(_: *anyopaque, alloc: std.mem.Allocator, _: types.SessionMeta) ![]types.TranscriptMessage {
            const rows = try alloc.alloc(types.TranscriptMessage, 1);
            rows[0] = .{ .role = .user, .content = "hello" };
            return rows;
        }
    }{};
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    const host: ScannerHost = .{ .ctx = &fake, .scan = @TypeOf(fake).scan, .loadTranscript = @TypeOf(fake).load };

    try session.scanNow(host);

    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqualStrings("Ready", session.status);
    try std.testing.expectEqualStrings("abc", session.rows.items[0].session_id);
}

test "ai_history_session: scan host warning count marks ready with warnings" {
    const allocator = std.testing.allocator;
    var fake = struct {
        fn scan(_: *anyopaque, alloc: std.mem.Allocator, _: source_mod.Source, _: ?ScanSink) !ScanResult {
            const rows = try alloc.alloc(types.SessionMeta, 1);
            rows[0] = .{
                .provider = .codex,
                .session_id = "warn",
                .title = "Warning",
                .source_path = "warn.jsonl",
                .resume_kind = .codex_resume,
            };
            return .{ .rows = rows, .warning_count = 1 };
        }
        fn load(_: *anyopaque, alloc: std.mem.Allocator, _: types.SessionMeta) ![]types.TranscriptMessage {
            return try alloc.alloc(types.TranscriptMessage, 0);
        }
    }{};
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    const host: ScannerHost = .{ .ctx = &fake, .scan = @TypeOf(fake).scan, .loadTranscript = @TypeOf(fake).load };

    try session.scanNow(host);

    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqualStrings("Ready with warnings", session.status);
}

test "ai_history_session: scan host rows are owned after provider result is freed" {
    const allocator = std.testing.allocator;
    var fake = struct {
        fn scan(_: *anyopaque, alloc: std.mem.Allocator, _: source_mod.Source, _: ?ScanSink) !ScanResult {
            const rows = try alloc.alloc(types.SessionMeta, 1);
            errdefer alloc.free(rows);

            rows[0] = .{
                .provider = .codex,
                .session_id = try alloc.dupe(u8, "owned-abc"),
                .title = try alloc.dupe(u8, "Owned Title"),
                .project_dir = try alloc.dupe(u8, "/tmp/project"),
                .source_path = try alloc.dupe(u8, "/tmp/a.jsonl"),
                .resume_kind = .codex_resume,
            };
            return .{ .rows = rows, .owns_row_strings = true };
        }
        fn load(_: *anyopaque, alloc: std.mem.Allocator, _: types.SessionMeta) ![]types.TranscriptMessage {
            return try alloc.alloc(types.TranscriptMessage, 0);
        }
    }{};
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    const host: ScannerHost = .{ .ctx = &fake, .scan = @TypeOf(fake).scan, .loadTranscript = @TypeOf(fake).load };

    try session.scanNow(host);

    try std.testing.expectEqualStrings("owned-abc", session.rows.items[0].session_id);
    try std.testing.expectEqualStrings("Owned Title", session.rows.items[0].title);
    try std.testing.expectEqualStrings("/tmp/project", session.rows.items[0].project_dir);
    try std.testing.expectEqualStrings("/tmp/a.jsonl", session.rows.items[0].source_path);
}

test "ai_history_session: loadSelectedTranscript stores fake transcript for selected row" {
    const allocator = std.testing.allocator;
    var fake = struct {
        fn scan(_: *anyopaque, alloc: std.mem.Allocator, _: source_mod.Source, _: ?ScanSink) !ScanResult {
            const rows = try alloc.alloc(types.SessionMeta, 1);
            rows[0] = .{
                .provider = .codex,
                .session_id = "abc",
                .title = "A",
                .source_path = "a.jsonl",
                .resume_kind = .codex_resume,
            };
            return .{ .rows = rows };
        }
        fn load(_: *anyopaque, alloc: std.mem.Allocator, meta: types.SessionMeta) ![]types.TranscriptMessage {
            try std.testing.expectEqualStrings("abc", meta.session_id);
            const messages = try alloc.alloc(types.TranscriptMessage, 1);
            errdefer alloc.free(messages);
            messages[0] = .{ .role = .user, .content = try alloc.dupe(u8, "hello") };
            return messages;
        }
    }{};
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    const host: ScannerHost = .{ .ctx = &fake, .scan = @TypeOf(fake).scan, .loadTranscript = @TypeOf(fake).load };
    try session.scanNow(host);

    try session.loadSelectedTranscript(host);

    try std.testing.expectEqual(TranscriptState.ready, session.transcript_state);
    try std.testing.expectEqual(@as(usize, 1), session.transcript.len);
    try std.testing.expectEqual(types.MessageRole.user, session.transcript[0].role);
    try std.testing.expectEqualStrings("hello", session.transcript[0].content);
}

test "ai_history_session: loadSelectedTranscript returns NoSelection without visible row" {
    const allocator = std.testing.allocator;
    var fake = struct {
        fn scan(_: *anyopaque, alloc: std.mem.Allocator, _: source_mod.Source, _: ?ScanSink) !ScanResult {
            return .{ .rows = try alloc.alloc(types.SessionMeta, 0) };
        }
        fn load(_: *anyopaque, alloc: std.mem.Allocator, _: types.SessionMeta) ![]types.TranscriptMessage {
            return try alloc.alloc(types.TranscriptMessage, 0);
        }
    }{};
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    const host: ScannerHost = .{ .ctx = &fake, .scan = @TypeOf(fake).scan, .loadTranscript = @TypeOf(fake).load };

    try std.testing.expectError(error.NoSelection, session.loadSelectedTranscript(host));
}

test "ai_history_session: scanLocalFilesystem reads codex and claude jsonl files" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".codex/sessions");
    try tmp.dir.makePath(".claude/projects/demo");
    try tmp.dir.writeFile(.{
        .sub_path = ".codex/sessions/a.jsonl",
        .data =
        \\{"type":"session_meta","timestamp":"2026-05-31T10:00:00Z","payload":{"id":"codex-abc","cwd":"/tmp/project"}}
        \\{"type":"response_item","timestamp":"2026-05-31T10:01:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Fix the renderer crash"}]}}
        \\
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = ".claude/projects/demo/b.jsonl",
        .data =
        \\{"sessionId":"claude-abc","cwd":"/tmp/project","timestamp":"2026-05-31T10:00:00Z","message":{"role":"user","content":"Explain the tests"}}
        \\{"sessionId":"claude-abc","cwd":"/tmp/project","timestamp":"2026-05-31T10:01:00Z","message":{"role":"assistant","content":"They pass."}}
        \\
        ,
    });

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmp.dir.realpath(".", &home_buf);
    const result = try scanLocalFilesystem(allocator, .{ .id = "local", .name = "Local", .target = .local }, home);
    defer freeScanResult(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.rows.len);
    try std.testing.expectEqual(@as(u32, 0), result.warning_count);
    var codex_count: usize = 0;
    var claude_count: usize = 0;
    for (result.rows) |row| {
        switch (row.provider) {
            .codex => codex_count += 1,
            .claude => claude_count += 1,
        }
    }
    try std.testing.expectEqual(@as(usize, 1), codex_count);
    try std.testing.expectEqual(@as(usize, 1), claude_count);
}

test "ai_history_session: scanNow failure marks failed and preserves existing rows" {
    const allocator = std.testing.allocator;
    var fake = struct {
        fn scan(_: *anyopaque, _: std.mem.Allocator, _: source_mod.Source, _: ?ScanSink) !ScanResult {
            return error.Boom;
        }
        fn load(_: *anyopaque, alloc: std.mem.Allocator, _: types.SessionMeta) ![]types.TranscriptMessage {
            return try alloc.alloc(types.TranscriptMessage, 0);
        }
    }{};
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    const existing = [_]types.SessionMeta{.{
        .provider = .codex,
        .session_id = "kept",
        .title = "Kept",
        .source_path = "kept.jsonl",
        .resume_kind = .codex_resume,
    }};
    try session.replaceRows(&existing);

    const host: ScannerHost = .{ .ctx = &fake, .scan = @TypeOf(fake).scan, .loadTranscript = @TypeOf(fake).load };
    try std.testing.expectError(error.Boom, session.scanNow(host));

    try std.testing.expectEqual(LoadState.failed, session.state);
    try std.testing.expectEqualStrings("Scan failed", session.status);
    try std.testing.expectEqual(@as(usize, 1), session.rows.items.len);
    try std.testing.expectEqualStrings("kept", session.rows.items[0].session_id);
}

test "ai_history_session: scanLocalFilesystem skips unusable metadata with warning" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".codex/sessions");
    try tmp.dir.writeFile(.{
        .sub_path = ".codex/sessions/good.jsonl",
        .data =
        \\{"type":"session_meta","timestamp":"2026-05-31T10:00:00Z","payload":{"id":"codex-good","cwd":"/tmp/project"}}
        \\{"type":"response_item","timestamp":"2026-05-31T10:01:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Keep this"}]}}
        \\
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = ".codex/sessions/bad.jsonl",
        .data =
        \\{"type":"unrelated","value":1}
        \\
        ,
    });

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmp.dir.realpath(".", &home_buf);
    const result = try scanLocalFilesystem(allocator, .{
        .id = "local",
        .name = "Local",
        .target = .local,
        .providers = .{ .codex = true, .claude = false },
    }, home);
    defer freeScanResult(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqual(@as(u32, 1), result.warning_count);
    try std.testing.expectEqualStrings("codex-good", result.rows[0].session_id);
}

test "ai_history_session: scanLocalFilesystem budget returns partial rows with warning" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".codex/sessions");
    for (0..3) |idx| {
        var path_buf: [64]u8 = undefined;
        const sub_path = try std.fmt.bufPrint(&path_buf, ".codex/sessions/{d}.jsonl", .{idx});
        var data_buf: [512]u8 = undefined;
        const data = try std.fmt.bufPrint(&data_buf,
            \\{{"type":"session_meta","timestamp":"2026-05-31T10:00:0{d}Z","payload":{{"id":"codex-{d}","cwd":"/tmp/project"}}}}
            \\{{"type":"response_item","timestamp":"2026-05-31T10:01:0{d}Z","payload":{{"type":"message","role":"user","content":[{{"type":"input_text","text":"Prompt {d}"}}]}}}}
            \\
        , .{ idx, idx, idx, idx });
        try tmp.dir.writeFile(.{ .sub_path = sub_path, .data = data });
    }

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmp.dir.realpath(".", &home_buf);
    const result = try scanLocalFilesystemWithBudget(allocator, .{
        .id = "local",
        .name = "Local",
        .target = .local,
        .providers = .{ .codex = true, .claude = false },
    }, home, .{ .max_files = 1, .max_bytes = 1024 * 1024 });
    defer freeScanResult(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqual(@as(u32, 1), result.warning_count);
}

test "ai_history_session: scanLocalFilesystem reuses unchanged cached metadata" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".codex/sessions");
    try tmp.dir.writeFile(.{
        .sub_path = ".codex/sessions/a.jsonl",
        .data =
        \\{"type":"session_meta","timestamp":"2026-05-31T10:00:00Z","payload":{"id":"codex-live","cwd":"/tmp/project"}}
        \\{"type":"response_item","timestamp":"2026-05-31T10:01:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Live title"}]}}
        \\
        ,
    });

    const cached_meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "codex-cached",
        .title = "Cached title",
        .project_dir = "/tmp/cached",
        .source_path = "cached.jsonl",
        .resume_kind = .codex_resume,
        .message_count = 1,
    };

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmp.dir.realpath(".", &home_buf);
    const first = try scanLocalFilesystemWithCache(allocator, .{
        .id = "local",
        .name = "Local",
        .target = .local,
        .providers = .{ .codex = true, .claude = false },
    }, home, .{}, null);
    defer freeScanResult(allocator, first);
    try std.testing.expectEqual(@as(usize, 1), first.cache_update.records.len);
    const first_record = first.cache_update.records[0];

    const records = [_]ai_history_cache.CacheRecord{.{
        .source_id = first_record.source_id,
        .provider = first_record.provider,
        .root_path = first_record.root_path,
        .source_path = first_record.source_path,
        .stamp = first_record.stamp,
        .meta = cached_meta,
    }};

    const result = try scanLocalFilesystemWithCache(allocator, .{
        .id = "local",
        .name = "Local",
        .target = .local,
        .providers = .{ .codex = true, .claude = false },
    }, home, .{}, .{ .records = @constCast(&records) });
    defer freeScanResult(allocator, result);

    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqualStrings("codex-cached", result.rows[0].session_id);
    try std.testing.expectEqualStrings("Cached title", result.rows[0].title);
    try std.testing.expectEqual(@as(usize, 1), result.cache_update.records.len);
    try std.testing.expectEqualStrings("codex-cached", result.cache_update.records[0].meta.session_id);
}

test "ai_history_session: category filter limits visible rows" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const rows = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "cx", .title = "Codex one", .source_path = "a.jsonl", .resume_kind = .codex_resume },
        .{ .provider = .claude, .session_id = "cl", .title = "Claude one", .source_path = "b.jsonl", .resume_kind = .claude_resume },
    };
    try session.replaceRows(&rows);

    try std.testing.expectEqual(@as(usize, 2), session.visibleCount());

    session.setCategory(.codex);
    try std.testing.expectEqual(@as(usize, 1), session.visibleCount());
    const sel = session.selectedVisible() orelse return error.ExpectedSelection;
    try std.testing.expectEqual(types.ProviderId.codex, sel.provider);

    session.setCategory(.claude);
    const sel2 = session.selectedVisible() orelse return error.ExpectedSelection;
    try std.testing.expectEqual(types.ProviderId.claude, sel2.provider);
}

test "ai_history_session: categoryCounts splits by provider and respects query" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const rows = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "a", .title = "Renderer fix", .source_path = "a.jsonl", .resume_kind = .codex_resume },
        .{ .provider = .codex, .session_id = "b", .title = "Docs", .source_path = "b.jsonl", .resume_kind = .codex_resume },
        .{ .provider = .claude, .session_id = "c", .title = "Renderer test", .source_path = "c.jsonl", .resume_kind = .claude_resume },
    };
    try session.replaceRows(&rows);

    const counts = session.categoryCounts("");
    try std.testing.expectEqual(@as(usize, 3), counts.all);
    try std.testing.expectEqual(@as(usize, 2), counts.codex);
    try std.testing.expectEqual(@as(usize, 1), counts.claude);

    const filtered = session.categoryCounts("renderer");
    try std.testing.expectEqual(@as(usize, 2), filtered.all);
    try std.testing.expectEqual(@as(usize, 1), filtered.codex);
    try std.testing.expectEqual(@as(usize, 1), filtered.claude);
}

test "ai_history_session: setCategory resets selection" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const rows = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a.jsonl", .resume_kind = .codex_resume },
        .{ .provider = .claude, .session_id = "b", .title = "B", .source_path = "b.jsonl", .resume_kind = .claude_resume },
    };
    try session.replaceRows(&rows);
    session.selected = 1;
    session.list_offset = 1;

    session.setCategory(.codex);
    try std.testing.expectEqual(types.CategoryFilter.codex, session.category);
    try std.testing.expectEqual(@as(usize, 0), session.selected);
    try std.testing.expectEqual(@as(usize, 0), session.list_offset);
}

test "ai_history_session: cycleCategory wraps forward and backward" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    try std.testing.expectEqual(types.CategoryFilter.all, session.category);
    session.cycleCategory(1);
    try std.testing.expectEqual(types.CategoryFilter.codex, session.category);
    session.cycleCategory(1);
    try std.testing.expectEqual(types.CategoryFilter.claude, session.category);
    session.cycleCategory(1);
    try std.testing.expectEqual(types.CategoryFilter.all, session.category);
    session.cycleCategory(-1);
    try std.testing.expectEqual(types.CategoryFilter.claude, session.category);
}

test "ai_history_session: finishScan applies rows when generation current" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    session.scan_generation = 7;

    const rows = try allocator.alloc(types.SessionMeta, 1);
    rows[0] = .{
        .provider = .codex,
        .session_id = try allocator.dupe(u8, "live"),
        .title = try allocator.dupe(u8, "Live"),
        .source_path = try allocator.dupe(u8, "live.jsonl"),
        .resume_kind = .codex_resume,
    };
    session.finishScan(7, .{ .rows = rows, .owns_row_strings = true });

    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqualStrings("Ready", session.status);
    try std.testing.expectEqual(@as(usize, 1), session.rows.items.len);
    try std.testing.expectEqualStrings("live", session.rows.items[0].session_id);
}

test "ai_history_session: finishScan discards stale generation" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    session.scan_generation = 9;

    const rows = try allocator.alloc(types.SessionMeta, 1);
    rows[0] = .{
        .provider = .codex,
        .session_id = try allocator.dupe(u8, "stale"),
        .title = try allocator.dupe(u8, "Stale"),
        .source_path = try allocator.dupe(u8, "stale.jsonl"),
        .resume_kind = .codex_resume,
    };
    // generation 4 != current 9 -> discarded and freed (testing allocator checks no leak)
    session.finishScan(4, .{ .rows = rows, .owns_row_strings = true });

    try std.testing.expectEqual(@as(usize, 0), session.rows.items.len);
}

test "ai_history_session: scanAsync publishes rows then joins clean" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        destroyed: bool = false,
        fn run(ptr: *anyopaque, alloc: std.mem.Allocator, _: source_mod.Source, _: ?ScanSink) anyerror!ScanResult {
            _ = ptr;
            const rows = try alloc.alloc(types.SessionMeta, 1);
            rows[0] = .{
                .provider = .codex,
                .session_id = try alloc.dupe(u8, "async-id"),
                .title = try alloc.dupe(u8, "Async"),
                .source_path = try alloc.dupe(u8, "async.jsonl"),
                .resume_kind = .codex_resume,
            };
            return .{ .rows = rows, .owns_row_strings = true };
        }
        fn destroy(ptr: *anyopaque, _: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.destroyed = true;
        }
    };

    var ctx = Ctx{};
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    session.scanAsync(.{ .ctx = &ctx, .run = Ctx.run, .destroy = Ctx.destroy });
    session.joinForTest();

    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqual(@as(usize, 1), session.rows.items.len);
    try std.testing.expectEqualStrings("async-id", session.rows.items[0].session_id);
    try std.testing.expect(ctx.destroyed);
}

test "ai_history_session: scanAsync marks failed when run errors" {
    const allocator = std.testing.allocator;
    const Ctx = struct {
        destroyed: bool = false,
        fn run(_: *anyopaque, _: std.mem.Allocator, _: source_mod.Source, _: ?ScanSink) anyerror!ScanResult {
            return error.ScanFailed;
        }
        fn destroy(ptr: *anyopaque, _: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.destroyed = true;
        }
    };
    var ctx = Ctx{};
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    session.scanAsync(.{ .ctx = &ctx, .run = Ctx.run, .destroy = Ctx.destroy });
    session.joinForTest();
    try std.testing.expectEqual(LoadState.failed, session.state);
    try std.testing.expect(ctx.destroyed);
}

test "ai_history_session: loadTranscriptAsync publishes messages then joins clean" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        fn run(_: *anyopaque, alloc: std.mem.Allocator) anyerror![]types.TranscriptMessage {
            const messages = try alloc.alloc(types.TranscriptMessage, 1);
            errdefer alloc.free(messages);
            messages[0] = .{ .role = .user, .content = try alloc.dupe(u8, "async-hello") };
            return messages;
        }
        fn destroy(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var ctx_byte: u8 = 0;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    session.loadTranscriptAsync(.{
        .ctx = &ctx_byte,
        .provider = .codex,
        .run = Ctx.run,
        .destroy = Ctx.destroy,
    });
    session.joinForTest();

    try std.testing.expectEqual(TranscriptState.ready, session.transcript_state);
    try std.testing.expectEqual(@as(usize, 1), session.transcript.len);
    try std.testing.expectEqualStrings("async-hello", session.transcript[0].content);
    try std.testing.expectEqual(@as(?types.ProviderId, .codex), session.transcript_provider);
}

test "ai_history_session: loadTranscriptAsync marks failed when run errors" {
    const allocator = std.testing.allocator;
    const Ctx = struct {
        destroyed: bool = false,
        fn run(_: *anyopaque, _: std.mem.Allocator) anyerror![]types.TranscriptMessage {
            return error.TranscriptFailed;
        }
        fn destroy(ptr: *anyopaque, _: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.destroyed = true;
        }
    };
    var ctx = Ctx{};
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    session.loadTranscriptAsync(.{ .ctx = &ctx, .provider = .codex, .run = Ctx.run, .destroy = Ctx.destroy });
    session.joinForTest();
    try std.testing.expectEqual(TranscriptState.failed, session.transcript_state);
    try std.testing.expect(ctx.destroyed);
}

test "ai_history_session: publishTranscript discards stale generation" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    session.transcript_generation = 3;

    const messages = try allocator.alloc(types.TranscriptMessage, 1);
    messages[0] = .{ .role = .user, .content = try allocator.dupe(u8, "stale") };
    // generation 1 != current 3 -> freed, not published (testing allocator checks no leak)
    session.publishTranscript(1, .codex, messages);

    try std.testing.expectEqual(@as(usize, 0), session.transcript.len);
}

test "ai_history_session: finishScan discards when closing" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    session.scan_generation = 2;
    session.closing.store(true, .release);

    const rows = try allocator.alloc(types.SessionMeta, 1);
    rows[0] = .{
        .provider = .codex,
        .session_id = try allocator.dupe(u8, "closing"),
        .title = try allocator.dupe(u8, "Closing"),
        .source_path = try allocator.dupe(u8, "closing.jsonl"),
        .resume_kind = .codex_resume,
    };
    // closing is set -> result is discarded and freed (testing allocator checks no leak)
    session.finishScan(2, .{ .rows = rows, .owns_row_strings = true });

    try std.testing.expectEqual(@as(usize, 0), session.rows.items.len);
}

test "ai_history_session: deinit joins an in-flight scan worker" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        gate: std.Thread.ResetEvent = .{},
        fn run(ptr: *anyopaque, alloc: std.mem.Allocator, _: source_mod.Source, _: ?ScanSink) anyerror!ScanResult {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.gate.wait(); // block until the test releases us
            const rows = try alloc.alloc(types.SessionMeta, 1);
            rows[0] = .{
                .provider = .codex,
                .session_id = try alloc.dupe(u8, "inflight"),
                .title = try alloc.dupe(u8, "Inflight"),
                .source_path = try alloc.dupe(u8, "inflight.jsonl"),
                .resume_kind = .codex_resume,
            };
            return .{ .rows = rows, .owns_row_strings = true };
        }
        fn destroy(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var ctx = Ctx{};
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });

    session.scanAsync(.{ .ctx = &ctx, .run = Ctx.run, .destroy = Ctx.destroy });

    // Release the worker from a helper thread so deinit can join it while it is
    // genuinely in flight (deinit sets closing, then blocks in join until the
    // worker returns; the worker discards its result because closing is set).
    const releaser = try std.Thread.spawn(.{}, struct {
        fn f(c: *Ctx) void {
            c.gate.set();
        }
    }.f, .{&ctx});

    session.deinit(); // sets closing, joins the worker — must not leak or crash
    releaser.join();
}

test "ai_history_session: rowVisible honors the date filter with category and query" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    // 1780315200000 = 2026-06-01 12:00 UTC; +86400000 = 2026-06-02.
    const rows = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 1780315200000 },
        .{ .provider = .claude, .session_id = "b", .title = "B", .source_path = "b.jsonl", .resume_kind = .claude_resume, .last_active_at_ms = 1780315200000 + 86400000 },
    };
    try session.replaceRows(&rows);
    try std.testing.expectEqual(@as(usize, 2), session.visibleCount());

    session.setDateFilter(20260601);
    try std.testing.expectEqual(@as(usize, 1), session.visibleCount());
    const sel = session.selectedVisible() orelse return error.ExpectedSelection;
    try std.testing.expectEqualStrings("a", sel.session_id);

    // Date AND category combine.
    session.setCategory(.claude);
    try std.testing.expectEqual(@as(usize, 0), session.visibleCount());
    session.setDateFilter(null);
    try std.testing.expectEqual(@as(usize, 1), session.visibleCount());
}

test "ai_history_session: setDateFilter resets selection and is a no-op when unchanged" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    const rows = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 1780315200000 },
        .{ .provider = .codex, .session_id = "b", .title = "B", .source_path = "b.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 1780315200000 },
    };
    try session.replaceRows(&rows);
    session.selected = 1;
    session.list_offset = 1;
    session.setDateFilter(20260601);
    try std.testing.expectEqual(@as(usize, 0), session.selected);
    try std.testing.expectEqual(@as(usize, 0), session.list_offset);

    // No-op path: setting the same filter again must not move selection.
    session.selected = 1;
    session.setDateFilter(20260601);
    try std.testing.expectEqual(@as(usize, 1), session.selected);
}

test "ai_history_session: scrollDateBy saturates at zero" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    try std.testing.expectEqual(@as(usize, 0), session.date_offset);
    session.scrollDateBy(-3);
    try std.testing.expectEqual(@as(usize, 0), session.date_offset);
    session.scrollDateBy(4);
    try std.testing.expectEqual(@as(usize, 4), session.date_offset);
    session.scrollDateBy(-1);
    try std.testing.expectEqual(@as(usize, 3), session.date_offset);
}

test "ai_history_session: buildDateBuckets groups distinct local days descending" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    const day1: i64 = 1780315200000; // 2026-06-01 12:00 UTC
    const day2: i64 = day1 + 86400000; // 2026-06-02
    const rows = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = day2 },
        .{ .provider = .claude, .session_id = "b", .title = "B", .source_path = "b.jsonl", .resume_kind = .claude_resume, .last_active_at_ms = day1 + 3600000 },
        .{ .provider = .codex, .session_id = "c", .title = "C", .source_path = "c.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = day1 },
        .{ .provider = .codex, .session_id = "d", .title = "D", .source_path = "d.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 0 }, // no timestamp
    };
    try session.replaceRows(&rows);

    var buf: [8]types.DateBucket = undefined;
    const all = session.buildDateBuckets(&buf);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqual(@as(types.DateKey, 20260602), all[0].key);
    try std.testing.expectEqual(@as(usize, 1), all[0].count);
    try std.testing.expectEqual(@as(types.DateKey, 20260601), all[1].key);
    try std.testing.expectEqual(@as(usize, 2), all[1].count); // b + c, no-timestamp d excluded
    try std.testing.expectEqual(@as(usize, 4), session.dateAllCount()); // includes d

    // Cross-filter: with category = Codex, day 20260601 has only c.
    session.setCategory(.codex);
    const codex = session.buildDateBuckets(&buf);
    try std.testing.expectEqual(@as(usize, 2), codex.len);
    try std.testing.expectEqual(@as(types.DateKey, 20260601), codex[1].key);
    try std.testing.expectEqual(@as(usize, 1), codex[1].count);
}

test "ai_history_session: categoryCounts honors the active date filter" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    const day1: i64 = 1780315200000;
    const day2: i64 = day1 + 86400000;
    const rows = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = day1 },
        .{ .provider = .claude, .session_id = "b", .title = "B", .source_path = "b.jsonl", .resume_kind = .claude_resume, .last_active_at_ms = day1 },
        .{ .provider = .codex, .session_id = "c", .title = "C", .source_path = "c.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = day2 },
    };
    try session.replaceRows(&rows);

    const all = session.categoryCounts("");
    try std.testing.expectEqual(@as(usize, 3), all.all);

    session.setDateFilter(20260601);
    const d1 = session.categoryCounts("");
    try std.testing.expectEqual(@as(usize, 2), d1.all);
    try std.testing.expectEqual(@as(usize, 1), d1.codex);
    try std.testing.expectEqual(@as(usize, 1), d1.claude);
}

test "ai_history_session: buildDateBuckets respects the buffer cap" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    const base: i64 = 1780315200000;
    var rows: [4]types.SessionMeta = undefined;
    for (&rows, 0..) |*r, i| {
        r.* = .{ .provider = .codex, .session_id = "x", .title = "X", .source_path = "x.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = base + @as(i64, @intCast(i)) * 86400000 };
    }
    try session.replaceRows(&rows);
    var small: [2]types.DateBucket = undefined;
    const capped = session.buildDateBuckets(&small);
    try std.testing.expectEqual(@as(usize, 2), capped.len); // 4 distinct days clipped to 2
}

fn testMakeRow(allocator: std.mem.Allocator, id: []const u8) !types.SessionMeta {
    return .{
        .provider = .codex,
        .session_id = try allocator.dupe(u8, id),
        .title = try allocator.dupe(u8, id),
        .source_path = try allocator.dupe(u8, id),
        .resume_kind = .codex_resume,
    };
}

test "ai_history_session: appendScanRows appends for current generation" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    session.scan_generation = 3;

    const rows = try allocator.alloc(types.SessionMeta, 2);
    rows[0] = try testMakeRow(allocator, "a");
    rows[1] = try testMakeRow(allocator, "b");

    try std.testing.expect(session.appendScanRows(3, rows));
    try std.testing.expectEqual(@as(usize, 2), session.rows.items.len);
    try std.testing.expectEqual(LoadState.scanning, session.state);
}

test "ai_history_session: appendScanRows discards stale generation" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    session.scan_generation = 9;

    const rows = try allocator.alloc(types.SessionMeta, 1);
    rows[0] = try testMakeRow(allocator, "stale");
    // generation 4 != current 9 -> freed, not appended (testing allocator checks no leak)
    try std.testing.expect(!session.appendScanRows(4, rows));
    try std.testing.expectEqual(@as(usize, 0), session.rows.items.len);
}

test "ai_history_session: appendScanRows discards when closing" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    session.scan_generation = 1;
    session.closing.store(true, .release);

    const rows = try allocator.alloc(types.SessionMeta, 1);
    rows[0] = try testMakeRow(allocator, "x");
    try std.testing.expect(!session.appendScanRows(1, rows));
    try std.testing.expectEqual(@as(usize, 0), session.rows.items.len);
}

test "ai_history_session: finishScan non-authoritative sorts streamed rows in place" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    session.scan_generation = 1;

    // Simulate streamed rows already appended out of order.
    const r = try allocator.alloc(types.SessionMeta, 2);
    r[0] = try testMakeRow(allocator, "old");
    r[0].last_active_at_ms = 100;
    r[1] = try testMakeRow(allocator, "new");
    r[1].last_active_at_ms = 200;
    try std.testing.expect(session.appendScanRows(1, r));

    const empty = try allocator.alloc(types.SessionMeta, 0);
    session.finishScan(1, .{ .rows = empty, .authoritative = false, .owns_row_strings = true });

    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqual(@as(usize, 2), session.rows.items.len);
    try std.testing.expectEqualStrings("new", session.rows.items[0].session_id); // desc by last_active
    try std.testing.expectEqualStrings("old", session.rows.items[1].session_id);
}

test "ai_history_session: replaceRows preserves selection by session id" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const first = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a", .resume_kind = .codex_resume, .last_active_at_ms = 300 },
        .{ .provider = .codex, .session_id = "b", .title = "B", .source_path = "b", .resume_kind = .codex_resume, .last_active_at_ms = 200 },
        .{ .provider = .codex, .session_id = "c", .title = "C", .source_path = "c", .resume_kind = .codex_resume, .last_active_at_ms = 100 },
    };
    try session.replaceRows(&first);
    session.selected = 0; // "a" (most-recent in `first`, index 0)

    // Replace with a reordered set; "b" jumps to most-recent so "a" moves to index 1.
    const second = [_]types.SessionMeta{
        .{ .provider = .codex, .session_id = "b", .title = "B", .source_path = "b", .resume_kind = .codex_resume, .last_active_at_ms = 900 },
        .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a", .resume_kind = .codex_resume, .last_active_at_ms = 300 },
        .{ .provider = .codex, .session_id = "c", .title = "C", .source_path = "c", .resume_kind = .codex_resume, .last_active_at_ms = 100 },
    };
    try session.replaceRows(&second);
    // New behavior follows "a" to index 1; old reset-to-0 behavior would give 0.
    try std.testing.expectEqual(@as(usize, 1), session.selected);
}

const TestCollectSink = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayListUnmanaged(types.SessionMeta) = .empty,

    fn sink(self: *TestCollectSink) ScanSink {
        return .{ .ctx = self, .publish = publish };
    }
    fn publish(ctx: *anyopaque, rows: []types.SessionMeta) bool {
        const self: *TestCollectSink = @ptrCast(@alignCast(ctx));
        self.rows.appendSlice(self.allocator, rows) catch {
            freeRows(self.allocator, rows);
            self.allocator.free(rows);
            return true;
        };
        self.allocator.free(rows); // structs moved in
        return true;
    }
    fn deinit(self: *TestCollectSink) void {
        freeRows(self.allocator, self.rows.items);
        self.rows.deinit(self.allocator);
    }
};

test "ai_history_session: local scan with sink streams rows and returns empty non-authoritative result" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".codex/sessions");
    try tmp.dir.writeFile(.{
        .sub_path = ".codex/sessions/one.jsonl",
        .data =
        \\{"type":"session_meta","timestamp":"2026-05-31T10:00:00Z","payload":{"id":"codex-one","cwd":"/tmp/project"}}
        \\{"type":"response_item","timestamp":"2026-05-31T10:01:00Z","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}
        \\
        ,
    });

    var collect = TestCollectSink{ .allocator = allocator };
    defer collect.deinit();

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmp.dir.realpath(".", &home_buf);
    const result = try scanLocalFilesystemWithCacheSink(allocator, .{
        .id = "local",
        .name = "Local",
        .target = .local,
        .providers = .{ .codex = true, .claude = false },
    }, home, .{}, null, collect.sink());
    defer freeScanResult(allocator, result);

    try std.testing.expect(!result.authoritative);
    try std.testing.expectEqual(@as(usize, 0), result.rows.len);
    try std.testing.expectEqual(@as(usize, 1), collect.rows.items.len);
    try std.testing.expectEqualStrings("codex-one", collect.rows.items[0].session_id);
}

test "ai_history_session: remote scan with sink streams rows and returns empty non-authoritative result" {
    const allocator = std.testing.allocator;

    var fake = FakeRemoteHost{};
    const host = fake.remoteExecHost();

    var collect = TestCollectSink{ .allocator = allocator };
    defer collect.deinit();

    const result = try scanRemoteFilesystemSink(allocator, .{
        .id = "wsl",
        .name = "WSL",
        .target = .{ .wsl = .{} },
        .providers = .{ .codex = true, .claude = false },
    }, host, collect.sink());
    defer freeScanResult(allocator, result);

    try std.testing.expect(!result.authoritative);
    try std.testing.expectEqual(@as(usize, 0), result.rows.len);
    try std.testing.expectEqual(@as(usize, 1), collect.rows.items.len);
    try std.testing.expectEqualStrings("codex-abc", collect.rows.items[0].session_id);
}

test "ai_history_session: scanningStatusLabel formats count" {
    var buf: [48]u8 = undefined;
    try std.testing.expectEqualStrings("Scanning…", scanningStatusLabel(&buf, 0));
    try std.testing.expectEqualStrings("Scanning… 7", scanningStatusLabel(&buf, 7));
}

test "ai_history_session: scanAsync streams batches via sink then finalizes ready and sorted" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        fn run(_: *anyopaque, alloc: std.mem.Allocator, _: source_mod.Source, sink: ?ScanSink) anyerror!ScanResult {
            const s = sink.?;
            {
                const b = try alloc.alloc(types.SessionMeta, 1);
                b[0] = .{ .provider = .codex, .session_id = try alloc.dupe(u8, "s1"), .title = try alloc.dupe(u8, "One"), .source_path = try alloc.dupe(u8, "1.jsonl"), .resume_kind = .codex_resume, .last_active_at_ms = 100 };
                _ = s.publish(s.ctx, b);
            }
            {
                const b = try alloc.alloc(types.SessionMeta, 1);
                b[0] = .{ .provider = .codex, .session_id = try alloc.dupe(u8, "s2"), .title = try alloc.dupe(u8, "Two"), .source_path = try alloc.dupe(u8, "2.jsonl"), .resume_kind = .codex_resume, .last_active_at_ms = 200 };
                _ = s.publish(s.ctx, b);
            }
            const rows = try alloc.alloc(types.SessionMeta, 0);
            return .{ .rows = rows, .authoritative = false, .owns_row_strings = true };
        }
        fn destroy(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var ctx_byte: u8 = 0;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    session.scanAsync(.{ .ctx = &ctx_byte, .run = Ctx.run, .destroy = Ctx.destroy });
    session.joinForTest();

    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqual(@as(usize, 2), session.rows.items.len);
    try std.testing.expectEqualStrings("s2", session.rows.items[0].session_id); // sorted desc by last_active
    try std.testing.expectEqualStrings("s1", session.rows.items[1].session_id);
}
