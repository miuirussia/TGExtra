#import "DebugLogViewController.h"
#import "Headers.h"
#import "../Headers.h"

#define TGExtraLoc(key) [TGExtraLocalization localizedStringForKey:(key)]

static NSArray<NSString *> *diagnosticKeys(void) {
    return @[@"TGExtraCaptureHookStatus", @"TGExtraCaptureCanvasStatus", @"TGExtraPaidCaptureStatus",
             @"TGExtraSecretCaptureStatus", @"TGExtraPaidMediaLastImport", @"TGExtraPaidMediaLastError"];
}

static UIColor *diagnosticColor(NSString *line) {
    static NSArray<NSRegularExpression *> *patterns;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *expressions = [NSMutableArray array];
        for (NSString *pattern in @[
            @"\\b(error|failed|failure|invalid|cannot|could not|timed out|timeout|denied)\\b",
            @"\\b(warning|unavailable|unsupported|missing|inactive|disabled|not recognized|optional|fallback)\\b",
            @"\\b(active|available|recognized|present|installed|ready|enabled|completed|created|success)\\b"
        ]) {
            [expressions addObject:[NSRegularExpression regularExpressionWithPattern:pattern
                options:NSRegularExpressionCaseInsensitive error:NULL]];
        }
        patterns = [expressions copy];
    });
    NSInteger level = NSNotFound;
    if ([line hasPrefix:@"TGExtraPaidMediaLastError:"]) level = 0;
    else if ([line hasPrefix:@"TGExtraPaidMediaLastImport:"]) level = 2;
    else {
        NSRange separator = [line rangeOfString:@": "];
        NSString *status = separator.location == NSNotFound ? line : [line substringFromIndex:NSMaxRange(separator)];
        for (NSUInteger i = 0; i < patterns.count; i++) {
            if ([patterns[i] firstMatchInString:status options:0 range:NSMakeRange(0, status.length)]) {
                level = i;
                break;
            }
        }
    }
    if (level == NSNotFound) return UIColor.labelColor;
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
        switch (level) {
            case 0: return dark ? [UIColor colorWithRed:1 green:0.43 blue:0.43 alpha:1]
                               : [UIColor colorWithRed:0.70 green:0.09 blue:0.12 alpha:1];
            case 1: return dark ? [UIColor colorWithRed:1 green:0.76 blue:0.32 alpha:1]
                               : [UIColor colorWithRed:0.48 green:0.29 blue:0 alpha:1];
            default: return dark ? [UIColor colorWithRed:0.35 green:0.88 blue:0.49 alpha:1]
                                : [UIColor colorWithRed:0 green:0.40 blue:0.16 alpha:1];
        }
    }];
}

@interface TGExtraDebugLogViewController ()
@property(nonatomic, strong) UITextView *textView;
@property(nonatomic, copy) NSString *logContent;
@end

@implementation TGExtraDebugLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = TGExtraLoc(@"DEBUG_LOG_TITLE");
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadLog)];

    self.textView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.adjustsFontForContentSizeCategory = YES;
    self.textView.backgroundColor = UIColor.systemBackgroundColor;
    self.textView.textContainerInset = UIEdgeInsetsMake(16, 16, 16, 16);
    self.textView.accessibilityLabel = self.title;
    [self.view addSubview:self.textView];

    UIToolbar *toolbar = [UIToolbar new];
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithTitle:TGExtraLoc(@"DEBUG_LOG_COPY")
        style:UIBarButtonItemStylePlain target:self action:@selector(copyLog)];
    UIBarButtonItem *space = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *clear = [[UIBarButtonItem alloc] initWithTitle:TGExtraLoc(@"DEBUG_LOG_CLEAR")
        style:UIBarButtonItemStylePlain target:self action:@selector(clearLog)];
    clear.tintColor = UIColor.systemRedColor;
    toolbar.items = @[copy, space, clear];
    [self.view addSubview:toolbar];
    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.textView.topAnchor constraintEqualToAnchor:safeArea.topAnchor],
        [self.textView.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
        [self.textView.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor],
        [self.textView.bottomAnchor constraintEqualToAnchor:toolbar.topAnchor],
        [toolbar.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor],
        [toolbar.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor],
        [toolbar.bottomAnchor constraintEqualToAnchor:safeArea.bottomAnchor],
        [toolbar.heightAnchor constraintEqualToConstant:44]
    ]];
    [self reloadLog];
}

- (void)reloadLog {
    NSMutableString *content = [[TLParser compatibilityReport] mutableCopy];
    for (NSString *key in diagnosticKeys()) {
        NSString *entry = [NSUserDefaults.standardUserDefaults stringForKey:key];
        if (entry.length) [content appendFormat:@"\n\n%@: %@", key, entry];
    }
    NSString *log = TGExtraReadLog();
    [content appendFormat:@"\n\n%@\n%@", TGExtraLoc(@"DEBUG_LOG_TITLE"),
        log.length ? log : TGExtraLoc(@"DEBUG_LOG_EMPTY")];
    self.logContent = content;
    [self updateAppearance];
}

- (void)updateAppearance {
    UIFont *baseFont = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    UIFont *font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleFootnote]
        scaledFontForFont:baseFont compatibleWithTraitCollection:self.traitCollection];
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineSpacing = 4;
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:self.logContent ?: @""
        attributes:@{NSFontAttributeName:font, NSParagraphStyleAttributeName:paragraph}];
    [text.string enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByLines
        usingBlock:^(NSString *line, NSRange range, NSRange enclosingRange, BOOL *stop) {
            [text addAttribute:NSForegroundColorAttributeName value:diagnosticColor(line) range:range];
            if (range.location == 0 || [line isEqualToString:TGExtraLoc(@"DEBUG_LOG_TITLE")]) {
                UIFont *heading = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline]
                    scaledFontForFont:[UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightSemibold]
                    compatibleWithTraitCollection:self.traitCollection];
                [text addAttribute:NSFontAttributeName value:heading range:range];
            }
        }];
    NSRange selection = self.textView.selectedRange;
    CGPoint offset = self.textView.contentOffset;
    self.textView.attributedText = text;
    if (NSMaxRange(selection) <= text.length) self.textView.selectedRange = selection;
    [self.textView layoutIfNeeded];
    CGFloat maxOffset = MAX(-self.textView.adjustedContentInset.top,
        self.textView.contentSize.height - self.textView.bounds.size.height + self.textView.adjustedContentInset.bottom);
    offset.y = MAX(-self.textView.adjustedContentInset.top, MIN(offset.y, maxOffset));
    self.textView.contentOffset = offset;
}

- (void)copyLog {
    UIPasteboard.generalPasteboard.string = self.logContent;
}

- (void)clearLog {
    TGExtraClearLog();
    for (NSString *key in @[@"TGExtraPaidMediaLastError", @"TGExtraPaidMediaLastImport",
                           @"TGExtraPaidCaptureStatus", @"TGExtraSecretCaptureStatus"]) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
    }
    [self reloadLog];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection] ||
        ![self.traitCollection.preferredContentSizeCategory isEqualToString:previousTraitCollection.preferredContentSizeCategory]) {
        [self updateAppearance];
    }
}

@end
