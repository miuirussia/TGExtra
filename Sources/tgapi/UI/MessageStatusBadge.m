#import "MessageBadges.h"
#import "../Headers.h"
void TGExtraUpdateMessageStatusBadge(ASDisplayNode *node, NSNumber *msgId, NSNumber *nodePeerKey, NSString *account, NSNumber *messageNamespace) {
        BOOL isDeletedMsg = (msgId && messageNamespace && [TLParser isDeleted:msgId peer:nodePeerKey account:account messageNamespace:messageNamespace]);
        BOOL isSelfDestructMsg = (msgId && messageNamespace && [TLParser isMessageSelfDestructing:msgId peer:nodePeerKey account:account messageNamespace:messageNamespace]);
        if (isDeletedMsg || isSelfDestructMsg) {
            UIImageView *statusIcon = nil;
            for (UIView *v in node.view.subviews) {
                if (v.tag == 8898) {
                    statusIcon = (UIImageView *)v;
                    break;
                }
            }

            BOOL isNewlyCreated = NO;
            if (!statusIcon) {
                statusIcon = [[UIImageView alloc] init];
                statusIcon.tag = 8898;
                [node.view addSubview:statusIcon];
                isNewlyCreated = YES;
            }

            if (isDeletedMsg) {
                statusIcon.image = [UIImage systemImageNamed:@"trash.fill"];
                statusIcon.tintColor = [UIColor systemRedColor];
            } else {
                statusIcon.image = [UIImage systemImageNamed:@"timer"];
                statusIcon.tintColor = [UIColor systemOrangeColor];
            }

            ASDisplayNode *statusNode = TGExtraFindDisplayNode(node, @"ChatMessageDateAndStatusNode");
            if (statusNode && statusNode.view) {
                CGRect statusFrame = [node.view convertRect:statusNode.view.bounds fromView:statusNode.view];
                statusIcon.frame = CGRectMake(statusFrame.origin.x - 18, statusFrame.origin.y + (statusFrame.size.height / 2.0) - 7, 14, 14);
                statusIcon.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
            } else {
                statusIcon.frame = CGRectMake(node.view.bounds.size.width - 34, node.view.bounds.size.height - 32, 14, 14);
                statusIcon.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
            }

            BOOL wasHidden = statusIcon.hidden;
            statusIcon.hidden = NO;
            [node.view bringSubviewToFront:statusIcon];

            if (wasHidden || isNewlyCreated) {
                statusIcon.transform = CGAffineTransformMakeScale(0.1, 0.1);
                statusIcon.alpha = 0.0;
                [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0.8 options:UIViewAnimationOptionCurveEaseOut animations:^{
                    statusIcon.transform = CGAffineTransformIdentity;
                    statusIcon.alpha = 1.0;
                } completion:nil];
            }

        } else {
            node.view.backgroundColor = [UIColor clearColor];
            for (UIView *v in node.view.subviews) {
                if (v.tag == 8898) {
                    v.hidden = YES;
                }
            }
        }

}
