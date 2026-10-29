#import "Headers.h"
void TGExtraOpenTelegramURL(NSURL *url) {
    if (!url) return;
    id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
    if ([delegate respondsToSelector:@selector(application:openURL:options:)]) {
        if ([delegate application:UIApplication.sharedApplication openURL:url options:@{}]) {
            return;
        }
    }
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}
