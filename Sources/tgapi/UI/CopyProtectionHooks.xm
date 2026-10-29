#import "../Compatibility.h"
#import "../Constants.h"
#import <objc/runtime.h>
%group TGExtraCopyProtectionUI
%hook _TtC10TelegramUI30ChatPresentationInterfaceState
- (BOOL)copyProtectionEnabled {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kDisableForwardRestriction]) {
        return NO;
    }
    return %orig;
}
%end
%end

%group TGExtraCopyProtectionState
%hook _TtC30ChatPresentationInterfaceState30ChatPresentationInterfaceState
- (BOOL)copyProtectionEnabled {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kDisableForwardRestriction]) {
        return NO;
    }
    return %orig;
}
%end
%end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        BOOL installed = NO;
        Class ui = objc_getClass("_TtC10TelegramUI30ChatPresentationInterfaceState");
        if (class_getInstanceMethod(ui, @selector(copyProtectionEnabled))) { %init(TGExtraCopyProtectionUI, _TtC10TelegramUI30ChatPresentationInterfaceState = ui); installed = YES; }
        Class state = objc_getClass("_TtC30ChatPresentationInterfaceState30ChatPresentationInterfaceState");
        if (class_getInstanceMethod(state, @selector(copyProtectionEnabled))) { %init(TGExtraCopyProtectionState, _TtC30ChatPresentationInterfaceState30ChatPresentationInterfaceState = state); installed = YES; }
        TGExtraRecordHookStatus(@"Copy protection UI", installed ? @"installed" : @"unavailable: presentation state");
    });
}
