#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <stdint.h>
#include <stdlib.h>

// Defined in window_macos_bridge.m — resolves a NativeHandle to its NSWindow.
extern void *wispterm_macos_window_ns_window(void *handle);

typedef struct WispTermMacWebView {
    WKWebView *webview;
    int32_t last_error;
} WispTermMacWebView;

// AppKit is main-thread only. The browser panel drives create/sync from the
// main UI loop, but guard so a background caller cannot crash AppKit. Because
// this uses dispatch_sync, the C-string arguments captured by value stay valid
// for the duration of the block.
static void wispterm_webview_run_on_main(dispatch_block_t block) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

// Convert top-left device-pixel bounds into a bottom-left point-space NSRect in
// the content view's coordinates. NOTE: coord flip + backing scale are the
// device-verify items in the design spec.
static NSRect wispterm_webview_frame(NSView *content, int left, int top, int right, int bottom) {
    CGFloat scale = content.window.backingScaleFactor;
    if (scale <= 0.0) scale = 1.0;
    CGFloat content_h = content.bounds.size.height; // points
    CGFloat x = (CGFloat)left / scale;
    CGFloat w = (CGFloat)(right - left) / scale;
    CGFloat h = (CGFloat)(bottom - top) / scale;
    CGFloat y = content_h - ((CGFloat)bottom / scale);
    return NSMakeRect(x, y, w, h);
}

int wispterm_webview_macos_loader_available(void) {
    return (NSClassFromString(@"WKWebView") != nil) ? 1 : 0;
}

void *wispterm_webview_macos_create(void *parent, int left, int top, int right, int bottom, const char *initial_url) {
    __block WispTermMacWebView *state = NULL;
    wispterm_webview_run_on_main(^{
        @autoreleasepool {
            NSWindow *window = (NSWindow *)wispterm_macos_window_ns_window(parent);
            if (window == nil) return;
            NSView *content = [window contentView];
            if (content == nil) return;

            WispTermMacWebView *st = (WispTermMacWebView *)calloc(1, sizeof(WispTermMacWebView));
            if (st == NULL) return;

            NSRect frame = wispterm_webview_frame(content, left, top, right, bottom);
            WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
            WKWebView *web = [[WKWebView alloc] initWithFrame:frame configuration:config];
            [config release];
            web.autoresizingMask = NSViewNotSizable;
            [content addSubview:web positioned:NSWindowAbove relativeTo:nil];

            // Ownership (MRR): `web` holds +1 from alloc AND +1 from addSubview:
            // (the superview retains it). We keep the alloc-time +1 in st->webview
            // WITHOUT an extra retain. destroy() drains both: removeFromSuperview
            // drops the superview's retain, then [release] drops the alloc-time +1.
            // Do NOT add a release here — that would over-release.
            st->webview = web;
            st->last_error = 0;
            state = st;

            if (initial_url != NULL && initial_url[0] != '\0') {
                NSString *s = [NSString stringWithUTF8String:initial_url];
                if (s != nil) {
                    NSURL *u = [NSURL URLWithString:s];
                    if (u != nil) [web loadRequest:[NSURLRequest requestWithURL:u]];
                }
            }
        }
    });
    return (void *)state;
}

void wispterm_webview_macos_set_bounds(void *browser, int left, int top, int right, int bottom) {
    WispTermMacWebView *st = (WispTermMacWebView *)browser;
    if (st == NULL || st->webview == nil) return;
    wispterm_webview_run_on_main(^{
        @autoreleasepool {
            NSView *content = st->webview.superview;
            if (content == nil) return;
            st->webview.frame = wispterm_webview_frame(content, left, top, right, bottom);
        }
    });
}

void wispterm_webview_macos_set_visible(void *browser, int visible) {
    WispTermMacWebView *st = (WispTermMacWebView *)browser;
    if (st == NULL || st->webview == nil) return;
    wispterm_webview_run_on_main(^{
        @autoreleasepool {
            st->webview.hidden = (visible == 0);
        }
    });
}

void wispterm_webview_macos_focus(void *browser) {
    WispTermMacWebView *st = (WispTermMacWebView *)browser;
    if (st == NULL || st->webview == nil) return;
    wispterm_webview_run_on_main(^{
        @autoreleasepool {
            [st->webview.window makeFirstResponder:st->webview];
        }
    });
}

void wispterm_webview_macos_navigate(void *browser, const char *url) {
    WispTermMacWebView *st = (WispTermMacWebView *)browser;
    if (st == NULL || st->webview == nil || url == NULL) return;
    wispterm_webview_run_on_main(^{
        @autoreleasepool {
            NSString *s = [NSString stringWithUTF8String:url];
            if (s != nil) {
                NSURL *u = [NSURL URLWithString:s];
                if (u != nil) [st->webview loadRequest:[NSURLRequest requestWithURL:u]];
            }
        }
    });
}

void wispterm_webview_macos_reload(void *browser) {
    WispTermMacWebView *st = (WispTermMacWebView *)browser;
    if (st == NULL || st->webview == nil) return;
    wispterm_webview_run_on_main(^{
        @autoreleasepool {
            [st->webview reload];
        }
    });
}

int wispterm_webview_macos_is_ready(void *browser) {
    WispTermMacWebView *st = (WispTermMacWebView *)browser;
    return (st != NULL && st->webview != nil) ? 1 : 0;
}

int32_t wispterm_webview_macos_last_error(void *browser) {
    WispTermMacWebView *st = (WispTermMacWebView *)browser;
    return (st != NULL) ? st->last_error : 0;
}

void wispterm_webview_macos_destroy(void *browser) {
    WispTermMacWebView *st = (WispTermMacWebView *)browser;
    if (st == NULL) return;
    wispterm_webview_run_on_main(^{
        @autoreleasepool {
            if (st->webview != nil) {
                [st->webview removeFromSuperview];
                [st->webview release];
                st->webview = nil;
            }
            free(st);
        }
    });
}
