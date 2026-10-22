#import <Foundation/Foundation.h>
NSUserDefaults *TGExtraUseTestDefaults(void);
void TGExtraSetTestHostVersion(NSString *version);
void TGExtraTestHandlersAndMigration(void);
NSDictionary *TGExtraRunForwardCopyScenario(NSDictionary *fixture, NSURL *journalDirectory);
