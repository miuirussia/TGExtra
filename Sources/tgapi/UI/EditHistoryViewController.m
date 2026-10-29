#import "EditHistoryViewController.h"
#import "EditHistoryDiff.h"
#import "Headers.h"

#define TGExtraLoc(key) [TGExtraLocalization localizedStringForKey:(key)]

@interface TGExtraEditHistoryViewController ()
@property (nonatomic, copy) NSArray<NSString *> *versions;
@property (nonatomic, copy) NSArray<NSDictionary *> *details;
@property (nonatomic, copy) NSArray<NSArray<NSDictionary *> *> *diffs;
@end

@implementation TGExtraEditHistoryViewController

- (instancetype)initWithVersions:(NSArray<NSString *> *)versions details:(NSArray<NSDictionary *> *)details {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
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

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.allowsSelection = NO;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 120;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:TGExtraLoc(@"CLOSE") style:UIBarButtonItemStyleDone target:self action:@selector(close)];
    UIBarButtonItem *space = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithTitle:TGExtraLoc(@"EDIT_HISTORY_COPY_LATEST")
        style:UIBarButtonItemStylePlain target:self action:@selector(copyLatest)];
    UIBarButtonItem *trailingSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    self.toolbarItems = @[space, copy, trailingSpace];
    [self.navigationController setToolbarHidden:NO];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)copyLatest {
    UIPasteboard.generalPasteboard.string = self.versions.lastObject;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.versions.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? TGExtraLoc(@"EDIT_HISTORY_ORIGINAL")
        : [NSString stringWithFormat:@"%@ %ld", TGExtraLoc(@"EDIT_HISTORY_EDIT"), (long)section];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"revision"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"revision"];
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    UIFont *font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody compatibleWithTraitCollection:self.traitCollection];
    NSDictionary *base = @{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.labelColor};
    NSMutableAttributedString *body = [[NSMutableAttributedString alloc] init];
    NSUInteger index = indexPath.section;
    BOOL textChanged = index == 0 || ![self.versions[index - 1] isEqualToString:self.versions[index]];
    if (textChanged) for (NSDictionary *run in self.diffs[index]) {
        NSMutableDictionary *attributes = [base mutableCopy];
        if ([run[@"kind"] isEqualToString:@"delete"]) {
            attributes[NSStrikethroughStyleAttributeName] = @(NSUnderlineStyleSingle);
            attributes[NSForegroundColorAttributeName] = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
                return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                    ? [UIColor colorWithRed:1 green:0.43 blue:0.43 alpha:1]
                    : [UIColor colorWithRed:0.70 green:0.09 blue:0.12 alpha:1];
            }];
        } else if ([run[@"kind"] isEqualToString:@"insert"]) {
            attributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
            attributes[NSForegroundColorAttributeName] = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
                return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                    ? [UIColor colorWithRed:0.35 green:0.88 blue:0.49 alpha:1]
                    : [UIColor colorWithRed:0 green:0.40 blue:0.16 alpha:1];
            }];
        }
        NSString *text = run[@"text"];
        if (![run[@"kind"] isEqualToString:@"equal"] &&
            ![text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
            // Make whitespace-only edits visible; Copy still uses the stored version.
            text = [[[[[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
                stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"]
                stringByReplacingOccurrencesOfString:@"\n" withString:@"↵\n"]
                stringByReplacingOccurrencesOfString:@"\t" withString:@"⇥"]
                stringByReplacingOccurrencesOfString:@" " withString:@"·"];
        }
        [body appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
    }
    NSDictionary *revision = index < self.details.count ? self.details[index] : nil;
    for (NSString *key in @[@"mediaChanged", @"formatChanged"]) {
        if (![revision[key] boolValue]) continue;
        NSString *note = TGExtraLoc([key isEqualToString:@"mediaChanged"] ? @"EDIT_HISTORY_MEDIA_CHANGED" : @"EDIT_HISTORY_FORMAT_CHANGED");
        [body appendAttributedString:[[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"%@[%@]", body.length ? @"\n" : @"", note] attributes:base]];
    }
    if (!body.length) [body appendAttributedString:[[NSAttributedString alloc] initWithString:@"—" attributes:base]];
    cell.textLabel.attributedText = body;
    return cell;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (![self.traitCollection.preferredContentSizeCategory isEqualToString:previousTraitCollection.preferredContentSizeCategory]) {
        [self.tableView reloadData];
    }
}

@end
