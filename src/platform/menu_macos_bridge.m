// Programmatic macOS NSMenu for Phantty.
//
// The Zig side drives the menu structure: it calls `menu_begin`, `menu_add`,
// `menu_add_separator`, `menu_end_submenu`, and finally `menu_finalize` to
// publish the constructed NSMenu via `[NSApp setMainMenu:]`. When an item is
// clicked, the registered action callback is invoked with the Zig-supplied
// integer action id so the dispatcher can route to the right
// keybind.Action.
//
// Modifier-mask bits accepted by `phantty_macos_menu_add_item` mirror
// NSEventModifierFlag* constants and are listed in PhanttyMacMenuMod below so
// the Zig side can stay AppKit-agnostic.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

// Modifier bitmask values exposed to Zig. The numeric values are stable and
// don't depend on NSEventModifierFlag* internals — the bridge translates.
//   PHANTTY_MAC_MENU_MOD_NONE  = 0
//   PHANTTY_MAC_MENU_MOD_CMD   = 1 << 0
//   PHANTTY_MAC_MENU_MOD_SHIFT = 1 << 1
//   PHANTTY_MAC_MENU_MOD_OPT   = 1 << 2
//   PHANTTY_MAC_MENU_MOD_CTRL  = 1 << 3
#define PHANTTY_MAC_MENU_MOD_CMD   (1 << 0)
#define PHANTTY_MAC_MENU_MOD_SHIFT (1 << 1)
#define PHANTTY_MAC_MENU_MOD_OPT   (1 << 2)
#define PHANTTY_MAC_MENU_MOD_CTRL  (1 << 3)

// Sentinel action id meaning "no Phantty action" (separator, system-provided).
#define PHANTTY_MAC_MENU_ACTION_NONE (-1)

// System-action ids (negative values reserved by the bridge).
#define PHANTTY_MAC_MENU_SYSTEM_ABOUT      (-2)
#define PHANTTY_MAC_MENU_SYSTEM_HIDE       (-3)
#define PHANTTY_MAC_MENU_SYSTEM_HIDE_OTHER (-4)
#define PHANTTY_MAC_MENU_SYSTEM_SHOW_ALL   (-5)
#define PHANTTY_MAC_MENU_SYSTEM_QUIT       (-6)

typedef void (*PhanttyMacMenuActionCallback)(int32_t action_id);

void phantty_macos_menu_install(PhanttyMacMenuActionCallback callback);
void phantty_macos_menu_begin(void);
void phantty_macos_menu_begin_submenu(const char *title);
void phantty_macos_menu_add_item(
    const char *title,
    int32_t action_id,
    const char *key_equivalent,
    uint32_t modifier_mask
);
void phantty_macos_menu_add_separator(void);
void phantty_macos_menu_end_submenu(void);
void phantty_macos_menu_finalize(void);
bool phantty_macos_menu_is_installed(void);
int32_t phantty_macos_menu_top_level_count_for_test(void);
int32_t phantty_macos_menu_item_count_for_test(int32_t menu_index);
int32_t phantty_macos_menu_item_action_for_test(int32_t menu_index, int32_t item_index);
const char *phantty_macos_menu_item_title_for_test(int32_t menu_index, int32_t item_index);
uint32_t phantty_macos_menu_item_modifier_for_test(int32_t menu_index, int32_t item_index);
const char *phantty_macos_menu_item_key_equivalent_for_test(int32_t menu_index, int32_t item_index);
void phantty_macos_menu_invoke_for_test(int32_t menu_index, int32_t item_index);

static PhanttyMacMenuActionCallback g_action_callback = NULL;

@interface PhanttyMacMenuTarget : NSObject
- (void)invokePhanttyAction:(id)sender;
@end

@implementation PhanttyMacMenuTarget
- (void)invokePhanttyAction:(id)sender {
    if (g_action_callback == NULL) return;
    if (![sender isKindOfClass:[NSMenuItem class]]) return;
    NSMenuItem *item = (NSMenuItem *)sender;
    int32_t action_id = (int32_t)item.tag;
    if (action_id == PHANTTY_MAC_MENU_ACTION_NONE) return;
    if (action_id < 0) {
        // System-action ids resolved by AppKit selectors; fall through.
        return;
    }
    g_action_callback(action_id);
}
@end

static PhanttyMacMenuTarget *g_menu_target = nil;
static NSMenu *g_main_menu = nil;          // installed (live) menu
static NSMenu *g_building_menu = nil;      // menu currently being built
static NSMenu *g_building_submenu = nil;   // active submenu inside build

static NSEventModifierFlags phantty_macos_translate_mods(uint32_t mask) {
    NSEventModifierFlags flags = 0;
    if (mask & PHANTTY_MAC_MENU_MOD_CMD) flags |= NSEventModifierFlagCommand;
    if (mask & PHANTTY_MAC_MENU_MOD_SHIFT) flags |= NSEventModifierFlagShift;
    if (mask & PHANTTY_MAC_MENU_MOD_OPT) flags |= NSEventModifierFlagOption;
    if (mask & PHANTTY_MAC_MENU_MOD_CTRL) flags |= NSEventModifierFlagControl;
    return flags;
}

static SEL phantty_macos_system_selector(int32_t action_id) {
    switch (action_id) {
        case PHANTTY_MAC_MENU_SYSTEM_ABOUT: return @selector(orderFrontStandardAboutPanel:);
        case PHANTTY_MAC_MENU_SYSTEM_HIDE: return @selector(hide:);
        case PHANTTY_MAC_MENU_SYSTEM_HIDE_OTHER: return @selector(hideOtherApplications:);
        case PHANTTY_MAC_MENU_SYSTEM_SHOW_ALL: return @selector(unhideAllApplications:);
        case PHANTTY_MAC_MENU_SYSTEM_QUIT: return @selector(terminate:);
        default: return (SEL)0;
    }
}

void phantty_macos_menu_install(PhanttyMacMenuActionCallback callback) {
    g_action_callback = callback;
    if (g_menu_target == nil) {
        g_menu_target = [[PhanttyMacMenuTarget alloc] init];
    }
}

void phantty_macos_menu_begin(void) {
    @autoreleasepool {
        if (g_building_menu != nil) {
            [g_building_menu release];
            g_building_menu = nil;
        }
        g_building_submenu = nil;
        g_building_menu = [[NSMenu alloc] initWithTitle:@""];
    }
}

void phantty_macos_menu_begin_submenu(const char *title) {
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

void phantty_macos_menu_add_item(
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
            action_sel = phantty_macos_system_selector(action_id);
            if (action_sel == (SEL)0) action_sel = @selector(invokePhanttyAction:);
        } else {
            action_sel = @selector(invokePhanttyAction:);
        }
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:title_ns
                   action:action_sel
            keyEquivalent:key_ns];
        if (action_id >= 0) [item setTarget:g_menu_target];
        [item setTag:(NSInteger)action_id];
        if (key_ns.length > 0) {
            [item setKeyEquivalentModifierMask:phantty_macos_translate_mods(modifier_mask)];
        }
        [g_building_submenu addItem:item];
        [item release];
    }
}

void phantty_macos_menu_add_separator(void) {
    if (g_building_submenu == nil) return;
    [g_building_submenu addItem:[NSMenuItem separatorItem]];
}

void phantty_macos_menu_end_submenu(void) {
    if (g_building_submenu != nil) {
        [g_building_submenu release];
        g_building_submenu = nil;
    }
}

void phantty_macos_menu_finalize(void) {
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

bool phantty_macos_menu_is_installed(void) {
    return g_main_menu != nil;
}

int32_t phantty_macos_menu_top_level_count_for_test(void) {
    if (g_main_menu == nil) return -1;
    return (int32_t)g_main_menu.numberOfItems;
}

int32_t phantty_macos_menu_item_count_for_test(int32_t menu_index) {
    if (g_main_menu == nil) return -1;
    if (menu_index < 0 || menu_index >= (int32_t)g_main_menu.numberOfItems) return -1;
    NSMenu *sub = [g_main_menu itemAtIndex:menu_index].submenu;
    if (sub == nil) return -1;
    return (int32_t)sub.numberOfItems;
}

int32_t phantty_macos_menu_item_action_for_test(int32_t menu_index, int32_t item_index) {
    if (g_main_menu == nil) return PHANTTY_MAC_MENU_ACTION_NONE;
    if (menu_index < 0 || menu_index >= (int32_t)g_main_menu.numberOfItems) return PHANTTY_MAC_MENU_ACTION_NONE;
    NSMenu *sub = [g_main_menu itemAtIndex:menu_index].submenu;
    if (sub == nil) return PHANTTY_MAC_MENU_ACTION_NONE;
    if (item_index < 0 || item_index >= (int32_t)sub.numberOfItems) return PHANTTY_MAC_MENU_ACTION_NONE;
    NSMenuItem *item = [sub itemAtIndex:item_index];
    if (item.isSeparatorItem) return PHANTTY_MAC_MENU_ACTION_NONE;
    return (int32_t)item.tag;
}

const char *phantty_macos_menu_item_title_for_test(int32_t menu_index, int32_t item_index) {
    if (g_main_menu == nil) return NULL;
    if (menu_index < 0 || menu_index >= (int32_t)g_main_menu.numberOfItems) return NULL;
    NSMenu *sub = [g_main_menu itemAtIndex:menu_index].submenu;
    if (sub == nil) return NULL;
    if (item_index < 0 || item_index >= (int32_t)sub.numberOfItems) return NULL;
    return [[sub itemAtIndex:item_index].title UTF8String];
}

uint32_t phantty_macos_menu_item_modifier_for_test(int32_t menu_index, int32_t item_index) {
    if (g_main_menu == nil) return 0;
    if (menu_index < 0 || menu_index >= (int32_t)g_main_menu.numberOfItems) return 0;
    NSMenu *sub = [g_main_menu itemAtIndex:menu_index].submenu;
    if (sub == nil) return 0;
    if (item_index < 0 || item_index >= (int32_t)sub.numberOfItems) return 0;
    NSEventModifierFlags flags = [sub itemAtIndex:item_index].keyEquivalentModifierMask;
    uint32_t out = 0;
    if (flags & NSEventModifierFlagCommand) out |= PHANTTY_MAC_MENU_MOD_CMD;
    if (flags & NSEventModifierFlagShift) out |= PHANTTY_MAC_MENU_MOD_SHIFT;
    if (flags & NSEventModifierFlagOption) out |= PHANTTY_MAC_MENU_MOD_OPT;
    if (flags & NSEventModifierFlagControl) out |= PHANTTY_MAC_MENU_MOD_CTRL;
    return out;
}

const char *phantty_macos_menu_item_key_equivalent_for_test(int32_t menu_index, int32_t item_index) {
    if (g_main_menu == nil) return NULL;
    if (menu_index < 0 || menu_index >= (int32_t)g_main_menu.numberOfItems) return NULL;
    NSMenu *sub = [g_main_menu itemAtIndex:menu_index].submenu;
    if (sub == nil) return NULL;
    if (item_index < 0 || item_index >= (int32_t)sub.numberOfItems) return NULL;
    return [[sub itemAtIndex:item_index].keyEquivalent UTF8String];
}

void phantty_macos_menu_invoke_for_test(int32_t menu_index, int32_t item_index) {
    if (g_main_menu == nil) return;
    if (menu_index < 0 || menu_index >= (int32_t)g_main_menu.numberOfItems) return;
    NSMenu *sub = [g_main_menu itemAtIndex:menu_index].submenu;
    if (sub == nil) return;
    if (item_index < 0 || item_index >= (int32_t)sub.numberOfItems) return;
    NSMenuItem *item = [sub itemAtIndex:item_index];
    if (item.tag < 0) return; // system items are AppKit-driven; tests skip
    [g_menu_target invokePhanttyAction:item];
}
