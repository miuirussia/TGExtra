#import <Foundation/Foundation.h>
NSUserDefaults *TGExtraUseTestDefaults(void);
void TGExtraTestHandlersAndMigration(void);
NSDictionary *TGExtraRunForwardCopyScenario(NSDictionary *fixture, NSURL *journalDirectory);

void TGExtraTestRustBridge(void);
NSDictionary *TGExtraTestReadContentsRequest(NSData *payload, NSString *account);
NSDictionary *TGExtraTestRustReadContentsRequest(NSData *payload, NSString *account, NSData *serverResponse);
NSData *TGExtraFakeResponseForPayload(NSData *payload);
void TGExtraTestSetGhostException(int64_t peerId, BOOL enabled);
