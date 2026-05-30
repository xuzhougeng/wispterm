# WispTerm OSC 9/777 Desktop Notifications — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When WispTerm receives an OSC 9 / OSC 777 desktop-notification sequence, show a native macOS toast (focus-aware, rate-limited, deduped) or fall back to the existing title-bar bell indicator on other platforms / when notification authorization is unavailable.

**Architecture:** All decision logic lives in a new pure module `src/notification.zig` (bounded queue, content hashing, dedup/rate-limit, focus/platform/auth routing) so it is unit-testable natively on Linux. WispTerm's existing `VtHandler` in `src/Surface.zig` intercepts the already-parsed `show_desktop_notification` action (mirroring its `.bell` interception) and enqueues a copied title/body. The existing per-frame bell drain in `src/AppWindow.zig` is extended to drain the notification queue, apply the pure decision functions, and either call the platform notification facade (macOS toast via UNUserNotificationCenter) or set the bell indicator. macOS work goes through the existing `src/platform/notifications*.zig` backend-dispatch abstraction and the `services_macos_bridge.m` Objective-C bridge.

**Tech Stack:** Zig (terminal core via pinned `ghostty` dependency), Objective-C bridge (`UserNotifications.framework`), existing WispTerm renderer/titlebar + platform abstraction.

**Spec:** `docs/superpowers/specs/2026-05-30-wispterm-osc-notifications-design.md`

**Branch:** `feat/wispterm-osc-notifications` (already created; spec committed at `d273ed1`).

---

## File Structure

| File | Responsibility | Create/Modify |
|---|---|---|
| `src/notification.zig` | Pure logic: `Item`, bounded `Queue`, `ingest`, `contentHash`, `shouldDeliver`, `AuthStatus`, `Route`, `decideRoute` + their unit tests | **Create** |
| `src/test_fast.zig` | Register `notification.zig` so its tests run in the fast suite | Modify (`:42` area) |
| `src/config.zig` | Add `desktop-notifications: bool = true` field | Modify (`:284` area) |
| `src/platform/notifications.zig` | Facade: add `showDesktopNotification`, `notificationAuthStatus`, `requestNotificationAuth` | Modify |
| `src/platform/notifications_unsupported.zig` | No-op / `.unavailable` impls | Modify |
| `src/platform/notifications_windows.zig` | No-op / `.unavailable` impls | Modify |
| `src/platform/notifications_macos.zig` | `extern` decls bridging to the `.m` symbols | Modify |
| `src/platform/services_macos_bridge.m` | UNUserNotificationCenter toast + delegate + auth cache | Modify |
| `build.zig` | Link `UserNotifications` framework; update framework-count test | Modify (`:31`, `:291-303`) |
| `src/Surface.zig` | `notif_queue` + `last_notif_*` fields; `.show_desktop_notification` branch in `VtHandler.vt` | Modify (`:134`, `:228` area) |
| `src/AppWindow.zig` | Drain `notif_queue` after the bell drain; routing + lazy auth + toast/badge | Modify (`:1353`, `:1700`, `:3452`, `:3961` areas) |
| `packaging/macos/` | Verify/add `CFBundleIdentifier` in `Info.plist` | Verify/Modify |

---

## Task 1: Pure notification module (`src/notification.zig`)

**Files:**
- Create: `src/notification.zig`
- Modify: `src/test_fast.zig` (register import)

This module has zero WispTerm dependencies (only `std`), so it compiles and tests natively on Linux.

**Authoritative behavior (resolves a minor ambiguity in the spec's dedup/rate-limit table):**
- `shouldDeliver` drops anything within `window_ms = 1000` of the last *delivered* notification (this is the ≤1/sec rate limit). Identical content within the window is also dropped (dedup). Different content within the window is **also** dropped (rate limit dominates). After 1000 ms, delivery is allowed. This matches Ghostty's "1 per second" and the user's decision #5 (both rate-limit and dedup).
- `decideRoute` returns `.toast` only on macOS + authorized + not (window-focused AND active-surface). Otherwise `.badge`. `.none` only when notifications are disabled. (The toast path ALSO sets the bell badge — that is handled by the caller in Task 6, not here.)

- [ ] **Step 1: Write the failing tests**

Create `src/notification.zig` with the test block at the bottom (implementation added in Step 3):

```zig
const std = @import("std");

// ---- (implementation goes here in Step 3) ----

test "makeItem copies and truncates title/body" {
    const long_title = "T" ** 300;
    const item = makeItem(long_title, "hello");
    try std.testing.expectEqual(@as(usize, max_title), item.title().len);
    try std.testing.expectEqualStrings("hello", item.body());

    const empty = makeItem("", "");
    try std.testing.expectEqual(@as(usize, 0), empty.title().len);
    try std.testing.expectEqual(@as(usize, 0), empty.body().len);
}

test "Queue is FIFO and drops oldest when full" {
    var q: Queue = .{};
    var i: usize = 0;
    while (i < queue_cap + 2) : (i += 1) {
        var buf: [8]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        ingest(&q, t, "b");
    }
    // First two ("0","1") were dropped; oldest remaining is "2".
    const first = q.pop().?;
    try std.testing.expectEqualStrings("2", first.title());
    var count: usize = 1;
    while (q.pop() != null) count += 1;
    try std.testing.expectEqual(queue_cap, count);
    try std.testing.expect(q.pop() == null);
}

test "contentHash distinguishes title vs body boundary" {
    try std.testing.expect(contentHash("ab", "c") != contentHash("a", "bc"));
    try std.testing.expectEqual(contentHash("x", "y"), contentHash("x", "y"));
}

test "shouldDeliver: rate-limit and dedup within window, allow after" {
    const h1: u64 = 111;
    const h2: u64 = 222;
    // First ever (last_ms = 0 sentinel, far in the past) -> allowed
    try std.testing.expect(shouldDeliver(10_000, h1, 0, 0));
    // Same hash within 1s -> dropped (dedup)
    try std.testing.expect(!shouldDeliver(10_500, h1, 10_000, h1));
    // Different hash within 1s -> dropped (rate limit)
    try std.testing.expect(!shouldDeliver(10_500, h2, 10_000, h1));
    // After 1s -> allowed
    try std.testing.expect(shouldDeliver(11_000, h2, 10_000, h1));
}

test "decideRoute matrix" {
    const A = AuthStatus.authorized;
    // disabled -> none regardless of anything
    try std.testing.expectEqual(Route.none, decideRoute(false, true, A, false, false));
    // macOS authorized, unfocused -> toast
    try std.testing.expectEqual(Route.toast, decideRoute(true, true, A, false, false));
    // macOS authorized, focused but background surface -> toast
    try std.testing.expectEqual(Route.toast, decideRoute(true, true, A, true, false));
    // macOS authorized, focused AND active surface -> suppressed -> badge
    try std.testing.expectEqual(Route.badge, decideRoute(true, true, A, true, true));
    // macOS denied -> badge
    try std.testing.expectEqual(Route.badge, decideRoute(true, true, .denied, false, false));
    // macOS not-yet-authorized -> badge
    try std.testing.expectEqual(Route.badge, decideRoute(true, true, .unavailable, false, false));
    // non-macOS -> badge even if "authorized"
    try std.testing.expectEqual(Route.badge, decideRoute(true, false, A, false, false));
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | tail -20`
Expected: compile error — `max_title`, `makeItem`, `Queue`, `ingest`, `queue_cap`, `contentHash`, `shouldDeliver`, `AuthStatus`, `Route`, `decideRoute` are undefined. (Note: the test won't run until registered in Step 4, but the file's own `zig test` would fail to compile; the registration in Step 4 is what surfaces it in the suite. If you want an immediate local check before registration, run `zig test src/notification.zig`.)

- [ ] **Step 3: Write the implementation**

Insert above the test block in `src/notification.zig` (replace the `// ---- (implementation goes here ...) ----` line):

```zig
/// Max bytes retained for a notification title / body. Longer input is truncated.
pub const max_title: usize = 256;
pub const max_body: usize = 1024;
/// Bounded queue capacity. When full, the oldest item is dropped.
pub const queue_cap: usize = 8;
/// Rate-limit / dedup window: drop notifications arriving within this many ms
/// of the last delivered one.
pub const window_ms: i64 = 1000;

/// One queued notification, owning fixed-size copies of title/body so the
/// transient slices handed to us by the VT parser can be safely retained.
pub const Item = struct {
    title_buf: [max_title]u8 = undefined,
    title_len: usize = 0,
    body_buf: [max_body]u8 = undefined,
    body_len: usize = 0,

    pub fn title(self: *const Item) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    pub fn body(self: *const Item) []const u8 {
        return self.body_buf[0..self.body_len];
    }
};

/// Copy + truncate raw (transient) title/body slices into an owned Item.
pub fn makeItem(title_in: []const u8, body_in: []const u8) Item {
    var item: Item = .{};
    item.title_len = @min(title_in.len, max_title);
    @memcpy(item.title_buf[0..item.title_len], title_in[0..item.title_len]);
    item.body_len = @min(body_in.len, max_body);
    @memcpy(item.body_buf[0..item.body_len], body_in[0..item.body_len]);
    return item;
}

/// Mutex-protected bounded FIFO. Pushed from the IO reader thread, popped from
/// the main thread (same producer/consumer split as `Surface.bell_pending`).
pub const Queue = struct {
    mutex: std.Thread.Mutex = .{},
    items: [queue_cap]Item = undefined,
    head: usize = 0,
    len: usize = 0,

    /// Enqueue; if full, drop the oldest item to make room (newest wins).
    pub fn push(self: *Queue, item: Item) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == queue_cap) {
            self.head = (self.head + 1) % queue_cap; // drop oldest
            self.len -= 1;
        }
        const tail = (self.head + self.len) % queue_cap;
        self.items[tail] = item;
        self.len += 1;
    }

    /// Dequeue the oldest item, or null if empty.
    pub fn pop(self: *Queue) ?Item {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == 0) return null;
        const item = self.items[self.head];
        self.head = (self.head + 1) % queue_cap;
        self.len -= 1;
        return item;
    }
};

/// Convenience: copy/truncate and enqueue in one call (used by the VtHandler).
pub fn ingest(queue: *Queue, title_in: []const u8, body_in: []const u8) void {
    queue.push(makeItem(title_in, body_in));
}

/// Stable hash of (title, body) for dedup. The zero byte separates the two
/// fields so ("ab","c") and ("a","bc") hash differently.
pub fn contentHash(title_in: []const u8, body_in: []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(title_in);
    h.update(&[_]u8{0});
    h.update(body_in);
    return h.final();
}

/// True if this notification should be delivered now. Drops anything within
/// `window_ms` of the last delivered notification (rate limit), and identical
/// content within the window (dedup). `last_time_ms == 0` means "none yet".
pub fn shouldDeliver(now_ms: i64, h: u64, last_time_ms: i64, last_hash: u64) bool {
    if (last_time_ms != 0 and (now_ms - last_time_ms) < window_ms) {
        _ = h;
        _ = last_hash;
        return false;
    }
    return true;
}

/// Cached macOS authorization status (mirrors the bridge's int contract).
pub const AuthStatus = enum(u8) { unavailable = 0, denied = 1, authorized = 2 };

/// What to do with a deliverable notification.
pub const Route = enum { none, toast, badge };

/// Pure routing decision. `.toast` only on macOS + authorized + not looking
/// right at it; `.badge` everywhere else; `.none` only when disabled.
pub fn decideRoute(
    notif_enabled: bool,
    is_macos: bool,
    auth: AuthStatus,
    window_focused: bool,
    is_active_surface: bool,
) Route {
    if (!notif_enabled) return .none;
    const suppress = window_focused and is_active_surface;
    if (is_macos and auth == .authorized and !suppress) return .toast;
    return .badge;
}
```

- [ ] **Step 4: Register the module in the fast test suite**

In `src/test_fast.zig`, after line `_ = @import("render_diagnostics.zig");` (currently `:42`), add:

```zig
    _ = @import("notification.zig");
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: build succeeds, suite passes (the 5 new `notification.zig` tests run green; overall count increases from the ~673 baseline, 0 failed).

- [ ] **Step 6: Commit**

```bash
git add src/notification.zig src/test_fast.zig
git commit -m "feat(notification): pure queue + dedup/rate-limit + routing module

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Config toggle `desktop-notifications`

**Files:**
- Modify: `src/config.zig` (`:284` area)
- Modify: `src/AppWindow.zig` (global decl `:1369` area; apply `:1708` area)

- [ ] **Step 1: Add the config field**

In `src/config.zig`, immediately after the `@"ai-agent-enabled"` field (currently `:284`), add:

```zig
/// Show native desktop notifications for OSC 9 / OSC 777 sequences (macOS).
/// When false, such sequences are ignored entirely (no toast, no bell badge).
/// Does not affect the plain terminal bell.
@"desktop-notifications": bool = true,
```

- [ ] **Step 2: Add the runtime global**

In `src/AppWindow.zig`, after `pub threadlocal var g_ssh_legacy_algorithms: bool = false;` (currently `:1369`), add:

```zig
pub threadlocal var g_desktop_notifications: bool = true;
```

- [ ] **Step 3: Wire the global in config-apply**

In `src/AppWindow.zig`, after `g_ssh_legacy_algorithms = cfg.@"ssh-legacy-algorithms";` (currently `:1711`), add:

```zig
    g_desktop_notifications = cfg.@"desktop-notifications";
```

- [ ] **Step 4: Verify it builds (config has parser/round-trip tests)**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS. `config.zig` is already registered in the fast suite (`test_fast.zig:29`); its existing parse/serialize tests cover the new field's default.

- [ ] **Step 5: Commit**

```bash
git add src/config.zig src/AppWindow.zig
git commit -m "feat(config): add desktop-notifications toggle (default on)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Platform notification facade + non-macOS backends

**Files:**
- Modify: `src/platform/notifications.zig`
- Modify: `src/platform/notifications_unsupported.zig`
- Modify: `src/platform/notifications_windows.zig`

This keeps Linux and Windows builds green. The macOS backend + bridge land in Task 4.

- [ ] **Step 1: Extend the facade**

In `src/platform/notifications.zig`, add a status enum and three pass-through functions. Insert the enum after the `Backend` enum (after its closing `};`, currently `:26`):

```zig
/// Cached desktop-notification authorization status. Mirrors the macOS
/// bridge contract: 0 = unavailable/not-determined, 1 = denied, 2 = authorized.
pub const NotifAuthStatus = enum(u8) { unavailable = 0, denied = 1, authorized = 2 };
```

Then add these three functions after the existing `requestAttention` function (after its closing `}`, currently `:51`):

```zig
/// Post a native desktop notification (macOS toast). No-op where unsupported.
pub fn showDesktopNotification(title: [:0]const u8, body: [:0]const u8) void {
    impl.showDesktopNotification(title, body);
}

/// Current cached authorization status (synchronous, cheap).
pub fn notificationAuthStatus() NotifAuthStatus {
    return @enumFromInt(impl.notificationAuthStatus());
}

/// Ask the OS for notification permission (shows the system prompt once).
/// Safe to call repeatedly; the OS only prompts on the first undetermined call.
pub fn requestNotificationAuth() void {
    impl.requestNotificationAuth();
}
```

- [ ] **Step 2: Implement the unsupported backend**

In `src/platform/notifications_unsupported.zig`, after the `requestAttention` function, add:

```zig
pub fn showDesktopNotification(title: [:0]const u8, body: [:0]const u8) void {
    _ = title;
    _ = body;
}

pub fn notificationAuthStatus() u8 {
    return 0; // unavailable
}

pub fn requestNotificationAuth() void {}
```

- [ ] **Step 3: Implement the windows backend (badge-only per spec)**

In `src/platform/notifications_windows.zig`, after the `requestAttention` function, add:

```zig
pub fn showDesktopNotification(title: [:0]const u8, body: [:0]const u8) void {
    // Windows uses the title-bar bell badge fallback (no native toast in v1).
    _ = title;
    _ = body;
}

pub fn notificationAuthStatus() u8 {
    return 0; // unavailable -> caller falls back to badge
}

pub fn requestNotificationAuth() void {}
```

- [ ] **Step 4: Update the facade shape test**

In `src/platform/notifications.zig`, extend the existing `test "notifications exposes bell and attention API shape"` by appending before its closing `}`:

```zig
    const show_info = @typeInfo(@TypeOf(showDesktopNotification)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), show_info.params.len);
    try std.testing.expect(show_info.return_type.? == void);

    const status_info = @typeInfo(@TypeOf(notificationAuthStatus)).@"fn";
    try std.testing.expectEqual(@as(usize, 0), status_info.params.len);
    try std.testing.expectEqual(NotifAuthStatus, status_info.return_type.?);
```

- [ ] **Step 5: Verify it builds and the facade test passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (Linux selects the `unsupported` backend; the shape test exercises the new functions).

- [ ] **Step 6: Commit**

```bash
git add src/platform/notifications.zig src/platform/notifications_unsupported.zig src/platform/notifications_windows.zig
git commit -m "feat(platform): notification facade (showDesktopNotification/auth) + non-macOS no-ops

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: macOS bridge (UNUserNotificationCenter) + build wiring

**Files:**
- Modify: `src/platform/notifications_macos.zig`
- Modify: `src/platform/services_macos_bridge.m`
- Modify: `build.zig` (`:31` frameworks; `:291-303` test)

> This task can only be **compiled and verified on macOS**. On Linux/Windows the macOS backend is not selected, so the build stays green; do the Step 4 build check on a macOS machine/CI.

- [ ] **Step 1: Add extern declarations in the macOS backend**

In `src/platform/notifications_macos.zig`, add the extern decls after the existing two `extern fn` lines, and the three pub functions after `requestAttention`:

```zig
extern fn wispterm_macos_notif_show(title: [*:0]const u8, body: [*:0]const u8) void;
extern fn wispterm_macos_notif_auth_status() c_int;
extern fn wispterm_macos_notif_request_auth() void;

pub fn showDesktopNotification(title: [:0]const u8, body: [:0]const u8) void {
    wispterm_macos_notif_show(title.ptr, body.ptr);
}

pub fn notificationAuthStatus() u8 {
    const s = wispterm_macos_notif_auth_status();
    return if (s < 0 or s > 2) 0 else @intCast(s);
}

pub fn requestNotificationAuth() void {
    wispterm_macos_notif_request_auth();
}
```

- [ ] **Step 2: Implement the Objective-C bridge**

Append to `src/platform/services_macos_bridge.m` (after the existing notification functions):

```objc
#import <UserNotifications/UserNotifications.h>

// Cached authorization status: 0 = unavailable/not-determined, 1 = denied, 2 = authorized.
static int g_wispterm_notif_auth = 0;

// Delegate so notifications also present while WispTerm is the foreground app
// (needed for the "focused window, background tab" case).
@interface WisptermNotifDelegate : NSObject <UNUserNotificationCenterDelegate>
@end
@implementation WisptermNotifDelegate
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}
@end

static WisptermNotifDelegate *g_wispterm_notif_delegate = nil;

static UNUserNotificationCenter *wispterm_notif_center(void) {
    // UNUserNotificationCenter requires a bundle identifier; un-bundled dev
    // runs have none -> report unavailable and skip.
    if ([[NSBundle mainBundle] bundleIdentifier] == nil) return nil;
    return [UNUserNotificationCenter currentNotificationCenter];
}

void wispterm_macos_notif_request_auth(void) {
    UNUserNotificationCenter *center = wispterm_notif_center();
    if (center == nil) { g_wispterm_notif_auth = 0; return; }
    if (g_wispterm_notif_delegate == nil) {
        g_wispterm_notif_delegate = [[WisptermNotifDelegate alloc] init];
    }
    center.delegate = g_wispterm_notif_delegate;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError *_Nullable error) {
        (void)error;
        g_wispterm_notif_auth = granted ? 2 : 1;
    }];
}

int wispterm_macos_notif_auth_status(void) {
    return g_wispterm_notif_auth;
}

void wispterm_macos_notif_show(const char *title, const char *body) {
    UNUserNotificationCenter *center = wispterm_notif_center();
    if (center == nil) return;
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = [NSString stringWithUTF8String:(title ? title : "")];
    content.body = [NSString stringWithUTF8String:(body ? body : "")];
    content.sound = [UNNotificationSound defaultSound];
    UNNotificationRequest *req =
        [UNNotificationRequest requestWithIdentifier:[[NSUUID UUID] UUIDString]
                                             content:content
                                             trigger:nil];
    [center addNotificationRequest:req withCompletionHandler:nil];
}
```

- [ ] **Step 3: Link the UserNotifications framework**

In `build.zig`, add `"UserNotifications"` to the `macos_app_frameworks` array (currently starts `:31`). After the `"Foundation",` entry add:

```zig
    "UserNotifications",
```

- [ ] **Step 4: Update the framework-count test**

In `build.zig`, the test `"macOS platform advertises required app frameworks"` (currently `:291-303`) asserts exactly 8 frameworks. Change the count and add a presence check:

```zig
    try std.testing.expectEqual(@as(usize, 9), frameworks.len);
```

and before the final `expectEqual(... .windows ... 0 ...)` line add:

```zig
    try expectContainsString(frameworks, "UserNotifications");
```

- [ ] **Step 5: Verify (macOS build + framework test)**

On macOS, run: `zig build test 2>&1 | tail -20` and `zig build 2>&1 | tail -20`
Expected: framework-count test PASS (now 9); macOS build links `UserNotifications` and the `.m` symbols resolve. On Linux, run `zig build test` to confirm the framework-count test (which is host-independent — it calls `appFrameworksFor(.macos)`) passes there too.

- [ ] **Step 6: Commit**

```bash
git add src/platform/notifications_macos.zig src/platform/services_macos_bridge.m build.zig
git commit -m "feat(macos): UNUserNotificationCenter toast bridge + UserNotifications framework

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Surface — intercept the action, enqueue

**Files:**
- Modify: `src/Surface.zig` (import; `VtHandler.vt` `:134`; fields `:228` area)

- [ ] **Step 1: Import the notification module**

In `src/Surface.zig`, after `const sync_output = @import("sync_output.zig");` (currently `:23`), add:

```zig
const notification = @import("notification.zig");
```

- [ ] **Step 2: Add per-surface notification state**

In `src/Surface.zig`, in the "Bell state" section, after the `last_bell_time: i64 = 0,` field (currently `:228`), add:

```zig

// ============================================================================
// Desktop notification state (OSC 9 / OSC 777)
// ============================================================================

/// Notifications pushed by the IO reader thread, drained on the main thread.
notif_queue: notification.Queue = .{},
/// Last delivered notification's content hash + time, for dedup / rate limit.
last_notif_hash: u64 = 0,
last_notif_time: i64 = 0,
```

- [ ] **Step 3: Intercept the action in `VtHandler.vt`**

In `src/Surface.zig`, in `VtHandler.vt`, immediately after the existing bell block (the `if (action == .bell) { ... return; }` ending at `:137`), add:

```zig
        if (action == .show_desktop_notification) {
            notification.ingest(
                &self.surface.notif_queue,
                std.mem.sliceTo(value.title, 0),
                std.mem.sliceTo(value.body, 0),
            );
            return;
        }
```

> Note: `value.title` / `value.body` are `[:0]const u8` (sentinel-terminated) per ghostty's `ShowDesktopNotification`. `notification.ingest` copies them immediately, so the transient slices are not retained.

- [ ] **Step 4: Verify it builds**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS. (The `.show_desktop_notification` tag and `value.title`/`value.body` come from the pinned ghostty `StreamAction`; the full app graph compiles. `notif_queue` default-initializes.)

- [ ] **Step 5: Commit**

```bash
git add src/Surface.zig
git commit -m "feat(surface): intercept show_desktop_notification, enqueue copied title/body

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: AppWindow — drain queue, route, toast/badge

**Files:**
- Modify: `src/AppWindow.zig` (imports; drain loop `:3961`; new `handleNotification` near `:3464`; lazy-auth global `:1369` area)

- [ ] **Step 1: Import the notification + platform modules (if not already imported)**

In `src/AppWindow.zig`, `platform_notifications` is imported at `:30`. Add the notification module import and `builtin` (NOT currently imported — confirmed) right after it:

```zig
const notification = @import("notification.zig");
const builtin = @import("builtin");
```

Also add a one-shot lazy-auth guard global. After `pub threadlocal var g_desktop_notifications: bool = true;` (added in Task 2, `:1370` area), add:

```zig
threadlocal var g_notif_auth_requested: bool = false;
```

- [ ] **Step 2: Add `handleNotification` next to `handleBell`**

In `src/AppWindow.zig`, immediately after `handleBell` (after its closing `}` at `:3464`), add:

```zig
/// Drain and handle queued desktop notifications for one surface.
/// `is_active_surface` is true only when the window is focused AND this is the
/// focused surface of the active tab (so we suppress the toast you'd see anyway).
fn handleNotification(surface: *Surface, is_active_surface: bool) void {
    if (!g_desktop_notifications) {
        // Drain and discard so the queue can't grow while disabled.
        while (surface.notif_queue.pop() != null) {}
        return;
    }

    const is_macos = builtin.os.tag == .macos;

    while (surface.notif_queue.pop()) |item| {
        const now = std.time.milliTimestamp();
        const h = notification.contentHash(item.title(), item.body());
        if (!notification.shouldDeliver(now, h, surface.last_notif_time, surface.last_notif_hash)) {
            continue;
        }

        // Lazy authorization request (macOS): first time we'd want a toast,
        // ask once. This delivery falls back to badge until the user answers.
        if (is_macos and !g_notif_auth_requested) {
            platform_notifications.requestNotificationAuth();
            g_notif_auth_requested = true;
        }

        const auth: notification.AuthStatus = @enumFromInt(
            @intFromEnum(platform_notifications.notificationAuthStatus()),
        );
        const route = notification.decideRoute(
            true, // g_desktop_notifications already checked above
            is_macos,
            auth,
            window_focused,
            is_active_surface,
        );

        switch (route) {
            .none => {},
            .toast => {
                var title_z: [notification.max_title + 1]u8 = undefined;
                var body_z: [notification.max_body + 1]u8 = undefined;
                const t = item.title();
                const b = item.body();
                @memcpy(title_z[0..t.len], t);
                title_z[t.len] = 0;
                @memcpy(body_z[0..b.len], b);
                body_z[b.len] = 0;
                platform_notifications.showDesktopNotification(
                    title_z[0..t.len :0],
                    body_z[0..b.len :0],
                );
                surface.bell_indicator = true; // also badge the tab
                surface.bell_indicator_time = now;
            },
            .badge => {
                surface.bell_indicator = true;
                surface.bell_indicator_time = now;
            },
        }

        surface.last_notif_hash = h;
        surface.last_notif_time = now;
    }
}
```

> `builtin` and `notification` are added as imports in Step 1 above.

- [ ] **Step 3: Call the drain in the per-frame loop**

In `src/AppWindow.zig`, in the bell-drain loop (currently `:3962-3972`), add the notification drain inside the same surface iteration. Replace:

```zig
                    if (entry.surface.bell_pending.swap(false, .acquire)) {
                        handleBell(entry.surface, win, ti == tab.g_active_tab);
                    }
```

with:

```zig
                    if (entry.surface.bell_pending.swap(false, .acquire)) {
                        handleBell(entry.surface, win, ti == tab.g_active_tab);
                    }
                    {
                        const is_active_surface = (ti == tab.g_active_tab) and
                            (if (tb.focusedSurface()) |fs| fs == entry.surface else false);
                        handleNotification(entry.surface, is_active_surface);
                    }
```

> `tb.focusedSurface()` exists (`src/appwindow/tab.zig:56`). `window_focused` is the existing main-thread global (`:1324`), refreshed each frame at `:3938-3940`.

- [ ] **Step 4: Verify it builds**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS. On Linux, `is_macos` is false → route is always `.badge`; `showDesktopNotification`/`requestNotificationAuth` resolve to the unsupported no-ops. Pure routing/dedup logic is already covered by Task 1's tests.

- [ ] **Step 5: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(appwindow): drain notification queue -> macOS toast or bell badge (focus-aware)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Verify `Info.plist` has `CFBundleIdentifier`

**Files:**
- Verify/Modify: `packaging/macos/` (`Info.plist` or its generator)

`UNUserNotificationCenter` returns no center (→ `unavailable` → badge) unless the running `.app` has a bundle identifier. Confirm one is set.

- [ ] **Step 1: Locate the Info.plist / generator**

Run: `grep -rni 'CFBundleIdentifier\|Info.plist\|bundleIdentifier' packaging/macos build.zig`
Expected: find where `Info.plist` is produced and whether `CFBundleIdentifier` is present.

- [ ] **Step 2: Ensure `CFBundleIdentifier` exists**

If absent, add to the `Info.plist` (or its template/generator) a stable identifier, e.g.:

```xml
<key>CFBundleIdentifier</key>
<string>app.cc-remote.phantty</string>
```

(Match the project's existing bundle/domain convention — check `packaging/macos/README.md` and any signing identity for the right reverse-DNS id; do not invent a new domain if one is already used elsewhere.)

- [ ] **Step 3: Verify (macOS)**

On macOS, after `bash packaging/macos/package.sh` (or the documented build), run:
`/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' zig-out/bin/WispTerm.app/Contents/Info.plist`
Expected: prints the identifier (non-empty).

- [ ] **Step 4: Commit (only if a change was needed)**

```bash
git add packaging/macos
git commit -m "build(macos): ensure CFBundleIdentifier is set (required for UNUserNotificationCenter)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Regression + macOS manual verification

**Files:** none (verification only)

- [ ] **Step 1: Full native regression**

Run: `zig build test 2>&1 | tail -5` then `zig build test-full 2>&1 | tail -5`
Expected: both exit 0, 0 failed (baseline ~673/677 + the new `notification.zig` tests).

- [ ] **Step 2: macOS manual checklist** (on a signed `.app` build)

Trigger a notification with: `printf '\033]777;notify;WispTerm;hello from claude\007'` (OSC 777) and `printf '\033]9;simple body\007'` (OSC 9).

- [ ] First notification → system authorization prompt appears → Allow → toast shows.
- [ ] Window unfocused → toast shows.
- [ ] Window focused, on the originating tab → NO toast, brief bell indicator.
- [ ] Window focused, originating tab in background → toast shows (foreground delegate) + bell on that tab.
- [ ] Deny authorization (`tccutil reset Notifications <bundle-id>`, relaunch, deny) → only bell badge, no toast.
- [ ] Emit the same OSC twice quickly → only one notification; emit 5 quickly → ≤1/sec.
- [ ] Set `desktop-notifications = false` in config → nothing (no toast, no bell badge from OSC; plain `\a` bell still works).

- [ ] **Step 3: Non-macOS sanity** (Linux/Windows build)

Emit the OSC sequence → only the title-bar bell badge appears (no crash, no toast).

- [ ] **Step 4: Finalize**

The branch `feat/wispterm-osc-notifications` now contains the spec + implementation. Use `superpowers:finishing-a-development-branch` to decide merge/PR.

---

## Self-Review

**Spec coverage:**
- §3.1 macOS-only native, others badge → Task 4 (macOS), Task 3 (windows/unsupported no-op), Task 6 routing. ✅
- §3.2 UNUserNotificationCenter + denied→badge → Task 4 bridge + Task 6 `decideRoute`. ✅
- §3.3 title-bar bell badge fallback, no body text v1 → Task 6 sets `bell_indicator` only. ✅
- §3.4 focus suppression → Task 6 `is_active_surface` + `decideRoute`. ✅
- §3.5 rate-limit + dedup → Task 1 `shouldDeliver`. ✅
- §3.6 single `desktop-notifications` toggle → Task 2 + Task 6 gate. ✅
- §4.1 pure module → Task 1. ✅  §4.3 three bridge fns + delegate + auth cache → Task 4. ✅  §4.5 framework + test → Task 4. ✅
- §6 tests (pure unit + regression) → Task 1, Task 8. ✅
- §7 CFBundleIdentifier → Task 7. ✅

**Resolved ambiguity:** the spec's dedup/rate-limit table row "异 hash 过" (different hash passes) conflicts with the ≤1/sec rate limit. Authoritative behavior (Task 1): anything within 1000 ms of the last delivered notification is dropped (rate limit dominant; dedup is the same-content subset). Documented in Task 1.

**Spec deviation (integration test):** §6② proposed feeding OSC bytes through `VtStream` in `test-full`. To avoid a fragile heavy-Surface construction, the owned logic was extracted into `notification.ingest`/`makeItem` and unit-tested directly in the fast suite (Task 1); the ghostty-parse→VtHandler wiring is verified by the manual OSC `printf` checks in Task 8. Net coverage is equal or better with no brittle test.

**Type consistency:** `AuthStatus`/`NotifAuthStatus` both `enum(u8){unavailable=0,denied=1,authorized=2}`; bridge returns `c_int` clamped to `u8` in `notifications_macos.zig`; `Route{none,toast,badge}` used identically in Task 1 and Task 6; `decideRoute` signature `(bool,bool,AuthStatus,bool,bool)` matches its call site; `notif_queue`/`last_notif_hash`/`last_notif_time` field names consistent across Task 5 and Task 6.

**Placeholder scan:** no TBD/TODO; every code step has complete code and exact paths/anchors.
