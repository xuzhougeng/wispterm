// macOS PDF rasterizer: CGPDFDocument draw into a bitmap context, PNG-encoded
// with ImageIO. System frameworks only (CoreGraphics, ImageIO).
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define WISP_PDF_OK 0
#define WISP_PDF_ERR_OS 1
#define WISP_PDF_ERR_INVALID 2
#define WISP_PDF_ERR_PASSWORD 3
#define WISP_PDF_ERR_RENDER 4
#define WISP_PDF_ERR_PAGE_RANGE 5

// Renders one 0-based page of an in-memory PDF to PNG bytes at target_width
// pixels wide (aspect preserved). *out_png is malloc'd; release with
// wisp_pdf_free_macos. Returns a WISP_PDF_* code. The pdf bytes are only read
// during this call (the data provider is released before returning).
int wisp_pdf_render_page_macos(const uint8_t *pdf, size_t pdf_len,
                               uint32_t page_index, uint32_t target_width,
                               uint8_t **out_png, size_t *out_png_len,
                               uint32_t *out_page_count) {
    *out_png = NULL;
    *out_png_len = 0;
    *out_page_count = 0;
    if (!pdf || pdf_len == 0 || target_width == 0) return WISP_PDF_ERR_INVALID;

    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pdf, pdf_len, NULL);
    if (!provider) return WISP_PDF_ERR_OS;
    CGPDFDocumentRef doc = CGPDFDocumentCreateWithProvider(provider);
    CGDataProviderRelease(provider);
    if (!doc) return WISP_PDF_ERR_INVALID;

    int rc = WISP_PDF_ERR_RENDER;
    CGContextRef ctx = NULL;
    CGColorSpaceRef space = NULL;
    CGImageRef image = NULL;
    CFMutableDataRef data = NULL;
    CGImageDestinationRef dest = NULL;

    if (CGPDFDocumentIsEncrypted(doc) && !CGPDFDocumentUnlockWithPassword(doc, "")) {
        rc = WISP_PDF_ERR_PASSWORD;
        goto done;
    }
    size_t count = CGPDFDocumentGetNumberOfPages(doc);
    *out_page_count = (uint32_t)count;
    if (page_index >= count) {
        rc = WISP_PDF_ERR_PAGE_RANGE;
        goto done;
    }
    CGPDFPageRef page = CGPDFDocumentGetPage(doc, page_index + 1); // 1-based
    if (!page) goto done;

    CGRect box = CGPDFPageGetBoxRect(page, kCGPDFCropBox);
    if (box.size.width <= 0 || box.size.height <= 0) goto done;
    // /Rotate 90/270 swaps the displayed width/height; the drawing transform
    // below applies the rotation itself, it just needs a target rect with the
    // rotated dimensions.
    int rotation = ((CGPDFPageGetRotationAngle(page) % 360) + 360) % 360;
    int swap_axes = rotation == 90 || rotation == 270;
    double box_w = swap_axes ? box.size.height : box.size.width;
    double box_h = swap_axes ? box.size.width : box.size.height;
    size_t px_w = target_width;
    size_t px_h = (size_t)((double)target_width * box_h / box_w + 0.5);
    if (px_h == 0 || px_h > 32768) goto done;

    space = CGColorSpaceCreateDeviceRGB();
    ctx = CGBitmapContextCreate(NULL, px_w, px_h, 8, 0, space,
                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!ctx) goto done;
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, (CGFloat)px_w, (CGFloat)px_h));
    CGContextSaveGState(ctx);
    // CGPDFPageGetDrawingTransform never scales up, so upscale to the pixel
    // canvas first and let the transform handle rotation/translation at 1:1
    // against a rect exactly matching the rotated box size.
    CGContextScaleCTM(ctx, (CGFloat)(px_w / box_w), (CGFloat)(px_h / box_h));
    CGAffineTransform draw_xf = CGPDFPageGetDrawingTransform(
        page, kCGPDFCropBox, CGRectMake(0, 0, (CGFloat)box_w, (CGFloat)box_h), 0, true);
    CGContextConcatCTM(ctx, draw_xf);
    CGContextDrawPDFPage(ctx, page);
    CGContextRestoreGState(ctx);

    image = CGBitmapContextCreateImage(ctx);
    if (!image) goto done;
    data = CFDataCreateMutable(NULL, 0);
    if (!data) { rc = WISP_PDF_ERR_OS; goto done; }
    dest = CGImageDestinationCreateWithData(data, CFSTR("public.png"), 1, NULL);
    if (!dest) goto done;
    CGImageDestinationAddImage(dest, image, NULL);
    if (!CGImageDestinationFinalize(dest)) goto done;

    size_t len = (size_t)CFDataGetLength(data);
    if (len == 0) goto done;
    uint8_t *buf = malloc(len);
    if (!buf) { rc = WISP_PDF_ERR_OS; goto done; }
    memcpy(buf, CFDataGetBytePtr(data), len);
    *out_png = buf;
    *out_png_len = len;
    rc = WISP_PDF_OK;

done:
    if (dest) CFRelease(dest);
    if (data) CFRelease(data);
    if (image) CGImageRelease(image);
    if (ctx) CGContextRelease(ctx);
    if (space) CGColorSpaceRelease(space);
    CGPDFDocumentRelease(doc);
    return rc;
}

void wisp_pdf_free_macos(void *p) { free(p); }
