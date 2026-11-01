#import "Headers.h"

@interface LegacyComponentsGlobals : NSObject
+ (id)provider;
@end

@protocol LegacyComponentsGlobalsProvider
- (TGLocalization *)effectiveLocalization;
@end

static TGLocalization *TGLocalizationShared = nil;

static TGLocalization *getActiveTGLocalization(void) {
    if (TGLocalizationShared) return TGLocalizationShared;
    @try {
        Class cls = objc_getClass("LegacyComponentsGlobals");
        if (cls && [cls respondsToSelector:@selector(provider)]) {
            id provider = [cls performSelector:@selector(provider)];
            if ([provider respondsToSelector:@selector(effectiveLocalization)]) {
                TGLocalization *loc = [provider performSelector:@selector(effectiveLocalization)];
                if (loc) { TGLocalizationShared = loc; return loc; }
            }
        }
    } @catch (...) {}
    return nil;
}

BOOL TGExtraIsTelegramSupportLabel(NSString *label) {
    if (label.length == 0) return NO;
    NSString *lower = label.lowercaseString;
    NSString *localized = [getActiveTGLocalization() get:@"Settings.Support"];
    if (localized.length && ![localized isEqualToString:@"Settings.Support"] &&
        [lower isEqualToString:localized.lowercaseString]) return YES;
    for (NSString *text in @[@"ask a question", @"задать вопрос",
         @"hacer una pregunta", @"poser une question", @"stellen sie eine frage",
         @"fai una domanda", @"bir soru sor", @"질문하기", @"提问", @"提問",
         @"質問する", @"đặt câu hỏi"]) {
        if ([lower isEqualToString:text]) return YES;
    }
    return NO;
}

BOOL TGExtraIsMyProfileLabel(NSString *label) {
    if (label.length == 0) return NO;
    NSString *lower = label.lowercaseString;
    NSString *localized = [getActiveTGLocalization() get:@"Settings.MyProfile"];
    if (localized.length && ![localized isEqualToString:@"Settings.MyProfile"] &&
        [lower isEqualToString:localized.lowercaseString]) return YES;
    for (NSString *text in @[@"my profile", @"мой профиль", @"mi perfil",
         @"mon profil", @"mein profil", @"il mio profilo", @"profilim",
         @"내 프로필", @"我的资料", @"我的個人資料", @"マイプロフィール",
         @"hồ sơ của tôi"]) {
        if ([lower isEqualToString:text]) return YES;
    }
    return NO;
}

%hook TGLocalization
- (id)get:(id)key {
    if ([key isKindOfClass:NSString.class] && [key hasPrefix:@"Settings."]) {
        TGLocalizationShared = self;
    }
    return %orig;
}

- (id)initWithVersion:(int)a code:(id)b dict:(id)c isActive:(BOOL)d {
    TGLocalization *instance = %orig;
    if (instance && a != 96929692) {
        TGLocalizationShared = instance;
    }
    return instance;
}
%end

%ctor { dispatch_async(dispatch_get_main_queue(), ^{ %init; }); }
