#import <Foundation/Foundation.h>
// Native messaging frames use a native-endian 32-bit UTF-8 byte length.
NSDictionary *SCBrowserReadMessage(int descriptor, NSError **error);
BOOL SCBrowserWriteMessage(int descriptor, NSDictionary *message, NSError **error);
