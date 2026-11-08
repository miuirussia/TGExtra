#import <Foundation/Foundation.h>
#import "EditHistoryDiff.h"
#ifdef TGEXTRA_UIKIT
#import "EditHistoryViewController.h"
#import "Headers.h"

void TGExtraShowToast(NSString *text) {}

@implementation TGExtraLocalization
+ (instancetype)shared { return [self new]; }
+ (NSString *)localizedStringForKey:(NSString *)key { return key; }
@end
#endif

static NSArray *checkDiff(NSString *before, NSString *after) {
    NSArray *runs = TGExtraTextDiff(before, after);
    NSMutableString *old = [NSMutableString string], *new = [NSMutableString string];
    NSString *previousKind = nil;
    for (NSDictionary *run in runs) {
        NSString *kind = run[@"kind"], *text = run[@"text"];
        NSCAssert(text.length && ![kind isEqual:previousKind], @"Nonempty, coalesced runs");
        NSCAssert(([@[@"equal", @"delete", @"insert"] containsObject:kind]), @"Known change kind");
        if (![kind isEqual:@"insert"]) [old appendString:text];
        if (![kind isEqual:@"delete"]) [new appendString:text];
        previousKind = kind;
    }
    NSCAssert([old compare:before options:NSLiteralSearch] == NSOrderedSame, @"Reconstruct exact original: %@", runs);
    NSCAssert([new compare:after options:NSLiteralSearch] == NSOrderedSame, @"Reconstruct exact revision: %@", runs);
    return runs;
}

#ifdef TGEXTRA_UIKIT
static UIView *findView(UIView *root, NSString *identifier, Class type) {
    if ((identifier && [root.accessibilityIdentifier isEqual:identifier]) || (type && [root isKindOfClass:type])) return root;
    for (UIView *child in root.subviews) {
        UIView *found = findView(child, identifier, type);
        if (found) return found;
    }
    return nil;
}

static UIView *revision(TGExtraEditHistoryViewController *history, NSUInteger index) {
    return findView(history.view, [NSString stringWithFormat:@"edit-history-revision-%lu", (unsigned long)index], Nil);
}

static UITextView *revisionBody(TGExtraEditHistoryViewController *history, NSUInteger index) {
    return (UITextView *)findView(revision(history, index), nil, UITextView.class);
}

static void checkHistoryUI(void) {
    NSNumber *today = @((long)NSDate.date.timeIntervalSince1970);
    TGExtraEditHistoryViewController *history = [[TGExtraEditHistoryViewController alloc]
        initWithVersions:@[@"Hello old world", @"Hello new world", @"Hello new world", @""]
        details:@[@{}, @{@"date": today}, @{@"mediaChanged": @YES, @"formatChanged": @YES, @"date": @1234}, @{}]];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:history];
    [navigation loadViewIfNeeded];
    [history loadViewIfNeeded];
    UIStackView *timeline = (UIStackView *)findView(history.view, @"edit-history-timeline", Nil);
    NSCAssert(timeline.arrangedSubviews.count == 5, @"Count plus original and every revision, including metadata-only edits");
    UILabel *original = (UILabel *)findView(revision(history, 0), nil, UILabel.class);
    UILabel *latest = (UILabel *)findView(revision(history, 3), nil, UILabel.class);
    NSCAssert([original.text isEqual:@"EDIT_HISTORY_ORIGINAL"] && [latest.text isEqual:@"EDIT_HISTORY_CURRENT"],
              @"Unknown dates are omitted; original and current labels remain distinct");
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.timeStyle = NSDateFormatterShortStyle;
    NSString *time = [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:today.doubleValue]];
    UILabel *dated = (UILabel *)findView(revision(history, 1), nil, UILabel.class);
    NSCAssert([dated.text containsString:time], @"Today's edits show their local time");
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.doesRelativeDateFormatting = YES;
    UILabel *older = (UILabel *)findView(revision(history, 2), nil, UILabel.class);
    NSCAssert([older.text containsString:[formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:1234]]],
              @"Older revisions show both date and time");
    NSCAssert(history.navigationItem.leftBarButtonItem && history.navigationItem.rightBarButtonItem,
              @"Close and copy-all remain reachable in the navigation bar");
    for (NSNumber *style in @[@(UIUserInterfaceStyleLight), @(UIUserInterfaceStyleDark)]) {
        history.overrideUserInterfaceStyle = style.integerValue;
        for (NSValue *size in @[[NSValue valueWithCGSize:CGSizeMake(375, 667)], [NSValue valueWithCGSize:CGSizeMake(667, 375)],
                               [NSValue valueWithCGSize:CGSizeMake(1024, 1366)]]) {
            history.view.frame = (CGRect){CGPointZero, size.CGSizeValue};
            [history.view layoutIfNeeded];
            UITextView *view = revisionBody(history, 1);
            NSAttributedString *text = view.attributedText;
            NSRange removed = [text.string rangeOfString:@"old"], added = [text.string rangeOfString:@"new"];
            NSCAssert([text.string isEqual:@"Hello old new world"], @"Replacements remain separated and readable");
            NSCAssert([[text attribute:NSStrikethroughStyleAttributeName atIndex:removed.location effectiveRange:NULL] integerValue] == NSUnderlineStyleSingle,
                      @"Removed words are struck through");
            NSCAssert([text attribute:NSBackgroundColorAttributeName atIndex:added.location effectiveRange:NULL], @"Added words have a highlight");
            NSCAssert(![text attribute:NSStrikethroughStyleAttributeName atIndex:0 effectiveRange:NULL] &&
                      ![text attribute:NSBackgroundColorAttributeName atIndex:0 effectiveRange:NULL], @"Unchanged context stays plain");
            UIColor *foreground = [text attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL];
            NSCAssert(CGColorEqualToColor(foreground.CGColor, [UIColor.labelColor resolvedColorWithTraitCollection:history.traitCollection].CGColor),
                      @"Attributed text resolves against the screen theme before TextKit lays it out");
            NSCAssert(!view.scrollEnabled && view.selectable && !view.editable && view.adjustsFontForContentSizeCategory,
                      @"Cards expand, allow selection, and support Dynamic Type");
            NSCAssert(view.bounds.size.width > 0 && view.bounds.size.height > 0 &&
                      view.bounds.size.width < history.view.bounds.size.width, @"Card content fits the available width");
        }
    }
    NSCAssert([revisionBody(history, 2).text isEqual:@"[EDIT_HISTORY_MEDIA_CHANGED]\n[EDIT_HISTORY_FORMAT_CHANGED]"],
              @"Metadata-only revisions retain both notes without repeating text");
    UITextView *cleared = revisionBody(history, 3);
    NSCAssert([cleared.text isEqual:@"Hello new world"] &&
              [[cleared.attributedText attribute:NSStrikethroughStyleAttributeName atIndex:0 effectiveRange:NULL] integerValue] == NSUnderlineStyleSingle,
              @"Cleared captions show the entire removed text");
    CGFloat defaultSize = [[cleared.attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL] pointSize];
    [navigation setOverrideTraitCollection:[UITraitCollection traitCollectionWithPreferredContentSizeCategory:UIContentSizeCategoryAccessibilityExtraExtraExtraLarge]
                   forChildViewController:history];
    [history.view layoutIfNeeded];
    UIFont *largeFont = [revisionBody(history, 3).attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
    NSCAssert(largeFont.pointSize >= defaultSize && [revisionBody(history, 3).text isEqual:@"Hello new world"],
              @"Largest Dynamic Type preserves the complete diff");
    UIBarButtonItem *copy = history.navigationItem.rightBarButtonItem;
    [copy.target performSelector:copy.action withObject:copy];
    NSString *copied = UIPasteboard.generalPasteboard.string;
    NSCAssert([copied containsString:@"EDIT_HISTORY_ORIGINAL\nHello old world"] &&
              [copied containsString:@"Hello new world"] && [copied hasSuffix:@"EDIT_HISTORY_CURRENT\n"] &&
              ![copied containsString:@"old new"] && ![copied containsString:@"MEDIA_CHANGED"],
              @"Copy-all exports exact saved versions with headings and dates, never rendered diffs or notes");
    [history viewWillAppear:NO];
    NSCAssert(revision(history, 0).alpha == 1 && CGAffineTransformIsIdentity(revision(history, 0).transform),
              @"Nonanimated presentation keeps all rows visible");
    TGExtraEditHistoryViewController *empty = [[TGExtraEditHistoryViewController alloc] initWithVersions:@[@"", @"Caption"] details:nil];
    [empty loadViewIfNeeded];
    NSCAssert([revisionBody(empty, 0).text isEqual:@"—"], @"Empty original remains visible");
    TGExtraEditHistoryViewController *whitespace = [[TGExtraEditHistoryViewController alloc] initWithVersions:@[@"\n", @" "] details:nil];
    [whitespace loadViewIfNeeded];
    NSCAssert([revisionBody(whitespace, 1).text isEqual:@"↵\n·"], @"Whitespace-only edits remain visible");
    puts("PASS history timeline, dates, metadata notes, themes, layout, Dynamic Type and copy-all");
}
#endif

int main(void) {
    @autoreleasepool {
        NSArray *runs = checkDiff(@"Hello old world", @"Hello new world");
        NSCAssert(([runs isEqual:@[@{@"kind": @"equal", @"text": @"Hello "}, @{@"kind": @"delete", @"text": @"old"},
                                 @{@"kind": @"insert", @"text": @"new"}, @{@"kind": @"equal", @"text": @" world"}]]), @"Highlight changed words, retain context");
        NSCAssert([checkDiff(@"", @"") count] == 0, @"Empty inputs");
        NSCAssert([checkDiff(@"same", @"same") count] == 1, @"Unchanged text");
        NSCAssert([checkDiff(@"", @"Caption")[0][@"kind"] isEqual:@"insert"], @"Previously empty caption");
        NSCAssert([checkDiff(@"Caption", @"")[0][@"kind"] isEqual:@"delete"], @"Cleared caption");
        checkDiff(@"Первая строка\nВторая строка", @"Первая строка\nНовая строка\nТретья строка");
        checkDiff(@"Привет, мир!", @"Привет, друг!");
        checkDiff(@"  \n\t", @"\n ");
        checkDiff(@"👩🏽‍💻 café é 🇷🇺", @"👨‍👩‍👧‍👦 cafe é 🇨🇳");
        checkDiff(@"你好世界 مرحبا بالعالم", @"你好朋友 مرحبا بالجميع");
        checkDiff(@"one two one three", @"one three one two");
        NSMutableString *old = [NSMutableString string], *new = [NSMutableString string];
        for (NSUInteger i = 0; i < 1000; i++) {
            [old appendFormat:@"old%lu ", (unsigned long)i];
            [new appendFormat:@"new%lu ", (unsigned long)i];
        }
        NSCAssert([checkDiff(old, new) count] <= 3, @"Large replacements use bounded fallback and common suffix");
        checkDiff([old stringByAppendingString:@"before"], [old stringByAppendingString:@"after"]);
        NSArray *tokens = @[@"кот", @"cat", @" ", @"\n", @"😀", @"👩🏽‍💻", @"é", @"你好", @"!", @"مرحبا"];
        srand(42);
        for (NSUInteger trial = 0; trial < 150; trial++) {
            NSMutableString *a = [NSMutableString string], *b = [NSMutableString string];
            for (NSUInteger i = 0; i < 30; i++) {
                [a appendString:tokens[rand() % tokens.count]];
                [b appendString:tokens[rand() % tokens.count]];
            }
            checkDiff(a, b);
        }
        puts("PASS word diffs, insertion, deletion, Unicode, whitespace, repeated words and bounded large replacements");
#ifdef TGEXTRA_UIKIT
        checkHistoryUI();
#endif
    }
    return 0;
}
