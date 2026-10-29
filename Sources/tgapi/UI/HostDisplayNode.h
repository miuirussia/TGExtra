#import <UIKit/UIKit.h>

@interface ASDisplayNode : NSObject
@property (atomic, readonly) UIView *view;
@property (atomic, copy, readonly) NSArray *subnodes;
@property (atomic, copy) NSString *accessibilityLabel;
@property (nonatomic, strong) UILongPressGestureRecognizer *tgextraLongPressGesture;
@property (nonatomic, strong) UITapGestureRecognizer *tapGesture;
- (ASDisplayNode *)supernode;
- (void)__handle5PleTap;
- (void)__handleTGExtraLongPress:(UILongPressGestureRecognizer *)gesture;
- (void)setNeedsLayout;
- (void)layoutIfNeeded;
@end

@interface UIView (TGExtraDisplayNode)
- (ASDisplayNode *)asyncdisplaykit_node;
@end

#ifdef __cplusplus
extern "C" {
#endif
ASDisplayNode *TGExtraFindDisplayNode(ASDisplayNode *root, NSString *name);
void TGExtraUpdateGhostExceptionButton(ASDisplayNode *header, long long peerId);
#ifdef __cplusplus
}
#endif
