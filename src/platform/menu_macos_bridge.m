// Programmatic macOS NSMenu for WispTerm.
//
// The Zig side drives the menu structure: it calls `menu_begin`, `menu_add`,
// `menu_add_separator`, `menu_end_submenu`, and finally `menu_finalize` to
// publish the constructed NSMenu via `[NSApp setMainMenu:]`. When an item is
// clicked, the registered action callback is invoked with the Zig-supplied
// integer action id so the dispatcher can route to the right
// keybind.Action.
//
// Modifier-mask bits accepted by `wispterm_macos_menu_add_item` mirror
// NSEventModifierFlag* constants and are listed in WispTermMacMenuMod below so
// the Zig side can stay AppKit-agnostic.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

// Modifier bitmask values exposed to Zig. The numeric values are stable and
// don't depend on NSEventModifierFlag* internals — the bridge translates.
//   WISPTERM_MAC_MENU_MOD_NONE  = 0
//   WISPTERM_MAC_MENU_MOD_CMD   = 1 << 0
//   WISPTERM_MAC_MENU_MOD_SHIFT = 1 << 1
//   WISPTERM_MAC_MENU_MOD_OPT   = 1 << 2
//   WISPTERM_MAC_MENU_MOD_CTRL  = 1 << 3
#define WISPTERM_MAC_MENU_MOD_CMD   (1 << 0)
#define WISPTERM_MAC_MENU_MOD_SHIFT (1 << 1)
#define WISPTERM_MAC_MENU_MOD_OPT   (1 << 2)
#define WISPTERM_MAC_MENU_MOD_CTRL  (1 << 3)

// Sentinel action id meaning "no WispTerm action" (separator, system-provided).
#define WISPTERM_MAC_MENU_ACTION_NONE (-1)

// System-action ids (negative values reserved by the bridge).
#define WISPTERM_MAC_MENU_SYSTEM_ABOUT      (-2)
#define WISPTERM_MAC_MENU_SYSTEM_HIDE       (-3)
#define WISPTERM_MAC_MENU_SYSTEM_HIDE_OTHER (-4)
#define WISPTERM_MAC_MENU_SYSTEM_SHOW_ALL   (-5)
#define WISPTERM_MAC_MENU_SYSTEM_QUIT       (-6)

typedef void (*WispTermMacMenuActionCallback)(int32_t action_id);

void wispterm_macos_menu_install(WispTermMacMenuActionCallback callback);
void wispterm_macos_menu_begin(void);
void wispterm_macos_menu_begin_submenu(const char *title);
void wispterm_macos_menu_add_item(
    const char *title,
    int32_t action_id,
    const char *key_equivalent,
    uint32_t modifier_mask
);
void wispterm_macos_menu_add_separator(void);
void wispterm_macos_menu_end_submenu(void);
void wispterm_macos_menu_finalize(void);
bool wispterm_macos_menu_is_installed(void);
bool wispterm_macos_menu_perform_system_key_equivalent(NSEvent *event);
int32_t wispterm_macos_menu_system_action_for_key_for_test(const char *characters, uint32_t modifier_mask);
int32_t wispterm_macos_menu_top_level_count_for_test(void);
int32_t wispterm_macos_menu_item_count_for_test(int32_t menu_index);
int32_t wispterm_macos_menu_item_action_for_test(int32_t menu_index, int32_t item_index);
const char *wispterm_macos_menu_item_title_for_test(int32_t menu_index, int32_t item_index);
uint32_t wispterm_macos_menu_item_modifier_for_test(int32_t menu_index, int32_t item_index);
const char *wispterm_macos_menu_item_key_equivalent_for_test(int32_t menu_index, int32_t item_index);
void wispterm_macos_menu_invoke_for_test(int32_t menu_index, int32_t item_index);

static WispTermMacMenuActionCallback g_action_callback = NULL;

@interface WispTermMacMenuTarget : NSObject
- (void)invokeWispTermAction:(id)sender;
@end

@implementation WispTermMacMenuTarget
- (void)invokeWispTermAction:(id)sender {
    if (g_action_callback == NULL) return;
    if (![sender isKindOfClass:[NSMenuItem class]]) return;
    NSMenuItem *item = (NSMenuItem *)sender;
    int32_t action_id = (int32_t)item.tag;
    if (action_id == WISPTERM_MAC_MENU_ACTION_NONE) return;
    if (action_id < 0) {
        // System-action ids resolved by AppKit selectors; fall through.
        return;
    }
    g_action_callback(action_id);
}
@end

static WispTermMacMenuTarget *g_menu_target = nil;
static NSMenu *g_main_menu = nil;          // installed (live) menu
static NSMenu *g_building_menu = nil;      // menu currently being built
static NSMenu *g_building_submenu = nil;   // active submenu inside build

static NSEventModifierFlags wispterm_macos_translate_mods(uint32_t mask) {
    NSEventModifierFlags flags = 0;
    if (mask & WISPTERM_MAC_MENU_MOD_CMD) flags |= NSEventModifierFlagCommand;
    if (mask & WISPTERM_MAC_MENU_MOD_SHIFT) flags |= NSEventModifierFlagShift;
    if (mask & WISPTERM_MAC_MENU_MOD_OPT) flags |= NSEventModifierFlagOption;
    if (mask & WISPTERM_MAC_MENU_MOD_CTRL) flags |= NSEventModifierFlagControl;
    return flags;
}

static SEL wispterm_macos_system_selector(int32_t action_id) {
    switch (action_id) {
        case WISPTERM_MAC_MENU_SYSTEM_ABOUT: return @selector(orderFrontStandardAboutPanel:);
        case WISPTERM_MAC_MENU_SYSTEM_HIDE: return @selector(hide:);
        case WISPTERM_MAC_MENU_SYSTEM_HIDE_OTHER: return @selector(hideOtherApplications:);
        case WISPTERM_MAC_MENU_SYSTEM_SHOW_ALL: return @selector(unhideAllApplications:);
        case WISPTERM_MAC_MENU_SYSTEM_QUIT: return @selector(terminate:);
        default: return (SEL)0;
    }
}

void wispterm_macos_menu_install(WispTermMacMenuActionCallback callback) {
    g_action_callback = callback;
    @autoreleasepool {
        if (g_menu_target == nil) {
            g_menu_target = [[WispTermMacMenuTarget alloc] init];
        }
    }
}

void wispterm_macos_menu_begin(void) {
    @autoreleasepool {
        if (g_building_menu != nil) {
            [g_building_menu release];
            g_building_menu = nil;
        }
        g_building_submenu = nil;
        g_building_menu = [[NSMenu alloc] initWithTitle:@""];
    }
}

void wispterm_macos_menu_begin_submenu(const char *title) {
    @autoreleasepool {
        if (g_building_menu == nil) return;
        NSString *title_ns = title != NULL ? [NSString stringWithUTF8String:title] : @"";
        NSMenuItem *holder = [[NSMenuItem alloc] init];
        NSMenu *sub = [[NSMenu alloc] initWithTitle:title_ns];
        [holder setSubmenu:sub];
        [g_building_menu addItem:holder];
        if (g_building_submenu != nil) {
            [g_building_submenu release];
        }
        g_building_submenu = sub; // retained by holder; we keep a strong ref too
        [g_building_submenu retain];
        [holder release];
    }
}

void wispterm_macos_menu_add_item(
    const char *title,
    int32_t action_id,
    const char *key_equivalent,
    uint32_t modifier_mask
) {
    @autoreleasepool {
        if (g_building_submenu == nil) return;
        NSString *title_ns = title != NULL ? [NSString stringWithUTF8String:title] : @"";
        NSString *key_ns = (key_equivalent != NULL && key_equivalent[0] != '\0')
            ? [NSString stringWithUTF8String:key_equivalent]
            : @"";
        SEL action_sel;
        if (action_id < 0) {
            action_sel = wispterm_macos_system_selector(action_id);
            if (action_sel == (SEL)0) action_sel = @selector(invokeWispTermAction:);
        } else {
            action_sel = @selector(invokeWispTermAction:);
        }
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:title_ns
                   action:action_sel
            keyEquivalent:key_ns];
        if (action_id >= 0) [item setTarget:g_menu_target];
        [item setTag:(NSInteger)action_id];
        if (key_ns.length > 0) {
            [item setKeyEquivalentModifierMask:wispterm_macos_translate_mods(modifier_mask)];
        }
        [g_building_submenu addItem:item];
        [item release];
    }
}

void wispterm_macos_menu_add_separator(void) {
    if (g_building_submenu == nil) return;
    @autoreleasepool {
        [g_building_submenu addItem:[NSMenuItem separatorItem]];
    }
}

void wispterm_macos_menu_end_submenu(void) {
    @autoreleasepool {
        if (g_building_submenu != nil) {
            [g_building_submenu release];
            g_building_submenu = nil;
        }
    }
}

void wispterm_macos_menu_finalize(void) {
    @autoreleasepool {
        if (g_building_menu == nil) return;
        if (g_building_submenu != nil) {
            [g_building_submenu release];
            g_building_submenu = nil;
        }
        if (g_main_menu != nil) {
            [g_main_menu release];
            g_main_menu = nil;
        }
        g_main_menu = g_building_menu;
        g_building_menu = nil;
        if (NSApp != nil) [NSApp setMainMenu:g_main_menu];
    }
}

bool wispterm_macos_menu_is_installed(void) {
    return g_main_menu != nil;
}

// ---------------------------------------------------------------------------
// System key equivalents (⌘Q Quit, ⌘H Hide, ⌥⌘H Hide Others).
//
// The terminal content view claims every ⌘ key in -performKeyEquivalent: so
// the zig keybinds see them, and AppKit only offers a key equivalent to the
// main menu after the key window's views decline it. The system items carry
// no WispTerm action, so ⌘Q reached zig, matched no binding and was dropped —
// it only quit while a menu was open, because the menu's own tracking loop
// handled it. The content view asks this helper first instead.
//
// Ghostty (SurfaceView_AppKit.swift, performKeyEquivalent) declines every ⌘
// key that is not a Ghostty binding so the main menu handles Quit/Hide, then
// re-dispatches the unclaimed ones for encoding. That needs a synchronous
// keyIsBinding query, but WispTerm's keybind set is threadlocal to each
// AppWindow thread, so the bridge cannot ask from the main thread. Matching
// only the items AppKit itself performs gives the same result for these keys
// while leaving every other ⌘ shortcut on the zig keybind path.
// ---------------------------------------------------------------------------

static const NSEventModifierFlags wispterm_macos_menu_key_mods =
    NSEventModifierFlagCommand | NSEventModifierFlagShift |
    NSEventModifierFlagOption | NSEventModifierFlagControl;

static bool wispterm_macos_menu_is_system_action(int32_t action_id) {
    return action_id < WISPTERM_MAC_MENU_ACTION_NONE;
}

static bool wispterm_macos_menu_item_matches_key(NSMenuItem *item, NSEvent *event) {
    NSString *key = item.keyEquivalent.lowercaseString;
    if (key.length == 0) return false;
    // An uppercase key equivalent implies Shift, as it does for AppKit.
    NSEventModifierFlags item_mods = item.keyEquivalentModifierMask & wispterm_macos_menu_key_mods;
    if (![item.keyEquivalent isEqualToString:key]) item_mods |= NSEventModifierFlagShift;
    if ((event.modifierFlags & wispterm_macos_menu_key_mods) != item_mods) return false;
    // charactersIgnoringModifiers drops Option (⌥⌘H reports "h", not "˙");
    // characters covers the "… – QWERTY ⌘" layouts that switch to QWERTY
    // only while ⌘ is held.
    return [event.charactersIgnoringModifiers.lowercaseString isEqualToString:key] ||
        [event.characters.lowercaseString isEqualToString:key];
}

static NSMenuItem *wispterm_macos_menu_system_item_for_event(NSMenu *menu, NSEvent *event) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.hasSubmenu) {
            NSMenuItem *found = wispterm_macos_menu_system_item_for_event(item.submenu, event);
            if (found != nil) return found;
            continue;
        }
        if (!wispterm_macos_menu_is_system_action((int32_t)item.tag)) continue;
        if (wispterm_macos_menu_item_matches_key(item, event)) return item;
    }
    return nil;
}

bool wispterm_macos_menu_perform_system_key_equivalent(NSEvent *event) {
    if (event == nil || g_main_menu == nil) return false;
    @autoreleasepool {
        if (event.type != NSEventTypeKeyDown) return false;
        NSMenuItem *item = wispterm_macos_menu_system_item_for_event(g_main_menu, event);
        if (item == nil || !item.isEnabled) return false;
        // Nil target: the responder chain ends at NSApp, which implements
        // terminate: / hide: / hideOtherApplications:.
        return [NSApp sendAction:item.action to:item.target from:item] ? true : false;
    }
}

int32_t wispterm_macos_menu_top_level_count_for_test(void) {
    if (g_main_menu == nil) return -1;
    return (int32_t)g_main_menu.numberOfItems;
}

// The *_for_test helpers below sit outside any AppKit event dispatch, so each
// opens its own pool. Returned strings are copied into a per-thread buffer
// (valid until the next call on that thread) because a -UTF8String pointer
// dies with the pool that owns it.
static _Thread_local char g_menu_test_string[512];

static const char *wispterm_macos_menu_copy_test_string(NSString *string) {
    if (string == nil) return NULL;
    const char *utf8 = [string UTF8String];
    if (utf8 == NULL) return NULL;
    strlcpy(g_menu_test_string, utf8, sizeof(g_menu_test_string));
    return g_menu_test_string;
}

static NSMenuItem *wispterm_macos_menu_test_item(int32_t menu_index, int32_t item_index) {
    if (g_main_menu == nil) return nil;
    if (menu_index < 0 || menu_index >= (int32_t)g_main_menu.numberOfItems) return nil;
    NSMenu *sub = [g_main_menu itemAtIndex:menu_index].submenu;
    if (sub == nil) return nil;
    if (item_index < 0 || item_index >= (int32_t)sub.numberOfItems) return nil;
    return [sub itemAtIndex:item_index];
}

int32_t wispterm_macos_menu_item_count_for_test(int32_t menu_index) {
    if (g_main_menu == nil) return -1;
    if (menu_index < 0 || menu_index >= (int32_t)g_main_menu.numberOfItems) return -1;
    @autoreleasepool {
        NSMenu *sub = [g_main_menu itemAtIndex:menu_index].submenu;
        if (sub == nil) return -1;
        return (int32_t)sub.numberOfItems;
    }
}

int32_t wispterm_macos_menu_item_action_for_test(int32_t menu_index, int32_t item_index) {
    @autoreleasepool {
        NSMenuItem *item = wispterm_macos_menu_test_item(menu_index, item_index);
        if (item == nil || item.isSeparatorItem) return WISPTERM_MAC_MENU_ACTION_NONE;
        return (int32_t)item.tag;
    }
}

const char *wispterm_macos_menu_item_title_for_test(int32_t menu_index, int32_t item_index) {
    @autoreleasepool {
        NSMenuItem *item = wispterm_macos_menu_test_item(menu_index, item_index);
        if (item == nil) return NULL;
        return wispterm_macos_menu_copy_test_string(item.title);
    }
}

uint32_t wispterm_macos_menu_item_modifier_for_test(int32_t menu_index, int32_t item_index) {
    @autoreleasepool {
        NSMenuItem *item = wispterm_macos_menu_test_item(menu_index, item_index);
        if (item == nil) return 0;
        NSEventModifierFlags flags = item.keyEquivalentModifierMask;
        uint32_t out = 0;
        if (flags & NSEventModifierFlagCommand) out |= WISPTERM_MAC_MENU_MOD_CMD;
        if (flags & NSEventModifierFlagShift) out |= WISPTERM_MAC_MENU_MOD_SHIFT;
        if (flags & NSEventModifierFlagOption) out |= WISPTERM_MAC_MENU_MOD_OPT;
        if (flags & NSEventModifierFlagControl) out |= WISPTERM_MAC_MENU_MOD_CTRL;
        return out;
    }
}

const char *wispterm_macos_menu_item_key_equivalent_for_test(int32_t menu_index, int32_t item_index) {
    @autoreleasepool {
        NSMenuItem *item = wispterm_macos_menu_test_item(menu_index, item_index);
        if (item == nil) return NULL;
        return wispterm_macos_menu_copy_test_string(item.keyEquivalent);
    }
}

// Matches a synthetic key-down against the system items without performing
// it (performing ⌘Q would terminate the test runner). Returns the matched
// item's system action id, or WISPTERM_MAC_MENU_ACTION_NONE.
int32_t wispterm_macos_menu_system_action_for_key_for_test(const char *characters, uint32_t modifier_mask) {
    if (g_main_menu == nil || characters == NULL) return WISPTERM_MAC_MENU_ACTION_NONE;
    @autoreleasepool {
        NSString *chars = [NSString stringWithUTF8String:characters];
        NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                          location:NSZeroPoint
                                     modifierFlags:wispterm_macos_translate_mods(modifier_mask)
                                         timestamp:0
                                      windowNumber:0
                                           context:nil
                                        characters:chars
                       charactersIgnoringModifiers:chars
                                         isARepeat:NO
                                           keyCode:0];
        NSMenuItem *item = wispterm_macos_menu_system_item_for_event(g_main_menu, event);
        return item != nil ? (int32_t)item.tag : WISPTERM_MAC_MENU_ACTION_NONE;
    }
}

void wispterm_macos_menu_invoke_for_test(int32_t menu_index, int32_t item_index) {
    @autoreleasepool {
        NSMenuItem *item = wispterm_macos_menu_test_item(menu_index, item_index);
        if (item == nil) return;
        if (item.tag < 0) return; // system items are AppKit-driven; tests skip
        [g_menu_target invokeWispTermAction:item];
    }
}
