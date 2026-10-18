//
//  SCDaemonXPC.h
//  selfcontrold
//
//  Created by Charlie Stigler on 5/30/20.
//

#import <Foundation/Foundation.h>
#import "SCDaemonProtocol.h"

NS_ASSUME_NONNULL_BEGIN

// Implementations for SC XPC methods
// (see SCDaemonProtocol for all method prototypes)
@interface SCDaemonXPC : NSObject <SCDaemonProtocol>
@property uid_t requestingUID;

@end

NS_ASSUME_NONNULL_END
