#import <UIKit/UIKit.h>

@class ASDisplayNode;

@interface TGExtraSettingsButton : UIButton
@property(nonatomic, weak) ASDisplayNode *profileSourceNode;
- (void)matchRow:(ASDisplayNode *)row joined:(BOOL)joined;
- (void)restoreJoinedRow;
@end
