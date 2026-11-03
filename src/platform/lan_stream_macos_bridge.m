// macOS pieces of the LAN screen stream (src/lan_stream.zig): JPEG encoding of
// an RGBA frame with ImageIO, Bonjour advertisement with dns_sd, and whole-
// display capture with ScreenCaptureKit. System frameworks only.
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <stdbool.h>
#include <arpa/inet.h>
#include <dns_sd.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// Encodes top-down RGBA8 pixels (row stride = width*4) to JPEG. *out_len is the
// byte count; the returned buffer is malloc'd, release with wispterm_lan_jpeg_free.
// Returns NULL on failure.
uint8_t *wispterm_lan_jpeg_encode(const uint8_t *rgba, uint32_t width, uint32_t height,
                                  float quality, size_t *out_len) {
    *out_len = 0;
    if (!rgba || width == 0 || height == 0) return NULL;
    uint8_t *result = NULL;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, rgba, (size_t)width * height * 4, NULL);
    CGImageRef image = NULL;
    CFMutableDataRef data = NULL;
    CGImageDestinationRef dest = NULL;
    CFNumberRef q = NULL;
    CFDictionaryRef opts = NULL;
    if (!space || !provider) goto done;
    image = CGImageCreate(width, height, 8, 32, (size_t)width * 4, space,
                          kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault,
                          provider, NULL, false, kCGRenderingIntentDefault);
    if (!image) goto done;
    data = CFDataCreateMutable(NULL, 0);
    dest = CGImageDestinationCreateWithData(data, CFSTR("public.jpeg"), 1, NULL);
    if (!data || !dest) goto done;
    q = CFNumberCreate(NULL, kCFNumberFloatType, &quality);
    const void *keys[] = { kCGImageDestinationLossyCompressionQuality };
    const void *vals[] = { q };
    opts = CFDictionaryCreate(NULL, keys, vals, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CGImageDestinationAddImage(dest, image, opts);
    if (!CGImageDestinationFinalize(dest)) goto done;
    CFIndex len = CFDataGetLength(data);
    if (len <= 0) goto done;
    result = malloc((size_t)len);
    if (!result) goto done;
    memcpy(result, CFDataGetBytePtr(data), (size_t)len);
    *out_len = (size_t)len;
done:
    if (opts) CFRelease(opts);
    if (q) CFRelease(q);
    if (dest) CFRelease(dest);
    if (data) CFRelease(data);
    if (image) CGImageRelease(image);
    if (provider) CGDataProviderRelease(provider);
    if (space) CGColorSpaceRelease(space);
    return result;
}

void wispterm_lan_jpeg_free(void *ptr) { free(ptr); }

// Registers `_wispterm._tcp` on the local link with a TXT record (`txt` is
// already in DNS length-prefixed form, e.g. "\x0fcaps=stream,msg"). The
// registration lives as long as the returned ref; we never process results,
// so no callback is needed.
void *wispterm_lan_mdns_register(const char *name, uint16_t port, const uint8_t *txt, uint16_t txt_len) {
    DNSServiceRef ref = NULL;
    DNSServiceErrorType err = DNSServiceRegister(&ref, 0, kDNSServiceInterfaceIndexAny, name,
                                                 "_wispterm._tcp", NULL, NULL, htons(port),
                                                 txt_len, txt, NULL, NULL);
    return err == kDNSServiceErr_NoError ? (void *)ref : NULL;
}

void wispterm_lan_mdns_unregister(void *ref) {
    if (ref) DNSServiceRefDeallocate((DNSServiceRef)ref);
}

// ---- Whole-display capture (lan-stream-source = display) -------------------
//
// ScreenCaptureKit (macOS 12.3+) delivers scaled BGRA frames of one display on
// its own dispatch queue; each complete frame is JPEG-encoded there and handed
// to Zig through `frame_fn`. The capture runs independently of the AppWindow
// render loop. Permission: the first start triggers the system "Screen
// Recording" prompt; until it is granted `wispterm_lan_display_start` returns
// NULL and Zig falls back to the window stream.

typedef void (*wispterm_lan_display_frame_fn)(void *ctx, const uint8_t *jpeg, size_t len);
typedef void (*wispterm_lan_display_error_fn)(void *ctx, const char *message);

static uint8_t *wispterm_lan_jpeg_encode_bgra(CVPixelBufferRef pixels, float quality, size_t *out_len);

API_AVAILABLE(macos(12.3))
@interface WispLanDisplayCapture : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic) void *ctx;
@property(nonatomic) wispterm_lan_display_frame_fn frameFn;
@property(nonatomic) wispterm_lan_display_error_fn errorFn;
@property(nonatomic) uint32_t displayIndex;
@property(nonatomic) uint32_t fps;
@property(nonatomic) uint32_t minWidth;
@property(nonatomic) uint32_t maxWidth;
@property(nonatomic) float quality;
@property(nonatomic) BOOL stopped;
@property(nonatomic, retain) SCStream *stream;
@property(nonatomic, assign) dispatch_queue_t queue;
@end

API_AVAILABLE(macos(12.3))
@implementation WispLanDisplayCapture

// Callbacks into Zig happen under @synchronized(self) and only while not
// stopped, so once `stop` returns Zig never hears from this object again.
- (void)reportError:(NSString *)message {
    @synchronized(self) {
        if (self.stopped) return;
        self.stopped = YES;
        if (self.errorFn) self.errorFn(self.ctx, message.UTF8String);
    }
}

- (void)dealloc {
    [_stream release];
    if (_queue) dispatch_release(_queue);
    [super dealloc];
}

// Manual reference counting: the completion blocks retain `self` until they
// run, so the object lives at least until capture is up or has failed.
- (void)start {
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                               onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent *content, NSError *error) {
        @autoreleasepool {
            if (error || !content) {
                [self reportError:[NSString stringWithFormat:@"shareable content unavailable: %@",
                                   error.localizedDescription ?: @"unknown error"]];
                return;
            }
            [self startWithContent:content];
        }
    }];
}

- (void)startWithContent:(SCShareableContent *)content {
    NSArray<SCDisplay *> *displays = content.displays;
    if (displays.count == 0) {
        [self reportError:@"no displays available"];
        return;
    }
    NSUInteger index = self.displayIndex < displays.count ? self.displayIndex : 0;
    SCDisplay *display = displays[index];

    SCContentFilter *filter = [[[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]] autorelease];
    SCStreamConfiguration *config = [[[SCStreamConfiguration alloc] init] autorelease];
    // Scale straight in the capture pipeline: a Retina display is never
    // encoded at native resolution. Width lands in [minWidth, maxWidth].
    double w = (double)display.width;
    double h = (double)display.height;
    if (w <= 0 || h <= 0) { w = 1920; h = 1080; }
    double target_w = w;
    if (target_w > self.maxWidth) target_w = self.maxWidth;
    if (target_w < self.minWidth) target_w = self.minWidth;
    double target_h = floor(h * target_w / w);
    config.width = (size_t)target_w;
    config.height = (size_t)target_h;
    config.pixelFormat = kCVPixelFormatType_32BGRA;
    config.minimumFrameInterval = CMTimeMake(1, (int32_t)(self.fps > 0 ? self.fps : 4));
    config.queueDepth = 3;
    config.showsCursor = YES;

    SCStream *stream = [[[SCStream alloc] initWithFilter:filter configuration:config delegate:self] autorelease];
    NSError *addError = nil;
    if (![stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self.queue error:&addError]) {
        [self reportError:[NSString stringWithFormat:@"addStreamOutput failed: %@", addError.localizedDescription ?: @"unknown error"]];
        return;
    }
    @synchronized(self) {
        if (self.stopped) return;
        self.stream = stream;
    }
    [stream startCaptureWithCompletionHandler:^(NSError *error) {
        if (!error) return;
        @autoreleasepool {
            [self reportError:[NSString stringWithFormat:@"startCapture failed: %@", error.localizedDescription]];
        }
    }];
}

- (void)stop {
    SCStream *stream = nil;
    @synchronized(self) {
        self.stopped = YES;
        stream = [self.stream retain];
        self.stream = nil;
    }
    if (stream) {
        [stream stopCaptureWithCompletionHandler:^(NSError *error) { (void)error; }];
        [stream release];
    }
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    [self reportError:[NSString stringWithFormat:@"capture stopped: %@", error.localizedDescription ?: @"unknown error"]];
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || !sampleBuffer || !CMSampleBufferIsValid(sampleBuffer)) return;
    // Only complete frames carry pixels; idle/blank frames are skipped.
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef attachment = CFArrayGetValueAtIndex(attachments, 0);
        CFNumberRef status = attachment ? CFDictionaryGetValue(attachment, (CFStringRef)SCStreamFrameInfoStatus) : NULL;
        int status_value = -1;
        if (status) CFNumberGetValue(status, kCFNumberIntType, &status_value);
        if (status_value != SCFrameStatusComplete) return;
    }
    CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixels) return;
    size_t len = 0;
    uint8_t *jpeg = wispterm_lan_jpeg_encode_bgra(pixels, self.quality, &len);
    if (!jpeg) return;
    @synchronized(self) {
        if (!self.stopped && self.frameFn) self.frameFn(self.ctx, jpeg, len);
    }
    free(jpeg);
}

@end

// JPEG from a locked BGRA CVPixelBuffer (what SCStream hands out).
static uint8_t *wispterm_lan_jpeg_encode_bgra(CVPixelBufferRef pixels, float quality, size_t *out_len) {
    *out_len = 0;
    if (CVPixelBufferLockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NULL;
    uint8_t *result = NULL;
    size_t width = CVPixelBufferGetWidth(pixels);
    size_t height = CVPixelBufferGetHeight(pixels);
    size_t stride = CVPixelBufferGetBytesPerRow(pixels);
    const void *base = CVPixelBufferGetBaseAddress(pixels);
    CGColorSpaceRef space = NULL;
    CGDataProviderRef provider = NULL;
    CGImageRef image = NULL;
    CFMutableDataRef data = NULL;
    CGImageDestinationRef dest = NULL;
    CFNumberRef q = NULL;
    CFDictionaryRef opts = NULL;
    if (!base || width == 0 || height == 0) goto done;
    space = CGColorSpaceCreateDeviceRGB();
    provider = CGDataProviderCreateWithData(NULL, base, stride * height, NULL);
    if (!space || !provider) goto done;
    image = CGImageCreate(width, height, 8, 32, stride, space,
                          kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little,
                          provider, NULL, false, kCGRenderingIntentDefault);
    if (!image) goto done;
    data = CFDataCreateMutable(NULL, 0);
    dest = CGImageDestinationCreateWithData(data, CFSTR("public.jpeg"), 1, NULL);
    if (!data || !dest) goto done;
    q = CFNumberCreate(NULL, kCFNumberFloatType, &quality);
    const void *keys[] = { kCGImageDestinationLossyCompressionQuality };
    const void *vals[] = { q };
    opts = CFDictionaryCreate(NULL, keys, vals, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CGImageDestinationAddImage(dest, image, opts);
    if (!CGImageDestinationFinalize(dest)) goto done;
    CFIndex len = CFDataGetLength(data);
    if (len <= 0) goto done;
    result = malloc((size_t)len);
    if (!result) goto done;
    memcpy(result, CFDataGetBytePtr(data), (size_t)len);
    *out_len = (size_t)len;
done:
    if (opts) CFRelease(opts);
    if (q) CFRelease(q);
    if (dest) CFRelease(dest);
    if (data) CFRelease(data);
    if (image) CGImageRelease(image);
    if (provider) CGDataProviderRelease(provider);
    if (space) CGColorSpaceRelease(space);
    CVPixelBufferUnlockBaseAddress(pixels, kCVPixelBufferLock_ReadOnly);
    return result;
}

// True when this process may record the screen. Asking (`request`) shows the
// system prompt once; the answer only takes effect on the next start.
bool wispterm_lan_display_access(bool request) {
    if (CGPreflightScreenCaptureAccess()) return true;
    if (request) CGRequestScreenCaptureAccess();
    return false;
}

// Starts capturing display `display_index` (0 = main) at `fps`, scaled so
// the width lands in [min_width, max_width]. Frames arrive on a private queue
// through `frame_fn`; a fatal problem arrives once through `error_fn`, after
// which no more callbacks follow. Returns NULL when ScreenCaptureKit is
// unavailable (macOS < 12.3) or screen recording is not permitted.
void *wispterm_lan_display_start(uint32_t display_index, uint32_t fps, uint32_t min_width, uint32_t max_width,
                                 float quality, void *ctx,
                                 wispterm_lan_display_frame_fn frame_fn,
                                 wispterm_lan_display_error_fn error_fn) {
    if (@available(macOS 12.3, *)) {
        @autoreleasepool {
            if (!wispterm_lan_display_access(true)) return NULL;
            WispLanDisplayCapture *capture = [[WispLanDisplayCapture alloc] init];
            capture.ctx = ctx;
            capture.frameFn = frame_fn;
            capture.errorFn = error_fn;
            capture.displayIndex = display_index;
            capture.fps = fps;
            capture.minWidth = min_width;
            capture.maxWidth = max_width;
            capture.quality = quality;
            capture.queue = dispatch_queue_create("dev.wispterm.lan-display", DISPATCH_QUEUE_SERIAL);
            [capture start];
            return (void *)capture; // +1 from alloc; released by wispterm_lan_display_stop

        }
    }
    return NULL;
}

// Stops the capture; after this returns neither callback fires again.
void wispterm_lan_display_stop(void *handle) {
    if (!handle) return;
    if (@available(macOS 12.3, *)) {
        @autoreleasepool {
            WispLanDisplayCapture *capture = (WispLanDisplayCapture *)handle;
            [capture stop];
            [capture release];
        }
    }
}
