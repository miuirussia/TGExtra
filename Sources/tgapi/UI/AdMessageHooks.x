#import "Headers.h"
#import "HostDisplayNode.h"
#import "MessageBadges.h"
#import "ProfileBridge.h"
#import "../Headers.h"
#import "../Logger/Logger.h"
#import <objc/message.h>
#import <math.h>

%hook ASDisplayNode
- (void)layout {
    %orig;
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kDisableAllAds]) {
        @try {
            NSString *className = NSStringFromClass([self class]);
            if ([className containsString:@"ChatSponsoredMessage"] || [className containsString:@"ChatChannelAdItemNode"] ||
                [TLParser hasAdMessageFromNode:self]) {
                self.view.hidden = YES;
                self.view.alpha = 0.0;
                return;
            }
        } @catch (NSException *e) {}
    }

}
%end

%ctor { %init; }
