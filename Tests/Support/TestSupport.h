#import <Foundation/Foundation.h>
NSUserDefaults *TGExtraUseTestDefaults(void);
void TGExtraTestHandlersAndMigration(void);
NSDictionary *TGExtraRunForwardCopyScenario(NSDictionary *fixture, NSURL *journalDirectory);

void TGExtraTestRustBridge(void);
NSDictionary *TGExtraTestReadContentsRequest(NSData *payload, NSString *account);
NSDictionary *TGExtraTestRustReadContentsRequest(NSData *payload, NSString *account, NSData *serverResponse);
NSData *TGExtraFakeResponseForPayload(NSData *payload);
void TGExtraTestSetGhostException(int64_t peerId, BOOL enabled);

BOOL TGExtraNativeTestConfig(NSDictionary *config, NSData *uuid, uintptr_t constructor, uintptr_t result);
void TGExtraNativeFixtureEnable(void);
NSData *TGExtraNativeFixtureParse(NSData *data, NSString *account, int32_t function, NSData *request, BOOL patch);
uint64_t TGExtraNativeFixtureParseCount(void);
int64_t TGExtraNativeFixtureLiveCount(void);

id TGExtraNativeFixtureDecode(NSData *data, NSString *account, int32_t function, NSData *request, BOOL patch) NS_RETURNS_RETAINED;
