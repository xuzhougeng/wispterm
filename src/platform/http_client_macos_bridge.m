#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct WispTermMacHttpHeader {
    const char *name;
    const char *value;
} WispTermMacHttpHeader;

typedef struct WispTermMacHttpResponse {
    int32_t status;
    void *body;
    int32_t body_len;
    int32_t error_code;
} WispTermMacHttpResponse;

void wispterm_macos_http_free(void *ptr) {
    free(ptr);
}

static NSString *wispterm_macos_http_string(const char *text) {
    if (text == NULL) return nil;
    return [NSString stringWithUTF8String:text];
}

static void wispterm_macos_http_release_semaphore(dispatch_semaphore_t sema) {
#if !OS_OBJECT_USE_OBJC
    dispatch_release(sema);
#else
    (void)sema;
#endif
}

int32_t wispterm_macos_http_fetch(
    const char *method,
    const char *url,
    const WispTermMacHttpHeader *headers,
    int32_t header_count,
    const void *body,
    int32_t body_len,
    int32_t timeout_ms,
    WispTermMacHttpResponse *out
) {
    @autoreleasepool {
        if (out == NULL) return 0;
        out->status = 0;
        out->body = NULL;
        out->body_len = 0;
        out->error_code = 0;

        NSString *method_string = wispterm_macos_http_string(method);
        NSString *url_string = wispterm_macos_http_string(url);
        if (method_string == nil || url_string == nil) {
            out->error_code = -1;
            return 0;
        }
        NSURL *ns_url = [NSURL URLWithString:url_string];
        if (ns_url == nil) {
            out->error_code = -1002; // NSURLErrorUnsupportedURL
            return 0;
        }

        NSTimeInterval timeout = timeout_ms > 0 ? ((NSTimeInterval)timeout_ms / 1000.0) : 30.0;
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = timeout;
        config.timeoutIntervalForResource = timeout;

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:ns_url];
        request.HTTPMethod = method_string;
        request.timeoutInterval = timeout;
        if (body != NULL && body_len > 0) {
            request.HTTPBody = [NSData dataWithBytes:body length:(NSUInteger)body_len];
        }
        for (int32_t i = 0; i < header_count; i++) {
            NSString *name = wispterm_macos_http_string(headers[i].name);
            NSString *value = wispterm_macos_http_string(headers[i].value);
            if (name != nil && value != nil) {
                [request setValue:value forHTTPHeaderField:name];
            }
        }

        NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:
            ^(NSData *data, NSURLResponse *response, NSError *error) {
                if (error != nil) {
                    out->error_code = (int32_t)[error code];
                } else {
                    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                        out->status = (int32_t)[(NSHTTPURLResponse *)response statusCode];
                    }
                    NSUInteger len = data != nil ? [data length] : 0;
                    if (len > 0) {
                        void *copy = malloc(len);
                        if (copy == NULL) {
                            out->error_code = -3;
                        } else {
                            memcpy(copy, [data bytes], len);
                            out->body = copy;
                            out->body_len = (int32_t)len;
                        }
                    }
                }
                dispatch_semaphore_signal(sema);
            }
        ];
        [task resume];

        int64_t wait_ms = timeout_ms > 0 ? (int64_t)timeout_ms + 5000 : 35000;
        long wait_result = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, wait_ms * NSEC_PER_MSEC));
        if (wait_result != 0) {
            [task cancel];
            [session invalidateAndCancel];
            wispterm_macos_http_release_semaphore(sema);
            out->error_code = -1001; // NSURLErrorTimedOut
            return 0;
        }

        [session finishTasksAndInvalidate];
        wispterm_macos_http_release_semaphore(sema);
        return out->error_code == 0 ? 1 : 0;
    }
}
