#import <Foundation/Foundation.h>
@class SCXPCClient;
int SCBrowserNativeMain(int argc, char *argv[]);
int SCBrowserSetupMain(void);
int SCBrowserStatusMain(void);
NSDictionary *SCBrowserReadStatus(SCXPCClient *client, NSError **error);
