#import <CoreFoundation/CoreFoundation.h>
#import <Security/Security.h>
#include <stdint.h>
#include <string.h>

// Password store key in the login Keychain. Plain CoreFoundation/Security C
// calls (no Objective-C message sends), so no autorelease pool is involved.

static CFMutableDictionaryRef wispterm_vault_key_query(void) {
    CFMutableDictionaryRef query = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(query, kSecAttrService, CFSTR("WispTerm Password Store"));
    CFDictionarySetValue(query, kSecAttrAccount, CFSTR("vault-key"));
    return query;
}

static OSStatus wispterm_vault_key_read(uint8_t *out, int32_t len) {
    CFMutableDictionaryRef query = wispterm_vault_key_query();
    CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
    CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitOne);
    CFTypeRef found = NULL;
    OSStatus status = SecItemCopyMatching(query, &found);
    CFRelease(query);
    if (status != errSecSuccess) return status;
    CFDataRef data = (CFDataRef)found;
    if (CFDataGetLength(data) == len) {
        memcpy(out, CFDataGetBytePtr(data), (size_t)len);
    } else {
        status = errSecDecode;
    }
    CFRelease(found);
    return status;
}

// Copy the key into `out`, minting and storing a random one on first use.
// Returns 0 (errSecSuccess) or the OSStatus of the failing Keychain call.
int32_t wispterm_macos_vault_key(uint8_t *out, int32_t len) {
    if (out == NULL || len <= 0) return errSecParam;
    OSStatus status = wispterm_vault_key_read(out, len);
    if (status != errSecItemNotFound) return status;

    if (SecRandomCopyBytes(kSecRandomDefault, (size_t)len, out) != errSecSuccess) return errSecAllocate;
    CFMutableDictionaryRef item = wispterm_vault_key_query();
    CFDataRef value = CFDataCreate(NULL, out, len);
    CFDictionarySetValue(item, kSecValueData, value);
    CFDictionarySetValue(item, kSecAttrLabel, CFSTR("WispTerm Password Store"));
    status = SecItemAdd(item, NULL);
    CFRelease(value);
    CFRelease(item);
    // Another process created it first: use theirs, never a second key.
    if (status == errSecDuplicateItem) return wispterm_vault_key_read(out, len);
    return status;
}
