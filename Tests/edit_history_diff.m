#import <Foundation/Foundation.h>
#import "EditHistoryDiff.h"
#ifdef TGEXTRA_UIKIT
#import "EditHistoryViewController.h"
#import "Headers.h"

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
static void checkHistoryUI(void) {
    TGExtraEditHistoryViewController *history = [[TGExtraEditHistoryViewController alloc]
        initWithVersions:@[@"Hello old world", @"Hello new world", @"Hello new world", @""]
        details:@[@{}, @{}, @{@"mediaChanged": @YES, @"formatChanged": @YES}, @{}]];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:history];
    [navigation loadViewIfNeeded];
    [history loadViewIfNeeded];
    NSCAssert([history numberOfSectionsInTableView:history.tableView] == 4, @"Original plus every revision");
    NSCAssert([[history tableView:history.tableView titleForHeaderInSection:0] isEqual:@"EDIT_HISTORY_ORIGINAL"], @"Original heading");
    NSCAssert([[history tableView:history.tableView titleForHeaderInSection:2] isEqual:@"EDIT_HISTORY_EDIT 2"], @"Chronological headings");
    NSCAssert(!navigation.toolbarHidden && history.navigationItem.rightBarButtonItem, @"Copy and close remain reachable");
    for (NSNumber *style in @[@(UIUserInterfaceStyleLight), @(UIUserInterfaceStyleDark)]) {
        history.overrideUserInterfaceStyle = style.integerValue;
        for (NSValue *size in @[[NSValue valueWithCGSize:CGSizeMake(375, 667)], [NSValue valueWithCGSize:CGSizeMake(667, 375)]]) {
            history.view.frame = (CGRect){CGPointZero, size.CGSizeValue};
            [history.view layoutIfNeeded];
            UITableViewCell *cell = [history tableView:history.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]];
            NSAttributedString *text = cell.textLabel.attributedText;
            NSRange removed = [text.string rangeOfString:@"old"], added = [text.string rangeOfString:@"new"];
            NSCAssert([[text attribute:NSStrikethroughStyleAttributeName atIndex:removed.location effectiveRange:NULL] integerValue] == NSUnderlineStyleSingle,
                      @"Removed words are struck through");
            NSCAssert([[text attribute:NSUnderlineStyleAttributeName atIndex:added.location effectiveRange:NULL] integerValue] == NSUnderlineStyleSingle,
                      @"Added words are underlined");
            NSCAssert(![text attribute:NSStrikethroughStyleAttributeName atIndex:0 effectiveRange:NULL], @"Unchanged context has no deletion style");
            NSCAssert(cell.textLabel.numberOfLines == 0 && cell.textLabel.adjustsFontForContentSizeCategory, @"Wrapping and Dynamic Type");
        }
    }
    UITableViewCell *notes = [history tableView:history.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:2]];
    NSCAssert([notes.textLabel.text isEqual:@"[EDIT_HISTORY_MEDIA_CHANGED]\n[EDIT_HISTORY_FORMAT_CHANGED]"], @"Metadata-only revisions show both notes without repeating text");
    UITableViewCell *cleared = [history tableView:history.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:3]];
    NSCAssert([cleared.textLabel.text isEqual:@"Hello new world"], @"Clearing a caption displays its removed text");
    NSCAssert([[cleared.textLabel.attributedText attribute:NSStrikethroughStyleAttributeName atIndex:0 effectiveRange:NULL] integerValue] == NSUnderlineStyleSingle,
              @"Cleared caption is entirely deleted");
    CGFloat defaultSize = cleared.textLabel.font.pointSize;
    [navigation setOverrideTraitCollection:[UITraitCollection traitCollectionWithPreferredContentSizeCategory:UIContentSizeCategoryAccessibilityExtraExtraExtraLarge]
                   forChildViewController:history];
    UITableViewCell *large = [history tableView:history.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:3]];
    UIFont *largeFont = [large.textLabel.attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
    NSCAssert([history.traitCollection.preferredContentSizeCategory isEqual:UIContentSizeCategoryAccessibilityExtraExtraExtraLarge] &&
              largeFont.pointSize >= defaultSize && [large.textLabel.text isEqual:@"Hello new world"],
              @"The largest Dynamic Type category preserves the complete diff (Catalyst can keep desktop font metrics)");
    UIBarButtonItem *copy = history.toolbarItems[1];
    [copy.target performSelector:copy.action withObject:copy];
    NSCAssert([UIPasteboard.generalPasteboard.string isEqual:@""], @"Copy uses the exact latest version, never the rendered diff");
    TGExtraEditHistoryViewController *empty = [[TGExtraEditHistoryViewController alloc] initWithVersions:@[@"", @"Caption"] details:nil];
    [empty loadViewIfNeeded];
    NSCAssert([[[empty tableView:empty.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]] textLabel].text isEqual:@"—"], @"Empty original remains visible");
    TGExtraEditHistoryViewController *whitespace = [[TGExtraEditHistoryViewController alloc] initWithVersions:@[@"\n", @" "] details:nil];
    [whitespace loadViewIfNeeded];
    UITableViewCell *spaces = [whitespace tableView:whitespace.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:1]];
    NSCAssert([spaces.textLabel.text isEqual:@"↵\n·"], @"Whitespace-only changes remain visible");
    puts("PASS history UIKit rendering, metadata notes, themes, wrapping and copy-latest");
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
