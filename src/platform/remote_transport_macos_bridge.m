#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// A live WebSocket connection. Obj-C objects are retained into this C struct
// (the bridge is compiled without ARC, matching the other *_macos_bridge.m
// files), so they survive across the connect/send/receive/close C calls.
typedef struct WispWsConn {
    NSURLSession *session;
    NSURLSessionWebSocketTask *task;
    // Remainder of an oversized message awaiting delivery: NSURLSession hands us
    // whole messages, but the caller's buffer is io_chunk_size, so a larger
    // message is sliced into utf8_fragment chunks across successive receives.
    NSMutableData *pending;
    bool pending_is_text;
} WispWsConn;

// dispatch objects are ARC-managed when OS_OBJECT_USE_OBJC is set; otherwise we
// must release them ourselves (mirrors http_client_macos_bridge.m).
static void wispterm_ws_release_semaphore(dispatch_semaphore_t sema) {
#if !OS_OBJECT_USE_OBJC
    dispatch_release(sema);
#else
    (void)sema;
#endif
}

// Copy the head of conn->pending into the caller buffer, fragmenting text
// messages that exceed it. out_type: 0=utf8_message (final), 1=utf8_fragment,
// 3=other (binary; the consumer ignores these, so deliver one chunk and drop).
static long wispterm_ws_emit_pending(WispWsConn *conn, char *buffer, size_t buffer_len, int32_t *out_type) {
    NSUInteger total = conn->pending.length;
    NSUInteger take = (total < buffer_len) ? total : buffer_len;
    if (take > 0) memcpy(buffer, conn->pending.bytes, take);

    BOOL is_final = (take == total);
    if (conn->pending_is_text) {
        *out_type = is_final ? 0 : 1;
    } else {
        *out_type = 3;
    }

    if (is_final || !conn->pending_is_text) {
        [conn->pending setLength:0];
    } else {
        [conn->pending replaceBytesInRange:NSMakeRange(0, take) withBytes:NULL length:0];
    }
    return (long)take;
}

void *wispterm_macos_ws_connect(bool secure, const char *host, uint16_t port, const char *object_name, double timeout_seconds) {
    @autoreleasepool {
        if (host == NULL || object_name == NULL) return NULL;
        NSString *host_str = [NSString stringWithUTF8String:host];
        NSString *object_str = [NSString stringWithUTF8String:object_name];
        if (host_str == nil || object_str == nil) return NULL;

        NSString *scheme = secure ? @"wss" : @"ws";
        NSString *url_str = [NSString stringWithFormat:@"%@://%@:%u%@", scheme, host_str, (unsigned)port, object_str];
        NSURL *url = [NSURL URLWithString:url_str];
        if (url == nil) return NULL;

        NSTimeInterval timeout = timeout_seconds > 0 ? (NSTimeInterval)timeout_seconds : 10.0;
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = timeout;
        config.timeoutIntervalForResource = timeout;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
        NSURLSessionWebSocketTask *task = [session webSocketTaskWithURL:url];
        if (task == nil) return NULL;
        [task resume];

        // Validate the handshake with a ping/pong before reporting success so a
        // dead endpoint surfaces as a connect error (like the Windows upgrade
        // handshake) rather than a silently-broken socket.
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        __block BOOL ok = NO;
        [task sendPingWithPongReceiveHandler:^(NSError *error) {
            ok = (error == nil);
            dispatch_semaphore_signal(sema);
        }];
        int64_t wait_ns = (int64_t)((timeout + 5.0) * NSEC_PER_SEC);
        long wait_result = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, wait_ns));
        wispterm_ws_release_semaphore(sema);

        if (wait_result != 0 || !ok) {
            [task cancel];
            [session invalidateAndCancel];
            return NULL;
        }

        WispWsConn *conn = calloc(1, sizeof(WispWsConn));
        if (conn == NULL) {
            [task cancel];
            [session invalidateAndCancel];
            return NULL;
        }
        conn->session = [session retain];
        conn->task = [task retain];
        conn->pending = [[NSMutableData alloc] init];
        conn->pending_is_text = false;
        return conn;
    }
}

bool wispterm_macos_ws_send(void *handle, const char *bytes, size_t len) {
    @autoreleasepool {
        WispWsConn *conn = (WispWsConn *)handle;
        if (conn == NULL || conn->task == nil) return false;

        NSData *data = [NSData dataWithBytes:(bytes != NULL ? bytes : "") length:len];
        NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        NSURLSessionWebSocketMessage *msg = (text != nil)
            ? [[[NSURLSessionWebSocketMessage alloc] initWithString:text] autorelease]
            : [[[NSURLSessionWebSocketMessage alloc] initWithData:data] autorelease];

        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        __block BOOL ok = NO;
        [conn->task sendMessage:msg completionHandler:^(NSError *error) {
            ok = (error == nil);
            dispatch_semaphore_signal(sema);
        }];
        // Block until the send resolves (mirrors the synchronous Windows send);
        // the handler always fires, so the semaphore is safe to release after.
        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
        wispterm_ws_release_semaphore(sema);
        return ok;
    }
}

long wispterm_macos_ws_receive(void *handle, char *buffer, size_t buffer_len, int32_t *out_type) {
    @autoreleasepool {
        WispWsConn *conn = (WispWsConn *)handle;
        if (conn == NULL || buffer == NULL || buffer_len == 0 || out_type == NULL) return -1;

        // Drain a buffered remainder from a previous oversized message first.
        if (conn->pending.length > 0) {
            return wispterm_ws_emit_pending(conn, buffer, buffer_len, out_type);
        }

        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        __block NSData *payload = nil;
        __block BOOL is_text = NO;
        __block BOOL failed = NO;
        [conn->task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
            if (error != nil || message == nil) {
                failed = YES;
            } else if (message.type == NSURLSessionWebSocketMessageTypeString) {
                is_text = YES;
                payload = [[message.string dataUsingEncoding:NSUTF8StringEncoding] retain];
            } else {
                is_text = NO;
                payload = [message.data retain];
            }
            dispatch_semaphore_signal(sema);
        }];
        // Block until a message arrives or the socket is torn down (close()
        // cancels the task, which completes this receive with an error).
        dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
        wispterm_ws_release_semaphore(sema);

        if (failed) return -1;
        if (payload == nil) {
            *out_type = 3;
            return 0;
        }

        conn->pending_is_text = is_text;
        [conn->pending setData:payload];
        [payload release];
        return wispterm_ws_emit_pending(conn, buffer, buffer_len, out_type);
    }
}

// Tear the socket down (idempotent). Unblocks an in-flight receive but does NOT
// free the connection — the receive thread may still be running; the caller
// frees via wispterm_macos_ws_free after joining it.
void wispterm_macos_ws_shutdown(void *handle) {
    @autoreleasepool {
        WispWsConn *conn = (WispWsConn *)handle;
        if (conn == NULL) return;
        if (conn->task != nil) {
            [conn->task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        }
        if (conn->session != nil) {
            [conn->session invalidateAndCancel];
        }
    }
}

void wispterm_macos_ws_free(void *handle) {
    @autoreleasepool {
        WispWsConn *conn = (WispWsConn *)handle;
        if (conn == NULL) return;
        [conn->task release];
        [conn->session release];
        [conn->pending release];
        conn->task = nil;
        conn->session = nil;
        conn->pending = nil;
        free(conn);
    }
}
