#import <UIKit/UIKit.h>
#import "Headers.h"
#import "../PaidMedia.h"
#import "../Logger/Logger.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

void showUI(void);

@interface ASDisplayNode : NSObject
@property (atomic, assign, readonly) UIView *view;
@property (atomic, copy, readonly) NSArray *subnodes;
@property (atomic, copy, readwrite) NSString *accessibilityLabel;
@property (nonatomic, strong) UILongPressGestureRecognizer *tgextraLongPressGesture;
- (ASDisplayNode *)supernode;
@property (nonatomic, strong) UITapGestureRecognizer *tapGesture;
- (void)__handle5PleTap;
- (void)setNeedsLayout;
- (void)layoutIfNeeded;
@end

@interface _TtC18MultiScaleTextNode18MultiScaleTextNode : ASDisplayNode
@end

@interface _TtC14PeerInfoScreen18PeerInfoHeaderNode : ASDisplayNode
@property (nonatomic, strong) id peer;
@end

@interface LegacyComponentsGlobals : NSObject
+ (id)provider;
@end

@protocol LegacyComponentsGlobalsProvider
- (TGLocalization *)effectiveLocalization;
@end

// TGExtra's own translations, not the host's. Deliberately not called TGLoc the way
// TGExtra.m calls it: this file talks to both localisations and they answer
// different questions — TGExtraLoc for the tweak's own wording, and
// getActiveTGLocalization() below for what the host app named a row on screen.
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

// Does this label say what the host's own localisation says for `key`?
//
// Asking the host beats listing phrases: a fork ships whatever languages it
// ships, and a phrase list only covers the ones somebody thought to write down.
//
// `twoWay` additionally accepts a label the localised string *contains*, which
// is how a fork that shortens a row ("Support" under "Support & FAQ") still
// gets recognised. It is only safe where a false match costs nothing. The
// one-way form guards itself with a length floor instead: a language that
// renders the key as one short word would otherwise swallow every row that
// happens to contain that word.
static BOOL tgextraLabelMatchesLocalizedKey(NSString *lower, NSString *key, BOOL twoWay) {
    TGLocalization *loc = getActiveTGLocalization();
    if (!loc) return NO;
    NSString *str = [loc get:key];
    // TGLocalization hands the key straight back when it has no entry for it.
    if (str.length == 0 || [str isEqualToString:key]) return NO;
    NSString *needle = [str lowercaseString];
    if ([lower isEqualToString:needle]) return YES;
    if (twoWay) {
        return [lower containsString:needle] || [needle containsString:lower];
    }
    return needle.length >= 6 && [lower containsString:needle];
}

// Shared with the visible Settings entry. Do not include fork names or gift
// labels here: those can also occur on another person's profile.
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

// Is this accessibility label the "Ask a Question" row in Settings?
//
// That row is the one and only way into the tweak's own menu, so a label this
// function fails to recognise means a host app whose settings cannot be opened
// at all. Turrit renames the row to "About Turrit"; the brand name stays in
// Latin script in every localisation it ships, Chinese included (关于Turrit), so
// a bare "turrit" substring covers all of them at once. Matching the full
// English and Russian phrases — which is what this used to do — left the Chinese
// build with no way in.
static BOOL tgextraLabelIsSupportRow(NSString *label) {
    if (label.length == 0) return NO;
    NSString *lower = [label lowercaseString];

    // Forks that rename the row. Brand names are not translated.
    if ([lower containsString:@"turrit"]) return YES;
    if ([lower containsString:@"leadgram"]) return YES;
    if ([lower containsString:@"swiftgram"]) return YES;

    // iMe does not reuse Telegram's wording: measured on 12.2.7 its row reads
    // "Support", which matches neither the phrases below nor Settings.Support
    // ("Ask a Question") that the lookup at the bottom compares against.
    if ([lower isEqualToString:@"support"]) return YES;

    // A second way in, because the first one does not always work.
    //
    // iMe's Support row opens a context menu of its own on long press, and that
    // menu is not built on a UILongPressGestureRecognizer — measured, the only
    // long-press recogniser within five levels of the row is the scroll bar's.
    // So there is nothing to make yield, and the tweak never sees the gesture.
    //
    // The gift row carries no such menu. Both rows stay recognised: whichever
    // one the host leaves alone is the one that works.
    //
    // These two literals are only what was measured on an English and a
    // Vietnamese build. Listing them is not enough — an iMe running in Russian
    // or Chinese would have had no way into the tweak at all — so the real
    // test is the Settings.SendGift lookup further down, which covers every
    // language the host ships. The literals stay as a floor for the case where
    // LegacyComponentsGlobals is not reachable and the lookup returns nothing.
    if ([lower isEqualToString:@"send a gift"]) return YES;
    if ([lower isEqualToString:@"tặng quà"]) return YES;

    // Telegram's own wording, for the languages worth not paying a lookup for.
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

    // The gift row in whatever language the host is running in. One-way, because
    // a match here only needs to be right — nothing is lost by missing a row
    // that some fork shortened, and a great deal is lost by claiming a row that
    // merely contains the word for "gift".
    if (tgextraLabelMatchesLocalizedKey(lower, @"Settings.SendGift", NO)) return YES;

    // Anything else: ask the running localisation. Compared both ways because a
    // fork may shorten the row ("Support" under "Support & FAQ") or pad it.
    return tgextraLabelMatchesLocalizedKey(lower, @"Settings.Support", YES);
}

// Reports every settings row that carries an accessibility label, with the node
// it hangs off. The one thing that decides whether the tweak can be opened at
// all is what that label actually says in the host app — guessing at it is what
// left the Chinese Turrit build and iMe with no way in.
//
// os_log, not customLog2: customLog2 writes to a file inside the app sandbox
// that a tethered Mac cannot read, so a probe written with it reports nothing
// and its silence looks like a negative result.
//
// Bounded, because settings screens set labels on every scroll pass.
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

void showUI();

// Defined further down, next to the rest of the edit-history code. Declared
// here so the notification observer above it can refresh a badge directly
// instead of asking for a layout pass that AsyncDisplayKit may never schedule.
static void updateTGExtraEditBadge(ASDisplayNode *node, NSNumber *msgId, NSNumber *peerKey, NSString *account, NSNumber *messageNamespace);
static void clearTGExtraEditBadgeBinding(UIButton *badge);

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

static BOOL _tgextraGestureAttached = NO;

// Helper target object for late-attached gestures
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
        // Settings may already be rendered — try to attach gesture now
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

void showUI() {
	// Attaching the gesture and the menu actually appearing are two different
	// claims, and only the first one used to leave a trace.
	tgextraDiag("showUI called");
	TGExtra *ui = [TGExtra new];
	UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:ui];

	UIWindow *window = UIApplication.sharedApplication.keyWindow;
	UIViewController *rootVC = window.rootViewController;
	while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;
	if ([rootVC isKindOfClass:UINavigationController.class] &&
	    [((UINavigationController *)rootVC).viewControllers.firstObject isKindOfClass:TGExtra.class]) return;
	if (rootVC) {
	    [rootVC presentViewController:navVC animated:YES completion:nil];
	}
}



// ============================================================
// Long-press to open TGExtra menu on "Ask a Question" row.
//
// Root cause of the language bug: didEnterHierarchy fires BEFORE
// update() sets accessibilityLabel, so the label is always empty
// at that point. The fix: hook setAccessibilityLabel: on
// AccessibilityAreaNode — it's called from update() with the
// correct localized text, regardless of language.
//
// "Ask a Question" is always id:0 in the .support section —
// its parent is always PeerInfoScreenDisclosureItemNode.
// We identify it by checking the parent node class + label;
// tgextraLabelIsSupportRow() owns the label half of that test and
// is shared with the late-attach path.
// ============================================================

%hook ASDisplayNode

%property (nonatomic, strong) UILongPressGestureRecognizer *tgextraLongPressGesture;
%property (nonatomic, strong) UITapGestureRecognizer *tapGesture;
%new
- (void)__handle5PleTap { showUI(); }

- (void)setAccessibilityLabel:(NSString *)label {
    %orig;

    // containsString rather than an exact match: a fork is free to vend its own
    // subclass, and the name is the only thing we can rely on here.
    NSString *cls = NSStringFromClass([self class]);
    if (![cls containsString:@"AccessibilityAreaNode"]) return;
    if (!label || label.length == 0) return;

    ASDisplayNode *parent = [self supernode];
    if (!parent) return;
    NSString *parentCls = NSStringFromClass([parent class]);

    tgextraDiagSettingsRow(label, parentCls);

    // A chat bubble also labels itself, and long-press there belongs to the
    // message context menu. Nothing else is off limits: the label is what
    // decides, and the parent is only somewhere to hang the gesture.
    //
    // This used to insist the parent be a *DisclosureItemNode. Measured on iMe,
    // 38 of 56 settings rows hand back Display.ContextControllerSourceNode
    // instead, so that test threw away the row we were looking for before the
    // label was ever consulted.
    if ([parentCls containsString:@"ChatMessage"]) return;

    if (!tgextraLabelIsSupportRow(label)) {
        tgextraDiag("unmatched settings label: %{public}@", label);
        return;
    }

    if (!parent.tgextraLongPressGesture) {
        UILongPressGestureRecognizer *gr = [[UILongPressGestureRecognizer alloc]
            initWithTarget:parent
                    action:@selector(__handleTGExtraLongPress:)];
        // The row may already long-press into a context menu of its own —
        // Display.ContextControllerSourceNode exists for exactly that. Let the
        // touch through so whatever the host wanted to do still happens.
        gr.cancelsTouchesInView = NO;
        gr.delaysTouchesBegan = NO;
        gr.delaysTouchesEnded = NO;
        parent.tgextraLongPressGesture = gr;
    }

    UIView *pv = parent.view;
    if (pv && ![pv.gestureRecognizers containsObject:parent.tgextraLongPressGesture]) {
        // The row usually long-presses into a context menu of its own. Two
        // recognizers watching the same gesture means the host's wins and ours
        // never fires — measured on iMe, where the gesture attached and showUI
        // was never called once.
        //
        // Making the host's wait on ours, rather than adding ours and hoping,
        // is the only arrangement where a long press reliably reaches the tweak.
        // Taps are left alone so the row still opens on a normal press.
        // Walk up as well as across: the context menu recogniser is not
        // necessarily on the row's own view.
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
        // What actually competes for a long press is often a UIInteraction, not
        // a recogniser — that is why the yield above found nothing on the row
        // itself, and why the Support row opens iMe's menu instead of ours while
        // the gift row, which carries none, works. Name them so the next
        // investigation does not have to guess either.
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



#import "../Headers.h"

@interface ASDisplayNode (TGExtra)
@property (nonatomic, readonly) UIView *view;
@property (nonatomic, copy, readonly) NSArray *subnodes;
@end

static ASDisplayNode *findNodeByClassNamePrefix(ASDisplayNode *root, NSString *prefix) {
    if (!root) return nil;
    if ([NSStringFromClass([root class]) containsString:prefix]) {
        return root;
    }
    @try {
        NSArray *subs = root.subnodes;
        for (ASDisplayNode *child in subs) {
            ASDisplayNode *found = findNodeByClassNamePrefix(child, prefix);
            if (found) return found;
        }
    } @catch (NSException *e) {}
    return nil;
}

static BOOL injectBadgeToNode(ASDisplayNode *textNode, ASDisplayNode *headerNode, long long peerId) {
    @try {
        if (!textNode.view || !headerNode.view) return NO;

        NSString *prefix = nil;
        UIColor *badgeColor = [UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:1.0]; // TGExtra Blue

        // Add your IDs here
        if (peerId == 5576711589 || peerId == 7846965839) {
            prefix = @"👑 TGExtra Owner";
            badgeColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.0 alpha:1.0]; // Gold
        } else {
            NSNumber *currId = [TLParser getOwnUserIdFromNode:headerNode];
            if (currId && [currId longLongValue] == peerId) {
                prefix = @"✨ TGExtra User";
            }
        }

        if (!prefix) {
            UIView *oldBadge = [headerNode.view viewWithTag:9988];
            if (oldBadge) [oldBadge removeFromSuperview];
            return NO;
        }

        UILabel *badge = (UILabel *)[headerNode.view viewWithTag:9988];
        if (!badge) {
            badge = [[UILabel alloc] init];
            badge.tag = 9988;
            badge.font = [UIFont boldSystemFontOfSize:10];
            badge.textColor = [UIColor whiteColor];
            badge.layer.cornerRadius = 4;
            badge.layer.masksToBounds = YES;
            badge.layer.zPosition = 9999;
            [headerNode.view addSubview:badge];
        }

        badge.backgroundColor = badgeColor;
        badge.text = [NSString stringWithFormat:@" %@ ", prefix];
        [badge sizeToFit];

        CGRect textFrame = [textNode.view convertRect:textNode.view.bounds toView:headerNode.view];
        if (textFrame.size.width > 0) {
            badge.frame = CGRectMake(textFrame.origin.x + textFrame.size.width + 6,
                                     textFrame.origin.y + (textFrame.size.height - badge.frame.size.height) / 2.0,
                                     badge.frame.size.width, badge.frame.size.height);
        } else {
            badge.frame = CGRectMake(headerNode.view.frame.size.width - badge.frame.size.width - 15, 45, badge.frame.size.width, badge.frame.size.height);
        }
        // Anything landing outside the header is a text node that is not laid
        // out yet, or not on screen at all. Placing the badge there is what put
        // it above the top edge; better to leave it for the next layout pass.
        if (!CGRectContainsRect(headerNode.view.bounds, CGRectInset(badge.frame, -1, -1))) {
            badge.hidden = YES;
            return NO;
        }

        badge.hidden = NO;
        [headerNode.view bringSubviewToFront:badge];
        return YES;
    } @catch (NSException *e) {}
    return NO;
}

/// Returns YES once the badge has been placed, so the walk can stop.
///
/// A header holds several text nodes — name, status, sometimes more. Every one
/// of them used to be handed to injectBadgeToNode, and since they all address
/// the same tagged label the badge ended up wherever the *last* node happened to
/// be, which is how it came to sit off the top of the screen. The name comes
/// first in the tree, so the first match is the one worth keeping.
static BOOL recursiveSearchAndInject(ASDisplayNode *node, ASDisplayNode *header, long long peerId) {
    if (!node) return NO;
    NSString *cls = NSStringFromClass([node class]);

    if ([cls containsString:@"TextNode"] && ![cls containsString:@"Accessibility"] && ![cls containsString:@"Button"]) {
        if (injectBadgeToNode(node, header, peerId)) return YES;
    }
    @try {
        NSArray *subs = node.subnodes;
        for (ASDisplayNode *sub in subs) {
            if (recursiveSearchAndInject(sub, header, peerId)) return YES;
        }
    } @catch (NSException *e) {}
    return NO;
}

// ============================================================
// Ghost Mode exception button, injected into a peer's profile header.
//
// Tapping it puts that user on the Ghost Exceptions list, so they keep seeing
// your real typing indicators and read receipts while Ghost Mode stays on for
// everybody else.
// ============================================================

#import "../GhostExceptions.h"

#define kTGExtraGhostExceptionButtonTag 9977

static const void *kTGExtraGhostPeerIdKey = &kTGExtraGhostPeerIdKey;
static const void *kTGExtraGhostNodeBoxKey = &kTGExtraGhostNodeBoxKey;

// Holds the header node weakly. Associating the node directly would form a
// retain cycle (node -> view -> button -> node) and leak every profile opened.
@interface TGExtraWeakBox : NSObject
@property (nonatomic, weak) id object;
@end
@implementation TGExtraWeakBox
@end

// Brief self-dismissing confirmation. The button's only state is a small icon,
// which is too subtle on its own to tell the user what just happened.
void TGExtraOpenTelegramURL(NSURL *url) {
    if (!url) return;
    id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
    if ([delegate respondsToSelector:@selector(application:openURL:options:)]) {
        if ([delegate application:UIApplication.sharedApplication openURL:url options:@{}]) {
            return;
        }
    }
    // Only reached when this app declined the URL, in which case letting iOS
    // route it is better than doing nothing.
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

void TGExtraShowToast(NSString *text) {
    // Audio extraction reports progress from a background queue, so callers
    // cannot be trusted to already be on main.
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ TGExtraShowToast(text); });
        return;
    }

    UIWindow *window = UIApplication.sharedApplication.keyWindow;
    if (!window) return;

    UILabel *toast = [[UILabel alloc] init];
    toast.text = text;
    toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    toast.textColor = [UIColor whiteColor];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.82];
    toast.numberOfLines = 0;
    toast.layer.cornerRadius = 14;
    toast.layer.masksToBounds = YES;
    toast.layer.zPosition = 99999;
    toast.alpha = 0.0;

    CGFloat maxWidth = window.bounds.size.width - 80;
    CGSize fitted = [toast sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)];
    CGFloat width = MIN(maxWidth, fitted.width + 32);
    CGFloat height = fitted.height + 20;
    toast.frame = CGRectMake((window.bounds.size.width - width) / 2.0,
                             window.bounds.size.height - height - 120,
                             width, height);

    [window addSubview:toast];
    [UIView animateWithDuration:0.2 animations:^{ toast.alpha = 1.0; } completion:^(BOOL done) {
        [UIView animateWithDuration:0.3 delay:1.6 options:0 animations:^{
            toast.alpha = 0.0;
        } completion:^(BOOL finished) {
            [toast removeFromSuperview];
        }];
    }];
}

static void updateGhostExceptionButtonAppearance(UIButton *button, BOOL isException) {
    UIImage *icon = [UIImage systemImageNamed:isException ? @"eye.fill" : @"eye.slash.fill"];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:16
                                                        weight:UIImageSymbolWeightSemibold];
    if (cfg && icon) icon = [icon imageByApplyingSymbolConfiguration:cfg];
    [button setImage:icon forState:UIControlStateNormal];
    button.accessibilityLabel = TGExtraLoc(@"GHOST_EXCEPTIONS_SECTION_HEADER");
    button.accessibilityValue = TGExtraLoc(isException ? @"GHOST_EXCEPTION_ADDED_TOAST" : @"GHOST_EXCEPTION_REMOVED_TOAST");
    button.tintColor = isException ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
}

@interface TGExtraGhostExceptionButtonTarget : NSObject
+ (instancetype)shared;
@end

@implementation TGExtraGhostExceptionButtonTarget

+ (instancetype)shared {
    static TGExtraGhostExceptionButtonTarget *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [self new]; });
    return instance;
}

- (void)handleTap:(UIButton *)sender {
    NSNumber *peerId = objc_getAssociatedObject(sender, kTGExtraGhostPeerIdKey);
    if (!peerId || peerId.longLongValue == 0) return;

    BOOL wasException = [TGExtraGhostExceptions containsPeerId:peerId.longLongValue];

    if (wasException) {
        [TGExtraGhostExceptions removePeerId:peerId.longLongValue];
        tgextraDiag("exception REMOVE peer=%{public}@", peerId);
        TGExtraShowToast([TGExtraLocalization localizedStringForKey:@"GHOST_EXCEPTION_REMOVED_TOAST"]);
    } else {
        // The name lookup is deliberately deferred to this point: it builds a
        // full description of the node, far too slow to do during layout.
        NSString *name = nil;
        NSString *username = nil;
        TGExtraWeakBox *box = objc_getAssociatedObject(sender, kTGExtraGhostNodeBoxKey);
        if (box.object) {
            @try {
                NSDictionary *info = [TLParser getPeerDisplayInfoFromNode:box.object];
                name = info[@"name"];
                username = info[@"username"];
            } @catch (NSException *e) {}
        }

        // Reflecting over the header node only works when the host hands the
        // tweak a peer object it can walk, which this fork does not — entries
        // ended up filed with no name and the list showed a bare numeric ID.
        // The same two fields came off the wire when the profile was opened.
        if (!name.length && !username.length) {
            @try {
                NSDictionary *cached = [TLParser cachedPeerInfoForId:peerId];
                name = cached[@"name"];
                username = cached[@"username"];
            } @catch (NSException *e) {}
        }

        [TGExtraGhostExceptions addPeerId:peerId.longLongValue name:name username:username];
        tgextraDiag("exception ADD peer=%{public}@ name=%{public}@ username=%{public}@", peerId,
                 name ?: @"(none)", username ?: @"(none)");
        TGExtraShowToast([TGExtraLocalization localizedStringForKey:@"GHOST_EXCEPTION_ADDED_TOAST"]);
    }

    updateGhostExceptionButtonAppearance(sender, !wasException);

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];
}

@end

// Profile diagnostics are compiled out with TGEXTRA_DIAG.
static void tgextraDiagProfileNode(NSString *cls, long long peerId, ASDisplayNode *node) {
#if TGEXTRA_DIAG
    static NSMutableSet *seen = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ seen = [NSMutableSet new]; });

    NSString *key = [NSString stringWithFormat:@"%@|%lld", cls, peerId];
    BOOL isNew = NO;
    @synchronized(seen) {
        if (![seen containsObject:key]) {
            [seen addObject:key];
            isNew = YES;
        }
    }
    if (!isNew) return;

    tgextraDiag("profile-node cls=%{public}@ peerId=%lld", cls, peerId);

    // Only the header node is worth dumping, and only when its peer came back
    // empty — that dump is what says whether the peer is absent or just unread.
    static BOOL dumped = NO;
    if (!dumped && peerId == 0 && [cls containsString:@"Header"]) {
        dumped = YES;
        @try {
            tgextraDiag("header-dump %{public}@", [TLParser debugPeerCandidates:node]);
        } @catch (NSException *e) {
            tgextraDiag("header-dump failed: %{public}@", e);
        }
    }
#endif
}

static void injectGhostExceptionButton(ASDisplayNode *headerNode, long long peerId) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            injectGhostExceptionButton(headerNode, peerId);
        });
        return;
    }

    @try {
        UIView *headerView = headerNode.view;
        if (!headerView) return;

        UIButton *existing = (UIButton *)[headerView viewWithTag:kTGExtraGhostExceptionButtonTag];

        // Users only — GhostExceptions.h explains why groups and channels are
        // out of scope. Your own profile gets nothing either.
        BOOL isOwnProfile = NO;
        BOOL ownIdKnown = NO;
        if (peerId > 0) {
            NSNumber *currentUserId = [TLParser getOwnUserIdFromNode:headerNode];
            ownIdKnown = (currentUserId != nil);
            isOwnProfile = (ownIdKnown && currentUserId.longLongValue == peerId);
            tgextraDiag("ghost-button peer=%lld me=%lld own=%d",
                     peerId, ownIdKnown ? currentUserId.longLongValue : -1, isOwnProfile);
        }
        // Not knowing who we are used to read as "this is somebody else", which
        // put the button on your own profile — the one place it must never be.
        // Withholding it costs nothing until the id arrives; the button only
        // matters once Ghost Mode is on, and by then a users vector has been
        // seen.
        if (peerId <= 0 || isOwnProfile || !ownIdKnown) {
            if (existing) [existing removeFromSuperview];
            return;
        }

        BOOL isException = [TGExtraGhostExceptions containsPeerId:peerId];

        UIButton *button = existing;
        if (!button) {
            button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.tag = kTGExtraGhostExceptionButtonTag;
            button.layer.zPosition = 9999;
            button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                      UIViewAutoresizingFlexibleBottomMargin;
            [button addTarget:[TGExtraGhostExceptionButtonTarget shared]
                       action:@selector(handleTap:)
             forControlEvents:UIControlEventTouchUpInside];
            [headerView addSubview:button];
        }

        objc_setAssociatedObject(button, kTGExtraGhostPeerIdKey, @(peerId),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        TGExtraWeakBox *box = [TGExtraWeakBox new];
        box.object = headerNode;
        objc_setAssociatedObject(button, kTGExtraGhostNodeBoxKey, box,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Anchored against the window's safe area, not the header's own origin.
        // The header starts flush with the top of the screen, so a small y here
        // lands the button under the status bar and navigation bar — drawn, but
        // with its touches swallowed by the bar above it.
        const CGFloat buttonSize = 44.0;
        const CGFloat rightMargin = 12.0;
        const CGFloat belowNavBar = 52.0;

        UIWindow *window = headerView.window ?: UIApplication.sharedApplication.keyWindow;
        CGRect frame;
        if (window) {
            CGPoint desired = CGPointMake(
                CGRectGetWidth(window.bounds) - buttonSize - rightMargin,
                window.safeAreaInsets.top + belowNavBar);
            CGPoint local = [headerView convertPoint:desired fromView:nil];
            frame = CGRectMake(local.x, local.y, buttonSize, buttonSize);
        } else {
            frame = CGRectMake(CGRectGetWidth(headerView.bounds) - buttonSize - rightMargin,
                               100.0, buttonSize, buttonSize);
        }
        button.frame = frame;
        updateGhostExceptionButtonAppearance(button, isException);
        [headerView bringSubviewToFront:button];
    } @catch (NSException *e) {}
}

static void updateTGExtraStatusBadge(ASDisplayNode *node, NSNumber *msgId, NSNumber *nodePeerKey, NSString *account, NSNumber *messageNamespace) {
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

            ASDisplayNode *statusNode = findNodeByClassNamePrefix(node, @"ChatMessageDateAndStatusNode");
            if (statusNode && statusNode.view) {
                CGRect statusFrame = [node.view convertRect:statusNode.view.bounds fromView:statusNode.view];
                statusIcon.frame = CGRectMake(statusFrame.origin.x - 18, statusFrame.origin.y + (statusFrame.size.height / 2.0) - 7, 14, 14);
                statusIcon.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
            } else {
                // Same 14pt as the anchored branch. A bubble with no
                // date-and-status node — a sticker, a GIF, a round video — used
                // to get a 20pt icon here, visibly bigger than the one every
                // other message shows.
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

static NSHashTable *activeMessageNodes = nil;

static void trackTGExtraMessageNode(ASDisplayNode *node) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        activeMessageNodes = [NSHashTable weakObjectsHashTable];
    });
    @synchronized(activeMessageNodes) {
        [activeMessageNodes addObject:node];
    }
}

static NSHashTable *pendingMessageNodes = nil;
static BOOL messageBadgeUpdateScheduled = NO;

static void scheduleTGExtraEditBadgeUpdate(ASDisplayNode *node) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ scheduleTGExtraEditBadgeUpdate(node); });
        return;
    }
    trackTGExtraMessageNode(node);
    if (!pendingMessageNodes) pendingMessageNodes = [NSHashTable weakObjectsHashTable];
    [pendingMessageNodes addObject:node];
    if (messageBadgeUpdateScheduled) return;
    messageBadgeUpdateScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *nodes = pendingMessageNodes.allObjects;
        [pendingMessageNodes removeAllObjects];
        messageBadgeUpdateScheduled = NO;
        for (ASDisplayNode *current in nodes) {
            // Resolve the current item after reuse, then observe and draw from
            // that same read. No ASDisplayNode.layout call is needed.
            NSDictionary *state = [TLParser messageStateFromNode:current observe:YES];
            updateTGExtraStatusBadge(current, state[@"id"], state[@"peer"], state[@"account"], state[@"namespace"]);
            updateTGExtraEditBadge(current, state[@"id"], state[@"peer"], state[@"account"], state[@"namespace"]);
        }
    });
}

@interface UIView (TGExtraMessageNode)
- (ASDisplayNode *)asyncdisplaykit_node;
@end

static ASDisplayNode *tgextraMessageNodeForView(UIView *view) {
    if (![view respondsToSelector:@selector(asyncdisplaykit_node)]) return nil;
    ASDisplayNode *node = [view asyncdisplaykit_node];
    NSString *name = NSStringFromClass([node class]);
    return [name containsString:@"ChatMessage"] && [name containsString:@"ItemNode"] ? node : nil;
}

// _ASDisplayView's UIKit lifecycle remains Objective-C in Telegram 13.0.0.
// layoutSubviews is inherited; didMoveToWindow is implemented by the view.
%group TGExtraMessageViewLayout
%hook _ASDisplayView
- (void)layoutSubviews {
    %orig;
    if ([(UIView *)self respondsToSelector:@selector(asyncdisplaykit_node)]) {
        TGExtraUpdatePaidMediaSaveButton([(UIView *)self asyncdisplaykit_node]);
    }
    ASDisplayNode *node = tgextraMessageNodeForView((UIView *)self);
    if (node) scheduleTGExtraEditBadgeUpdate(node);
}
%end
%end

%group TGExtraMessageViewWindow
%hook _ASDisplayView
- (void)didMoveToWindow {
    %orig;
    if ([(UIView *)self respondsToSelector:@selector(asyncdisplaykit_node)]) {
        TGExtraUpdatePaidMediaSaveButton([(UIView *)self asyncdisplaykit_node]);
    }
    ASDisplayNode *node = tgextraMessageNodeForView((UIView *)self);
    if (node) scheduleTGExtraEditBadgeUpdate(node);
}
%end
%end

@interface TGExtraAntiRevokeUpdater : NSObject
@end
@implementation TGExtraAntiRevokeUpdater
+ (instancetype)shared {
    static id instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [self new];
        // Both notifications refresh matching message badges directly: a
        // message change need not trigger another -layout call.
        [[NSNotificationCenter defaultCenter] addObserver:instance selector:@selector(handleMessagesChanged:) name:@"TGExtraMessageDeletedRealtime" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:instance selector:@selector(handleMessagesChanged:) name:@"TGExtraMessageEditedRealtime" object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:instance selector:@selector(handleMessageDataCleared:) name:@"TGExtraMessageDataCleared" object:nil];
    });
    return instance;
}
- (void)handleMessageDataCleared:(NSNotification *)note {
    NSHashTable *nodesCopy = nil;
    @synchronized(activeMessageNodes) {
        nodesCopy = [activeMessageNodes copy];
    }
    for (ASDisplayNode *node in nodesCopy) {
        for (UIView *view in node.view.subviews) {
            if (view.tag == 8898) view.hidden = YES;
            if (view.tag == 8899) clearTGExtraEditBadgeBinding((UIButton *)view);
        }
    }
}
- (void)handleMessagesChanged:(NSNotification *)note {
    NSArray *deletedIds = note.userInfo[@"ids"];
    NSNumber *maxId = note.userInfo[@"maxId"];
    if (deletedIds.count == 0 && !maxId) return;

    NSHashTable *nodesCopy = nil;
    @synchronized(activeMessageNodes) {
        nodesCopy = [activeMessageNodes copy];
    }

    for (ASDisplayNode *node in nodesCopy) {
        NSDictionary *state = [TLParser messageStateFromNode:node observe:NO];
        NSNumber *msgId = state[@"id"];
        if (!msgId || (![deletedIds containsObject:msgId] && !(maxId && msgId.intValue > 0 && msgId.intValue <= maxId.intValue))) continue;
        NSString *account = note.userInfo[@"account"];
        if (account && ![account isEqualToString:state[@"account"]]) continue;
        NSNumber *changedPeer = note.userInfo[@"peer"];
        NSNumber *messageNamespace = note.userInfo[@"namespace"];
        if (messageNamespace && ![messageNamespace isEqual:state[@"namespace"]]) continue;
        NSNumber *nodePeer = state[@"peer"];
        if (changedPeer && changedPeer.longLongValue != 0 && ![changedPeer isEqual:nodePeer]) continue;
        if (changedPeer && changedPeer.longLongValue == 0 && (!nodePeer || nodePeer.longLongValue <= -1000000000000LL)) continue;

        scheduleTGExtraEditBadgeUpdate(node);
    }
}
@end

// ============================================================
// Edit history: a pencil badge on any message Anti-Edit has more than one
// recorded version of. Tapping it lists every version, oldest first, while
// the bubble continues to display Telegram's current message.
// ============================================================
static const NSInteger kTGExtraEditBadgeTag = 8899;
static char kTGExtraEditMsgIdKey;
static char kTGExtraEditPeerKey;
static char kTGExtraEditAccountKey;
static char kTGExtraEditNamespaceKey;

static void clearTGExtraEditBadgeBinding(UIButton *badge) {
    if (!badge) return;
    badge.hidden = YES;
    objc_setAssociatedObject(badge, &kTGExtraEditMsgIdKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(badge, &kTGExtraEditPeerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(badge, &kTGExtraEditAccountKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(badge, &kTGExtraEditNamespaceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@interface TGExtraEditHistoryButtonTarget : NSObject
+ (instancetype)shared;
@end

@implementation TGExtraEditHistoryButtonTarget

+ (instancetype)shared {
    static TGExtraEditHistoryButtonTarget *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [self new]; });
    return instance;
}

- (void)handleTap:(UIButton *)sender {
    NSNumber *msgId = objc_getAssociatedObject(sender, &kTGExtraEditMsgIdKey);
    if (!msgId) return;
    NSNumber *peerKey = objc_getAssociatedObject(sender, &kTGExtraEditPeerKey);
    NSString *account = objc_getAssociatedObject(sender, &kTGExtraEditAccountKey);
    NSNumber *messageNamespace = objc_getAssociatedObject(sender, &kTGExtraEditNamespaceKey);

    ASDisplayNode *node = tgextraMessageNodeForView(sender.superview);
    NSDictionary *current = node ? [TLParser messageStateFromNode:node observe:NO] : nil;
    if (![msgId isEqual:current[@"id"]] || ![peerKey isEqual:current[@"peer"]] ||
        ![account isEqual:current[@"account"]] || ![messageNamespace isEqual:current[@"namespace"]]) {
        clearTGExtraEditBadgeBinding(sender);
        if (node) scheduleTGExtraEditBadgeUpdate(node);
        return;
    }

    NSArray<NSString *> *versions = [TLParser editHistoryForId:msgId peer:peerKey account:account messageNamespace:messageNamespace];
    if (versions.count < 2) return;
    NSArray<NSDictionary *> *details = [TLParser editRevisionDetailsForId:msgId peer:peerKey account:account messageNamespace:messageNamespace];

    NSMutableString *body = [NSMutableString string];
    for (NSUInteger i = 0; i < versions.count; i++) {
        NSString *label = (i == 0) ? [TGExtraLocalization localizedStringForKey:@"EDIT_HISTORY_ORIGINAL"]
                                   : [NSString stringWithFormat:@"%@ %lu",
                                        [TGExtraLocalization localizedStringForKey:@"EDIT_HISTORY_EDIT"],
                                        (unsigned long)i];
        [body appendFormat:@"%@\n%@", label, versions[i]];
        NSDictionary *revision = i < details.count ? details[i] : nil;
        if ([revision[@"mediaChanged"] boolValue]) {
            [body appendFormat:@"\n[%@]", TGExtraLoc(@"EDIT_HISTORY_MEDIA_CHANGED")];
        }
        if ([revision[@"formatChanged"] boolValue]) {
            [body appendFormat:@"\n[%@]", TGExtraLoc(@"EDIT_HISTORY_FORMAT_CHANGED")];
        }
        if (i < versions.count - 1) [body appendString:@"\n\n"];
    }

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:[TGExtraLocalization localizedStringForKey:@"EDIT_HISTORY_TITLE"]
                         message:body
                  preferredStyle:UIAlertControllerStyleAlert];

    // The newest version is what the user came for, so that is what Copy takes.
    [sheet addAction:[UIAlertAction
        actionWithTitle:[TGExtraLocalization localizedStringForKey:@"EDIT_HISTORY_COPY_LATEST"]
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction *action) {
                    UIPasteboard.generalPasteboard.string = versions.lastObject;
                }]];
    [sheet addAction:[UIAlertAction
        actionWithTitle:[TGExtraLocalization localizedStringForKey:@"CLOSE"]
                  style:UIAlertActionStyleCancel
                handler:nil]];

    UIViewController *top = sender.window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (top) [top presentViewController:sheet animated:YES completion:nil];
}

@end

static void tgextraCollectEditBadgeObstacles(UIView *view, UIView *root, UIButton *badge, NSMutableArray<NSValue *> *frames) {
    if (view == badge || view.hidden || view.alpha <= 0.01) return;
    if (view != root) {
        ASDisplayNode *node = [view respondsToSelector:@selector(asyncdisplaykit_node)] ? [view asyncdisplaykit_node] : nil;
        NSString *name = NSStringFromClass([node class]);
        // AsyncDisplayKit controls are often plain UIViews, not UIControls.
        BOOL isControl = [view isKindOfClass:[UIControl class]] || [name containsString:@"Button"] ||
            [name containsString:@"ThreadInfo"] || [name containsString:@"ReplyInfo"];
        if (isControl || view.tag == 8898) {
            CGRect frame = [root convertRect:view.bounds fromView:view];
            if (!CGRectIsEmpty(frame)) [frames addObject:[NSValue valueWithCGRect:frame]];
            return;
        }
    }
    for (UIView *child in view.subviews) tgextraCollectEditBadgeObstacles(child, root, badge, frames);
}

static CGRect tgextraEditBadgeFrame(CGRect bounds, CGRect statusFrame, BOOL hasStatus, NSArray<NSValue *> *obstacles) {
    CGFloat side = MIN(44.0, MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds)));
    CGFloat x = hasStatus ? CGRectGetMaxX(statusFrame) + 8.0 : CGRectGetMaxX(bounds) - side;
    CGFloat y = hasStatus ? CGRectGetMidY(statusFrame) - side / 2.0 : CGRectGetMaxY(bounds) - side;
    x = MAX(CGRectGetMinX(bounds), MIN(x, CGRectGetMaxX(bounds) - side));
    y = MAX(CGRectGetMinY(bounds), MIN(y, CGRectGetMaxY(bounds) - side));

    // Search the edges of occupied areas rather than clamping onto Telegram's
    // share/translate buttons. Prefer moving vertically in the same gutter.
    const CGFloat gap = 8.0;
    NSMutableArray<NSNumber *> *xs = [NSMutableArray arrayWithArray:@[@(x), @(CGRectGetMinX(bounds)), @(CGRectGetMaxX(bounds) - side)]];
    NSMutableArray<NSNumber *> *ys = [NSMutableArray arrayWithArray:@[@(y), @(CGRectGetMinY(bounds)), @(CGRectGetMaxY(bounds) - side)]];
    for (NSValue *value in obstacles) {
        CGRect frame = value.CGRectValue;
        [xs addObject:@(CGRectGetMinX(frame) - gap - side)];
        [xs addObject:@(CGRectGetMaxX(frame) + gap)];
        [ys addObject:@(CGRectGetMinY(frame) - gap - side)];
        [ys addObject:@(CGRectGetMaxY(frame) + gap)];
    }
    CGRect best = CGRectNull;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (NSNumber *candidateX in xs) {
        for (NSNumber *candidateY in ys) {
            CGRect candidate = CGRectMake(candidateX.doubleValue, candidateY.doubleValue, side, side);
            if (!CGRectContainsRect(bounds, candidate)) continue;
            BOOL occupied = NO;
            for (NSValue *value in obstacles) {
                if (CGRectIntersectsRect(candidate, CGRectInset(value.CGRectValue, -gap, -gap))) {
                    occupied = YES;
                    break;
                }
            }
            if (occupied) continue;
            CGFloat distance = fabs(candidate.origin.x - x) * (CGRectGetHeight(bounds) + 1.0) + fabs(candidate.origin.y - y);
            if (distance < bestDistance) {
                best = candidate;
                bestDistance = distance;
            }
        }
    }
    return best;
}

/// Places, or hides, the pencil badge on one message node.
static void updateTGExtraEditBadge(ASDisplayNode *node, NSNumber *msgId, NSNumber *peerKey, NSString *account, NSNumber *messageNamespace) {
    UIButton *badge = nil;
    for (UIView *v in node.view.subviews) {
        if (v.tag == kTGExtraEditBadgeTag) { badge = (UIButton *)v; break; }
    }

    NSUInteger versions = (msgId != nil && messageNamespace != nil)
        ? [TLParser editHistoryForId:msgId peer:peerKey account:account messageNamespace:messageNamespace].count
        : 0;
    BOOL hasHistory = (versions > 1);

    // The pencil survives while the chat is on screen and is gone after leaving
    // and coming back. Both paths end here, so the three things that decide it
    // — the id, the conversation, and how many versions the lookup returns —
    // are worth naming rather than inferring from whether a glyph appeared.
#if TGEXTRA_DIAG
    {
        static NSMutableSet *seen = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ seen = [NSMutableSet set]; });
        NSString *key = [NSString stringWithFormat:@"%@/%@/%@/%lu", account, msgId, peerKey,
                         (unsigned long)versions];
        BOOL report = NO;
        @synchronized(seen) {
            if (seen.count < 40 && ![seen containsObject:key]) {
                [seen addObject:key];
                report = YES;
            }
        }
        if (report) {
            tgextraDiag("edit-badge account=%{public}s id=%{public}s peer=%{public}s versions=%lu drawn=%d",
                   account ? account.UTF8String : "nil",
                   msgId ? msgId.stringValue.UTF8String : "nil",
                   peerKey ? peerKey.stringValue.UTF8String : "nil",
                   (unsigned long)versions, hasHistory);
        }
    }
#endif

    if (!hasHistory || CGRectIsEmpty(node.view.bounds)) {
        clearTGExtraEditBadgeBinding(badge);
        return;
    }

    if (!badge) {
        badge = [UIButton buttonWithType:UIButtonTypeSystem];
        badge.tag = kTGExtraEditBadgeTag;
        UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightRegular];
        [badge setImage:[UIImage systemImageNamed:@"pencil" withConfiguration:symbol]
               forState:UIControlStateNormal];
        // Match Telegram's 30pt side-button disc while keeping a 44pt target.
        UIView *background = [[UIView alloc] init];
        background.tag = 8897;
        background.userInteractionEnabled = NO;
        background.isAccessibilityElement = NO;
        [badge insertSubview:background atIndex:0];
        [badge addTarget:[TGExtraEditHistoryButtonTarget shared]
                  action:@selector(handleTap:)
        forControlEvents:UIControlEventTouchUpInside];
        [node.view addSubview:badge];
    }
    objc_setAssociatedObject(badge, &kTGExtraEditMsgIdKey, msgId, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(badge, &kTGExtraEditPeerKey, peerKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(badge, &kTGExtraEditAccountKey, account, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(badge, &kTGExtraEditNamespaceKey, messageNamespace, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Keep the parent interactive; some bubble nodes ship with taps disabled on
    // their backing view, which would swallow every touch aimed at the badge.
    node.view.userInteractionEnabled = YES;

    // Keep the full touch target inside the message and clear of native
    // controls, whose gesture handlers can otherwise intercept the tap.
    ASDisplayNode *statusNode = findNodeByClassNamePrefix(node, @"ChatMessageDateAndStatusNode");
    BOOL hasStatus = statusNode && statusNode.view;
    CGRect statusFrame = hasStatus ? [node.view convertRect:statusNode.view.bounds fromView:statusNode.view] : CGRectZero;
    NSMutableArray<NSValue *> *obstacles = [NSMutableArray array];
    tgextraCollectEditBadgeObstacles(node.view, node.view, badge, obstacles);
    if (hasStatus) [obstacles addObject:[NSValue valueWithCGRect:statusFrame]];
    CGRect frame = tgextraEditBadgeFrame(node.view.bounds, statusFrame, hasStatus, obstacles);
    if (CGRectIsNull(frame)) {
        clearTGExtraEditBadgeBinding(badge);
        return;
    }
    badge.frame = frame;
    badge.autoresizingMask = UIViewAutoresizingNone;
    CGFloat inset = MAX(0.0, (CGRectGetWidth(badge.frame) - 18.0) / 2.0);
    badge.contentEdgeInsets = UIEdgeInsetsMake(inset, inset, inset, inset);

    NSDictionary *colors = [TLParser editHistoryButtonColorsFromNode:node];
    UIColor *fill = [colors[@"fill"] isKindOfClass:UIColor.class] ? colors[@"fill"] : [UIColor colorWithWhite:0.0 alpha:0.3];
    UIColor *foreground = [colors[@"foreground"] isKindOfClass:UIColor.class] ? colors[@"foreground"] : UIColor.whiteColor;
    UIColor *stroke = [colors[@"stroke"] isKindOfClass:UIColor.class] ? colors[@"stroke"] : UIColor.clearColor;
    UIView *background = [badge viewWithTag:8897];
    CGFloat diameter = MIN(30.0, CGRectGetWidth(badge.bounds));
    background.frame = CGRectMake((CGRectGetWidth(badge.bounds) - diameter) / 2.0,
                                  (CGRectGetHeight(badge.bounds) - diameter) / 2.0, diameter, diameter);
    background.layer.cornerRadius = diameter / 2.0;
    background.backgroundColor = fill;
    background.layer.borderColor = stroke.CGColor;
    background.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    badge.tintColor = foreground;

    badge.accessibilityLabel = TGExtraLoc(@"EDIT_HISTORY_TITLE");
    badge.hidden = NO;
    [node.view bringSubviewToFront:badge];
}

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

    NSString *cls = NSStringFromClass([self class]);

    // Only profile headers own these badges. ASDisplayNode.layout runs on main.
    BOOL isProfileHeader = [cls containsString:@"PeerInfoHeaderNode"];

    if (isProfileHeader) {
        long long peerId = 0;
        peerId = [[NSClassFromString(@"TLParser") performSelector:@selector(getPeerIdFromNode:) withObject:self] longLongValue];

        // A header that cannot say whose it is used to be assumed to be yours.
        // On the settings screen that guess is right; on any other header it
        // hands your own id to somebody else's profile, and the badge follows.
        // Only the settings screen has no peer of its own, so ask the header
        // whether it is showing one at all before falling back.
        SEL peerSel = NSSelectorFromString(@"peer");
        BOOL headerHasNoPeer = NO;
        if ([self respondsToSelector:peerSel]) {
            id (*getPeer)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            headerHasNoPeer = (getPeer(self, peerSel) == nil);
        }
        if (peerId == 0 && headerHasNoPeer) {
            peerId = [[TLParser getOwnUserIdFromNode:self] longLongValue];
        }
        recursiveSearchAndInject(self, self, peerId);

        // Diagnostic: report every distinct class/peer pair reaching this point
        // exactly once. Keyed on the pair rather than the peer alone, because
        // logging only on change hides "called constantly, always resolves to 0"
        // — which is indistinguishable from "never called at all".
        tgextraDiagProfileNode(cls, peerId, self);

        injectGhostExceptionButton(self, peerId);
    }

}
%end

/// The chat screen's class, whichever of the two names this client uses.
static Class tgextraChatControllerClass(void) {
    Class cls = objc_getClass("_TtC10TelegramUI18ChatControllerImpl");
    return cls ?: objc_getClass("_TtC10TelegramUI14ChatController");
}

// The chat screen's concrete class is TelegramUI.ChatControllerImpl; plain
// ChatController is a protocol declared in AccountContext, and objc_getClass on
// its mangled name has been returning nil for as long as this hook has existed.
// %init below resolves Impl first and keeps the old name as a fallback for any
// client still shipping it.
%group TGExtraChatContext
%hook _TtC10TelegramUI18ChatControllerImpl
- (void)viewDidLoad {
    %orig;
    @try {
        id context = [((id)self) valueForKey:@"context"];
        Class tlParser = NSClassFromString(@"TLParser");
        if ([tlParser respondsToSelector:@selector(setSharedContext:)]) {
            [tlParser performSelector:@selector(setSharedContext:) withObject:context];

            NSNumber *currId = [tlParser performSelector:@selector(getCurrentUserId)];
            if (currId) {
                [[NSUserDefaults standardUserDefaults] setInteger:[currId integerValue] forKey:@"TGExtraLastKnownUserId"];
            }
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
        Class tlParser = NSClassFromString(@"TLParser");
        if (context && [tlParser respondsToSelector:@selector(setSharedContext:)]) {
            [tlParser performSelector:@selector(setSharedContext:) withObject:context];
        }
    } @catch (NSException *e) {}
}
%end
%end

__attribute__((constructor))
static void hook() {
    NSLog(@"[TGExtra] Tweak initializing...");

    TGExtraRestorePreferences();
    [TLParser loadPersistedIds];
    [TGExtraAntiRevokeUpdater shared];

    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kDisableAllAds: @NO,
        kIgnorePrivateChatCopyProtection: @NO,
        kAntiRevoke: @NO,
        kAntiEdit: @NO,
        kAntiSelfDestruct: @NO,
        kDisableMessageReadReceipt: @NO,
        kDisableReactionReadReceipt: @NO,
        kDisableMentionReadReceipt: @NO,
        kDisableStoriesReadReceipt: @NO,
        kDisableOnlineStatus: @NO,
        kDisableTypingStatus: @NO,
        kHideDisappearingLabel: @NO,
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        %init;
        Class displayView = objc_getClass("_ASDisplayView");
        Method nodeGetter = class_getInstanceMethod(displayView, @selector(asyncdisplaykit_node));
        if (nodeGetter && method_getNumberOfArguments(nodeGetter) == 2) {
            Method layout = class_getInstanceMethod(displayView, @selector(layoutSubviews));
            if (layout && method_getNumberOfArguments(layout) == 2) {
                %init(TGExtraMessageViewLayout, _ASDisplayView = displayView);
            }
            Method moved = class_getInstanceMethod(displayView, @selector(didMoveToWindow));
            if (moved && method_getNumberOfArguments(moved) == 2) {
                %init(TGExtraMessageViewWindow, _ASDisplayView = displayView);
            }
        }
        Class uiState = objc_getClass("_TtC10TelegramUI30ChatPresentationInterfaceState");
        Method uiMethod = class_getInstanceMethod(uiState, @selector(copyProtectionEnabled));
        if (uiMethod && method_getNumberOfArguments(uiMethod) == 2) {
            %init(TGExtraCopyProtectionUI, _TtC10TelegramUI30ChatPresentationInterfaceState = uiState);
        }
        Class state = objc_getClass("_TtC30ChatPresentationInterfaceState30ChatPresentationInterfaceState");
        Method stateMethod = class_getInstanceMethod(state, @selector(copyProtectionEnabled));
        if (stateMethod && method_getNumberOfArguments(stateMethod) == 2) {
            %init(TGExtraCopyProtectionState, _TtC30ChatPresentationInterfaceState30ChatPresentationInterfaceState = state);
        }
        Class chat = tgextraChatControllerClass();
        Method chatMethod = class_getInstanceMethod(chat, @selector(viewDidLoad));
        if (chatMethod && method_getNumberOfArguments(chatMethod) == 2) {
            %init(TGExtraChatContext, _TtC10TelegramUI18ChatControllerImpl = chat);
        }
        Class root = objc_getClass("_TtC10TelegramUI22TelegramRootController");
        Method rootMethod = class_getInstanceMethod(root, @selector(loadView));
        if (rootMethod && method_getNumberOfArguments(rootMethod) == 2) {
            %init(TGExtraRootContext, _TtC10TelegramUI22TelegramRootController = root);
        }

    });
 }

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
