#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct WispTermMacRect {
    int32_t left;
    int32_t top;
    int32_t right;
    int32_t bottom;
} WispTermMacRect;

typedef struct WispTermMacKeyEvent {
    uintptr_t key_code;
    bool ctrl;
    bool shift;
    bool alt;
    bool super;
} WispTermMacKeyEvent;

typedef struct WispTermMacCharEvent {
    uint32_t codepoint;
    bool ctrl;
    bool shift;
    bool alt;
    bool super;
} WispTermMacCharEvent;

typedef struct WispTermMacMouseButtonEvent {
    uint8_t button;
    uint8_t action;
    int32_t x;
    int32_t y;
    bool ctrl;
    bool shift;
    bool alt;
    bool super;
} WispTermMacMouseButtonEvent;

typedef struct WispTermMacMouseMoveEvent {
    int32_t x;
    int32_t y;
    bool ctrl;
    bool shift;
    bool alt;
    bool super;
} WispTermMacMouseMoveEvent;

typedef struct WispTermMacMouseWheelEvent {
    int16_t delta;
    int32_t xpos;
    int32_t ypos;
    bool ctrl;
    bool shift;
    bool alt;
} WispTermMacMouseWheelEvent;

typedef struct WispTermMacMessageEvent {
    uint32_t message;
    uintptr_t wparam;
    intptr_t lparam;
} WispTermMacMessageEvent;

typedef struct WispTermMacFileDropEvent {
    char path[4096];
    size_t path_len;
    int32_t x;
    int32_t y;
} WispTermMacFileDropEvent;

typedef struct WispTermMacWindowState WispTermMacWindowState;

@interface WispTermMacContentView : NSView <NSTextInputClient>
@property(nonatomic, assign) WispTermMacWindowState *state;
@end

@interface WispTermMacWindowDelegate : NSObject <NSWindowDelegate>
@property(nonatomic, assign) WispTermMacWindowState *state;
@end

struct WispTermMacWindowState {
    NSWindow *window;
    WispTermMacContentView *view;
    CAMetalLayer *layer;
    WispTermMacWindowDelegate *delegate;
    bool close_requested;
    int32_t ime_caret_x;
    int32_t ime_caret_y;
    int32_t ime_caret_height;
    char ime_preedit[1024];
    size_t ime_preedit_len;
    NSEventModifierFlags insert_text_modifier_flags;
    // Guards the key/char/mouse/file-drop rings below. For windows running on
    // a worker thread (every window past the first: Dock reopen / new-window),
    // AppKit dispatches input on the main thread while that window's worker
    // thread drains via pollEvents, so these rings are cross-thread too. One
    // shared lock suffices: the worker drains them sequentially and AppKit
    // dispatch on main is itself serialized, so there is no cross-queue
    // contention to gain from per-ring locks.
    os_unfair_lock input_lock;
    WispTermMacKeyEvent key_events[64];
    size_t key_head;
    size_t key_count;
    WispTermMacCharEvent char_events[64];
    size_t char_head;
    size_t char_count;
    WispTermMacMouseButtonEvent mouse_button_events[32];
    size_t mouse_button_head;
    size_t mouse_button_count;
    WispTermMacMouseMoveEvent mouse_move_events[64];
    size_t mouse_move_head;
    size_t mouse_move_count;
    WispTermMacMouseWheelEvent mouse_wheel_events[16];
    size_t mouse_wheel_head;
    size_t mouse_wheel_count;
    WispTermMacMessageEvent message_events[32];
    size_t message_head;
    size_t message_count;
    // The message ring is the one event queue written from arbitrary caller
    // threads (remote-client / poller threads via
    // wispterm_macos_window_post_message) and drained from the per-window
    // worker thread (windowThreadMain -> pollEvents -> drainMessageEvents).
    // Without a lock, the non-atomic head/count are a data race: concurrent
    // RMW loses/duplicates messages and torn reads hand the consumer garbage.
    os_unfair_lock message_lock;
    WispTermMacFileDropEvent file_drop_events[16];
    size_t file_drop_head;
    size_t file_drop_count;
};

// Defined with the other worker-wakeup primitives below; the close callbacks
// need it early so a worker window blocked in its idle wait notices
// close_requested promptly instead of sleeping out its full timeout.
static void wispterm_macos_worker_wakeup_signal(void);

@implementation WispTermMacWindowDelegate
- (BOOL)windowShouldClose:(id)sender {
    (void)sender;
    if (self.state != NULL) self.state->close_requested = true;
    wispterm_macos_worker_wakeup_signal();
    return YES;
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    if (self.state != NULL) self.state->close_requested = true;
    wispterm_macos_worker_wakeup_signal();
}
@end

// ---------------------------------------------------------------------------
// WispTermAppDelegate — owns app-level lifecycle so closing the last window
// does not terminate the process (Terminal.app / VS Code semantics). A reopen
// (Dock icon click when no visible window) is reported back to zig either via
// a registered C callback or via an atomic flag the zig idle loop polls.
// ---------------------------------------------------------------------------

typedef void (*wispterm_macos_reopen_callback)(void *userdata);

static wispterm_macos_reopen_callback g_reopen_callback = NULL;
static void *g_reopen_userdata = NULL;
// _Atomic(bool) is not supported by Clang's __atomic_* builtins on all targets,
// and stdatomic.h's atomic_bool is the portable way to express the same intent.
static atomic_bool g_reopen_pending = false;
static atomic_bool g_quit_pending = false;

@interface WispTermAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation WispTermAppDelegate
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    (void)sender;
    if (flag) return YES;
    atomic_store_explicit(&g_reopen_pending, true, memory_order_release);
    if (g_reopen_callback != NULL) g_reopen_callback(g_reopen_userdata);
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    atomic_store_explicit(&g_quit_pending, true, memory_order_release);
    // Ask every live window to close. Each AppWindow's main loop observes
    // the close_requested flag and exits cleanly; App.run() then drains the
    // quit flag and breaks out of its idle loop. We return Cancel so AppKit
    // doesn't tear NSApp down underneath us — zig owns the actual shutdown.
    //
    // Only message WispTerm's own terminal windows. -[NSApplication windows]
    // also returns AppKit's borderless helper windows (e.g. TUINSWindow from
    // the text-input / Touch Bar subsystem), which have no close button and so
    // are not closable. Sending -performClose: to a non-closable window makes
    // AppKit emit the system alert sound, so quitting (Dock menu Quit, ⌘Q, menu
    // Quit — all routed here) would ring a bell. Gating on our delegate class
    // skips those helper windows; our terminal windows all carry it (and are
    // closable), so the intended shutdown is unchanged.
    NSArray<NSWindow *> *snapshot = [[NSApp windows] copy];
    for (NSWindow *win in snapshot) {
        if (![win.delegate isKindOfClass:[WispTermMacWindowDelegate class]]) continue;
        [win performClose:nil];
    }
    [snapshot release];
    return NSTerminateCancel;
}
@end

static WispTermAppDelegate *g_app_delegate = nil;

static void wispterm_macos_app_ensure(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        if (g_app_delegate == nil) {
            g_app_delegate = [[WispTermAppDelegate alloc] init];
            [app setDelegate:g_app_delegate];
        }
        [app finishLaunching];
    }
}

void wispterm_macos_app_install_reopen_handler(wispterm_macos_reopen_callback cb, void *userdata) {
    g_reopen_callback = cb;
    g_reopen_userdata = userdata;
}

bool wispterm_macos_app_consume_reopen(void) {
    bool expected = true;
    return atomic_compare_exchange_strong_explicit(
        &g_reopen_pending, &expected, false,
        memory_order_acq_rel, memory_order_acquire);
}

bool wispterm_macos_app_consume_quit(void) {
    bool expected = true;
    return atomic_compare_exchange_strong_explicit(
        &g_quit_pending, &expected, false,
        memory_order_acq_rel, memory_order_acquire);
}

void wispterm_macos_app_request_quit(void) {
    atomic_store_explicit(&g_quit_pending, true, memory_order_release);
}

static NSString *wispterm_macos_title_from_utf16(const uint16_t *title) {
    if (title == NULL) return [@"WispTerm" retain];

    NSUInteger len = 0;
    while (title[len] != 0) len += 1;
    if (len == 0) return [@"WispTerm" retain];

    return [[NSString alloc] initWithCharacters:(const unichar *)title length:len];
}

static WispTermMacWindowState *wispterm_macos_state(void *handle) {
    return (WispTermMacWindowState *)handle;
}

static int32_t wispterm_macos_round_double(double value) {
    return (int32_t)(value + (value >= 0 ? 0.5 : -0.5));
}

// Marshal an AppKit operation onto the main thread. NSWindow modifiers
// (setFrame, setContentSize, makeKeyAndOrderFront, close, zoom, …) trip the
// "Must only be used from the main thread" assertion on macOS 14+ when called
// off-main. wispterm spawns per-window worker threads (windowThreadMain) that
// own the zig event/render loop, so every wrapper that mutates NSWindow state
// must run through here. Inline if we're already on main to avoid a
// dispatch_sync self-deadlock; otherwise wait for the main run loop to drain
// the block (the main thread idles in -nextEventMatchingMask: which keeps the
// main queue running).
static void wispterm_macos_run_on_main(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

static void wispterm_macos_rect_from_nsrect(NSRect rect, WispTermMacRect *out) {
    if (out == NULL) return;
    out->left = wispterm_macos_round_double(NSMinX(rect));
    out->top = wispterm_macos_round_double(NSMinY(rect));
    out->right = wispterm_macos_round_double(NSMaxX(rect));
    out->bottom = wispterm_macos_round_double(NSMaxY(rect));
}

static double wispterm_macos_scale(WispTermMacWindowState *state) {
    if (state == NULL || state->window == nil) return 1.0;
    double scale = [state->window backingScaleFactor];
    return scale > 0.0 ? scale : 1.0;
}

// ---------------------------------------------------------------------------
// Worker-thread idle wait. -[NSApp nextEventMatchingMask:] is main-thread-only
// (AppKit throws NSInternalInconsistencyException off-main), but every window
// past the first runs its loop on a worker thread and blocks in
// wispterm_macos_app_pump_events between frames. Off-main the pump waits on
// this condition instead; producers signal it: the main thread after pushing
// into any per-window event ring, the window-close delegate callbacks, and
// wispterm_macos_post_wakeup (already the cross-thread render wakeup).
//
// Each waiter remembers the last sequence it consumed, so a signal landing
// between a caller's "nothing to render" check and the wait itself is never
// lost — the next wait returns immediately. Same semantics the Windows
// backend gets from MsgWaitForMultipleObjectsEx(MWMO_INPUTAVAILABLE).
// ---------------------------------------------------------------------------

static pthread_mutex_t g_worker_wakeup_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_worker_wakeup_cond = PTHREAD_COND_INITIALIZER;
static uint64_t g_worker_wakeup_seq = 0;
static _Thread_local uint64_t t_worker_wakeup_seen = 0;

static void wispterm_macos_worker_wakeup_signal(void) {
    pthread_mutex_lock(&g_worker_wakeup_mutex);
    g_worker_wakeup_seq += 1;
    pthread_cond_broadcast(&g_worker_wakeup_cond);
    pthread_mutex_unlock(&g_worker_wakeup_mutex);
}

static void wispterm_macos_worker_wakeup_wait(double timeout_seconds) {
    pthread_mutex_lock(&g_worker_wakeup_mutex);
    if (t_worker_wakeup_seen == g_worker_wakeup_seq && timeout_seconds > 0) {
        struct timespec rel;
        rel.tv_sec = (time_t)timeout_seconds;
        rel.tv_nsec = (long)((timeout_seconds - (double)rel.tv_sec) * 1e9);
        if (rel.tv_nsec > 999999999L) rel.tv_nsec = 999999999L;
        if (rel.tv_nsec < 0) rel.tv_nsec = 0;
        // A single timed wait suffices: a spurious wakeup just returns to the
        // caller's loop, which re-checks its rings and render gate anyway.
        (void)pthread_cond_timedwait_relative_np(
            &g_worker_wakeup_cond, &g_worker_wakeup_mutex, &rel);
    }
    t_worker_wakeup_seen = g_worker_wakeup_seq;
    pthread_mutex_unlock(&g_worker_wakeup_mutex);
}

static void wispterm_macos_push_key_event(WispTermMacWindowState *state, WispTermMacKeyEvent event) {
    if (state == NULL) return;
    const size_t capacity = sizeof(state->key_events) / sizeof(state->key_events[0]);
    os_unfair_lock_lock(&state->input_lock);
    const size_t idx = (state->key_head + state->key_count) % capacity;
    state->key_events[idx] = event;
    if (state->key_count < capacity) {
        state->key_count += 1;
    } else {
        state->key_head = (state->key_head + 1) % capacity;
    }
    os_unfair_lock_unlock(&state->input_lock);
    wispterm_macos_worker_wakeup_signal();
}

static bool wispterm_macos_pop_key_event(WispTermMacWindowState *state, WispTermMacKeyEvent *out) {
    if (state == NULL || out == NULL) return false;
    const size_t capacity = sizeof(state->key_events) / sizeof(state->key_events[0]);
    os_unfair_lock_lock(&state->input_lock);
    bool has_event = state->key_count != 0;
    if (has_event) {
        *out = state->key_events[state->key_head];
        state->key_head = (state->key_head + 1) % capacity;
        state->key_count -= 1;
    }
    os_unfair_lock_unlock(&state->input_lock);
    return has_event;
}

static void wispterm_macos_push_char_event(WispTermMacWindowState *state, WispTermMacCharEvent event) {
    if (state == NULL) return;
    const size_t capacity = sizeof(state->char_events) / sizeof(state->char_events[0]);
    os_unfair_lock_lock(&state->input_lock);
    const size_t idx = (state->char_head + state->char_count) % capacity;
    state->char_events[idx] = event;
    if (state->char_count < capacity) {
        state->char_count += 1;
    } else {
        state->char_head = (state->char_head + 1) % capacity;
    }
    os_unfair_lock_unlock(&state->input_lock);
    wispterm_macos_worker_wakeup_signal();
}

static bool wispterm_macos_pop_char_event(WispTermMacWindowState *state, WispTermMacCharEvent *out) {
    if (state == NULL || out == NULL) return false;
    const size_t capacity = sizeof(state->char_events) / sizeof(state->char_events[0]);
    os_unfair_lock_lock(&state->input_lock);
    bool has_event = state->char_count != 0;
    if (has_event) {
        *out = state->char_events[state->char_head];
        state->char_head = (state->char_head + 1) % capacity;
        state->char_count -= 1;
    }
    os_unfair_lock_unlock(&state->input_lock);
    return has_event;
}

static void wispterm_macos_push_mouse_button_event(WispTermMacWindowState *state, WispTermMacMouseButtonEvent event) {
    if (state == NULL) return;
    const size_t capacity = sizeof(state->mouse_button_events) / sizeof(state->mouse_button_events[0]);
    os_unfair_lock_lock(&state->input_lock);
    const size_t idx = (state->mouse_button_head + state->mouse_button_count) % capacity;
    state->mouse_button_events[idx] = event;
    if (state->mouse_button_count < capacity) {
        state->mouse_button_count += 1;
    } else {
        state->mouse_button_head = (state->mouse_button_head + 1) % capacity;
    }
    os_unfair_lock_unlock(&state->input_lock);
    wispterm_macos_worker_wakeup_signal();
}

static bool wispterm_macos_pop_mouse_button_event(WispTermMacWindowState *state, WispTermMacMouseButtonEvent *out) {
    if (state == NULL || out == NULL) return false;
    const size_t capacity = sizeof(state->mouse_button_events) / sizeof(state->mouse_button_events[0]);
    os_unfair_lock_lock(&state->input_lock);
    bool has_event = state->mouse_button_count != 0;
    if (has_event) {
        *out = state->mouse_button_events[state->mouse_button_head];
        state->mouse_button_head = (state->mouse_button_head + 1) % capacity;
        state->mouse_button_count -= 1;
    }
    os_unfair_lock_unlock(&state->input_lock);
    return has_event;
}

static void wispterm_macos_push_mouse_move_event(WispTermMacWindowState *state, WispTermMacMouseMoveEvent event) {
    if (state == NULL) return;
    const size_t capacity = sizeof(state->mouse_move_events) / sizeof(state->mouse_move_events[0]);
    os_unfair_lock_lock(&state->input_lock);
    const size_t idx = (state->mouse_move_head + state->mouse_move_count) % capacity;
    state->mouse_move_events[idx] = event;
    if (state->mouse_move_count < capacity) {
        state->mouse_move_count += 1;
    } else {
        state->mouse_move_head = (state->mouse_move_head + 1) % capacity;
    }
    os_unfair_lock_unlock(&state->input_lock);
    wispterm_macos_worker_wakeup_signal();
}

static bool wispterm_macos_pop_mouse_move_event(WispTermMacWindowState *state, WispTermMacMouseMoveEvent *out) {
    if (state == NULL || out == NULL) return false;
    const size_t capacity = sizeof(state->mouse_move_events) / sizeof(state->mouse_move_events[0]);
    os_unfair_lock_lock(&state->input_lock);
    bool has_event = state->mouse_move_count != 0;
    if (has_event) {
        *out = state->mouse_move_events[state->mouse_move_head];
        state->mouse_move_head = (state->mouse_move_head + 1) % capacity;
        state->mouse_move_count -= 1;
    }
    os_unfair_lock_unlock(&state->input_lock);
    return has_event;
}

static void wispterm_macos_push_mouse_wheel_event(WispTermMacWindowState *state, WispTermMacMouseWheelEvent event) {
    if (state == NULL) return;
    const size_t capacity = sizeof(state->mouse_wheel_events) / sizeof(state->mouse_wheel_events[0]);
    os_unfair_lock_lock(&state->input_lock);
    const size_t idx = (state->mouse_wheel_head + state->mouse_wheel_count) % capacity;
    state->mouse_wheel_events[idx] = event;
    if (state->mouse_wheel_count < capacity) {
        state->mouse_wheel_count += 1;
    } else {
        state->mouse_wheel_head = (state->mouse_wheel_head + 1) % capacity;
    }
    os_unfair_lock_unlock(&state->input_lock);
    wispterm_macos_worker_wakeup_signal();
}

static bool wispterm_macos_pop_mouse_wheel_event(WispTermMacWindowState *state, WispTermMacMouseWheelEvent *out) {
    if (state == NULL || out == NULL) return false;
    const size_t capacity = sizeof(state->mouse_wheel_events) / sizeof(state->mouse_wheel_events[0]);
    os_unfair_lock_lock(&state->input_lock);
    bool has_event = state->mouse_wheel_count != 0;
    if (has_event) {
        *out = state->mouse_wheel_events[state->mouse_wheel_head];
        state->mouse_wheel_head = (state->mouse_wheel_head + 1) % capacity;
        state->mouse_wheel_count -= 1;
    }
    os_unfair_lock_unlock(&state->input_lock);
    return has_event;
}

// The message ring is the only event queue with producers off the window
// worker thread, so push/pop must serialize on state->message_lock. The lock
// is held only for the few non-blocking ring operations below — never across
// an AppKit call or a callback — so contention is negligible.
static void wispterm_macos_push_message_event(WispTermMacWindowState *state, WispTermMacMessageEvent event) {
    if (state == NULL) return;
    const size_t capacity = sizeof(state->message_events) / sizeof(state->message_events[0]);
    os_unfair_lock_lock(&state->message_lock);
    const size_t idx = (state->message_head + state->message_count) % capacity;
    state->message_events[idx] = event;
    if (state->message_count < capacity) {
        state->message_count += 1;
    } else {
        state->message_head = (state->message_head + 1) % capacity;
    }
    os_unfair_lock_unlock(&state->message_lock);
    wispterm_macos_worker_wakeup_signal();
}

static bool wispterm_macos_pop_message_event(WispTermMacWindowState *state, WispTermMacMessageEvent *out) {
    if (state == NULL || out == NULL) return false;
    const size_t capacity = sizeof(state->message_events) / sizeof(state->message_events[0]);
    os_unfair_lock_lock(&state->message_lock);
    bool has_event = state->message_count != 0;
    if (has_event) {
        *out = state->message_events[state->message_head];
        state->message_head = (state->message_head + 1) % capacity;
        state->message_count -= 1;
    }
    os_unfair_lock_unlock(&state->message_lock);
    return has_event;
}

static bool wispterm_macos_push_file_drop_event(WispTermMacWindowState *state, const char *path, int32_t x, int32_t y) {
    if (state == NULL || path == NULL) return false;
    const size_t capacity = sizeof(state->file_drop_events) / sizeof(state->file_drop_events[0]);
    const size_t source_len = strlen(path);
    const size_t len = source_len < sizeof(state->file_drop_events[0].path) ? source_len : sizeof(state->file_drop_events[0].path) - 1;
    os_unfair_lock_lock(&state->input_lock);
    const size_t idx = (state->file_drop_head + state->file_drop_count) % capacity;
    WispTermMacFileDropEvent *event = &state->file_drop_events[idx];
    memcpy(event->path, path, len);
    event->path[len] = 0;
    event->path_len = len;
    event->x = x;
    event->y = y;
    if (state->file_drop_count < capacity) {
        state->file_drop_count += 1;
    } else {
        state->file_drop_head = (state->file_drop_head + 1) % capacity;
    }
    os_unfair_lock_unlock(&state->input_lock);
    wispterm_macos_worker_wakeup_signal();
    return true;
}

static bool wispterm_macos_pop_file_drop_event(WispTermMacWindowState *state, WispTermMacFileDropEvent *out) {
    if (state == NULL || out == NULL) return false;
    const size_t capacity = sizeof(state->file_drop_events) / sizeof(state->file_drop_events[0]);
    os_unfair_lock_lock(&state->input_lock);
    bool has_event = state->file_drop_count != 0;
    if (has_event) {
        *out = state->file_drop_events[state->file_drop_head];
        state->file_drop_head = (state->file_drop_head + 1) % capacity;
        state->file_drop_count -= 1;
    }
    os_unfair_lock_unlock(&state->input_lock);
    return has_event;
}

static void wispterm_macos_mods(NSEventModifierFlags flags, bool *ctrl, bool *shift, bool *alt, bool *super) {
    if (ctrl != NULL) *ctrl = (flags & NSEventModifierFlagControl) != 0;
    if (shift != NULL) *shift = (flags & NSEventModifierFlagShift) != 0;
    if (alt != NULL) *alt = (flags & NSEventModifierFlagOption) != 0;
    if (super != NULL) *super = (flags & NSEventModifierFlagCommand) != 0;
}

static NSEventModifierFlags wispterm_macos_flags_from_bools(bool ctrl, bool shift, bool alt, bool super) {
    NSEventModifierFlags flags = 0;
    if (ctrl) flags |= NSEventModifierFlagControl;
    if (shift) flags |= NSEventModifierFlagShift;
    if (alt) flags |= NSEventModifierFlagOption;
    if (super) flags |= NSEventModifierFlagCommand;
    return flags;
}

static WispTermMacKeyEvent wispterm_macos_key_event(uintptr_t key_code, NSEventModifierFlags flags) {
    return (WispTermMacKeyEvent){
        .key_code = key_code,
        .ctrl = (flags & NSEventModifierFlagControl) != 0,
        .shift = (flags & NSEventModifierFlagShift) != 0,
        .alt = (flags & NSEventModifierFlagOption) != 0,
        .super = (flags & NSEventModifierFlagCommand) != 0,
    };
}

static WispTermMacCharEvent wispterm_macos_char_event(uint32_t codepoint, NSEventModifierFlags flags) {
    WispTermMacCharEvent event = { .codepoint = codepoint, .ctrl = false, .shift = false, .alt = false, .super = false };
    wispterm_macos_mods(flags, &event.ctrl, &event.shift, &event.alt, &event.super);
    return event;
}

static uintptr_t wispterm_macos_map_ansi_key_code(unsigned short key_code) {
    switch (key_code) {
        case 0: return 'A';
        case 1: return 'S';
        case 2: return 'D';
        case 3: return 'F';
        case 4: return 'H';
        case 5: return 'G';
        case 6: return 'Z';
        case 7: return 'X';
        case 8: return 'C';
        case 9: return 'V';
        case 11: return 'B';
        case 12: return 'Q';
        case 13: return 'W';
        case 14: return 'E';
        case 15: return 'R';
        case 16: return 'Y';
        case 17: return 'T';
        case 18: return '1';
        case 19: return '2';
        case 20: return '3';
        case 21: return '4';
        case 22: return '6';
        case 23: return '5';
        case 24: return 0xBB; // = / +
        case 25: return '9';
        case 26: return '7';
        case 27: return 0xBD; // - / _
        case 28: return '8';
        case 29: return '0';
        case 30: return 0xDD; // ] / }
        case 31: return 'O';
        case 32: return 'U';
        case 33: return 0xDB; // [ / {
        case 34: return 'I';
        case 35: return 'P';
        case 37: return 'L';
        case 38: return 'J';
        case 39: return 0xDE; // ' / "
        case 40: return 'K';
        case 41: return 0xBA; // ; / :
        case 42: return 0xDC; // \ / |
        case 43: return 0xBC; // , / <
        case 44: return 0xBF; // / / ?
        case 45: return 'N';
        case 46: return 'M';
        case 47: return 0xBE; // . / >
        case 50: return 0xC0; // ` / ~
        default: return 0;
    }
}

static uintptr_t wispterm_macos_map_key_code(unsigned short key_code, NSString *characters) {
    switch (key_code) {
        case 36: return 0x0D;  // Return
        case 48: return 0x09;  // Tab
        case 51: return 0x08;  // Backspace
        case 53: return 0x1B;  // Escape
        case 115: return 0x24; // Home
        case 116: return 0x21; // Page Up
        case 117: return 0x2E; // Forward Delete
        case 119: return 0x23; // End
        case 121: return 0x22; // Page Down
        case 123: return 0x25; // Left
        case 124: return 0x27; // Right
        case 125: return 0x28; // Down
        case 126: return 0x26; // Up
        default: break;
    }

    // Keybindings and the Windows backend both key on Windows virtual-key
    // codes tied to the physical key, so prefer the physical-key mapping.
    // Punctuation keys like "=" and "-" produce VK codes (0xBB/0xBD) that do
    // not equal their ASCII character; matching them by character breaks Cmd
    // shortcuts (font size, open config, splits, Quake). Typed text is
    // delivered separately via char events, so this never affects input.
    uintptr_t ansi = wispterm_macos_map_ansi_key_code(key_code);
    if (ansi != 0) return ansi;

    if (characters.length > 0) {
        unichar ch = [characters characterAtIndex:0];
        if (ch >= 'a' && ch <= 'z') return (uintptr_t)(ch - ('a' - 'A'));
        return (uintptr_t)ch;
    }
    return (uintptr_t)key_code;
}

static NSString *wispterm_macos_key_characters(NSEvent *event) {
    if (event == nil) return nil;
    NSString *characters = nil;
    if ((event.modifierFlags & NSEventModifierFlagControl) != 0) {
        NSEventModifierFlags translation_flags = event.modifierFlags & ~NSEventModifierFlagControl;
        characters = [event charactersByApplyingModifiers:translation_flags];
    }
    if (characters != nil) return characters;
    return event.charactersIgnoringModifiers != nil ? event.charactersIgnoringModifiers : event.characters;
}

static void wispterm_macos_handle_event(WispTermMacWindowState *state, NSEvent *event) {
    if (state == NULL || event == nil) return;
    switch (event.type) {
        case NSEventTypeKeyDown: {
            NSString *characters = wispterm_macos_key_characters(event);
            uintptr_t key_code = wispterm_macos_map_key_code(event.keyCode, characters);
            wispterm_macos_push_key_event(state, wispterm_macos_key_event(key_code, event.modifierFlags));
            break;
        }
        default:
            break;
    }
}

static int16_t wispterm_macos_scroll_delta(NSEvent *event) {
    double value = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 10.0 : event.scrollingDeltaY * 120.0;
    if (value > 32767.0) value = 32767.0;
    if (value < -32768.0) value = -32768.0;
    if (value > -1.0 && value < 1.0 && event.scrollingDeltaY != 0.0) {
        value = event.scrollingDeltaY > 0.0 ? 1.0 : -1.0;
    }
    return (int16_t)wispterm_macos_round_double(value);
}

static NSPoint wispterm_macos_event_point(WispTermMacWindowState *state, NSEvent *event) {
    if (state == NULL || state->view == nil || event == nil) return NSMakePoint(0, 0);
    NSPoint point = [state->view convertPoint:event.locationInWindow fromView:nil];
    NSRect bounds = [state->view bounds];
    const double scale = wispterm_macos_scale(state);
    return NSMakePoint(point.x * scale, (bounds.size.height - point.y) * scale);
}

static void wispterm_macos_push_string(WispTermMacWindowState *state, id string_or_attributed, NSEventModifierFlags flags) {
    if (state == NULL || string_or_attributed == nil) return;
    NSString *string = [string_or_attributed isKindOfClass:[NSAttributedString class]]
        ? [(NSAttributedString *)string_or_attributed string]
        : (NSString *)string_or_attributed;
    for (NSUInteger i = 0; i < string.length; i++) {
        unichar first = [string characterAtIndex:i];
        uint32_t codepoint = first;
        if (first >= 0xD800 && first <= 0xDBFF && i + 1 < string.length) {
            unichar second = [string characterAtIndex:i + 1];
            if (second >= 0xDC00 && second <= 0xDFFF) {
                i += 1;
                codepoint = 0x10000 + (((uint32_t)first - 0xD800) << 10) + ((uint32_t)second - 0xDC00);
            }
        }
        if (codepoint >= 32) {
            wispterm_macos_push_char_event(state, wispterm_macos_char_event(codepoint, flags));
        }
    }
}

void wispterm_macos_window_test_insert_text_after_key(void *handle, uint32_t codepoint, bool ctrl, bool shift, bool alt) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL) return;
    @autoreleasepool {
        state->insert_text_modifier_flags = wispterm_macos_flags_from_bools(ctrl, shift, alt, false);
        NSString *string = nil;
        if (codepoint <= 0xFFFF) {
            unichar ch = (unichar)codepoint;
            string = [[NSString alloc] initWithCharacters:&ch length:1];
        } else if (codepoint <= 0x10FFFF) {
            uint32_t value = codepoint - 0x10000;
            unichar pair[2] = {
                (unichar)(0xD800 + (value >> 10)),
                (unichar)(0xDC00 + (value & 0x3FF)),
            };
            string = [[NSString alloc] initWithCharacters:pair length:2];
        }
        if (string != nil) {
            wispterm_macos_push_string(state, string, state->insert_text_modifier_flags);
            [string release];
        }
        state->insert_text_modifier_flags = 0;
    }
}

static void wispterm_macos_set_preedit(WispTermMacWindowState *state, id string_or_attributed) {
    if (state == NULL) return;
    NSString *string = nil;
    if (string_or_attributed != nil) {
        string = [string_or_attributed isKindOfClass:[NSAttributedString class]]
            ? [(NSAttributedString *)string_or_attributed string]
            : (NSString *)string_or_attributed;
    }
    if (string == nil || string.length == 0) {
        state->ime_preedit_len = 0;
        state->ime_preedit[0] = 0;
        return;
    }

    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger len = data.length < sizeof(state->ime_preedit) ? data.length : sizeof(state->ime_preedit) - 1;
    memcpy(state->ime_preedit, data.bytes, len);
    state->ime_preedit[len] = 0;
    state->ime_preedit_len = len;
}

@implementation WispTermMacContentView
- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self.window makeFirstResponder:self];
}

- (void)keyDown:(NSEvent *)event {
    // While an IME composition is active, every keystroke belongs to the input
    // method, not the app: Return commits the highlighted candidate, space and
    // number keys pick candidates, arrows page the candidate window, backspace
    // edits the preedit. Forwarding the raw key event in that state is exactly
    // the "Enter commits 你好 but also fires send" bug — the committed text
    // arrives separately via -insertText:, so the raw Return must not also reach
    // the app. Only push the raw key event when there is no composition; let
    // -interpretKeyEvents: route composing keystrokes to the IME.
    if (self.state != NULL) self.state->insert_text_modifier_flags = event.modifierFlags;
    if (self.state != NULL && ![self hasMarkedText]) {
        NSString *characters = wispterm_macos_key_characters(event);
        uintptr_t key_code = wispterm_macos_map_key_code(event.keyCode, characters);
        wispterm_macos_push_key_event(self.state, wispterm_macos_key_event(key_code, event.modifierFlags));
    }
    [self interpretKeyEvents:@[event]];
    if (self.state != NULL) self.state->insert_text_modifier_flags = 0;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    // Cmd shortcuts never reach -keyDown:, so we intercept them here.
    // Pushing the event ourselves and returning YES prevents AppKit from
    // emitting the unhandled-shortcut system beep.
    if ((event.modifierFlags & NSEventModifierFlagCommand) == 0) return NO;
    if (self.state == NULL) return NO;
    NSString *characters = wispterm_macos_key_characters(event);
    uintptr_t key_code = wispterm_macos_map_key_code(event.keyCode, characters);
    wispterm_macos_push_key_event(self.state, wispterm_macos_key_event(key_code, event.modifierFlags));
    return YES;
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    (void)replacementRange;
    NSEventModifierFlags flags = self.state != NULL ? self.state->insert_text_modifier_flags : 0;
    wispterm_macos_push_string(self.state, string, flags);
    wispterm_macos_set_preedit(self.state, nil);
}

- (void)doCommandBySelector:(SEL)selector {
    (void)selector;
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    (void)selectedRange;
    (void)replacementRange;
    wispterm_macos_set_preedit(self.state, string);
}

- (void)unmarkText {
    wispterm_macos_set_preedit(self.state, nil);
}

- (BOOL)hasMarkedText {
    return self.state != NULL && self.state->ime_preedit_len > 0;
}

- (NSRange)markedRange {
    if (![self hasMarkedText]) return NSMakeRange(NSNotFound, 0);
    return NSMakeRange(0, self.state->ime_preedit_len);
}

- (NSRange)selectedRange {
    return NSMakeRange(NSNotFound, 0);
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
    return @[];
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    if (actualRange != NULL) *actualRange = NSMakeRange(NSNotFound, 0);
    (void)range;
    return nil;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    (void)point;
    return 0;
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    if (actualRange != NULL) *actualRange = range;
    WispTermMacWindowState *state = self.state;
    if (state == NULL || self.window == nil) return NSZeroRect;
    const double scale = wispterm_macos_scale(state);
    NSRect bounds = [self bounds];
    NSRect local = NSMakeRect(
        state->ime_caret_x / scale,
        bounds.size.height - ((state->ime_caret_y + state->ime_caret_height) / scale),
        1,
        state->ime_caret_height / scale
    );
    NSRect window_rect = [self convertRect:local toView:nil];
    return [self.window convertRectToScreen:window_rect];
}

- (WispTermMacMouseButtonEvent)mouseButtonEvent:(NSEvent *)event button:(uint8_t)button action:(uint8_t)action {
    NSPoint point = wispterm_macos_event_point(self.state, event);
    WispTermMacMouseButtonEvent out = {
        .button = button,
        .action = action,
        .x = wispterm_macos_round_double(point.x),
        .y = wispterm_macos_round_double(point.y),
        .ctrl = false,
        .shift = false,
        .alt = false,
        .super = false,
    };
    wispterm_macos_mods(event.modifierFlags, &out.ctrl, &out.shift, &out.alt, &out.super);
    return out;
}

- (void)mouseDown:(NSEvent *)event {
    wispterm_macos_push_mouse_button_event(self.state, [self mouseButtonEvent:event button:0 action:(event.clickCount > 1 ? 2 : 0)]);
}

- (void)mouseUp:(NSEvent *)event {
    wispterm_macos_push_mouse_button_event(self.state, [self mouseButtonEvent:event button:0 action:1]);
}

- (void)rightMouseDown:(NSEvent *)event {
    wispterm_macos_push_mouse_button_event(self.state, [self mouseButtonEvent:event button:1 action:(event.clickCount > 1 ? 2 : 0)]);
}

- (void)rightMouseUp:(NSEvent *)event {
    wispterm_macos_push_mouse_button_event(self.state, [self mouseButtonEvent:event button:1 action:1]);
}

- (void)otherMouseDown:(NSEvent *)event {
    wispterm_macos_push_mouse_button_event(self.state, [self mouseButtonEvent:event button:2 action:(event.clickCount > 1 ? 2 : 0)]);
}

- (void)otherMouseUp:(NSEvent *)event {
    wispterm_macos_push_mouse_button_event(self.state, [self mouseButtonEvent:event button:2 action:1]);
}

- (void)pushMouseMove:(NSEvent *)event {
    NSPoint point = wispterm_macos_event_point(self.state, event);
    WispTermMacMouseMoveEvent out = {
        .x = wispterm_macos_round_double(point.x),
        .y = wispterm_macos_round_double(point.y),
        .ctrl = false,
        .shift = false,
        .alt = false,
        .super = false,
    };
    wispterm_macos_mods(event.modifierFlags, &out.ctrl, &out.shift, &out.alt, &out.super);
    wispterm_macos_push_mouse_move_event(self.state, out);
}

- (void)mouseMoved:(NSEvent *)event { [self pushMouseMove:event]; }
- (void)mouseDragged:(NSEvent *)event { [self pushMouseMove:event]; }
- (void)rightMouseDragged:(NSEvent *)event { [self pushMouseMove:event]; }
- (void)otherMouseDragged:(NSEvent *)event { [self pushMouseMove:event]; }

- (void)scrollWheel:(NSEvent *)event {
    NSPoint point = wispterm_macos_event_point(self.state, event);
    WispTermMacMouseWheelEvent out = {
        .delta = wispterm_macos_scroll_delta(event),
        .xpos = wispterm_macos_round_double(point.x),
        .ypos = wispterm_macos_round_double(point.y),
        .ctrl = false,
        .shift = false,
        .alt = false,
    };
    wispterm_macos_mods(event.modifierFlags, &out.ctrl, &out.shift, &out.alt, NULL);
    wispterm_macos_push_mouse_wheel_event(self.state, out);
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    (void)sender;
    return NSDragOperationCopy;
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
    (void)sender;
    return YES;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    if (self.state == NULL) return NO;

    NSPasteboard *pasteboard = [sender draggingPasteboard];
    NSDictionary *options = @{ NSPasteboardURLReadingFileURLsOnlyKey: @YES };
    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[[NSURL class]] options:options];
    if (urls.count == 0) return NO;

    NSPoint point = [self convertPoint:[sender draggingLocation] fromView:nil];
    NSRect bounds = [self bounds];
    const double scale = wispterm_macos_scale(self.state);
    int32_t x = wispterm_macos_round_double(point.x * scale);
    int32_t y = wispterm_macos_round_double((bounds.size.height - point.y) * scale);
    BOOL accepted = NO;
    for (NSURL *url in urls) {
        if (!url.isFileURL) continue;
        const char *path = url.path.UTF8String;
        if (wispterm_macos_push_file_drop_event(self.state, path, x, y)) accepted = YES;
    }
    return accepted;
}
@end

static void wispterm_macos_sync_layer(WispTermMacWindowState *state) {
    if (state == NULL || state->view == nil || state->layer == nil) return;
    const double scale = wispterm_macos_scale(state);
    NSRect bounds = [state->view bounds];
    state->layer.contentsScale = scale;
    state->layer.drawableSize = CGSizeMake(bounds.size.width * scale, bounds.size.height * scale);
    state->layer.frame = bounds;
}

void *wispterm_macos_window_create(
    int32_t width,
    int32_t height,
    const uint16_t *title,
    int32_t x,
    int32_t y,
    bool has_position,
    bool maximize
) {
    __block WispTermMacWindowState *result = NULL;
    dispatch_block_t create_block = ^{
        @autoreleasepool {
            wispterm_macos_app_ensure();

            WispTermMacWindowState *state = calloc(1, sizeof(WispTermMacWindowState));
            if (state == NULL) return;

            NSRect content_rect = NSMakeRect(
                has_position ? (CGFloat)x : 120.0,
                has_position ? (CGFloat)y : 120.0,
                width > 0 ? (CGFloat)width : 800.0,
                height > 0 ? (CGFloat)height : 600.0
            );
            // FullSizeContentView lets wispterm's own GL/Metal-drawn titlebar
            // extend behind the traffic-light buttons, matching Codex / VS
            // Code / Ghostty. titlebarAppearsTransparent + titleVisibility
            // hide the system-drawn title chrome so only the traffic lights
            // remain visible on top of our content.
            NSUInteger style =
                NSWindowStyleMaskTitled |
                NSWindowStyleMaskClosable |
                NSWindowStyleMaskMiniaturizable |
                NSWindowStyleMaskResizable |
                NSWindowStyleMaskFullSizeContentView;
            NSWindow *window = [[NSWindow alloc]
                initWithContentRect:content_rect
                          styleMask:style
                            backing:NSBackingStoreBuffered
                              defer:NO];
            if (window == nil) {
                free(state);
                return;
            }
            [window setTitlebarAppearsTransparent:YES];
            [window setTitleVisibility:NSWindowTitleHidden];

            NSString *window_title = wispterm_macos_title_from_utf16(title);
            [window setTitle:window_title];
            [window_title release];
            [window setReleasedWhenClosed:NO];
            [window setSharingType:NSWindowSharingReadOnly];

            WispTermMacContentView *view = [[WispTermMacContentView alloc] initWithFrame:NSMakeRect(0, 0, content_rect.size.width, content_rect.size.height)];
            CAMetalLayer *layer = [CAMetalLayer layer];
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            layer.device = device;
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.framebufferOnly = YES;
            if (device != nil) [device release];
            [view setWantsLayer:YES];
            [view setLayer:layer];
            [view registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
            [window setContentView:view];

            WispTermMacWindowDelegate *delegate = [[WispTermMacWindowDelegate alloc] init];
            delegate.state = state;
            [window setDelegate:delegate];

            state->window = window;
            state->view = view;
            state->layer = [layer retain];
            state->delegate = delegate;
            state->close_requested = false;
            state->input_lock = OS_UNFAIR_LOCK_INIT;
            state->message_lock = OS_UNFAIR_LOCK_INIT;
            state->ime_caret_x = 0;
            state->ime_caret_y = 0;
            state->ime_caret_height = 16;
            state->ime_preedit[0] = 0;
            state->ime_preedit_len = 0;
            view.state = state;
            wispterm_macos_sync_layer(state);

            [window setAcceptsMouseMovedEvents:YES];
            [window makeKeyAndOrderFront:nil];
            [window makeFirstResponder:view];
            [NSApp activateIgnoringOtherApps:NO];
            if (maximize) [window zoom:nil];
            result = state;
        }
    };

    // AppKit window construction (NSApplication/NSWindow) is main-thread only;
    // macOS 26 raises NSInternalInconsistencyException from -[NSWindow _initContent:]
    // when invoked off-main. Worker threads (e.g. App.requestNewWindow) marshal
    // here via the main queue; if we are already on the main thread, run inline
    // to avoid a dispatch_sync self-deadlock.
    if ([NSThread isMainThread]) {
        create_block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), create_block);
    }
    return result;
}

void wispterm_macos_window_destroy(void *handle) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL) return;
    wispterm_macos_run_on_main(^{
        @autoreleasepool {
            [state->window setDelegate:nil];
            [state->window orderOut:nil];
            [state->layer release];
            [state->view release];
            [state->delegate release];
            [state->window close];
            [state->window release];
            free(state);
        }
    });
}

void *wispterm_macos_window_ns_window(void *handle) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL) return NULL;
    return (void *)state->window;
}

// True iff the window is on-screen (not occluded) and not miniaturized.
bool wispterm_macos_window_visible(void *handle) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL || state->window == NULL) return true;
    NSWindowOcclusionState occ = [state->window occlusionState];
    bool visible = (occ & NSWindowOcclusionStateVisible) != 0;
    bool miniaturized = [state->window isMiniaturized];
    return visible && !miniaturized;
}

// True iff the window is the key window (has keyboard focus).
bool wispterm_macos_window_is_key(void *handle) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL || state->window == NULL) return true;
    return [state->window isKeyWindow] ? true : false;
}

void wispterm_macos_window_poll(void *handle) {
    @autoreleasepool {
        WispTermMacWindowState *state = wispterm_macos_state(handle);
        if (state == NULL) return;
        // -nextEventMatchingMask: / -sendEvent: must run on the main thread.
        // Worker AppWindow threads still call into here every frame; for them
        // we skip the AppKit pump (the main thread idle loop drains events
        // and AppKit dispatches them to WispTermMacWindowDelegate, which pushes
        // into state->*_events). Worker threads only need to sync the Metal
        // layer to the current backing scale.
        if ([NSThread isMainThread]) {
            for (;;) {
                NSEvent *event = [NSApp
                    nextEventMatchingMask:NSEventMaskAny
                                 untilDate:[NSDate distantPast]
                                    inMode:NSDefaultRunLoopMode
                                   dequeue:YES];
                if (event == nil) break;
                [NSApp sendEvent:event];
            }
            [NSApp updateWindows];
        }
        wispterm_macos_sync_layer(state);
    }
}

// Pump pending NSApp events without requiring a window handle. Used by the
// zig idle loop in App.run() between window sessions so the AppDelegate's
// reopen / terminate callbacks (Dock icon, cmd+Q) still fire while no
// AppWindow loop is running, and by every AppWindow render loop as its idle
// block between frames.
//
// `timeout_seconds` is how long the main thread is willing to block waiting
// for the next event. Blocking (rather than spinning + sleeping in zig) is
// what keeps the main run loop alive — that's how dispatch_get_main_queue()
// blocks posted from worker threads via wispterm_macos_run_on_main() actually
// get drained. With distantPast (0s) the main queue never runs and any
// worker dispatch_sync to main deadlocks until something else wakes the run
// loop.
void wispterm_macos_app_pump_events(double timeout_seconds) {
    // Worker-thread window loops (every window past the first) must not touch
    // NSApp — AppKit throws off-main. They block on the wakeup condition; the
    // main thread's pump dispatches their input into the rings and signals it.
    if (![NSThread isMainThread]) {
        wispterm_macos_worker_wakeup_wait(timeout_seconds);
        return;
    }
    @autoreleasepool {
        NSDate *first_until = (timeout_seconds > 0)
            ? [NSDate dateWithTimeIntervalSinceNow:timeout_seconds]
            : [NSDate distantPast];
        // Block once for up to timeout_seconds (or until any event arrives),
        // then drain anything else without blocking.
        NSDate *until = first_until;
        for (;;) {
            NSEvent *event = [NSApp
                nextEventMatchingMask:NSEventMaskAny
                             untilDate:until
                                inMode:NSDefaultRunLoopMode
                               dequeue:YES];
            if (event == nil) break;
            [NSApp sendEvent:event];
            until = [NSDate distantPast];
        }
        [NSApp updateWindows];
    }
}

// Wake any blocked idle pump from any thread: posts an application-defined
// NSEvent for the main thread's -nextEventMatchingMask: and signals the
// worker-window wakeup condition. Safe off-main.
void wispterm_macos_post_wakeup(void) {
    @autoreleasepool {
        NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                            location:NSMakePoint(0, 0)
                                       modifierFlags:0
                                           timestamp:0
                                        windowNumber:0
                                             context:nil
                                             subtype:0
                                               data1:0
                                               data2:0];
        if (event != nil) [NSApp postEvent:event atStart:NO];
    }
    wispterm_macos_worker_wakeup_signal();
}

bool wispterm_macos_window_close_requested(void *handle) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    return state != NULL && state->close_requested;
}

bool wispterm_macos_window_pop_key_event(void *handle, WispTermMacKeyEvent *out) {
    return wispterm_macos_pop_key_event(wispterm_macos_state(handle), out);
}

bool wispterm_macos_window_pop_char_event(void *handle, WispTermMacCharEvent *out) {
    return wispterm_macos_pop_char_event(wispterm_macos_state(handle), out);
}

bool wispterm_macos_window_pop_mouse_button_event(void *handle, WispTermMacMouseButtonEvent *out) {
    return wispterm_macos_pop_mouse_button_event(wispterm_macos_state(handle), out);
}

bool wispterm_macos_window_pop_mouse_move_event(void *handle, WispTermMacMouseMoveEvent *out) {
    return wispterm_macos_pop_mouse_move_event(wispterm_macos_state(handle), out);
}

bool wispterm_macos_window_pop_mouse_wheel_event(void *handle, WispTermMacMouseWheelEvent *out) {
    return wispterm_macos_pop_mouse_wheel_event(wispterm_macos_state(handle), out);
}

bool wispterm_macos_window_pop_message_event(void *handle, WispTermMacMessageEvent *out) {
    return wispterm_macos_pop_message_event(wispterm_macos_state(handle), out);
}

bool wispterm_macos_window_pop_file_drop_event(void *handle, WispTermMacFileDropEvent *out) {
    return wispterm_macos_pop_file_drop_event(wispterm_macos_state(handle), out);
}

size_t wispterm_macos_window_copy_ime_preedit(void *handle, char *out, size_t out_len) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL || out == NULL || out_len == 0) return 0;
    size_t len = state->ime_preedit_len < out_len ? state->ime_preedit_len : out_len;
    memcpy(out, state->ime_preedit, len);
    return len;
}

void wispterm_macos_window_set_ime_caret(void *handle, int32_t x, int32_t y, int32_t height) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL) return;
    state->ime_caret_x = x > 0 ? x : 0;
    state->ime_caret_y = y > 0 ? y : 0;
    state->ime_caret_height = height > 1 ? height : 1;
}

void wispterm_macos_window_test_push_key(void *handle, uintptr_t key_code, bool ctrl, bool shift, bool alt) {
    wispterm_macos_push_key_event(wispterm_macos_state(handle), (WispTermMacKeyEvent){
        .key_code = key_code,
        .ctrl = ctrl,
        .shift = shift,
        .alt = alt,
    });
}

uintptr_t wispterm_macos_window_test_map_key_code(uint16_t native_key_code, const char *characters_utf8) {
    @autoreleasepool {
        NSString *characters = nil;
        if (characters_utf8 != NULL) {
            characters = [NSString stringWithUTF8String:characters_utf8];
        }
        return wispterm_macos_map_key_code(native_key_code, characters);
    }
}

void wispterm_macos_window_test_push_char(void *handle, uint32_t codepoint, bool ctrl, bool shift, bool alt) {
    wispterm_macos_push_char_event(wispterm_macos_state(handle), (WispTermMacCharEvent){
        .codepoint = codepoint,
        .ctrl = ctrl,
        .shift = shift,
        .alt = alt,
    });
}

void wispterm_macos_window_test_push_mouse_button(
    void *handle,
    uint8_t button,
    uint8_t action,
    int32_t x,
    int32_t y,
    bool ctrl,
    bool shift,
    bool alt
) {
    wispterm_macos_push_mouse_button_event(wispterm_macos_state(handle), (WispTermMacMouseButtonEvent){
        .button = button,
        .action = action,
        .x = x,
        .y = y,
        .ctrl = ctrl,
        .shift = shift,
        .alt = alt,
    });
}

void wispterm_macos_window_test_push_mouse_move(void *handle, int32_t x, int32_t y, bool ctrl, bool shift, bool alt) {
    wispterm_macos_push_mouse_move_event(wispterm_macos_state(handle), (WispTermMacMouseMoveEvent){
        .x = x,
        .y = y,
        .ctrl = ctrl,
        .shift = shift,
        .alt = alt,
    });
}

void wispterm_macos_window_test_push_mouse_wheel(
    void *handle,
    int16_t delta,
    int32_t xpos,
    int32_t ypos,
    bool ctrl,
    bool shift,
    bool alt
) {
    wispterm_macos_push_mouse_wheel_event(wispterm_macos_state(handle), (WispTermMacMouseWheelEvent){
        .delta = delta,
        .xpos = xpos,
        .ypos = ypos,
        .ctrl = ctrl,
        .shift = shift,
        .alt = alt,
    });
}

void wispterm_macos_window_test_set_ime_preedit(void *handle, const char *text) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL || text == NULL) return;
    wispterm_macos_set_preedit(state, [NSString stringWithUTF8String:text]);
}

void wispterm_macos_window_test_push_file_drop(void *handle, const char *path, int32_t x, int32_t y) {
    wispterm_macos_push_file_drop_event(wispterm_macos_state(handle), path, x, y);
}

void wispterm_macos_window_request_close(void *handle) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL) return;
    state->close_requested = true;
}

bool wispterm_macos_window_post_message(void *handle, uint32_t message, uintptr_t wparam, intptr_t lparam) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL) return false;
    wispterm_macos_push_message_event(state, (WispTermMacMessageEvent){
        .message = message,
        .wparam = wparam,
        .lparam = lparam,
    });
    return true;
}

void wispterm_macos_window_get_framebuffer_size(void *handle, int32_t *width, int32_t *height, uint32_t *dpi) {
    @autoreleasepool {
        WispTermMacWindowState *state = wispterm_macos_state(handle);
        if (state == NULL || state->view == nil) {
            if (width != NULL) *width = 0;
            if (height != NULL) *height = 0;
            if (dpi != NULL) *dpi = 96;
            return;
        }
        wispterm_macos_sync_layer(state);
        const double scale = wispterm_macos_scale(state);
        NSRect bounds = [state->view bounds];
        if (width != NULL) *width = wispterm_macos_round_double(bounds.size.width * scale);
        if (height != NULL) *height = wispterm_macos_round_double(bounds.size.height * scale);
        if (dpi != NULL) *dpi = (uint32_t)wispterm_macos_round_double(96.0 * scale);
    }
}

void wispterm_macos_window_set_content_size(void *handle, int32_t width, int32_t height) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL || state->window == nil) return;
    wispterm_macos_run_on_main(^{
        @autoreleasepool {
            // wispterm sizes the client area in *framebuffer pixels* (cell_width ×
            // cols, etc.), but -setContentSize: takes *logical points*. On a 2x
            // Retina display, passing framebuffer pixels straight through made the
            // window twice the intended size. Convert by the backing scale so the
            // resulting backing-store size matches the requested framebuffer px.
            double scale = wispterm_macos_scale(state);
            if (scale <= 0.0) scale = 1.0;
            CGFloat w = (CGFloat)(width > 0 ? width : 1) / scale;
            CGFloat h = (CGFloat)(height > 0 ? height : 1) / scale;
            [state->window setContentSize:NSMakeSize(w, h)];
            wispterm_macos_sync_layer(state);
        }
    });
}

void *wispterm_macos_window_metal_layer(void *handle) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL) return NULL;
    return state->layer;
}

bool wispterm_macos_window_get_frame(void *handle, WispTermMacRect *out) {
    @autoreleasepool {
        WispTermMacWindowState *state = wispterm_macos_state(handle);
        if (state == NULL || state->window == nil || out == NULL) return false;
        wispterm_macos_rect_from_nsrect([state->window frame], out);
        return true;
    }
}

bool wispterm_macos_window_get_content_frame(void *handle, WispTermMacRect *out) {
    @autoreleasepool {
        WispTermMacWindowState *state = wispterm_macos_state(handle);
        if (state == NULL || state->view == nil || out == NULL) return false;
        wispterm_macos_rect_from_nsrect([state->view bounds], out);
        return true;
    }
}

uint32_t wispterm_macos_window_dpi(void *handle) {
    const double scale = wispterm_macos_scale(wispterm_macos_state(handle));
    return (uint32_t)wispterm_macos_round_double(96.0 * scale);
}

void wispterm_macos_window_show(void *handle) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL || state->window == nil) return;
    wispterm_macos_run_on_main(^{
        @autoreleasepool {
            [state->window makeKeyAndOrderFront:nil];
        }
    });
}

void wispterm_macos_window_hide(void *handle) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL || state->window == nil) return;
    wispterm_macos_run_on_main(^{
        @autoreleasepool {
            [state->window orderOut:nil];
        }
    });
}

void wispterm_macos_window_make_key(void *handle) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL || state->window == nil) return;
    wispterm_macos_run_on_main(^{
        @autoreleasepool {
            [state->window makeKeyWindow];
            [NSApp activateIgnoringOtherApps:NO];
        }
    });
}

bool wispterm_macos_window_is_zoomed(void *handle) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    return state != NULL && state->window != nil && [state->window isZoomed];
}

void wispterm_macos_window_zoom(void *handle) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL || state->window == nil) return;
    wispterm_macos_run_on_main(^{
        @autoreleasepool {
            [state->window zoom:nil];
        }
    });
}

bool wispterm_macos_window_set_frame(void *handle, int32_t x, int32_t y, int32_t width, int32_t height) {
    WispTermMacWindowState *state = wispterm_macos_state(handle);
    if (state == NULL || state->window == nil) return false;
    wispterm_macos_run_on_main(^{
        @autoreleasepool {
            NSRect frame = NSMakeRect(x, y, width > 0 ? width : 1, height > 0 ? height : 1);
            [state->window setFrame:frame display:YES];
            wispterm_macos_sync_layer(state);
        }
    });
    return true;
}

bool wispterm_macos_window_nearest_monitor_frame(void *handle, WispTermMacRect *out) {
    @autoreleasepool {
        WispTermMacWindowState *state = wispterm_macos_state(handle);
        NSScreen *screen = (state != NULL && state->window != nil) ? [state->window screen] : [NSScreen mainScreen];
        if (screen == nil || out == NULL) return false;
        wispterm_macos_rect_from_nsrect([screen frame], out);
        return true;
    }
}

bool wispterm_macos_window_nearest_monitor_work_area(void *handle, WispTermMacRect *out) {
    @autoreleasepool {
        WispTermMacWindowState *state = wispterm_macos_state(handle);
        NSScreen *screen = (state != NULL && state->window != nil) ? [state->window screen] : [NSScreen mainScreen];
        if (screen == nil || out == NULL) return false;
        wispterm_macos_rect_from_nsrect([screen visibleFrame], out);
        return true;
    }
}
