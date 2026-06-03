#import <CoreFoundation/CoreFoundation.h>
#import <CoreText/CoreText.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

uint16_t wispterm_coretext_font_glyph_index(void *handle, uint32_t codepoint);

bool wispterm_coretext_is_available(void) {
    return true;
}

static char *wispterm_coretext_copy_cfstring(CFStringRef string) {
    if (string == NULL) return NULL;
    CFIndex length = CFStringGetLength(string);
    CFIndex max_size = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    char *buf = malloc((size_t)max_size);
    if (buf == NULL) return NULL;
    if (!CFStringGetCString(string, buf, max_size, kCFStringEncodingUTF8)) {
        free(buf);
        return NULL;
    }
    return buf;
}

static CFStringRef wispterm_coretext_create_string(const char *bytes) {
    if (bytes == NULL) return NULL;
    return CFStringCreateWithCString(kCFAllocatorDefault, bytes, kCFStringEncodingUTF8);
}

static CFStringRef wispterm_coretext_create_string_for_codepoint(uint32_t codepoint, CFIndex *utf16_len) {
    UniChar chars[2] = {0, 0};
    if (codepoint > 0xFFFF) {
        uint32_t scalar = codepoint - 0x10000;
        chars[0] = (UniChar)(0xD800 + (scalar >> 10));
        chars[1] = (UniChar)(0xDC00 + (scalar & 0x3FF));
        if (utf16_len != NULL) *utf16_len = 2;
        return CFStringCreateWithCharacters(kCFAllocatorDefault, chars, 2);
    }
    chars[0] = (UniChar)codepoint;
    if (utf16_len != NULL) *utf16_len = 1;
    return CFStringCreateWithCharacters(kCFAllocatorDefault, chars, 1);
}

static bool wispterm_coretext_font_is_last_resort(CTFontRef font) {
    if (font == NULL) return true;
    CFStringRef name = CTFontCopyPostScriptName(font);
    if (name == NULL) return false;
    bool result = CFStringCompare(name, CFSTR("LastResort"), 0) == kCFCompareEqualTo;
    CFRelease(name);
    return result;
}

void *wispterm_coretext_find_font(const char *family, uint16_t weight) {
    CFStringRef family_name = wispterm_coretext_create_string(family);
    if (family_name == NULL) return NULL;

    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (attrs == NULL) {
        CFRelease(family_name);
        return NULL;
    }
    CFDictionarySetValue(attrs, kCTFontFamilyNameAttribute, family_name);

    CGFloat normalized_weight = ((CGFloat)weight - 400.0) / 500.0;
    if (normalized_weight < -1.0) normalized_weight = -1.0;
    if (normalized_weight > 1.0) normalized_weight = 1.0;
    CFNumberRef weight_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &normalized_weight);
    const void *trait_keys[] = { kCTFontWeightTrait };
    const void *trait_values[] = { weight_number };
    CFDictionaryRef traits = CFDictionaryCreate(
        kCFAllocatorDefault,
        trait_keys,
        trait_values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (traits != NULL) CFDictionarySetValue(attrs, kCTFontTraitsAttribute, traits);

    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attrs);
    CTFontDescriptorRef match = descriptor != NULL
        ? CTFontDescriptorCreateMatchingFontDescriptor(descriptor, NULL)
        : NULL;
    CTFontRef font = match != NULL ? CTFontCreateWithFontDescriptor(match, 12.0, NULL) : NULL;

    if (traits != NULL) CFRelease(traits);
    if (weight_number != NULL) CFRelease(weight_number);
    if (match != NULL) CFRelease(match);
    if (descriptor != NULL) CFRelease(descriptor);
    CFRelease(attrs);
    CFRelease(family_name);
    return font;
}

void *wispterm_coretext_find_fallback(uint32_t codepoint) {
    CFIndex len = 0;
    CFStringRef string = wispterm_coretext_create_string_for_codepoint(codepoint, &len);
    if (string == NULL) return NULL;

    CTFontRef base = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 12.0, NULL);
    if (base == NULL) {
        CFRelease(string);
        return NULL;
    }

    CFArrayRef cascade = CTFontCopyDefaultCascadeListForLanguages(base, NULL);
    if (cascade != NULL) {
        CFIndex count = CFArrayGetCount(cascade);
        for (CFIndex i = 0; i < count; i++) {
            CTFontDescriptorRef descriptor = (CTFontDescriptorRef)CFArrayGetValueAtIndex(cascade, i);
            if (descriptor == NULL) continue;
            CTFontRef candidate = CTFontCreateWithFontDescriptor(descriptor, 12.0, NULL);
            if (candidate == NULL) continue;
            if (!wispterm_coretext_font_is_last_resort(candidate) &&
                wispterm_coretext_font_glyph_index(candidate, codepoint) != 0)
            {
                CFRelease(cascade);
                CFRelease(base);
                CFRelease(string);
                return candidate;
            }
            CFRelease(candidate);
        }
        CFRelease(cascade);
    }

    CTFontRef font = CTFontCreateForString(base, string, CFRangeMake(0, len));
    CFRelease(base);
    CFRelease(string);
    if (font == NULL) return NULL;
    if (wispterm_coretext_font_is_last_resort(font)) {
        CFRelease(font);
        return NULL;
    }
    return font;
}

void wispterm_coretext_font_retain(void *handle) {
    if (handle != NULL) CFRetain(handle);
}

void wispterm_coretext_font_release(void *handle) {
    if (handle != NULL) CFRelease(handle);
}

bool wispterm_coretext_font_has_character(void *handle, uint32_t codepoint) {
    return wispterm_coretext_font_glyph_index(handle, codepoint) != 0;
}

uint16_t wispterm_coretext_font_glyph_index(void *handle, uint32_t codepoint) {
    CTFontRef font = (CTFontRef)handle;
    if (font == NULL) return 0;

    CFIndex len = 0;
    CFStringRef string = wispterm_coretext_create_string_for_codepoint(codepoint, &len);
    if (string == NULL) return 0;

    UniChar chars[2] = {0, 0};
    CFStringGetCharacters(string, CFRangeMake(0, len), chars);
    CGGlyph glyphs[2] = {0, 0};
    bool ok = CTFontGetGlyphsForCharacters(font, chars, glyphs, len);
    CFRelease(string);
    return ok ? glyphs[0] : 0;
}

char *wispterm_coretext_font_copy_path(void *handle) {
    CTFontRef font = (CTFontRef)handle;
    if (font == NULL) return NULL;

    CFURLRef url = CTFontCopyAttribute(font, kCTFontURLAttribute);
    if (url == NULL) return NULL;
    CFStringRef path = CFURLCopyFileSystemPath(url, kCFURLPOSIXPathStyle);
    CFRelease(url);
    if (path == NULL) return NULL;

    char *result = wispterm_coretext_copy_cfstring(path);
    CFRelease(path);
    return result;
}

static void wispterm_write_u32_be(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)(v);
}

static void wispterm_write_u16_be(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)(v);
}

static uint32_t wispterm_sfnt_checksum(const uint8_t *data, uint32_t len) {
    uint32_t sum = 0;
    uint32_t words = (len + 3u) / 4u;
    for (uint32_t i = 0; i < words; i++) {
        uint32_t word = 0;
        for (uint32_t j = 0; j < 4; j++) {
            uint32_t idx = i * 4u + j;
            word = (word << 8) | (idx < len ? data[idx] : 0u);
        }
        sum += word;
    }
    return sum;
}

// Reconstruct a standalone sfnt (TrueType/OpenType) blob from a CTFont's
// tables. This lets FreeType load fonts that have no FreeType-openable file
// path — most importantly macOS 26's reserved PingFang.ttc, which CoreText can
// read but FT_New_Face(path) cannot open, the root cause of CJK tofu. Pulling
// one font's tables also sidesteps .ttc face-index ambiguity. Returns a malloc'd
// buffer (free via wispterm_coretext_free) and writes its length to *out_len,
// or NULL on failure.
uint8_t *wispterm_coretext_font_copy_table_data(void *handle, size_t *out_len) {
    if (out_len != NULL) *out_len = 0;
    CTFontRef font = (CTFontRef)handle;
    if (font == NULL) return NULL;

    CFArrayRef tags = CTFontCopyAvailableTables(font, kCTFontTableOptionNoOptions);
    if (tags == NULL) return NULL;
    CFIndex num_tables = CFArrayGetCount(tags);
    if (num_tables <= 0) {
        CFRelease(tags);
        return NULL;
    }

    typedef struct {
        uint32_t tag;
        CFDataRef data;
        uint32_t length;
        uint32_t padded;
    } TableEntry;

    TableEntry *entries = calloc((size_t)num_tables, sizeof(TableEntry));
    if (entries == NULL) {
        CFRelease(tags);
        return NULL;
    }

    bool has_cff = false;
    size_t total_data = 0;
    CFIndex count = 0;
    for (CFIndex i = 0; i < num_tables; i++) {
        CTFontTableTag tag = (CTFontTableTag)(uintptr_t)CFArrayGetValueAtIndex(tags, i);
        CFDataRef data = CTFontCopyTable(font, tag, kCTFontTableOptionNoOptions);
        if (data == NULL) continue;
        uint32_t len = (uint32_t)CFDataGetLength(data);
        entries[count].tag = (uint32_t)tag;
        entries[count].data = data;
        entries[count].length = len;
        entries[count].padded = (len + 3u) & ~3u;
        if (tag == 0x43464620u /* 'CFF ' */ || tag == 0x43464632u /* 'CFF2' */) has_cff = true;
        total_data += entries[count].padded;
        count++;
    }
    CFRelease(tags);

    if (count == 0) {
        free(entries);
        return NULL;
    }

    // sfnt requires the table directory to be sorted by tag ascending.
    for (CFIndex a = 0; a + 1 < count; a++) {
        for (CFIndex b = a + 1; b < count; b++) {
            if (entries[b].tag < entries[a].tag) {
                TableEntry tmp = entries[a];
                entries[a] = entries[b];
                entries[b] = tmp;
            }
        }
    }

    size_t header_size = 12 + (size_t)count * 16;
    size_t total_size = header_size + total_data;
    uint8_t *out = malloc(total_size);
    if (out == NULL) {
        for (CFIndex i = 0; i < count; i++) CFRelease(entries[i].data);
        free(entries);
        return NULL;
    }
    memset(out, 0, total_size);

    uint16_t num = (uint16_t)count;
    uint16_t max_pow2 = 1;
    uint16_t entry_selector = 0;
    while ((uint16_t)(max_pow2 << 1) <= num) {
        max_pow2 = (uint16_t)(max_pow2 << 1);
        entry_selector++;
    }
    uint16_t search_range = (uint16_t)(max_pow2 * 16);
    uint16_t range_shift = (uint16_t)(num * 16 - search_range);

    wispterm_write_u32_be(out + 0, has_cff ? 0x4F54544Fu /* 'OTTO' */ : 0x00010000u);
    wispterm_write_u16_be(out + 4, num);
    wispterm_write_u16_be(out + 6, search_range);
    wispterm_write_u16_be(out + 8, entry_selector);
    wispterm_write_u16_be(out + 10, range_shift);

    size_t data_offset = header_size;
    for (CFIndex i = 0; i < count; i++) {
        const uint8_t *src = CFDataGetBytePtr(entries[i].data);
        uint8_t *dir = out + 12 + (size_t)i * 16;
        wispterm_write_u32_be(dir + 0, entries[i].tag);
        wispterm_write_u32_be(dir + 4, wispterm_sfnt_checksum(src, entries[i].length));
        wispterm_write_u32_be(dir + 8, (uint32_t)data_offset);
        wispterm_write_u32_be(dir + 12, entries[i].length);
        memcpy(out + data_offset, src, entries[i].length);
        data_offset += entries[i].padded;
        CFRelease(entries[i].data);
    }
    free(entries);

    if (out_len != NULL) *out_len = total_size;
    return out;
}

size_t wispterm_coretext_family_count(void) {
    CFArrayRef families = CTFontManagerCopyAvailableFontFamilyNames();
    if (families == NULL) return 0;
    CFIndex count = CFArrayGetCount(families);
    CFRelease(families);
    return count > 0 ? (size_t)count : 0;
}

char *wispterm_coretext_copy_family_name(size_t index) {
    CFArrayRef families = CTFontManagerCopyAvailableFontFamilyNames();
    if (families == NULL) return NULL;
    CFIndex count = CFArrayGetCount(families);
    if (index >= (size_t)count) {
        CFRelease(families);
        return NULL;
    }
    CFStringRef family = (CFStringRef)CFArrayGetValueAtIndex(families, (CFIndex)index);
    char *result = wispterm_coretext_copy_cfstring(family);
    CFRelease(families);
    return result;
}

void wispterm_coretext_free(void *ptr) {
    free(ptr);
}
