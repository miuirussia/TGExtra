#import <UIKit/UIKit.h>

@interface ASDisplayNode : NSObject
@property (atomic, readonly) UIView *view;
@property (atomic, readonly) CALayer *layer;
@property (atomic, copy, readonly) NSArray *subnodes;
@property (atomic, copy) NSString *accessibilityLabel;
@property (nonatomic, readonly, getter=isHidden) BOOL hidden;
@property (nonatomic, readonly) CGFloat alpha;
@property (nonatomic, readonly) UIColor *backgroundColor;
@property (nonatomic) CGRect frame;
@property (nonatomic) CGPoint position;
- (ASDisplayNode *)supernode;
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
