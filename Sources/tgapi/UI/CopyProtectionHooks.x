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
        Method uiGetter = class_getInstanceMethod(ui, @selector(copyProtectionEnabled));
        if (TGExtraMethodMatches(uiGetter, @encode(BOOL), @[])) { %init(TGExtraCopyProtectionUI, _TtC10TelegramUI30ChatPresentationInterfaceState = ui); installed = YES; }
        Class state = objc_getClass("_TtC30ChatPresentationInterfaceState30ChatPresentationInterfaceState");
        Method stateGetter = class_getInstanceMethod(state, @selector(copyProtectionEnabled));
        if (TGExtraMethodMatches(stateGetter, @encode(BOOL), @[])) { %init(TGExtraCopyProtectionState, _TtC30ChatPresentationInterfaceState30ChatPresentationInterfaceState = state); installed = YES; }
        // Telegram 13.3 and Swiftgram 13.2 store this flag without an Objective-C getter.
        // Protocol copy-protection policies do not depend on this optional hook.
        NSString *status = installed ? @"installed" :
            ((uiGetter || stateGetter) ? @"unavailable: getter ABI" :
             ((ui || state) ? @"protocol policies; no Objective-C getter (optional)" : @"unavailable: presentation state"));
        TGExtraRecordHookStatus(@"Copy protection UI", status);
    });
}
