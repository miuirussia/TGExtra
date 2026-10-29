#import "Headers.h"
#import "HostDisplayNode.h"
#import "../Logger/Logger.h"
#import "SettingsNavigation.h"
void showUI(void);

@interface LegacyComponentsGlobals : NSObject
+ (id)provider;
@end

@protocol LegacyComponentsGlobalsProvider
- (TGLocalization *)effectiveLocalization;
@end

#define TGExtraLoc(key) [TGExtraLocalization localizedStringForKey:(key)]

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

static BOOL tgextraLabelMatchesLocalizedKey(NSString *lower, NSString *key, BOOL twoWay) {
    TGLocalization *loc = getActiveTGLocalization();
    if (!loc) return NO;
    NSString *str = [loc get:key];
    if (str.length == 0 || [str isEqualToString:key]) return NO;
    NSString *needle = [str lowercaseString];
    if ([lower isEqualToString:needle]) return YES;
    if (twoWay) {
        return [lower containsString:needle] || [needle containsString:lower];
    }
    return needle.length >= 6 && [lower containsString:needle];
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

static BOOL tgextraLabelIsSupportRow(NSString *label) {
    if (label.length == 0) return NO;
    NSString *lower = [label lowercaseString];

    if ([lower containsString:@"turrit"]) return YES;
    if ([lower containsString:@"leadgram"]) return YES;
    if ([lower containsString:@"swiftgram"]) return YES;

    if ([lower isEqualToString:@"support"]) return YES;

    if ([lower isEqualToString:@"send a gift"]) return YES;
    if ([lower isEqualToString:@"tặng quà"]) return YES;

    static NSArray *known = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        known = @[
            @"ask a question", @"задать вопрос",
            @"hacer una pregunta", @"poser une question",
            @"stellen sie eine frage", @"fai una domanda", @"bir soru sor",
            @"질문하기", @"提问", @"提問",
            @"質問する", @"đặt câu hỏi"
        ];
    });
    for (NSString *s in known) {
        if ([lower containsString:s]) return YES;
    }

    if (tgextraLabelMatchesLocalizedKey(lower, @"Settings.SendGift", NO)) return YES;

    return tgextraLabelMatchesLocalizedKey(lower, @"Settings.Support", YES);
}

static void tgextraDiagSettingsRow(NSString *label, NSString *parentClass) {
#if TGEXTRA_DIAG
    static NSMutableSet *seen = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ seen = [NSMutableSet set]; });
    @synchronized(seen) {
        if (seen.count >= 80 || [seen containsObject:label]) return;
        [seen addObject:label];
    }
    tgextraDiag("settings-row label=%{public}s parent=%{public}s",
           label.UTF8String, parentClass.UTF8String);
#endif
}

static BOOL _tgextraGestureAttached = NO;

@interface TGExtraGestureTarget : NSObject
@end
@implementation TGExtraGestureTarget
- (void)handleLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateBegan) showUI();
}
@end
static TGExtraGestureTarget *_tgextraGestureTarget = nil;

static void tryAttachTGExtraGesture(void);

%hook TGLocalization
- (id)get:(id)key {
    if ([key isKindOfClass:NSString.class] && [key hasPrefix:@"Settings."]) TGLocalizationShared = self;
    if (!_tgextraGestureAttached) {
        dispatch_async(dispatch_get_main_queue(), ^{
            tryAttachTGExtraGesture();
        });
    }
    return %orig;
}

- (id)initWithVersion:(int)a code:(id)b dict:(id)c isActive:(BOOL)d {
    TGLocalization *instance = %orig;
    if (instance && a != 96929692) {
        TGLocalizationShared = instance;
        if (!_tgextraGestureAttached) {
            dispatch_async(dispatch_get_main_queue(), ^{
                tryAttachTGExtraGesture();
            });
        }
    }
    return instance;
}
%end

static void tryAttachTGExtraGestureInView(UIView *view) {
    if (!view) return;
    if ([NSStringFromClass([view class]) isEqualToString:@"Display.AccessibilityAreaNode"]) {
        NSString *label = view.accessibilityLabel;
        if (tgextraLabelIsSupportRow(label)) {
            UIView *parent = view.superview;
            if (parent) {
                BOOL alreadyHas = NO;
                for (UIGestureRecognizer *g in parent.gestureRecognizers) {
                    if ([g isKindOfClass:[UILongPressGestureRecognizer class]]) {
                        alreadyHas = YES; break;
                    }
                }
                if (!alreadyHas) {
                    if (!_tgextraGestureTarget) _tgextraGestureTarget = [TGExtraGestureTarget new];
                    UILongPressGestureRecognizer *gr = [[UILongPressGestureRecognizer alloc]
                        initWithTarget:_tgextraGestureTarget action:@selector(handleLongPress:)];
                    [parent addGestureRecognizer:gr];
                    _tgextraGestureAttached = YES;
                    customLog2(@"[TGExtra] late-attach OK: %@", label);
                }
            }
        }
        return;
    }
    for (UIView *sub in view.subviews) {
        tryAttachTGExtraGestureInView(sub);
        if (_tgextraGestureAttached) return;
    }
}

static void tryAttachTGExtraGesture(void) {
    if (_tgextraGestureAttached) return;
    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    if (window) tryAttachTGExtraGestureInView(window);
}

void showUI() { TGExtraShowSettings(); }

%hook ASDisplayNode

%property (nonatomic, strong) UILongPressGestureRecognizer *tgextraLongPressGesture;
%property (nonatomic, strong) UITapGestureRecognizer *tapGesture;
%new
- (void)__handle5PleTap { showUI(); }

- (void)setAccessibilityLabel:(NSString *)label {
    %orig;

    NSString *cls = NSStringFromClass([self class]);
    if (![cls containsString:@"AccessibilityAreaNode"]) return;
    if (!label || label.length == 0) return;

    ASDisplayNode *parent = [self supernode];
    if (!parent) return;
    NSString *parentCls = NSStringFromClass([parent class]);

    tgextraDiagSettingsRow(label, parentCls);

    if ([parentCls containsString:@"ChatMessage"]) return;

    if (!tgextraLabelIsSupportRow(label)) {
        tgextraDiag("unmatched settings label: %{public}@", label);
        return;
    }

    if (!parent.tgextraLongPressGesture) {
        UILongPressGestureRecognizer *gr = [[UILongPressGestureRecognizer alloc]
            initWithTarget:parent
                    action:@selector(__handleTGExtraLongPress:)];
        gr.cancelsTouchesInView = NO;
        gr.delaysTouchesBegan = NO;
        gr.delaysTouchesEnded = NO;
        parent.tgextraLongPressGesture = gr;
    }

    UIView *pv = parent.view;
    if (pv && ![pv.gestureRecognizers containsObject:parent.tgextraLongPressGesture]) {
        UIView *scan = pv;
        for (int depth = 0; scan && depth < 5; depth++, scan = scan.superview) {
            for (UIGestureRecognizer *existing in scan.gestureRecognizers) {
                if (existing == parent.tgextraLongPressGesture) continue;
                if (![existing isKindOfClass:[UILongPressGestureRecognizer class]]) continue;
                [existing requireGestureRecognizerToFail:parent.tgextraLongPressGesture];
                tgextraDiag("yielded host long-press %{public}s (depth %d) on row %{public}s",
                       NSStringFromClass([existing class]).UTF8String, depth,
                       label.UTF8String);
            }
        }

        [pv addGestureRecognizer:parent.tgextraLongPressGesture];
        customLog2(@"[TGExtra] gesture attached: %@", label);
        tgextraDiag("gesture attached to row %{public}s (parent %{public}s, %lu recognizer(s), "
               "%lu interaction(s))",
               label.UTF8String, parentCls.UTF8String,
               (unsigned long)pv.gestureRecognizers.count,
               (unsigned long)pv.interactions.count);
#if TGEXTRA_DIAG
        for (id<UIInteraction> interaction in pv.interactions) {
            tgextraDiag("  row %{public}s carries interaction %{public}s",
                   label.UTF8String, NSStringFromClass([interaction class]).UTF8String);
        }
#endif
    }
}

%new
- (void)__handleTGExtraLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        showUI();
    }
}

%end
%group TGExtraLegacyMenu
%hook TabBarNode

- (void)didEnterHierarchy {
	%orig;

	ASDisplayNode *mainNode = self;

    for (ASDisplayNode *child in mainNode.subnodes) {
		NSString *localizedTitle = @"Chats";

		NSString *resultTitle = [getActiveTGLocalization() get:@"DialogList.TabTitle"];
		if (resultTitle.length > 0 && ![resultTitle isEqualToString:@"DialogList.TabTitle"]) {
			localizedTitle = resultTitle;
		}

        if ([child.accessibilityLabel isEqualToString:localizedTitle]) {

			if (!child.tapGesture) {
				child.tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:child action:@selector(__handle5PleTap)];
				child.tapGesture.numberOfTapsRequired = 5;
			}

			if (![child.view.gestureRecognizers containsObject:child.tapGesture]) {
                [child.view addGestureRecognizer:child.tapGesture];
			}
        }
    }
}

%end
%end

@implementation ThreeFingerGestureHandler
- (void)handleThreeFingerLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) showUI();
}
@end

__attribute__((constructor)) static void TGExtraInstallLegacyMenu(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        Class tab = objc_getClass("TabBarUI.TabBarNode");
        if (tab && class_getInstanceMethod(tab, @selector(didEnterHierarchy))) {
            %init(TGExtraLegacyMenu, TabBarNode = tab);
        }
        static ThreeFingerGestureHandler *handler;
        handler = [ThreeFingerGestureHandler new];
        UIWindow *window = UIApplication.sharedApplication.keyWindow;
        UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
            initWithTarget:handler action:@selector(handleThreeFingerLongPress:)];
        gesture.numberOfTouchesRequired = 3;
        gesture.minimumPressDuration = 0.5;
        [window addGestureRecognizer:gesture];
    });
}

%ctor { dispatch_async(dispatch_get_main_queue(), ^{ %init; }); }
