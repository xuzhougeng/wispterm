# Directory Download/Upload + Cancelable Downloads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the remote file explorer download and upload whole directories (recursively), and make download tasks — including folder downloads — cancelable with the partial result cleaned up.

**Architecture:** Reuse the existing single-job transfer system. Add an `scp -r` variant in `src/scp.zig` (`transferDirWithControl`) that matches the existing `TransferFn` signature, so directories flow through the unchanged job queue/worker/toast/cancel machinery. The file explorer picks the recursive transfer function for directory entries (download) and for the new `Shift+U` folder upload. On cancel, the download's partial destination is deleted. A new cross-platform `pickFolder` dialog backs folder selection.

**Tech Stack:** Zig 0.15.2; `scp`/`ssh` child processes; Windows `comdlg32`/`shell32`/`ole32`, macOS `NSOpenPanel` (ObjC bridge), Linux `zenity`. Fast tests: `zig build test`. Full suite (default target windows-gnu): `zig build test-full`.

---

## File Structure

- `src/scp.zig` — add `transferDirWithControl` + an internal `transferImpl(..., recursive)`; thread a `recursive` flag through `runScpTransfer`; extract a pure `buildScpFlagArgs` so the `-r` flag is unit-testable. (Modify)
- `src/file_explorer.zig` — `downloadSelected` handles directories via a new pure `pickDownloadTransferFn`; add `uploadFolder`; add `removePartialDownload` and call it when a download cancels. (Modify)
- `src/platform/file_dialog.zig` — re-export `pickFolder`; add a signature test. (Modify)
- `src/platform/file_dialog_windows.zig` — `pickFolder` via `SHBrowseForFolderW`. (Modify)
- `src/platform/file_dialog_macos.zig` — `pickFolder` extern + wrapper. (Modify)
- `src/platform/services_macos_bridge.m` — `wispterm_macos_pick_folder_dialog`. (Modify)
- `src/platform/file_dialog_linux.zig` — `pickFolder` via `zenity --directory`. (Modify)
- `src/platform/file_dialog_unsupported.zig` — `pickFolder` returns null. (Modify)
- `src/input.zig` — `Shift+U` → `openFolderDialogAndUpload`. (Modify)

---

## Task 1: `scp -r` recursive transfer

**Files:**
- Modify: `src/scp.zig` (`runScpTransfer` ~120-181, `transferWithControl` ~64-94)
- Test: `src/scp.zig` (tests section, after `test "buildUploadCommand handles target directories"`)

- [ ] **Step 1: Write the failing test**

Add to the tests section of `src/scp.zig` (e.g. after the `appendShellQuote` test):

```zig
fn containsArg(args: []const []const u8, needle: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

test "buildScpFlagArgs includes -r only for recursive transfers" {
    var conn: SshConnection = .{};
    conn.password_auth = false;
    conn.port_len = 0;

    var argv_buf: [32][]const u8 = undefined;

    const argc_file = buildScpFlagArgs(&argv_buf, &conn, null, false, false);
    try std.testing.expect(!containsArg(argv_buf[0..argc_file], "-r"));

    const argc_dir = buildScpFlagArgs(&argv_buf, &conn, null, false, true);
    try std.testing.expect(containsArg(argv_buf[0..argc_dir], "-r"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: compile error — `buildScpFlagArgs` is not defined.

- [ ] **Step 3: Add the pure `buildScpFlagArgs` helper (only)**

In `src/scp.zig`, add this helper just above `fn runScpTransfer(`. Add **only** the helper in this step — leave `runScpTransfer` untouched so the file keeps compiling (the temporary duplication of the flag-building logic is removed in Step 5):

```zig
/// Build the scp argv up to (but excluding) the src/dst path arguments.
/// Returns the count of arguments written into `argv_buf`. Pure/testable.
fn buildScpFlagArgs(
    argv_buf: *[32][]const u8,
    conn: *const SshConnection,
    control_path: ?[]const u8,
    legacy_protocol: bool,
    recursive: bool,
) usize {
    var argc: usize = 0;
    argv_buf[argc] = platform_pty_command.scpExecutableName();
    argc += 1;
    argv_buf[argc] = "-q";
    argc += 1;
    if (recursive) {
        argv_buf[argc] = "-r";
        argc += 1;
    }
    if (legacy_protocol) {
        argv_buf[argc] = "-O";
        argc += 1;
    }
    return appendSshOptions(argv_buf, argc, conn, .scp, control_path);
}
```

(Unused file-scope functions are allowed in Zig, so this compiles even though nothing calls it yet.)

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: the `buildScpFlagArgs` test passes; the rest of the file is unchanged and still compiles.

- [ ] **Step 5: Route `runScpTransfer` through the helper, add the `recursive` parameter, and add `transferImpl` + `transferDirWithControl`**

First, change `runScpTransfer`'s signature to add a `recursive: bool` parameter (place it right before `control`) and replace its inline argv-prefix building. The current head:

```zig
fn runScpTransfer(
    allocator: std.mem.Allocator,
    conn: *const SshConnection,
    src: []const u8,
    dst: []const u8,
    control_path: ?[]const u8,
    env_map: ?*std.process.EnvMap,
    legacy_protocol: bool,
    control: *TransferControl,
) TransferResult {
    if (control.cancelRequested()) return .cancelled;

    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = platform_pty_command.scpExecutableName();
    argc += 1;
    argv_buf[argc] = "-q";
    argc += 1;
    if (legacy_protocol) {
        argv_buf[argc] = "-O";
        argc += 1;
    }

    argc = appendSshOptions(&argv_buf, argc, conn, .scp, control_path);

    argv_buf[argc] = src;
    argc += 1;
    argv_buf[argc] = dst;
    argc += 1;
```

becomes:

```zig
fn runScpTransfer(
    allocator: std.mem.Allocator,
    conn: *const SshConnection,
    src: []const u8,
    dst: []const u8,
    control_path: ?[]const u8,
    env_map: ?*std.process.EnvMap,
    legacy_protocol: bool,
    recursive: bool,
    control: *TransferControl,
) TransferResult {
    if (control.cancelRequested()) return .cancelled;

    var argv_buf: [32][]const u8 = undefined;
    var argc = buildScpFlagArgs(&argv_buf, conn, control_path, legacy_protocol, recursive);

    argv_buf[argc] = src;
    argc += 1;
    argv_buf[argc] = dst;
    argc += 1;
```

(The rest of `runScpTransfer` — spawn, wait, result — is unchanged.)

Next, in the **same step**, replace the body of `transferWithControl` (lines ~64-94) so it delegates to a shared `transferImpl`, and add the public recursive variant. Doing the `runScpTransfer` change and this together keeps the file compiling (`transferWithControl` is the only caller of `runScpTransfer`). Replace:

```zig
pub fn transferWithControl(allocator: std.mem.Allocator, conn: *const SshConnection, src: []const u8, dst: []const u8, control: *TransferControl) TransferResult {
    var askpass_path: ?[]const u8 = null;
    defer if (askpass_path) |p| allocator.free(p);
    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*map| map.deinit();

    if (conn.password_auth) {
        askpass_path = platform_process.ensureSshAskPassScript(allocator) orelse return .spawn_error;
        env_map = std.process.getEnvMap(allocator) catch return .spawn_error;
        if (env_map) |*map| {
            platform_process.putSshAskPassEnv(map, askpass_path.?, conn.password()) catch return .spawn_error;
        }
    }

    // Windows OpenSSH's ControlMaster support relies on Unix-domain socket
    // semantics that fail here with "getsockname failed: Not a socket".
    // Keep helper SSH/SCP calls independent; the real interactive SSH session
    // remains untouched.
    const control_path: ?[]const u8 = null;

    const env_ptr: ?*std.process.EnvMap = if (env_map) |*map| map else null;
    const default_result = runScpTransfer(allocator, conn, src, dst, control_path, env_ptr, false, control);
    if (default_result == .ok or default_result == .spawn_error or default_result == .cancelled) return default_result;

    std.debug.print("SCP default mode failed; retrying legacy scp protocol (-O)\n", .{});
    const legacy_result = runScpTransfer(allocator, conn, src, dst, control_path, env_ptr, true, control);
    if (legacy_result == .ok or legacy_result == .spawn_error or legacy_result == .cancelled) return legacy_result;

    std.debug.print("SCP legacy mode failed; retrying over ssh stream\n", .{});
    return runSshStreamTransfer(allocator, conn, src, dst, control_path, env_ptr, control);
}
```

with:

```zig
pub fn transferWithControl(allocator: std.mem.Allocator, conn: *const SshConnection, src: []const u8, dst: []const u8, control: *TransferControl) TransferResult {
    return transferImpl(allocator, conn, src, dst, control, false);
}

/// Recursively transfer a directory with `scp -r`. Falls back through the
/// legacy scp protocol (`-O`) but NOT the ssh `cat` stream (which cannot
/// transfer directories).
pub fn transferDirWithControl(allocator: std.mem.Allocator, conn: *const SshConnection, src: []const u8, dst: []const u8, control: *TransferControl) TransferResult {
    return transferImpl(allocator, conn, src, dst, control, true);
}

fn transferImpl(allocator: std.mem.Allocator, conn: *const SshConnection, src: []const u8, dst: []const u8, control: *TransferControl, recursive: bool) TransferResult {
    var askpass_path: ?[]const u8 = null;
    defer if (askpass_path) |p| allocator.free(p);
    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*map| map.deinit();

    if (conn.password_auth) {
        askpass_path = platform_process.ensureSshAskPassScript(allocator) orelse return .spawn_error;
        env_map = std.process.getEnvMap(allocator) catch return .spawn_error;
        if (env_map) |*map| {
            platform_process.putSshAskPassEnv(map, askpass_path.?, conn.password()) catch return .spawn_error;
        }
    }

    // Windows OpenSSH's ControlMaster support relies on Unix-domain socket
    // semantics that fail here with "getsockname failed: Not a socket".
    // Keep helper SSH/SCP calls independent; the real interactive SSH session
    // remains untouched.
    const control_path: ?[]const u8 = null;

    const env_ptr: ?*std.process.EnvMap = if (env_map) |*map| map else null;
    const default_result = runScpTransfer(allocator, conn, src, dst, control_path, env_ptr, false, recursive, control);
    if (default_result == .ok or default_result == .spawn_error or default_result == .cancelled) return default_result;

    std.debug.print("SCP default mode failed; retrying legacy scp protocol (-O)\n", .{});
    const legacy_result = runScpTransfer(allocator, conn, src, dst, control_path, env_ptr, true, recursive, control);
    if (legacy_result == .ok or legacy_result == .spawn_error or legacy_result == .cancelled) return legacy_result;

    // The ssh `cat` stream fallback only handles single files; directories have
    // no further fallback after both scp modes fail.
    if (recursive) return legacy_result;

    std.debug.print("SCP legacy mode failed; retrying over ssh stream\n", .{});
    return runSshStreamTransfer(allocator, conn, src, dst, control_path, env_ptr, control);
}
```

- [ ] **Step 6: Run the full fast suite to verify it compiles and passes**

Run: `zig build test 2>&1 | tail -20`
Expected: all tests pass (the new test + existing scp tests). No remaining `runScpTransfer` call-site errors.

- [ ] **Step 7: Commit**

```bash
git add src/scp.zig
git commit -m "feat(scp): add recursive transferDirWithControl (scp -r)"
```

---

## Task 2: File explorer — directory download + folder upload

**Files:**
- Modify: `src/file_explorer.zig` (`downloadSelected` ~1561-1584, `uploadFile` ~1586-1599)
- Test: `src/file_explorer.zig` (tests section)

- [ ] **Step 1: Write the failing test**

Add near the other file_explorer transfer tests (e.g. after `test "file_explorer: download helper starts transfer with explicit remote path"`):

```zig
test "file_explorer: download picks recursive transfer for directories" {
    try std.testing.expectEqual(
        @as(TransferFn, scp.transferDirWithControl),
        pickDownloadTransferFn(true),
    );
    try std.testing.expectEqual(
        @as(TransferFn, scp.transferWithControl),
        pickDownloadTransferFn(false),
    );
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: compile error — `pickDownloadTransferFn` is not defined.

- [ ] **Step 3: Add `pickDownloadTransferFn` and use it in `downloadSelected`; add `uploadFolder`**

In `src/file_explorer.zig`, add the helper just above `pub fn downloadSelected`:

```zig
/// Choose the transfer function for a download based on whether the selected
/// entry is a directory (recursive `scp -r`) or a regular file.
fn pickDownloadTransferFn(is_dir: bool) TransferFn {
    return if (is_dir) scp.transferDirWithControl else scp.transferWithControl;
}
```

Then change `downloadSelected` — remove the directory skip and select the transfer function. Replace:

```zig
    const entry = &g_entries[sel];
    if (entry.is_dir) return; // Only download files

    const remote_path = entry.path_buf[0..entry.path_len];

    // Build remote spec: user@host:path
    var spec_buf: [512]u8 = undefined;
    const src = scp.remoteSpec(&spec_buf, &g_ssh_conn, remote_path);

    var dst_buf: [512]u8 = undefined;
    const name = entry.name_buf[0..entry.name_len];
    const dst = platform_local_path.joinInto(dst_buf[0..], local_dir, name) orelse {
        setTransferStatusForKind(.download, .failed, "Path too long");
        return;
    };

    _ = startTransferJob(.download, &g_ssh_conn, src, dst, name, scp.transferWithControl);
```

with:

```zig
    const entry = &g_entries[sel];

    const remote_path = entry.path_buf[0..entry.path_len];

    // Build remote spec: user@host:path
    var spec_buf: [512]u8 = undefined;
    const src = scp.remoteSpec(&spec_buf, &g_ssh_conn, remote_path);

    var dst_buf: [512]u8 = undefined;
    const name = entry.name_buf[0..entry.name_len];
    const dst = platform_local_path.joinInto(dst_buf[0..], local_dir, name) orelse {
        setTransferStatusForKind(.download, .failed, "Path too long");
        return;
    };

    _ = startTransferJob(.download, &g_ssh_conn, src, dst, name, pickDownloadTransferFn(entry.is_dir));
```

Also update the doc comment on `downloadSelected` from `/// Download the selected remote file to a local directory.` to `/// Download the selected remote file or directory to a local directory.`

Then add `uploadFolder` immediately after `uploadFile` (after line ~1599):

```zig
/// Upload a local folder (recursively) to the current remote directory.
pub fn uploadFolder(local_path: []const u8) void {
    if (g_mode != .remote or !g_has_ssh_conn) return;

    // Destination: current remote dir
    const remote_dir = g_root_path[0..g_root_path_len];

    var spec_buf: [512]u8 = undefined;
    const dst = scp.remoteSpec(&spec_buf, &g_ssh_conn, remote_dir);

    const name = platform_local_path.basename(local_path);

    _ = startTransferJob(.upload, &g_ssh_conn, local_path, dst, name, scp.transferDirWithControl);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: the new test passes; existing file_explorer tests still pass.

- [ ] **Step 5: Commit**

```bash
git add src/file_explorer.zig
git commit -m "feat(file-explorer): download directories and add uploadFolder"
```

---

## Task 3: Cancel deletes the partial download

**Files:**
- Modify: `src/file_explorer.zig` (`tickTransferJob` `.cancelled` branch ~1104)
- Test: `src/file_explorer.zig` (extend cancel coverage)

- [ ] **Step 1: Write the failing test**

Add after `test "file_explorer: active download transfer can be cancelled"`:

```zig
test "file_explorer: cancelling a download deletes the partial destination" {
    resetTransferStateForTest();
    defer resetTransferStateForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "partial.bin", .data = "incomplete" });
    const dst = try tmp.dir.realpathAlloc(std.testing.allocator, "partial.bin");
    defer std.testing.allocator.free(dst);

    var conn: ssh_connection.SshConnection = .{};
    try std.testing.expect(startTransferJobForTest(.download, &conn, "remote", dst, "partial.bin", transferWaitForCancelForTest));
    try std.testing.expect(cancelActiveDownloadForTest());

    tickTransfersUntilIdleForTest();

    try std.testing.expectEqual(TransferStatus.cancelled, g_transfer_status);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("partial.bin", .{}));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — the partial file still exists (`access` succeeds, so `expectError` fails), or `removePartialDownload` is undefined if referenced early. It should fail on the `expectError` assertion.

- [ ] **Step 3: Add `removePartialDownload` and call it when a download cancels**

In `src/file_explorer.zig`, add the helper near the other transfer helpers (e.g. just above `pub fn cancelActiveTransfer`):

```zig
/// Remove a partially-transferred download destination — a half-written file or
/// an incomplete folder tree. Best-effort: any error (e.g. already gone) is
/// ignored.
fn removePartialDownload(path: []const u8) void {
    if (path.len == 0) return;
    if (std.fs.path.isAbsolute(path)) {
        std.fs.deleteTreeAbsolute(path) catch {};
    } else {
        std.fs.cwd().deleteTree(path) catch {};
    }
}
```

Then update the `.cancelled` arm of the `switch (job.result)` in `tickTransferJob`. Replace:

```zig
        .cancelled => setTransferStatusForKind(job.request.kind, .cancelled, display),
```

with:

```zig
        .cancelled => {
            if (job.request.kind == .download) {
                removePartialDownload(job.request.dst_buf[0..job.request.dst_len]);
            }
            setTransferStatusForKind(job.request.kind, .cancelled, display);
        },
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: the new test passes; the existing "active download transfer can be cancelled" test (dst = `"local"`, a non-existent relative path) still passes — `removePartialDownload` no-ops on the missing path.

- [ ] **Step 5: Commit**

```bash
git add src/file_explorer.zig
git commit -m "feat(file-explorer): delete partial destination when a download is cancelled"
```

---

## Task 4: Cross-platform `pickFolder` dialog

**Files:**
- Modify: `src/platform/file_dialog.zig` (re-export + test)
- Modify: `src/platform/file_dialog_windows.zig`
- Modify: `src/platform/file_dialog_macos.zig`
- Modify: `src/platform/services_macos_bridge.m`
- Modify: `src/platform/file_dialog_linux.zig`
- Modify: `src/platform/file_dialog_unsupported.zig`
- Test: `src/platform/file_dialog.zig`

- [ ] **Step 1: Write the failing test**

Add to `src/platform/file_dialog.zig` after the existing `"platform file dialog exposes typed open and save APIs"` test:

```zig
test "platform file dialog exposes a folder picker" {
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(@TypeOf(pickFolder)).@"fn".params.len);
    try std.testing.expect(@typeInfo(@TypeOf(pickFolder)).@"fn".params[0].type.? == std.mem.Allocator);
    try std.testing.expect(@typeInfo(@TypeOf(pickFolder)).@"fn".params[1].type.? == OpenRequest);
    try std.testing.expect(@typeInfo(@TypeOf(pickFolder)).@"fn".return_type.? == ?[]u8);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full 2>&1 | tail -30`
Expected: compile error — `pickFolder` is not defined in `file_dialog.zig` (and the backends).

- [ ] **Step 3: Re-export `pickFolder` from the dispatcher**

In `src/platform/file_dialog.zig`, add after `pub const saveFile = impl.saveFile;`:

```zig
pub const pickFolder = impl.pickFolder;
```

- [ ] **Step 4: Implement the unsupported backend**

In `src/platform/file_dialog_unsupported.zig`, add after `saveFile`:

```zig
pub fn pickFolder(allocator: std.mem.Allocator, request: OpenRequest) ?[]u8 {
    _ = allocator;
    _ = request;
    return null;
}
```

- [ ] **Step 5: Implement the Linux backend (zenity --directory)**

In `src/platform/file_dialog_linux.zig`, add after `openFile`:

```zig
/// Open a folder-chooser dialog via zenity and return the selected directory,
/// or null if the user cancelled or zenity is unavailable.
/// The returned slice is allocated with `allocator`; caller must free it.
pub fn pickFolder(allocator: std.mem.Allocator, request: OpenRequest) ?[]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    argv.append(a, "zenity") catch return null;
    argv.append(a, "--file-selection") catch return null;
    argv.append(a, "--directory") catch return null;
    argv.append(a, "--title") catch return null;
    argv.append(a, request.title) catch return null;

    return runZenityDialog(allocator, a, argv.items);
}
```

- [ ] **Step 6: Implement the macOS backend**

In `src/platform/services_macos_bridge.m`, add right after `wispterm_macos_open_file_dialog` (after its closing `}`):

```objc
char *wispterm_macos_pick_folder_dialog(const char *title) {
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseFiles = NO;
        panel.canChooseDirectories = YES;
        panel.allowsMultipleSelection = NO;
        if (title != NULL) panel.title = [NSString stringWithUTF8String:title];
        if ([panel runModal] != NSModalResponseOK) return NULL;
        return wispterm_macos_copy_nsstring(panel.URL.path);
    }
}
```

In `src/platform/file_dialog_macos.zig`, add the extern next to the others (after the `wispterm_macos_save_file_dialog` extern):

```zig
extern fn wispterm_macos_pick_folder_dialog(title: [*:0]const u8) ?[*:0]u8;
```

and the wrapper after `openFile`:

```zig
pub fn pickFolder(allocator: std.mem.Allocator, request: OpenRequest) ?[]u8 {
    _ = request.owner;
    _ = request.filters;
    const title = allocator.dupeZ(u8, request.title) catch return null;
    defer allocator.free(title);
    const raw = wispterm_macos_pick_folder_dialog(title.ptr) orelse return null;
    defer wispterm_macos_services_free(raw);
    return allocator.dupe(u8, std.mem.span(raw)) catch null;
}
```

- [ ] **Step 7: Implement the Windows backend (SHBrowseForFolderW)**

In `src/platform/file_dialog_windows.zig`, add these extern declarations and constants after the existing `extern "comdlg32"` lines (after line ~37):

```zig
const BIF_RETURNONLYFSDIRS: windows.UINT = 0x00000001;
const BIF_EDITBOX: windows.UINT = 0x00000010;
const BIF_NEWDIALOGSTYLE: windows.UINT = 0x00000040;
const COINIT_APARTMENTTHREADED: windows.DWORD = 0x2;

const BROWSEINFOW = extern struct {
    hwndOwner: ?windows.HWND = null,
    pidlRoot: ?*anyopaque = null,
    pszDisplayName: ?[*]windows.WCHAR = null,
    lpszTitle: ?[*:0]const windows.WCHAR = null,
    ulFlags: windows.UINT = 0,
    lpfn: ?*const anyopaque = null,
    lParam: windows.LPARAM = 0,
    iImage: c_int = 0,
};

extern "shell32" fn SHBrowseForFolderW(lpbi: *BROWSEINFOW) callconv(.winapi) ?*anyopaque;
extern "shell32" fn SHGetPathFromIDListW(pidl: ?*anyopaque, pszPath: [*]windows.WCHAR) callconv(.winapi) windows.BOOL;
extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;
extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: windows.DWORD) callconv(.winapi) windows.HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
```

Add the public `pickFolder` after `saveFile` (after line ~79):

```zig
pub fn pickFolder(allocator: std.mem.Allocator, request: OpenRequest) ?[]u8 {
    return switch (builtin.os.tag) {
        .windows => pickWindowsFolder(allocator, request),
        else => null,
    };
}
```

Add the implementation near `openWindowsFile`:

```zig
fn pickWindowsFolder(allocator: std.mem.Allocator, request: OpenRequest) ?[]u8 {
    const title_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, request.title) catch return null;
    defer allocator.free(title_w);

    // BIF_NEWDIALOGSTYLE needs an apartment-threaded COM context. Initialize it
    // here; tolerate "already initialized" (S_FALSE) and a pre-existing
    // different mode (RPC_E_CHANGED_MODE) by only uninitializing when we
    // actually acquired a reference.
    const hr = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    const we_initialized = (hr == 0) or (hr == 1); // S_OK or S_FALSE
    defer if (we_initialized) CoUninitialize();

    var display_buf: [windows.MAX_PATH]windows.WCHAR = undefined;
    var bi: BROWSEINFOW = .{
        .hwndOwner = ownerHwnd(request.owner),
        .pszDisplayName = &display_buf,
        .lpszTitle = title_w.ptr,
        .ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE | BIF_EDITBOX,
    };

    const pidl = SHBrowseForFolderW(&bi) orelse return null;
    defer CoTaskMemFree(pidl);

    var path_buf: [windows.MAX_PATH]windows.WCHAR = undefined;
    if (SHGetPathFromIDListW(pidl, &path_buf) == 0) return null;
    return pathFromWindowsBuffer(allocator, path_buf[0..]);
}
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `zig build test-full 2>&1 | tail -30`
Expected: the signature test passes and the whole suite compiles (default target windows-gnu builds `file_dialog_windows.zig`).

- [ ] **Step 9: Verify the macOS backend compiles for an Apple target**

Run: `zig build test-full -Dtarget=aarch64-macos 2>&1 | tail -30`
Expected: compiles past the dialog backends. If the cross-SDK is unavailable on this host and it fails for an unrelated SDK/linker reason (not in `file_dialog_macos.zig`/`services_macos_bridge.m`), note it and rely on the macOS CI build. Do not let an SDK-availability failure block the task.

- [ ] **Step 10: Commit**

```bash
git add src/platform/file_dialog.zig src/platform/file_dialog_windows.zig src/platform/file_dialog_macos.zig src/platform/services_macos_bridge.m src/platform/file_dialog_linux.zig src/platform/file_dialog_unsupported.zig
git commit -m "feat(file-dialog): add cross-platform pickFolder"
```

---

## Task 5: Wire `Shift+U` to folder upload

**Files:**
- Modify: `src/input.zig` (`0x55` handler ~2492-2500, helpers near `openFileDialogAndUpload` ~2550-2565)

- [ ] **Step 1: Replace the `0x55` ('U') key handler**

In `src/input.zig`, replace:

```zig
        0x55 => { // 'U' key = upload local file to remote
            if (!ev.ctrl and !ev.alt and !ev.shift and !ev.super) {
                if (file_explorer.g_mode == .remote) {
                    openFileDialogAndUpload();
                    return true;
                }
            }
            return false;
        },
```

with:

```zig
        0x55 => { // 'U' = upload file; Shift+U = upload folder
            if (file_explorer.g_mode == .remote and !ev.ctrl and !ev.alt and !ev.super) {
                if (ev.shift) {
                    openFolderDialogAndUpload();
                } else {
                    openFileDialogAndUpload();
                }
                return true;
            }
            return false;
        },
```

- [ ] **Step 2: Add `openFolderDialogAndUpload` next to `openFileDialogAndUpload`**

In `src/input.zig`, add immediately after the `openFileDialogAndUpload` function (after line ~2565):

```zig
fn openFolderDialogAndUpload() void {
    const allocator = AppWindow.g_allocator orelse return;
    const filters = [_]platform_file_dialog.Filter{.{ .name = "All Files", .pattern = "*.*" }};
    const owner: platform_file_dialog.Owner = if (AppWindow.currentNativeHandleBits()) |handle_bits|
        platform_file_dialog.windowOwner(handle_bits)
    else
        .{};
    const path = platform_file_dialog.pickFolder(allocator, .{
        .owner = owner,
        .title = "Upload folder to remote",
        .filters = &filters,
    }) orelse return;
    defer allocator.free(path);

    file_explorer.uploadFolder(path);
}
```

- [ ] **Step 3: Verify it compiles (debug build)**

Run: `zig build 2>&1 | tail -20`
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add src/input.zig
git commit -m "feat(input): Shift+U uploads a folder to the remote"
```

---

## Task 6: Final verification

- [ ] **Step 1: Run the fast suite**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (all fast tests, including the new scp `-r`, download-fn-selection, and cancel-cleanup tests).

- [ ] **Step 2: Run the full suite (default windows-gnu target)**

Run: `zig build test-full 2>&1 | tail -30`
Expected: PASS (includes the `pickFolder` signature test; cross-compiles the Windows `SHBrowseForFolderW` backend).

- [ ] **Step 3: Debug build**

Run: `zig build 2>&1 | tail -20`
Expected: builds cleanly.

- [ ] **Step 4: Manual GUI verification (record results; do not block on environments you cannot run)**

In a real GUI build, with an SSH remote open in the file explorer:
- Select a remote **directory**, press **Ctrl/Cmd+S** → it downloads recursively into Downloads; toast shows progress; the folder appears with its contents.
- Press **Shift+U** → folder picker opens; choose a local folder → it uploads recursively into the current remote dir; the remote listing refreshes to show it.
- Start a large folder **download**, click the transfer toast → confirm → it cancels and the partial `Downloads/<name>` folder is removed.
- Existing single-**file** download (Ctrl/Cmd+S on a file) and upload (**U**) still work unchanged.

- [ ] **Step 5: Final commit (if any verification fixes were needed)**

```bash
git add -A
git commit -m "test: verify directory download/upload + cancel"
```

---

## Self-Review notes (for the implementer)

- **Spec coverage:** scp `-r` (Task 1) · directory download (Task 2) · folder upload + `Shift+U` (Tasks 2, 5) · folder picker on all 4 backends (Task 4) · cancel + partial cleanup (Task 3) · folder progress = graceful "calculating…" with no code change (covered by inaction; noted in spec). Toast wording reuses existing generic verbs (no change needed).
- **Type consistency:** `transferDirWithControl`/`transferWithControl` share the `TransferFn` signature `(Allocator, *const SshConnection, []const u8, []const u8, *TransferControl) TransferResult`. `pickDownloadTransferFn(bool) TransferFn`. `pickFolder(Allocator, OpenRequest) ?[]u8` matches `openFile` across all backends.
- **Uploads remain non-cancelable** (out of scope; `cancelActiveTransfer` keeps its `kind != .download` guard). Folder downloads are cancelable through the unchanged job system.
