#import "ProfileBridge.h"
#import "../Headers.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
static Class tgextraChatControllerClass(void) {
    Class cls = objc_getClass("_TtC10TelegramUI18ChatControllerImpl");
    return cls ?: objc_getClass("_TtC10TelegramUI14ChatController");
}

%group TGExtraChatContext
%hook _TtC10TelegramUI18ChatControllerImpl
- (void)viewWillAppear:(BOOL)animated {
    [TLParser registerVideoConversionChat:self];
    %orig;
}
- (void)viewDidLoad {
    %orig;
    @try {
        id context = [((id)self) valueForKey:@"context"];
        TGExtraProfileBridge.sharedContext = context;
        [TLParser registerMessageCleanupContext:context];
        NSNumber *currId = [TGExtraProfileBridge getCurrentUserId];
        if (currId) {
            [[NSUserDefaults standardUserDefaults] setInteger:[currId integerValue] forKey:@"TGExtraLastKnownUserId"];
        }
    } @catch (NSException *e) {}
}
%end
%end

%group TGExtraRootContext
%hook _TtC10TelegramUI22TelegramRootController
- (void)loadView {
    %orig;
    @try {
        id context = [((id)self) valueForKey:@"context"];
        if (context) {
            TGExtraProfileBridge.sharedContext = context;
            [TLParser registerMessageCleanupContext:context];
        }
    } @catch (NSException *e) {}
}
%end
%end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        Class chat = tgextraChatControllerClass();
        if (class_getInstanceMethod(chat, @selector(viewDidLoad))) { %init(TGExtraChatContext, _TtC10TelegramUI18ChatControllerImpl = chat); }
        Class root = objc_getClass("_TtC10TelegramUI22TelegramRootController");
        if (class_getInstanceMethod(root, @selector(loadView))) { %init(TGExtraRootContext, _TtC10TelegramUI22TelegramRootController = root); }
    });
}
