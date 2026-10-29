#import "SettingsController.h"
#import "Icons.h"

static NSString *const kTGExtraTweakVersion = @"1.3.0";

@implementation TGExtra

- (void)viewDidLoad {
  self.isGhostModeExpanded = [[NSUserDefaults standardUserDefaults] boolForKey:kGhostDetailsToggle];

  [super viewDidLoad];
  [self setupTableView];
  [self setupIconAsHeader];
  [self setupFooterView];
  [self setupApplyButton];
  self.title = @"TGExtra";
  self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
  self.tableView.rowHeight = UITableViewAutomaticDimension;
  self.tableView.estimatedRowHeight = 72;

  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(didChangeLanguage)
             name:@"LanguageChangedNotification"
           object:nil];

  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(didChangeFakeLocation)
             name:@"TGExtraLocationChanged"
           object:nil];
}

- (void)setupFooterView {
  UIView *footerView = [[UIView alloc]
      initWithFrame:CGRectMake(0, 0, self.tableView.frame.size.width, 60)];
  UILabel *versionLabel = [[UILabel alloc] init];
  versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
  versionLabel.font = [UIFont systemFontOfSize:12];
  versionLabel.textColor = [UIColor secondaryLabelColor];
  versionLabel.textAlignment = NSTextAlignmentCenter;
  versionLabel.numberOfLines = 0;

    versionLabel.text =
      [NSString stringWithFormat:@"TGExtra Version %@\nTGExtra",
                                 kTGExtraTweakVersion];

  [footerView addSubview:versionLabel];

  [NSLayoutConstraint activateConstraints:@[
    [versionLabel.topAnchor constraintEqualToAnchor:footerView.topAnchor
                                           constant:20],
    [versionLabel.centerXAnchor
        constraintEqualToAnchor:footerView.centerXAnchor],
    [versionLabel.leadingAnchor constraintEqualToAnchor:footerView.leadingAnchor
                                               constant:20],
    [versionLabel.trailingAnchor
        constraintEqualToAnchor:footerView.trailingAnchor
                       constant:-20]
  ]];

  self.tableView.tableFooterView = footerView;
}

- (void)didChangeLanguage {
  [self.tableView reloadData];
}

- (void)didChangeFakeLocation {
  NSIndexSet *section = [NSIndexSet indexSetWithIndex:FAKE_LOCATION];
  [self.tableView reloadSections:section
                withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)setupTableView {
  self.tableView =
      [[UITableView alloc] initWithFrame:CGRectZero
                                   style:UITableViewStyleInsetGrouped];
  self.tableView.delegate = self;
  self.tableView.dataSource = self;
  self.tableView.translatesAutoresizingMaskIntoConstraints = NO;

  [self.view addSubview:self.tableView];

  [NSLayoutConstraint activateConstraints:@[
    [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
    [self.tableView.leadingAnchor
        constraintEqualToAnchor:self.view.leadingAnchor],
    [self.tableView.trailingAnchor
        constraintEqualToAnchor:self.view.trailingAnchor],
    [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
  ]];
}

- (void)setupIconAsHeader {
  UIView *headerContainer = [[UIView alloc]
      initWithFrame:CGRectMake(0, 0, self.tableView.frame.size.width, 120)];

  NSData *imageData = [[NSData alloc]
      initWithBase64EncodedString:CHOCOPNG
                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
  UIImageView *iconView =
      [[UIImageView alloc] initWithImage:[UIImage imageWithData:imageData]];
  iconView.translatesAutoresizingMaskIntoConstraints = NO;
  iconView.layer.cornerRadius = 100 / 4;
  iconView.userInteractionEnabled = YES;
  iconView.clipsToBounds = YES;
  iconView.contentMode = UIViewContentModeScaleAspectFill;
  iconView.tag = 100;

  [headerContainer addSubview:iconView];

  [NSLayoutConstraint activateConstraints:@[
    [iconView.topAnchor constraintEqualToAnchor:headerContainer.topAnchor
                                       constant:10],
    [iconView.centerXAnchor
        constraintEqualToAnchor:headerContainer.centerXAnchor],
    [iconView.widthAnchor constraintEqualToConstant:100],
    [iconView.heightAnchor constraintEqualToConstant:100],

  ]];

  self.tableView.tableHeaderView = headerContainer;
}

- (void)setupApplyButton {
  UIButton *applyChangesButton = [UIButton buttonWithType:UIButtonTypeSystem];
  UIImage *applyImage = [UIImage systemImageNamed:@"checkmark.square"];
  applyImage =
      [applyImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
  applyChangesButton.accessibilityLabel = TGLoc(@"APPLY");
  applyChangesButton.frame = CGRectMake(0, 0, 44, 44);
  applyChangesButton.tintColor = [UIColor systemPinkColor];
  [applyChangesButton setImage:applyImage forState:UIControlStateNormal];
  [applyChangesButton addTarget:self
                         action:@selector(applyChanges)
               forControlEvents:UIControlEventTouchUpInside];
  UIBarButtonItem *applyButtonItem =
      [[UIBarButtonItem alloc] initWithCustomView:applyChangesButton];
  self.navigationItem.rightBarButtonItems = @[ applyButtonItem ];
}

- (UIColor *)dynamicColorBW {
  static dispatch_once_t token;
  static UIColor *cached;
  dispatch_once(&token, ^{
    cached = [UIColor colorWithDynamicProvider:^UIColor *_Nonnull(
                          UITraitCollection *_Nonnull trait) {
      if (trait.userInterfaceStyle == UIUserInterfaceStyleDark) {
        return [UIColor whiteColor];
      } else {
        return [UIColor blackColor];
      }
    }];
  });
  return cached;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  return [self settingsCellForTableView:tableView indexPath:indexPath];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return SECTION_COUNT;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  NSArray *rows = [TGExtraSettingRow featureRowsForSection:section];
  if (rows) return rows.count;

  switch (section) {
  case GHOST_MODE:
    return 2 + (self.isGhostModeExpanded ? [TGExtraSettingRow ghostRows].count : 0);
  case GHOST_EXCEPTIONS:
    return MAX((NSInteger)[TGExtraGhostExceptions all].count, 1);
  case FILE_FIXER:
    return 2;
  case FAKE_LOCATION:
    return 2;
  case LANGUAGE:
    return 1;
  case MESSAGE_DATA:
    return 2;
  case CREDITS:
    return 2;
  default:
    return 0;
  }
  return 0;
}

- (NSString *)tableView:(UITableView *)tableView
    titleForHeaderInSection:(NSInteger)section {

  switch (section) {
  case GHOST_MODE:
    return TGLoc(@"GHOST_MODE_SECTION_HEADER");
  case GHOST_EXCEPTIONS:
    return TGLoc(@"GHOST_EXCEPTIONS_SECTION_HEADER");
  case MESSAGE_HISTORY:
    return TGLoc(@"MESSAGE_HISTORY_SECTION_HEADER");
  case CONTENT_ACCESS:
    return TGLoc(@"CONTENT_ACCESS_SECTION_HEADER");
  case MEDIA:
    return TGLoc(@"MEDIA_SECTION_HEADER");
  case INTERFACE:
    return TGLoc(@"INTERFACE_SECTION_HEADER");
  case FILE_FIXER:
    return TGLoc(@"FILE_FIXER_SECTION_HEADER");
  case FAKE_LOCATION:
    return TGLoc(@"FAKE_LOCATION_SECTION_HEADER");
  case LANGUAGE:
    return TGLoc(@"LANGUAGE_SECTION_HEADER");
  case MESSAGE_DATA:
    return TGLoc(@"MESSAGE_DATA_SECTION_HEADER");
  case CREDITS:
    return TGLoc(@"CREDITS_SECTION_HEADER");
  default:
    return nil;
  }
  return nil;
}

- (NSString *)tableView:(UITableView *)tableView
    titleForFooterInSection:(NSInteger)section {
  if (section == GHOST_EXCEPTIONS) {
    return TGLoc(@"GHOST_EXCEPTIONS_SECTION_FOOTER");
  }
  return nil;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];

  if (indexPath.section == GHOST_MODE && indexPath.row == 1) { // Ghost Expansion
    self.isGhostModeExpanded = !self.isGhostModeExpanded;
    [[NSUserDefaults standardUserDefaults] setBool:self.isGhostModeExpanded
                                            forKey:kGhostDetailsToggle];
    TGExtraSavePreferences();
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:GHOST_MODE]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
    return;
  }

  if (indexPath.section == GHOST_EXCEPTIONS) {
    NSArray<NSDictionary *> *exceptions = [TGExtraGhostExceptions all];
    if (indexPath.row < (NSInteger)exceptions.count) {
      [self openProfileForException:exceptions[indexPath.row]];
    }
    return;
  }

  if (indexPath.section == FILE_FIXER && indexPath.row == 1) {
    [self clearFilePickerFixCache];
    return;
  }

  if (indexPath.section == FAKE_LOCATION) { // Fake Location
    if (indexPath.row == 1) {
      [self showLocationSelector];
    }
  }

  if (indexPath.section == LANGUAGE) { // Language
    if (indexPath.row == 0) {
      [self showLanguageSelector];
    }
  }

  if (indexPath.section == MESSAGE_DATA) {
    if (indexPath.row == 0) [self confirmClearMessageData];
    else if (indexPath.row == 1) [self showDebugLog];
    return;
  }

  if (indexPath.section == CREDITS) {
    if (indexPath.row == 0) {
      NSURL *url = [NSURL URLWithString:@"https://github.com/miuirussia/TGExtra"];
      if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url
                                           options:@{}
                                 completionHandler:nil];
      }
    } else if (indexPath.row == 1) {
      [self showDisclaimer];
    }
  }
}

- (void)showDisclaimer {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:TGLoc(@"DISCLAIMER")
                                          message:TGLoc(@"AUTHOR_MESSAGE")
                                   preferredStyle:UIAlertControllerStyleAlert];

  UIAlertAction *okAction =
      [UIAlertAction actionWithTitle:TGLoc(@"OK")
                               style:UIAlertActionStyleDefault
                             handler:nil];

  [alert addAction:okAction];

  [self presentViewController:alert animated:YES completion:nil];
}

- (void)showLanguageSelector {
  LanguageSelector *ui = [LanguageSelector new];
  UINavigationController *navVC =
      [[UINavigationController alloc] initWithRootViewController:ui];
  [self presentViewController:navVC animated:YES completion:nil];
}

- (void)showLocationSelector {
  LocationSelector *ui = [LocationSelector new];
  UINavigationController *navVC =
      [[UINavigationController alloc] initWithRootViewController:ui];
  [self presentViewController:navVC animated:YES completion:nil];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

@end
