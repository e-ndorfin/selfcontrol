#import "SCBrowserMessage.h"
#import <unistd.h>
#import <errno.h>
#import <stdint.h>

static NSError *messageError(NSString *message) {
    return [NSError errorWithDomain:@"SelfControl.Browser.Protocol" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL transferBytes(int descriptor, void *buffer, size_t length, BOOL writing) {
    uint8_t *cursor = buffer;
    while (length) {
        ssize_t count = writing ? write(descriptor, cursor, length) : read(descriptor, cursor, length);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        cursor += count; length -= count;
    }
    return YES;
}
NSDictionary *SCBrowserReadMessage(int descriptor, NSError **error) {
    uint32_t length;
    if (!transferBytes(descriptor, &length, sizeof(length), NO) || !length || length > 8192) {
        if (error) *error = messageError(@"Invalid or incomplete browser message.");
        return nil;
    }
    NSMutableData *payload = [NSMutableData dataWithLength:length];
    if (!transferBytes(descriptor, payload.mutableBytes, length, NO)) {
        if (error) *error = messageError(@"Incomplete browser message.");
        return nil;
    }
    id value = [NSJSONSerialization JSONObjectWithData:payload options:0 error:error];
    if (![value isKindOfClass:NSDictionary.class]) {
        if (error && !*error) *error = messageError(@"The browser message must be a JSON object.");
        return nil;
    }
    return value;
}
BOOL SCBrowserWriteMessage(int descriptor, NSDictionary *message, NSError **error) {
    NSData *payload = [NSJSONSerialization dataWithJSONObject:message options:0 error:error];
    if (!payload || payload.length > 1024 * 1024) return NO;
    uint32_t length = (uint32_t)payload.length;
    BOOL success = transferBytes(descriptor, &length, sizeof(length), YES) &&
        transferBytes(descriptor, (void *)payload.bytes, length, YES);
    if (!success && error) *error = messageError(@"Could not reply to Chrome.");
    return success;
}
