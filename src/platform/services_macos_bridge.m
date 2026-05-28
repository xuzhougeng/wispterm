#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <CoreFoundation/CoreFoundation.h>
#include <libproc.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Query the current working directory of a live process by pid (used to
// resolve relative preview paths for shells that don't emit OSC 7, e.g. zsh).
// Writes the path into `buf` and returns its length, or -1 on failure.
int32_t phantty_macos_proc_cwd(int32_t pid, char *buf, int32_t buf_len) {
    if (pid <= 0 || buf == NULL || buf_len <= 0) return -1;
    struct proc_vnodepathinfo vpi;
    const int ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof(vpi));
    if (ret <= 0) return -1;
    const char *path = vpi.pvi_cdir.vip_path;
    const size_t len = strlen(path);
    if (len == 0 || (int32_t)len >= buf_len) return -1;
    memcpy(buf, path, len);
    return (int32_t)len;
}

__attribute__((weak)) bool phantty_macos_window_post_message(void *handle, uint32_t message, uintptr_t wparam, intptr_t lparam) {
    (void)handle;
    (void)message;
    (void)wparam;
    (void)lparam;
    return false;
}

typedef struct PhanttyMacHotkeySlot {
    int32_t id;
    void *window_handle;
    EventHotKeyRef ref;
} PhanttyMacHotkeySlot;

static const OSType phantty_macos_hotkey_signature = 'PhTY';
static const uint32_t phantty_macos_hotkey_message = 0x0312;
static PhanttyMacHotkeySlot phantty_macos_hotkey_slots[32];
static EventHandlerRef phantty_macos_hotkey_handler_ref = NULL;

void phantty_macos_global_hotkey_unregister(void *window_handle, int32_t id);

static char *phantty_macos_copy_nsstring(NSString *string) {
    if (string == nil) return NULL;
    const char *utf8 = [string UTF8String];
    if (utf8 == NULL) return NULL;
    size_t len = strlen(utf8);
    char *out = malloc(len + 1);
    if (out == NULL) return NULL;
    memcpy(out, utf8, len + 1);
    return out;
}

void phantty_macos_services_free(void *ptr) {
    free(ptr);
}

bool phantty_macos_clipboard_write_text(const char *text) {
    @autoreleasepool {
        if (text == NULL) return false;
        NSString *string = [NSString stringWithUTF8String:text];
        if (string == nil) return false;
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        return [pasteboard setString:string forType:NSPasteboardTypeString];
    }
}

char *phantty_macos_clipboard_copy_text(void) {
    @autoreleasepool {
        NSString *string = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
        return phantty_macos_copy_nsstring(string);
    }
}

void phantty_macos_cursor_set(uint32_t shape) {
    @autoreleasepool {
        switch (shape) {
            case 1: [[NSCursor IBeamCursor] set]; break;
            case 2: [[NSCursor resizeLeftRightCursor] set]; break;
            case 3: [[NSCursor resizeUpDownCursor] set]; break;
            case 4: [[NSCursor openHandCursor] set]; break;
            default: [[NSCursor arrowCursor] set]; break;
        }
    }
}

void phantty_macos_notification_bell(void) {
    NSBeep();
}

void phantty_macos_notification_request_attention(void *window_handle) {
    (void)window_handle;
    @autoreleasepool {
        [[NSApplication sharedApplication] requestUserAttention:NSInformationalRequest];
    }
}

bool phantty_macos_display_point_on_any_screen(int32_t x, int32_t y) {
    @autoreleasepool {
        NSPoint point = NSMakePoint(x, y);
        for (NSScreen *screen in [NSScreen screens]) {
            if (NSPointInRect(point, [screen frame])) return true;
        }
        return false;
    }
}

int32_t phantty_macos_text_case_insensitive_equal(const char *a, const char *b) {
    @autoreleasepool {
        if (a == NULL || b == NULL) return -1;
        NSString *lhs = [NSString stringWithUTF8String:a];
        NSString *rhs = [NSString stringWithUTF8String:b];
        if (lhs == nil || rhs == nil) return -1;
        return [lhs caseInsensitiveCompare:rhs] == NSOrderedSame ? 1 : 0;
    }
}

bool phantty_macos_workspace_open_url(const char *url) {
    @autoreleasepool {
        if (url == NULL) return false;
        NSString *string = [NSString stringWithUTF8String:url];
        if (string == nil) return false;
        NSURL *ns_url = [NSURL URLWithString:string];
        if (ns_url == nil) return false;
        return [[NSWorkspace sharedWorkspace] openURL:ns_url];
    }
}

bool phantty_macos_workspace_open_path(const char *path, bool reveal) {
    @autoreleasepool {
        if (path == NULL) return false;
        NSString *string = [NSString stringWithUTF8String:path];
        if (string == nil) return false;
        NSURL *url = [NSURL fileURLWithPath:string];
        if (url == nil) return false;
        if (reveal) {
            [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
            return true;
        }
        return [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

static uint32_t phantty_macos_carbon_modifiers(uint32_t modifiers) {
    uint32_t out = 0;
    if ((modifiers & 0x0001) != 0) out |= optionKey;
    if ((modifiers & 0x0002) != 0) out |= controlKey;
    if ((modifiers & 0x0004) != 0) out |= shiftKey;
    if ((modifiers & 0x0008) != 0) out |= cmdKey;
    return out;
}

static bool phantty_macos_carbon_key_code(uint32_t key_code, UInt32 *out) {
    if (out == NULL) return false;

    switch (key_code) {
        case 'A': case 'a': *out = kVK_ANSI_A; return true;
        case 'B': case 'b': *out = kVK_ANSI_B; return true;
        case 'C': case 'c': *out = kVK_ANSI_C; return true;
        case 'D': case 'd': *out = kVK_ANSI_D; return true;
        case 'E': case 'e': *out = kVK_ANSI_E; return true;
        case 'F': case 'f': *out = kVK_ANSI_F; return true;
        case 'G': case 'g': *out = kVK_ANSI_G; return true;
        case 'H': case 'h': *out = kVK_ANSI_H; return true;
        case 'I': case 'i': *out = kVK_ANSI_I; return true;
        case 'J': case 'j': *out = kVK_ANSI_J; return true;
        case 'K': case 'k': *out = kVK_ANSI_K; return true;
        case 'L': case 'l': *out = kVK_ANSI_L; return true;
        case 'M': case 'm': *out = kVK_ANSI_M; return true;
        case 'N': case 'n': *out = kVK_ANSI_N; return true;
        case 'O': case 'o': *out = kVK_ANSI_O; return true;
        case 'P': case 'p': *out = kVK_ANSI_P; return true;
        case 'Q': case 'q': *out = kVK_ANSI_Q; return true;
        case 'R': case 'r': *out = kVK_ANSI_R; return true;
        case 'S': case 's': *out = kVK_ANSI_S; return true;
        case 'T': case 't': *out = kVK_ANSI_T; return true;
        case 'U': case 'u': *out = kVK_ANSI_U; return true;
        case 'V': case 'v': *out = kVK_ANSI_V; return true;
        case 'W': case 'w': *out = kVK_ANSI_W; return true;
        case 'X': case 'x': *out = kVK_ANSI_X; return true;
        case 'Y': case 'y': *out = kVK_ANSI_Y; return true;
        case 'Z': case 'z': *out = kVK_ANSI_Z; return true;
        case '0': *out = kVK_ANSI_0; return true;
        case '1': *out = kVK_ANSI_1; return true;
        case '2': *out = kVK_ANSI_2; return true;
        case '3': *out = kVK_ANSI_3; return true;
        case '4': *out = kVK_ANSI_4; return true;
        case '5': *out = kVK_ANSI_5; return true;
        case '6': *out = kVK_ANSI_6; return true;
        case '7': *out = kVK_ANSI_7; return true;
        case '8': *out = kVK_ANSI_8; return true;
        case '9': *out = kVK_ANSI_9; return true;
        case 0x08: *out = kVK_Delete; return true;
        case 0x09: *out = kVK_Tab; return true;
        case 0x0D: *out = kVK_Return; return true;
        case 0x1B: *out = kVK_Escape; return true;
        case 0x20: *out = kVK_Space; return true;
        case 0x21: *out = kVK_PageUp; return true;
        case 0x22: *out = kVK_PageDown; return true;
        case 0x23: *out = kVK_End; return true;
        case 0x24: *out = kVK_Home; return true;
        case 0x25: *out = kVK_LeftArrow; return true;
        case 0x26: *out = kVK_UpArrow; return true;
        case 0x27: *out = kVK_RightArrow; return true;
        case 0x28: *out = kVK_DownArrow; return true;
        case 0x2D: *out = kVK_Help; return true;
        case 0x2E: *out = kVK_ForwardDelete; return true;
        case 0xBB: *out = kVK_ANSI_Equal; return true;
        case 0xBC: *out = kVK_ANSI_Comma; return true;
        case 0xBD: *out = kVK_ANSI_Minus; return true;
        case 0xC0: *out = kVK_ANSI_Grave; return true;
        case 0xDB: *out = kVK_ANSI_LeftBracket; return true;
        case 0xDD: *out = kVK_ANSI_RightBracket; return true;
        default: break;
    }

    if (key_code >= 0x70 && key_code <= 0x83) {
        static const UInt32 function_keys[] = {
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5,
            kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
            kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        };
        *out = function_keys[key_code - 0x70];
        return true;
    }

    return false;
}

bool phantty_macos_global_hotkey_translate(uint32_t modifiers, uint32_t key_code, uint32_t *out_modifiers, uint32_t *out_key_code) {
    UInt32 carbon_key = 0;
    if (!phantty_macos_carbon_key_code(key_code, &carbon_key)) return false;
    if (out_modifiers != NULL) *out_modifiers = phantty_macos_carbon_modifiers(modifiers);
    if (out_key_code != NULL) *out_key_code = carbon_key;
    return true;
}

static PhanttyMacHotkeySlot *phantty_macos_hotkey_slot_for_id(int32_t id) {
    for (size_t i = 0; i < sizeof(phantty_macos_hotkey_slots) / sizeof(phantty_macos_hotkey_slots[0]); i++) {
        if (phantty_macos_hotkey_slots[i].ref != NULL && phantty_macos_hotkey_slots[i].id == id) {
            return &phantty_macos_hotkey_slots[i];
        }
    }
    return NULL;
}

static PhanttyMacHotkeySlot *phantty_macos_empty_hotkey_slot(void) {
    for (size_t i = 0; i < sizeof(phantty_macos_hotkey_slots) / sizeof(phantty_macos_hotkey_slots[0]); i++) {
        if (phantty_macos_hotkey_slots[i].ref == NULL) return &phantty_macos_hotkey_slots[i];
    }
    return NULL;
}

static OSStatus phantty_macos_hotkey_handler(EventHandlerCallRef next_handler, EventRef event, void *context) {
    (void)next_handler;
    (void)context;

    EventHotKeyID hotkey_id = {0};
    OSStatus status = GetEventParameter(
        event,
        kEventParamDirectObject,
        typeEventHotKeyID,
        NULL,
        sizeof(hotkey_id),
        NULL,
        &hotkey_id
    );
    if (status != noErr || hotkey_id.signature != phantty_macos_hotkey_signature) return eventNotHandledErr;

    PhanttyMacHotkeySlot *slot = phantty_macos_hotkey_slot_for_id((int32_t)hotkey_id.id);
    if (slot == NULL) return eventNotHandledErr;

    if (phantty_macos_window_post_message != NULL && slot->window_handle != NULL) {
        phantty_macos_window_post_message(
            slot->window_handle,
            phantty_macos_hotkey_message,
            (uintptr_t)slot->id,
            0
        );
    }
    return noErr;
}

static bool phantty_macos_install_hotkey_handler(void) {
    if (phantty_macos_hotkey_handler_ref != NULL) return true;

    EventTypeSpec event_type = { .eventClass = kEventClassKeyboard, .eventKind = kEventHotKeyPressed };
    OSStatus status = InstallApplicationEventHandler(
        &phantty_macos_hotkey_handler,
        1,
        &event_type,
        NULL,
        &phantty_macos_hotkey_handler_ref
    );
    return status == noErr;
}

char *phantty_macos_open_file_dialog(const char *title) {
    @autoreleasepool {
        NSOpenPanel *panel = [NSOpenPanel openPanel];
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = NO;
        if (title != NULL) panel.title = [NSString stringWithUTF8String:title];
        if ([panel runModal] != NSModalResponseOK) return NULL;
        return phantty_macos_copy_nsstring(panel.URL.path);
    }
}

char *phantty_macos_save_file_dialog(const char *title, const char *initial_dir, const char *default_filename) {
    @autoreleasepool {
        NSSavePanel *panel = [NSSavePanel savePanel];
        if (title != NULL) panel.title = [NSString stringWithUTF8String:title];
        if (initial_dir != NULL) {
            NSString *dir = [NSString stringWithUTF8String:initial_dir];
            if (dir != nil) panel.directoryURL = [NSURL fileURLWithPath:dir];
        }
        if (default_filename != NULL) panel.nameFieldStringValue = [NSString stringWithUTF8String:default_filename];
        if ([panel runModal] != NSModalResponseOK) return NULL;
        return phantty_macos_copy_nsstring(panel.URL.path);
    }
}

bool phantty_macos_global_hotkey_register(void *window_handle, int32_t id, uint32_t modifiers, uint32_t key_code) {
    @autoreleasepool {
        if (window_handle == NULL) return false;
        UInt32 carbon_modifiers = 0;
        UInt32 carbon_key = 0;
        if (!phantty_macos_global_hotkey_translate(modifiers, key_code, &carbon_modifiers, &carbon_key)) return false;
        if (!phantty_macos_install_hotkey_handler()) return false;

        phantty_macos_global_hotkey_unregister(window_handle, id);
        PhanttyMacHotkeySlot *slot = phantty_macos_empty_hotkey_slot();
        if (slot == NULL) return false;

        EventHotKeyID hotkey_id = {
            .signature = phantty_macos_hotkey_signature,
            .id = (UInt32)id,
        };
        EventHotKeyRef ref = NULL;
        OSStatus status = RegisterEventHotKey(
            carbon_key,
            carbon_modifiers,
            hotkey_id,
            GetApplicationEventTarget(),
            0,
            &ref
        );
        if (status != noErr || ref == NULL) return false;

        slot->id = id;
        slot->window_handle = window_handle;
        slot->ref = ref;
        return true;
    }
}

void phantty_macos_global_hotkey_unregister(void *window_handle, int32_t id) {
    (void)window_handle;
    PhanttyMacHotkeySlot *slot = phantty_macos_hotkey_slot_for_id(id);
    if (slot == NULL) return;
    UnregisterEventHotKey(slot->ref);
    slot->id = 0;
    slot->window_handle = NULL;
    slot->ref = NULL;
}
