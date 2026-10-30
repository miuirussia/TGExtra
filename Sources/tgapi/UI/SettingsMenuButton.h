#import <UIKit/UIKit.h>

@class ASDisplayNode;

@interface TGExtraSettingsButton : UIButton
- (void)matchRow:(ASDisplayNode *)row joined:(BOOL)joined;
- (void)restoreJoinedRow;
@end
