// macOS pieces of the LAN screen stream (src/lan_stream.zig): JPEG encoding of
// an RGBA frame with ImageIO, and Bonjour advertisement with dns_sd. System
// frameworks only (CoreGraphics, ImageIO, libSystem's mDNSResponder client).
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
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

// Registers `_wispterm._tcp` on the local link. The registration lives as long
// as the returned ref; we never process results, so no callback is needed.
void *wispterm_lan_mdns_register(const char *name, uint16_t port) {
    DNSServiceRef ref = NULL;
    DNSServiceErrorType err = DNSServiceRegister(&ref, 0, kDNSServiceInterfaceIndexAny, name,
                                                 "_wispterm._tcp", NULL, NULL, htons(port),
                                                 0, NULL, NULL, NULL);
    return err == kDNSServiceErr_NoError ? (void *)ref : NULL;
}

void wispterm_lan_mdns_unregister(void *ref) {
    if (ref) DNSServiceRefDeallocate((DNSServiceRef)ref);
}
