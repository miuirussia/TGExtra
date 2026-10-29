#import "Headers.h"
#import <objc/runtime.h>
#import "EmbeddedLangs.h"

@interface LanguageSelector ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *languages;
@property (nonatomic, strong) NSString *initialLanguageCode;
@property (nonatomic, strong) NSString *selectedLanguageCode;
@end

@implementation LanguageSelector

- (void)viewDidLoad {
    [super viewDidLoad];

    self.initialLanguageCode = TGExtraLocalization.shared.languageCode;
    self.selectedLanguageCode = self.initialLanguageCode;

    self.languages = @[
        @{@"name": @"Arabic", @"code": @"ar", @"flag": @"🇸🇦"},
        @{@"name": @"Chinese", @"code": @"cn", @"flag": @"🇨🇳"},
        @{@"name": @"English", @"code": @"en", @"flag": @"🇺🇸"},
        @{@"name": @"French", @"code": @"fr", @"flag": @"🇫🇷"},
        @{@"name": @"Italian", @"code": @"it", @"flag": @"🇮🇹"},
        @{@"name": @"Japanese", @"code": @"ja", @"flag": @"🇯🇵"},
        @{@"name": @"Russian", @"code": @"ru", @"flag": @"🇷🇺"},
        @{@"name": @"Spanish", @"code": @"es", @"flag": @"🇪🇸"},
        @{@"name": @"Taiwan", @"code": @"tw", @"flag": @"🇹🇼"},
        @{@"name": @"Vietnamese", @"code": @"vn", @"flag": @"🇻🇳"}
    ];

    self.title = [TGExtraLocalization localizedStringForKey:@"LANGUAGE_SECTION_HEADER"] ?: @"Language";

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *closeImage = [UIImage systemImageNamed:@"xmark"];
    closeImage = [closeImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [closeButton setImage:closeImage forState:UIControlStateNormal];
    [closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:closeButton];

    UIButton *applyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *applyImage = [UIImage systemImageNamed:@"checkmark.square"];
    applyImage = [applyImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    applyButton.tintColor = [UIColor systemPinkColor];
    [applyButton setImage:applyImage forState:UIControlStateNormal];
    [applyButton addTarget:self action:@selector(applyTapped) forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:applyButton];

    [self setupTableView];
}

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.languages.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"languageCell";

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    } else {
        cell.imageView.image = nil;
        cell.accessoryView = nil;
        cell.alpha = 1.0;
        cell.userInteractionEnabled = YES;
        cell.accessoryType = UITableViewCellAccessoryNone;
    }

    NSDictionary *languageData = self.languages[indexPath.row];

    NSString *title = [NSString stringWithFormat:@"%@ %@", languageData[@"flag"], languageData[@"name"]];
    cell.textLabel.text = title;

    if ([self.selectedLanguageCode isEqualToString:languageData[@"code"]]) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *languageData = self.languages[indexPath.row];
    self.selectedLanguageCode = languageData[@"code"];

    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [tableView reloadData];
}

- (void)closeTapped {
    if ([self.selectedLanguageCode isEqualToString:self.initialLanguageCode]) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self applyTapped];
    }
}

- (void)applyTapped {
    if ([self.selectedLanguageCode isEqualToString:self.initialLanguageCode]) {
        [self dismissViewControllerAnimated:YES completion:nil];
        return;
    }

    NSString *title = [TGExtraLocalization localizedStringForKey:@"APPLY"] ?: @"Apply";
    NSString *message = [TGExtraLocalization localizedStringForKey:@"APPLY_CHANGES"] ?: @"To apply the language, you need to restart the app.";

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *restartAction = [UIAlertAction actionWithTitle:@"Restart"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(UIAlertAction *action) {
        id previousLanguage = [NSUserDefaults.standardUserDefaults objectForKey:@"TGExtraLanguage"];
        [[NSUserDefaults standardUserDefaults] setObject:self.selectedLanguageCode forKey:@"TGExtraLanguage"];
        if (!TGExtraSavePreferences()) {
            if (previousLanguage) [NSUserDefaults.standardUserDefaults setObject:previousLanguage forKey:@"TGExtraLanguage"];
            else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"TGExtraLanguage"];
            TGExtraShowToast([TGExtraLocalization localizedStringForKey:@"SETTINGS_SAVE_FAILED"]);
            return;
        }
        [[NSUserDefaults standardUserDefaults] synchronize];

        [[UIApplication sharedApplication] performSelector:@selector(suspend)];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            exit(0);
        });
    }];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:[TGExtraLocalization localizedStringForKey:@"CANCEL"] ?: @"Cancel"
                                                           style:UIAlertActionStyleCancel
                                                         handler:^(UIAlertAction *action) {
        self.selectedLanguageCode = self.initialLanguageCode;
        [self.tableView reloadData];
        [self dismissViewControllerAnimated:YES completion:nil];
    }];

    [alert addAction:restartAction];
    [alert addAction:cancelAction];

    [self presentViewController:alert animated:YES completion:nil];
}

@end
