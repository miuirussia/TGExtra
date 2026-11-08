#import "MessageLogViewController.h"
#import "Headers.h"
#import "SettingsCells.h"
#import "TGExtraLocalization.h"
#import "EditHistoryViewController.h"
#import "../Headers.h"

#define TGLoc(key) [TGExtraLocalization localizedStringForKey:(key)]

@interface TGExtraMessageLogViewController ()
@property NSArray<NSDictionary *> *allEntries;
@property NSArray<NSDictionary *> *entries;
@property UISegmentedControl *filter;
@property NSString *account;
@property NSDictionary<NSString *, NSString *> *accountNames;
@property NSUInteger reloadGeneration;
@end

@implementation TGExtraMessageLogViewController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = TGLoc(@"MESSAGE_LOG_TITLE");
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 110;
    self.filter = [[UISegmentedControl alloc] initWithItems:@[TGLoc(@"MESSAGE_LOG_ALL"), TGLoc(@"MESSAGE_LOG_DELETED"), TGLoc(@"MESSAGE_LOG_EDITED")]];
    self.filter.selectedSegmentIndex = 0;
    self.filter.accessibilityLabel = TGLoc(@"MESSAGE_LOG_FILTER");
    [self.filter addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 60)];
    self.filter.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:self.filter];
    [NSLayoutConstraint activateConstraints:@[
        [self.filter.leadingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.leadingAnchor],
        [self.filter.trailingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.trailingAnchor],
        [self.filter.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [self.filter.heightAnchor constraintGreaterThanOrEqualToConstant:44]
    ]];
    self.tableView.tableHeaderView = header;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:TGLoc(@"MESSAGE_LOG_CLEAR")
        style:UIBarButtonItemStylePlain target:self action:@selector(clearLog)];
    self.navigationItem.rightBarButtonItem.tintColor = UIColor.systemRedColor;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadEntries)
        name:@"TGExtraMessageLogChanged" object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadEntries)
        name:@"TGExtraMessageDataCleared" object:nil];
    [self reloadEntries];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)reloadEntries {
    NSUInteger generation = ++self.reloadGeneration;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *entries = [TLParser messageLogEntries];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.reloadGeneration) return;
            self.allEntries = entries;
            NSMutableSet *accounts = [NSMutableSet new];
            for (NSDictionary *entry in entries) if (entry[@"account"]) [accounts addObject:entry[@"account"]];
            NSArray *ordered = [accounts.allObjects sortedArrayUsingSelector:@selector(compare:)];
            NSMutableDictionary *names = [NSMutableDictionary new];
            for (NSUInteger index = 0; index < ordered.count; index++) {
                NSString *account = ordered[index];
                NSString *name = nil;
                for (NSDictionary *entry in entries) if ([entry[@"account"] isEqual:account] && [entry[@"accountName"] length]) {
                    name = entry[@"accountName"]; break;
                }
                names[account] = name ?: [NSString stringWithFormat:TGLoc(@"MESSAGE_LOG_ACCOUNT"), (unsigned long)index + 1];
            }
            self.accountNames = names;
            if (self.account && !names[self.account]) self.account = nil;
            [self filterChanged];
        });
    });
}

- (void)filterChanged {
    NSString *kind = self.filter.selectedSegmentIndex == 1 ? @"deleted" : self.filter.selectedSegmentIndex == 2 ? @"edited" : nil;
    NSMutableArray *entries = [NSMutableArray new];
    for (NSDictionary *entry in self.allEntries) {
        if ((!kind || [entry[@"kind"] isEqual:kind]) && (!self.account || [entry[@"account"] isEqual:self.account])) [entries addObject:entry];
    }
    self.entries = entries;
    self.navigationItem.rightBarButtonItem.enabled = self.allEntries.count != 0;
    NSMutableArray *actions = [NSMutableArray new];
    NSArray *accounts = [self.accountNames.allKeys sortedArrayUsingSelector:@selector(compare:)];
    __weak typeof(self) weakSelf = self;
    UIAction *all = [UIAction actionWithTitle:TGLoc(@"MESSAGE_LOG_ALL_ACCOUNTS") image:nil identifier:nil handler:^(UIAction *action) {
        weakSelf.account = nil; [weakSelf filterChanged];
    }];
    all.state = self.account ? UIMenuElementStateOff : UIMenuElementStateOn;
    [actions addObject:all];
    for (NSString *account in accounts) {
        UIAction *action = [UIAction actionWithTitle:self.accountNames[account] image:nil identifier:nil handler:^(UIAction *action) {
            weakSelf.account = account; [weakSelf filterChanged];
        }];
        action.state = [self.account isEqual:account] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    UIBarButtonItem *selector = [[UIBarButtonItem alloc] initWithTitle:self.account ? self.accountNames[self.account] : TGLoc(@"MESSAGE_LOG_ALL_ACCOUNTS")
        menu:[UIMenu menuWithTitle:@"" children:actions]];
    self.toolbarItems = @[selector];
    [self.navigationController setToolbarHidden:accounts.count < 2 animated:NO];
    UILabel *empty = [UILabel new];
    empty.text = TGLoc(@"MESSAGE_LOG_EMPTY");
    empty.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    empty.adjustsFontForContentSizeCategory = YES;
    empty.textColor = UIColor.secondaryLabelColor;
    empty.textAlignment = NSTextAlignmentCenter;
    empty.numberOfLines = 0;
    self.tableView.backgroundView = entries.count ? nil : empty;
    [self.tableView reloadData];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:self.accountNames.count < 2 animated:animated];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.entries.count; }

- (NSString *)entryDate:(NSDictionary *)entry {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterMediumStyle;
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:[entry[@"date"] doubleValue]]];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = TGExtraNormalSettingsCell(tableView);
    NSDictionary *entry = self.entries[indexPath.row];
    BOOL deleted = [entry[@"kind"] isEqual:@"deleted"];
    NSString *peer = [entry[@"name"] length] ? entry[@"name"] : [NSString stringWithFormat:@"ID %@", entry[@"peer"]];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@", peer, TGLoc(deleted ? @"MESSAGE_LOG_DELETED" : @"MESSAGE_LOG_EDITED")];
    NSString *body = [entry[@"text"] length] ? entry[@"text"] : TGLoc(@"MESSAGE_LOG_NO_TEXT");
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@\n%@", self.accountNames[entry[@"account"]], [self entryDate:entry], body];
    cell.detailTextLabel.numberOfLines = 4;
    cell.imageView.image = [UIImage systemImageNamed:deleted ? @"trash" : @"pencil"];
    cell.imageView.tintColor = deleted ? UIColor.systemRedColor : UIColor.systemBlueColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *entry = self.entries[indexPath.row];
    NSArray *details = [TLParser editRevisionDetailsForId:entry[@"id"] peer:entry[@"peer"] account:entry[@"account"] messageNamespace:entry[@"namespace"]];
    if ([entry[@"kind"] isEqual:@"edited"] && details.count > 1) {
        NSArray *versions = [details valueForKey:@"text"];
        TGExtraEditHistoryViewController *history = [[TGExtraEditHistoryViewController alloc] initWithVersions:versions details:details];
        [self presentViewController:[[UINavigationController alloc] initWithRootViewController:history] animated:YES completion:nil];
        return;
    }
    NSString *body = [entry[@"text"] length] ? entry[@"text"] : TGLoc(@"MESSAGE_LOG_NO_TEXT");
    if ([entry[@"kind"] isEqual:@"edited"]) body = [NSString stringWithFormat:@"%@\n\n%@", entry[@"old"] ?: @"", body];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[self entryDate:entry] message:body preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"DEBUG_LOG_COPY") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = body;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"CLOSE") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearLog {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:TGLoc(@"MESSAGE_LOG_CLEAR")
        message:TGLoc(@"MESSAGE_LOG_CLEAR_CONFIRM") preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"CANCEL") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"MESSAGE_LOG_CLEAR") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            BOOL cleared = [TLParser clearMessageLog];
            if (!cleared) dispatch_async(dispatch_get_main_queue(), ^{ TGExtraShowToast(TGLoc(@"MESSAGE_DATA_CLEAR_FAILED")); });
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
