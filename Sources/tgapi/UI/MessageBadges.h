#import "HostDisplayNode.h"

#ifdef __cplusplus
extern "C" {
#endif
void TGExtraUpdateMessageStatusBadge(ASDisplayNode *node, NSNumber *id, NSNumber *peer, NSString *account, NSNumber *messageNamespace);
void TGExtraUpdateEditBadge(ASDisplayNode *node, NSNumber *id, NSNumber *peer, NSString *account, NSNumber *messageNamespace);
void TGExtraClearEditBadgeBinding(UIButton *badge);
void TGExtraScheduleMessageBadgeUpdate(ASDisplayNode *node);
ASDisplayNode *TGExtraMessageNodeForView(UIView *view);
void TGExtraStartMessageBadges(void);
#ifdef __cplusplus
}
#endif
