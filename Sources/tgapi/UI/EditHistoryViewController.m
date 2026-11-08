#import "EditHistoryViewController.h"
#import "EditHistoryDiff.h"
#import "Headers.h"

#define TGExtraLoc(key) [TGExtraLocalization localizedStringForKey:(key)]

// Timeline adapted from w3ltyyy/lead (c561ef1), LeadEditHistoryViewController.m.
// https://github.com/w3ltyyy/lead/blob/c561ef19f0cf24765df37f2de90cc738fb7bd1be/Sources/tgapi/UI/LeadEditHistoryViewController.m
@interface TGExtraEditHistoryViewController () <UIContextMenuInteractionDelegate>
@property (nonatomic, copy) NSArray<NSString *> *versions;
@property (nonatomic, copy) NSArray<NSDictionary *> *details;
@property (nonatomic, copy) NSArray<NSArray<NSDictionary *> *> *diffs;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, copy) NSArray<UIView *> *rowsToAnimate;
@end

@implementation TGExtraEditHistoryViewController

- (instancetype)initWithVersions:(NSArray<NSString *> *)versions details:(NSArray<NSDictionary *> *)details {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _versions = [versions copy];
        _details = [details copy];
        NSMutableArray *diffs = [NSMutableArray array];
        for (NSUInteger i = 0; i < versions.count; i++) {
            [diffs addObject:i == 0 ? @[@{@"kind": @"equal", @"text": versions[i]}]
                                   : TGExtraTextDiff(versions[i - 1], versions[i])];
        }
        _diffs = [diffs copy];
        self.title = TGExtraLoc(@"EDIT_HISTORY_TITLE");
    }
    return self;
}

- (UIFont *)fontWithSize:(CGFloat)size weight:(UIFontWeight)weight {
    UIFontTextStyle style = size <= 13 ? UIFontTextStyleFootnote : UIFontTextStyleBody;
    return [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:[UIFont systemFontOfSize:size weight:weight]
                                              compatibleWithTraitCollection:self.traitCollection];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.view.tintColor = UIColor.labelColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.leftBarButtonItem.accessibilityLabel = TGExtraLoc(@"CLOSE");
    if (self.versions.count) {
        UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"doc.on.doc"]
            style:UIBarButtonItemStylePlain target:self action:@selector(copyAll)];
        copy.accessibilityLabel = TGExtraLoc(@"EDIT_HISTORY_COPY_ALL");
        self.navigationItem.rightBarButtonItem = copy;
    }
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = self.navigationController.sheetPresentationController;
        sheet.detents = self.versions.count > 2 ? @[UISheetPresentationControllerDetent.largeDetent]
            : @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible = YES;
        sheet.preferredCornerRadius = 24;
    }
    UIScrollView *scroll = [UIScrollView new];
    scroll.alwaysBounceVertical = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    self.stack = [UIStackView new];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    self.stack.accessibilityIdentifier = @"edit-history-timeline";
    [scroll addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:8],
        [self.stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [self.stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:20],
        [self.stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-20],
    ]];
    [self buildTimeline];
    self.rowsToAnimate = self.versions.count ? [self.stack.arrangedSubviews subarrayWithRange:NSMakeRange(1, self.versions.count)] : nil;
}

- (NSString *)labelAtIndex:(NSUInteger)index {
    if (index == 0) return TGExtraLoc(@"EDIT_HISTORY_ORIGINAL");
    if (index + 1 == self.versions.count) return TGExtraLoc(@"EDIT_HISTORY_CURRENT");
    return [NSString stringWithFormat:@"%@ %lu", TGExtraLoc(@"EDIT_HISTORY_EDIT"), (unsigned long)index];
}

- (NSString *)dateAtIndex:(NSUInteger)index {
    id timestamp = index < self.details.count ? self.details[index][@"date"] : nil;
    if (![timestamp isKindOfClass:NSNumber.class] || [timestamp doubleValue] <= 0) return nil;
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:[timestamp doubleValue]];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.timeStyle = NSDateFormatterShortStyle;
    formatter.dateStyle = [NSCalendar.currentCalendar isDateInToday:date] ? NSDateFormatterNoStyle : NSDateFormatterMediumStyle;
    formatter.doesRelativeDateFormatting = YES;
    return [formatter stringFromDate:date];
}

- (NSAttributedString *)bodyAtIndex:(NSUInteger)index {
    UIFont *font = [self fontWithSize:16 weight:UIFontWeightRegular];
    UIColor *foreground = [UIColor.labelColor resolvedColorWithTraitCollection:self.traitCollection];
    UIColor *removed = [UIColor.secondaryLabelColor resolvedColorWithTraitCollection:self.traitCollection];
    NSDictionary *base = @{NSFontAttributeName: font, NSForegroundColorAttributeName: foreground};
    NSMutableAttributedString *body = [[NSMutableAttributedString alloc] init];
    BOOL textChanged = index == 0 || ![self.versions[index - 1] isEqualToString:self.versions[index]];
    NSString *previousKind = nil;
    if (textChanged) for (NSDictionary *run in self.diffs[index]) {
        NSMutableDictionary *attributes = [base mutableCopy];
        if ([run[@"kind"] isEqualToString:@"delete"]) {
            attributes[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
            attributes[NSForegroundColorAttributeName] = removed;
            attributes[NSStrikethroughColorAttributeName] = removed;
        } else if ([run[@"kind"] isEqualToString:@"insert"]) {
            attributes[NSBackgroundColorAttributeName] = [[UIColor.systemGreenColor resolvedColorWithTraitCollection:self.traitCollection] colorWithAlphaComponent:0.22];
        }
        NSString *text = run[@"text"];
        if (![run[@"kind"] isEqualToString:@"equal"] &&
            ![text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
            text = [[[[[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
                stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"]
                stringByReplacingOccurrencesOfString:@"\n" withString:@"↵\n"]
                stringByReplacingOccurrencesOfString:@"\t" withString:@"⇥"]
                stringByReplacingOccurrencesOfString:@" " withString:@"·"];
        }
        if ([previousKind isEqualToString:@"delete"] && [run[@"kind"] isEqualToString:@"insert"] && body.length && text.length &&
            ![NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:[body.string characterAtIndex:body.length - 1]] &&
            ![NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:[text characterAtIndex:0]]) {
            [body appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:base]];
        }
        [body appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
        previousKind = run[@"kind"];
    }
    NSDictionary *revision = index < self.details.count ? self.details[index] : nil;
    for (NSString *key in @[@"mediaChanged", @"formatChanged"]) {
        if (![revision[key] boolValue]) continue;
        NSString *note = TGExtraLoc([key isEqualToString:@"mediaChanged"] ? @"EDIT_HISTORY_MEDIA_CHANGED" : @"EDIT_HISTORY_FORMAT_CHANGED");
        [body appendAttributedString:[[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"%@[%@]", body.length ? @"\n" : @"", note] attributes:base]];
    }
    if (!body.length) [body appendAttributedString:[[NSAttributedString alloc] initWithString:@"—" attributes:base]];
    return body;
}

- (void)buildTimeline {
    self.rowsToAnimate = nil;
    self.view.backgroundColor = [UIColor.systemGroupedBackgroundColor resolvedColorWithTraitCollection:self.traitCollection];
    for (UIView *view in self.stack.arrangedSubviews) [view removeFromSuperview];
    UILabel *count = [UILabel new];
    count.text = [NSString stringWithFormat:TGExtraLoc(@"EDIT_HISTORY_COUNT"), (long)self.versions.count];
    count.font = [self fontWithSize:13 weight:UIFontWeightMedium];
    count.adjustsFontForContentSizeCategory = YES;
    count.numberOfLines = 0;
    count.textColor = UIColor.secondaryLabelColor;
    [self.stack addArrangedSubview:count];
    [self.stack setCustomSpacing:14 afterView:count];
    for (NSUInteger index = 0; index < self.versions.count; index++) {
        BOOL last = index + 1 == self.versions.count;
        [self.stack addArrangedSubview:[self rowWithLabel:[self labelAtIndex:index] date:[self dateAtIndex:index]
            body:[self bodyAtIndex:index] current:last last:last index:index]];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (animated && !UIAccessibilityIsReduceMotionEnabled()) {
        [self.rowsToAnimate enumerateObjectsUsingBlock:^(UIView *row, NSUInteger index, BOOL *stop) {
            row.alpha = 0;
            row.transform = CGAffineTransformMakeTranslation(0, 14);
            [UIView animateWithDuration:0.5 delay:MIN(index, 8) * 0.045 usingSpringWithDamping:0.86 initialSpringVelocity:0.4
                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
                    row.alpha = 1;
                    row.transform = CGAffineTransformIdentity;
                } completion:nil];
        }];
    }
    self.rowsToAnimate = nil;
}

- (UIView *)rowWithLabel:(NSString *)label date:(NSString *)date body:(NSAttributedString *)body current:(BOOL)current last:(BOOL)last index:(NSUInteger)index {
  UIView *row = [UIView new];
  row.accessibilityIdentifier = [NSString stringWithFormat:@"edit-history-revision-%lu", (unsigned long)index];

  // Timeline rail: a dot per version, joined by a hairline.
  UIView *dot = [UIView new];
  dot.translatesAutoresizingMaskIntoConstraints = NO;
  dot.layer.cornerRadius = 5;
  dot.layer.borderWidth = 1.5;
  dot.layer.borderColor = [(current ? UIColor.labelColor : UIColor.secondaryLabelColor) resolvedColorWithTraitCollection:self.traitCollection].CGColor;
  dot.backgroundColor = current ? UIColor.labelColor : UIColor.systemGroupedBackgroundColor;
  UIView *line = [UIView new];
  line.translatesAutoresizingMaskIntoConstraints = NO;
  line.backgroundColor = UIColor.separatorColor;
  line.hidden = last;
  [row addSubview:line];
  [row addSubview:dot];

  UILabel *title = [UILabel new];
  title.translatesAutoresizingMaskIntoConstraints = NO;
  title.numberOfLines = 0;
  title.adjustsFontForContentSizeCategory = YES;
  title.accessibilityTraits |= UIAccessibilityTraitHeader;
  NSMutableAttributedString *heading = [[NSMutableAttributedString alloc] initWithString:label attributes:@{
    NSFontAttributeName : [self fontWithSize:13 weight:UIFontWeightSemibold],
    NSForegroundColorAttributeName : [(current ? UIColor.labelColor : UIColor.secondaryLabelColor) resolvedColorWithTraitCollection:self.traitCollection],
  }];
  if (date.length) {
    [heading appendAttributedString:[[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:date] attributes:@{
      NSFontAttributeName : [self fontWithSize:13 weight:UIFontWeightRegular],
      NSForegroundColorAttributeName : [UIColor.secondaryLabelColor resolvedColorWithTraitCollection:self.traitCollection],
    }]];
  }
  title.attributedText = heading;
  [row addSubview:title];

  UIView *card = [UIView new];
  card.translatesAutoresizingMaskIntoConstraints = NO;
  card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
  card.layer.cornerRadius = 16;
  card.layer.cornerCurve = kCACornerCurveContinuous;
  card.tag = (NSInteger)index;
  [card addInteraction:[[UIContextMenuInteraction alloc] initWithDelegate:self]];
  [row addSubview:card];

  UITextView *textView = [UITextView new];
  textView.translatesAutoresizingMaskIntoConstraints = NO;
  textView.editable = NO;
  textView.adjustsFontForContentSizeCategory = YES;
  textView.scrollEnabled = NO;
  textView.backgroundColor = UIColor.clearColor;
  textView.textContainerInset = UIEdgeInsetsZero;
  textView.textContainer.lineFragmentPadding = 0;
  textView.attributedText = body.length ? body : [[NSAttributedString alloc] initWithString:@"—" attributes:@{
    NSFontAttributeName : [self fontWithSize:16 weight:UIFontWeightRegular],
    NSForegroundColorAttributeName : UIColor.secondaryLabelColor,
  }];
  [card addSubview:textView];

  [NSLayoutConstraint activateConstraints:@[
    [dot.widthAnchor constraintEqualToConstant:10],
    [dot.heightAnchor constraintEqualToConstant:10],
    [dot.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
    [dot.topAnchor constraintEqualToAnchor:title.topAnchor constant:3],
    [line.widthAnchor constraintEqualToConstant:1.5],
    [line.centerXAnchor constraintEqualToAnchor:dot.centerXAnchor],
    [line.topAnchor constraintEqualToAnchor:dot.bottomAnchor constant:4],
    [line.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:4],
    [title.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:12],
    [title.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
    [title.topAnchor constraintEqualToAnchor:row.topAnchor],
    [card.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
    [card.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
    [card.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
    [card.heightAnchor constraintGreaterThanOrEqualToConstant:44],
    [card.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:last ? 0 : -18],
    [textView.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
    [textView.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
    [textView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
    [textView.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
  ]];
  return row;
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    NSUInteger index = (NSUInteger)interaction.view.tag;
    if (index >= self.versions.count) return nil;
    NSString *text = self.versions[index];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested) {
        UIAction *copy = [UIAction actionWithTitle:TGExtraLoc(@"DEBUG_LOG_COPY") image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *action) {
            UIPasteboard.generalPasteboard.string = text;
            TGExtraShowToast(TGExtraLoc(@"EDIT_HISTORY_COPIED"));
        }];
        return [UIMenu menuWithTitle:@"" children:@[copy]];
    }];
}

- (void)copyAll {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSUInteger index = 0; index < self.versions.count; index++) {
        NSString *date = [self dateAtIndex:index];
        NSString *heading = date.length ? [NSString stringWithFormat:@"%@ · %@", [self labelAtIndex:index], date] : [self labelAtIndex:index];
        [parts addObject:[NSString stringWithFormat:@"%@\n%@", heading, self.versions[index]]];
    }
    UIPasteboard.generalPasteboard.string = [parts componentsJoinedByString:@"\n\n"];
    TGExtraShowToast(TGExtraLoc(@"EDIT_HISTORY_COPIED"));
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (![self.traitCollection.preferredContentSizeCategory isEqualToString:previousTraitCollection.preferredContentSizeCategory] ||
        [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        if (self.isViewLoaded) [self buildTimeline];
    }
}

@end
