#import "Headers.h"
#import "../GhostExceptions.h"
#import "../SwiftgramPro.h"
#import "../Headers.h"
#import "../Logger/Logger.h"
#import "Icons.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TGLoc(key) [TGExtraLocalization localizedStringForKey:(key)]

// Declared up here rather than beside the data source because methods above it
// reload sections by index too — didChangeFakeLocation used a literal 3, which
// silently pointed at the wrong section the moment a section was inserted.
typedef NS_ENUM(NSInteger, TABLE_VIEW_SECTIONS) {
  GHOST_MODE = 0,
  GHOST_EXCEPTIONS = 1,
  MISC = 2,
  FILE_FIXER = 3,
  FAKE_LOCATION = 4,
  LANGUAGE = 5,
  MESSAGE_DATA = 6,
  CREDITS = 7,
};

static NSString *const kTGExtraTweakVersion = @"1.3.0";

@interface TGExtra ()
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) NSString *cacheSize;
@property(nonatomic, assign) BOOL isGhostModeExpanded;
@property(nonatomic, assign) BOOL isClearingMessageData;
- (NSString *)switchKeyForIndexPath:(NSIndexPath *)indexPath;
- (NSString *)sizeOfUglyFileFixDirectory;
- (void)reloadGhostExceptions;
- (void)openProfileForException:(NSDictionary *)entry;
- (void)showRenamePromptForException:(NSDictionary *)entry;
- (void)confirmClearMessageData;
+ (NSArray<NSString *> *)ghostSubFeatureKeys;
@end

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

  // Logo Image
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

- (void)applyChanges {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:TGLoc(@"APPLY")
                                          message:TGLoc(@"APPLY_CHANGES")
                                   preferredStyle:UIAlertControllerStyleAlert];

  UIAlertAction *okAction = [UIAlertAction
      actionWithTitle:TGLoc(@"OK")
                style:UIAlertActionStyleDefault
              handler:^(UIAlertAction *_Nonnull action) {
                if (!TGExtraSavePreferences()) {
                  TGExtraShowToast(TGLoc(@"SETTINGS_SAVE_FAILED"));
                  return;
                }
                // Apply forces an exit, so finish pending preference writes first.
                [[NSUserDefaults standardUserDefaults] synchronize];
                [[UIApplication sharedApplication]
                    performSelector:@selector(suspend)];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                                 exit(0);
                               });
              }];

  [alert addAction:okAction];

  UIAlertAction *cancelAction =
      [UIAlertAction actionWithTitle:TGLoc(@"CANCEL")
                               style:UIAlertActionStyleCancel
                             handler:nil];
  [alert addAction:cancelAction];
  [self presentViewController:alert animated:YES completion:nil];
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

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 8;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  switch (section) {
  case GHOST_MODE:
    return 2 + (self.isGhostModeExpanded ? [TGExtra ghostSubFeatureKeys].count : 0);
  case GHOST_EXCEPTIONS:
    // Falls back to a single explanatory row when the list is empty, so the
    // section never renders as a bare header.
    return MAX((NSInteger)[TGExtraGhostExceptions all].count, 1);
  case MISC:
    return TGExtraSwiftgramProAvailable() ? 11 : 10;
  case FILE_FIXER:
    return 2;
  case FAKE_LOCATION:
    return 2;
  case LANGUAGE:
    return 1;
  case MESSAGE_DATA:
    return 1;
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
  case MISC:
    return TGLoc(@"MISC_SECTION_HEADER");
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
  // Spells out that online status is exempt: account.updateStatus carries no
  // peer, so it cannot be made visible to one person only.
  if (section == GHOST_EXCEPTIONS) {
    return TGLoc(@"GHOST_EXCEPTIONS_SECTION_FOOTER");
  }
  if (section == MISC && TGExtraSwiftgramProAvailable()) {
    return TGLoc(@"SWIFTGRAM_SUPPORT_AUTHOR");
  }
  return nil;
}

- (UITableViewCell *)switchCellFromTableView:(UITableView *)tableView {
  UITableViewCell *switchCell =
      [tableView dequeueReusableCellWithIdentifier:@"switchCell"];
  if (!switchCell) {
    switchCell =
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                               reuseIdentifier:@"switchCell"];
  }

  return switchCell;
}

- (UITableViewCell *)normalCellFromTableView:(UITableView *)tableView {
  UITableViewCell *normalCell =
      [tableView dequeueReusableCellWithIdentifier:@"normalCell"];
  if (!normalCell) {
    normalCell =
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                               reuseIdentifier:@"normalCell"];
  }

  return normalCell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell;

  if (indexPath.section == GHOST_MODE) {
    if (indexPath.row == 1) {
      cell = [self normalCellFromTableView:tableView];
      cell.textLabel.text = TGLoc(@"ADVANCED_SETTINGS_TITLE");
      cell.detailTextLabel.text = self.isGhostModeExpanded ? TGLoc(@"ADVANCED_SETTINGS_HIDE") : TGLoc(@"ADVANCED_SETTINGS_SHOW");
      cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
      cell.accessoryView = nil;
      cell.imageView.image = [UIImage systemImageNamed:@"slider.horizontal.3"];
      cell.imageView.tintColor = [self dynamicColorBW];
      return cell;
    }

    cell = [self switchCellFromTableView:tableView];
    cell.imageView.image = nil;

    if (indexPath.row == 0) {
      cell.textLabel.text = TGLoc(@"GHOST_MODE_SECTION_HEADER");
      cell.detailTextLabel.text = TGLoc(@"GHOST_MODE_SUBTITLE");
      cell.imageView.image = [UIImage systemImageNamed:@"eye.slash.fill"];
      cell.imageView.tintColor = [self dynamicColorBW];
    } else {
      NSInteger ghostRow = indexPath.row - 2;
      if (ghostRow == 0) {
        cell.textLabel.text = TGLoc(@"DISABLE_ONLINE_STATUS_TITLE");
        cell.detailTextLabel.text = TGLoc(@"DISABLE_ONLINE_STATUS_SUBTITLE");
      } else if (ghostRow == 1) {
        cell.textLabel.text = TGLoc(@"DISABLE_TYPING_STATUS_TITLE");
        cell.detailTextLabel.text = TGLoc(@"DISABLE_TYPING_STATUS_SUBTITLE");
      } else if (ghostRow == 2) {
        cell.textLabel.text = TGLoc(@"DISABLE_RECORDING_VIDEO_STATUS_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_RECORDING_VIDEO_STATUS_SUBTITLE");
      } else if (ghostRow == 3) {
        cell.textLabel.text = TGLoc(@"DISABLE_UPLOADING_VIDEO_STATUS_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_UPLOADING_VIDEO_STATUS_SUBTITLE");
      } else if (ghostRow == 4) {
        cell.textLabel.text = TGLoc(@"DISABLE_VC_MESSAGE_RECORDING_STATUS_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_VC_MESSAGE_RECORDING_STATUS_SUBTITLE");
      } else if (ghostRow == 5) {
        cell.textLabel.text = TGLoc(@"DISABLE_VC_MESSAGE_UPLOADING_STATUS_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_VC_MESSAGE_UPLOADING_STATUS_SUBTITLE");
      } else if (ghostRow == 6) {
        cell.textLabel.text = TGLoc(@"DISABLE_UPLOADING_PHOTO_STATUS_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_UPLOADING_PHOTO_STATUS_SUBTITLE");
      } else if (ghostRow == 7) {
        cell.textLabel.text = TGLoc(@"DISABLE_UPLOADING_FILE_STATUS_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_UPLOADING_FILE_STATUS_SUBTITLE");
      } else if (ghostRow == 8) {
        cell.textLabel.text = TGLoc(@"DISABLE_CHOOSING_LOCATION_STATUS_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_CHOOSING_LOCATION_STATUS_SUBTITLE");
      } else if (ghostRow == 9) {
        cell.textLabel.text = TGLoc(@"DISABLE_CHOOSING_CONTACT_TITLE");
        cell.detailTextLabel.text = TGLoc(@"DISABLE_CHOOSING_CONTACT_SUBTITLE");
      } else if (ghostRow == 10) {
        cell.textLabel.text = TGLoc(@"DISABLE_PLAYING_GAME_STATUS_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_PLAYING_GAME_STATUS_SUBTITLE");
      } else if (ghostRow == 11) {
        cell.textLabel.text =
            TGLoc(@"DISABLE_RECORDING_ROUND_VIDEO_STATUS_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_RECORDING_ROUND_VIDEO_STATUS_SUBTITLE");
      } else if (ghostRow == 12) {
        cell.textLabel.text =
            TGLoc(@"DISABLE_UPLOADING_ROUND_VIDEO_STATUS_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_UPLOADING_ROUND_VIDEO_STATUS_TITLE");
      } else if (ghostRow == 13) {
        cell.textLabel.text =
            TGLoc(@"DISABLE_SPEAKING_IN_GROUP_CALL_STATUS_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_SPEAKING_IN_GROUP_CALL_STATUS_SUBTITLE");
      } else if (ghostRow == 14) {
        cell.textLabel.text = TGLoc(@"DISABLE_CHOOSING_STICKER_STATUS_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_CHOOSING_STICKER_STATUS_SUBTITLE");
      } else if (ghostRow == 15) {
        cell.textLabel.text = TGLoc(@"DISABLE_EMOJI_INTERACTION_STATUS_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_EMOJI_INTERACTION_STATUS_SUBTITLE");
      } else if (ghostRow == 16) {
        cell.textLabel.text =
            TGLoc(@"DISABLE_EMOJI_ACKNOWLEDGEMENT_STATUS_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_EMOJI_ACKNOWLEDGEMENT_STATUS_SUBTITLE");
      } else if (ghostRow == 17) {
        cell.textLabel.text = TGLoc(@"DISABLE_MESSAGE_READ_RECEIPT_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_MESSAGE_READ_RECEIPT_SUBTITLE");
      } else if (ghostRow == 18) {
        cell.textLabel.text = TGLoc(@"DISABLE_REACTION_READ_RECEIPT_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_REACTION_READ_RECEIPT_SUBTITLE");
      } else if (ghostRow == 19) {
        cell.textLabel.text = TGLoc(@"DISABLE_MENTION_READ_RECEIPT_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_MENTION_READ_RECEIPT_SUBTITLE");
      } else if (ghostRow == 20) {
        cell.textLabel.text = TGLoc(@"DISABLE_STORY_READ_RECEIPT_TITLE");
        cell.detailTextLabel.text =
            TGLoc(@"DISABLE_STORY_READ_RECEIPT_SUBTITLE");
      }
    }

    UISwitch *toggle = (UISwitch *)cell.accessoryView;
    if (!toggle || ![toggle isKindOfClass:[UISwitch class]]) {
      toggle = [[UISwitch alloc] init];
    }

    NSString *switchKey = [self switchKeyForIndexPath:indexPath];
    toggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:switchKey];
    toggle.accessibilityLabel = cell.textLabel.text;
    [toggle addTarget:self
                  action:@selector(switchChanged:)
        forControlEvents:UIControlEventValueChanged];
    toggle.tag = 1000 + (indexPath.section * 1000) + indexPath.row;
    cell.accessoryView = toggle;

    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    return cell;

  } else if (indexPath.section == GHOST_EXCEPTIONS) {
    cell = [self normalCellFromTableView:tableView];
    cell.accessoryView = nil;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    NSArray<NSDictionary *> *exceptions = [TGExtraGhostExceptions all];

    if (exceptions.count == 0) {
      cell.textLabel.text = TGLoc(@"GHOST_EXCEPTIONS_EMPTY_TITLE");
      cell.detailTextLabel.text = TGLoc(@"GHOST_EXCEPTIONS_EMPTY_SUBTITLE");
      cell.imageView.image = [UIImage systemImageNamed:@"person.badge.plus"];
      cell.imageView.tintColor = [UIColor secondaryLabelColor];
      cell.accessoryType = UITableViewCellAccessoryNone;
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
      return cell;
    }

    // The store is also mutated from the profile button, so never index it
    // blindly off a row count captured earlier.
    if (indexPath.row >= (NSInteger)exceptions.count) return cell;

    NSDictionary *entry = exceptions[indexPath.row];

    // Entries added before the name could be read off the wire have nothing but
    // an ID. Fill them in from the parser cache the first time they are drawn
    // after that peer has been seen again.
    if (!((NSString *)entry[kTGExtraGhostExceptionName]).length &&
        !((NSString *)entry[kTGExtraGhostExceptionUsername]).length) {
      NSNumber *peerId = entry[kTGExtraGhostExceptionId];
      NSDictionary *cached = [TLParser cachedPeerInfoForId:peerId];
      if (cached.count) {
        [TGExtraGhostExceptions addPeerId:peerId.longLongValue
                                  name:cached[@"name"]
                              username:cached[@"username"]];
        NSArray<NSDictionary *> *refreshed = [TGExtraGhostExceptions all];
        if (indexPath.row < (NSInteger)refreshed.count) {
          entry = refreshed[indexPath.row];
        }
      }
    }

    cell.textLabel.text = [TGExtraGhostExceptions displayNameForEntry:entry];

    NSString *username = entry[kTGExtraGhostExceptionUsername];
    cell.detailTextLabel.text =
        username.length ? [@"@" stringByAppendingString:username]
                        : [NSString stringWithFormat:@"ID %@",
                                                     entry[kTGExtraGhostExceptionId]];

    cell.imageView.image = [UIImage systemImageNamed:@"person.crop.circle.badge.checkmark"];
    cell.imageView.tintColor = [UIColor systemGreenColor];
    // Detail button opens the rename prompt; tapping the row opens the profile.
    cell.accessoryType = UITableViewCellAccessoryDetailDisclosureButton;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;

  } else if (indexPath.section == MISC) {
    cell = [self switchCellFromTableView:tableView];
    cell.imageView.image = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;

    if (indexPath.row == 0) {
      cell.imageView.image = [UIImage systemImageNamed:@"nosign"];
      cell.imageView.tintColor = [self dynamicColorBW];
      cell.textLabel.text = TGLoc(@"DISABLE_ALL_ADS_TITLE");
      cell.detailTextLabel.text = TGLoc(@"DISABLE_ALL_ADS_SUBTITLE");
    } else if (indexPath.row == 1) {
      cell.imageView.image = [UIImage systemImageNamed:@"lock.open.fill"];
      cell.imageView.tintColor = [self dynamicColorBW];
      cell.textLabel.text = TGLoc(@"ENABLE_SAVING_PROTECTED_CONTENT_TITLE");
      cell.detailTextLabel.text =
          TGLoc(@"ENABLE_SAVING_PROTECTED_CONTENT_SUBTITLE");
    } else if (indexPath.row == 2) {
      cell.imageView.image = [UIImage systemImageNamed:@"trash.slash.fill"];
      cell.imageView.tintColor = [self dynamicColorBW];
      cell.textLabel.text = TGLoc(@"ANTI_REVOKE_TITLE");
      cell.detailTextLabel.text = TGLoc(@"ANTI_REVOKE_SUBTITLE");
    } else if (indexPath.row == 3) {
      cell.imageView.image =
          [UIImage systemImageNamed:@"clock.arrow.circlepath"];
      cell.imageView.tintColor = [self dynamicColorBW];
      cell.textLabel.text = TGLoc(@"ANTI_AUTO_DELETE_TITLE");
      cell.detailTextLabel.text = TGLoc(@"ANTI_AUTO_DELETE_SUBTITLE");
    } else if (indexPath.row == 4) {
      cell.imageView.image = [UIImage systemImageNamed:@"camera.fill"];
      cell.imageView.tintColor = [self dynamicColorBW];
      cell.textLabel.text = TGLoc(@"ANTI_SCREENSHOT_TITLE");
      cell.detailTextLabel.text = TGLoc(@"ANTI_SCREENSHOT_SUBTITLE");
    } else if (indexPath.row == 5) {
      cell.imageView.image = [UIImage systemImageNamed:@"eye.fill"];
      cell.imageView.tintColor = [self dynamicColorBW];
      cell.textLabel.text = TGLoc(@"ANTI_SELF_DESTRUCT_TITLE");
      cell.detailTextLabel.text = TGLoc(@"ANTI_SELF_DESTRUCT_SUBTITLE");
    } else if (indexPath.row == 6) {
      cell.imageView.image = [UIImage systemImageNamed:@"pencil.slash"];
      cell.imageView.tintColor = [self dynamicColorBW];
      cell.textLabel.text = TGLoc(@"ANTI_EDIT_TITLE");
      cell.detailTextLabel.text = TGLoc(@"ANTI_EDIT_SUBTITLE");
    } else if (indexPath.row == 7) {
      cell.imageView.image = [UIImage systemImageNamed:@"text.badge.xmark"];
      cell.imageView.tintColor = [self dynamicColorBW];
      cell.textLabel.text = TGLoc(@"HIDE_DISAPPEARING_LABEL_TITLE");
      cell.detailTextLabel.text = TGLoc(@"HIDE_DISAPPEARING_LABEL_SUBTITLE");
    } else if (indexPath.row == 8) {
      cell.imageView.image = [UIImage systemImageNamed:@"waveform.circle.fill"];
      cell.imageView.tintColor = [self dynamicColorBW];
      cell.textLabel.text = TGLoc(@"VIDEO_TO_VOICE_TITLE");
      cell.detailTextLabel.text = TGLoc(@"VIDEO_TO_VOICE_SUBTITLE");
    } else if (indexPath.row == 9) {
      cell.imageView.image = [UIImage systemImageNamed:@"doc.on.doc"];
      cell.imageView.tintColor = [self dynamicColorBW];
      cell.textLabel.text = TGLoc(@"IGNORE_PRIVATE_COPY_PROTECTION_TITLE");
      cell.detailTextLabel.text = TGLoc(@"IGNORE_PRIVATE_COPY_PROTECTION_SUBTITLE");
    } else if (indexPath.row == 10) {
      cell.imageView.image = [UIImage systemImageNamed:@"star.circle.fill"];
      cell.imageView.tintColor = [self dynamicColorBW];
      cell.textLabel.text = TGLoc(@"SWIFTGRAM_PRO_TITLE");
      cell.detailTextLabel.text = TGLoc(@"SWIFTGRAM_PRO_SUBTITLE");
    }

    UISwitch *toggle = (UISwitch *)cell.accessoryView;
    if (!toggle || ![toggle isKindOfClass:[UISwitch class]]) {
      toggle = [[UISwitch alloc] init];
    }

    NSString *switchKey = [self switchKeyForIndexPath:indexPath];
    toggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:switchKey];
    toggle.accessibilityLabel = cell.textLabel.text;
    // Reset on every pass because cells are reused: a row disabled in an
    // earlier build would otherwise carry that state onto a working row.
    toggle.enabled = YES;
    [toggle addTarget:self
                  action:@selector(switchChanged:)
        forControlEvents:UIControlEventValueChanged];
    toggle.tag = 1000 + (indexPath.section * 1000) + indexPath.row;
    cell.accessoryView = toggle;

    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    return cell;
  } else if (indexPath.section == FILE_FIXER) {
    if (indexPath.row == 0) {
      cell = [self switchCellFromTableView:tableView];
      cell.imageView.image = [UIImage systemImageNamed:@"folder.fill.badge.gear"];
      cell.imageView.tintColor = [self dynamicColorBW];
      cell.textLabel.text = TGLoc(@"FIX_FILE_PICKER_TITLE");
      cell.detailTextLabel.text = TGLoc(@"FIX_FILE_PICKER_SUBTITLE");
      UISwitch *toggle = (UISwitch *)cell.accessoryView;
      if (!toggle || ![toggle isKindOfClass:[UISwitch class]]) toggle = [[UISwitch alloc] init];
      NSString *switchKey = [self switchKeyForIndexPath:indexPath];
      toggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:switchKey];
    toggle.accessibilityLabel = cell.textLabel.text;
      [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
      toggle.tag = 1000 + (indexPath.section * 1000) + indexPath.row;
      cell.accessoryView = toggle;
      cell.textLabel.numberOfLines = 0;
      cell.detailTextLabel.numberOfLines = 0;
      return cell;
    }
    cell = [self normalCellFromTableView:tableView];
    cell.textLabel.text = TGLoc(@"CLEAR_FILE_PICKER_CACHE_TITLE");
    cell.detailTextLabel.text = TGLoc(@"CLEAR_FILE_PICKER_CACHE_SUBTITLE");
    cell.imageView.image = [UIImage systemImageNamed:@"trash"];
    cell.imageView.tintColor = [UIColor redColor];
    UIActivityIndicatorView *loadingIcon = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [loadingIcon startAnimating];
    cell.accessoryView = loadingIcon;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
      if (!self.cacheSize) self.cacheSize = [self sizeOfUglyFileFixDirectory];
      dispatch_async(dispatch_get_main_queue(), ^{
        UITableViewCell *currentCell = [tableView cellForRowAtIndexPath:indexPath];
        if (currentCell == cell) {
          UILabel *sizeLabel = [[UILabel alloc] init];
          sizeLabel.text = self.cacheSize;
          cell.accessoryView = sizeLabel;
          [sizeLabel sizeToFit];
        }
      });
    });
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    return cell;
  } else if (indexPath.section == FAKE_LOCATION) {
    if (indexPath.row == 0) {
      cell = [self switchCellFromTableView:tableView];
      cell.imageView.image = [UIImage systemImageNamed:@"location.fill"];
      cell.imageView.tintColor = [self dynamicColorBW];
      cell.textLabel.text = TGLoc(@"ENABLE_FAKE_LOCATION_TITLE");
      cell.detailTextLabel.text = TGLoc(@"ENABLE_FAKE_LOCATION_SUBTITLE");
      UISwitch *toggle = (UISwitch *)cell.accessoryView;
      if (!toggle || ![toggle isKindOfClass:[UISwitch class]]) toggle = [[UISwitch alloc] init];
      NSString *switchKey = [self switchKeyForIndexPath:indexPath];
      toggle.on = [[NSUserDefaults standardUserDefaults] boolForKey:switchKey];
    toggle.accessibilityLabel = cell.textLabel.text;
      [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
      toggle.tag = 1000 + (indexPath.section * 1000) + indexPath.row;
      cell.accessoryView = toggle;
    }
    if (indexPath.row == 1) {
      cell = [self normalCellFromTableView:tableView];
      cell.imageView.image = [UIImage systemImageNamed:@"location.fill"];
      cell.imageView.tintColor = [self dynamicColorBW];
      cell.textLabel.text = TGLoc(@"SELECT_FAKE_LOCATION_TITLE");
      NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
      CGFloat savedLongitude = [defaults floatForKey:FAKE_LONGITUDE_KEY];
      CGFloat savedLatitude = [defaults floatForKey:FAKE_LATITUDE_KEY];
      cell.detailTextLabel.text = [NSString stringWithFormat:@"lon :%f\nlat :%f", savedLongitude ?: 0, savedLatitude ?: 0];
    }
    cell.detailTextLabel.numberOfLines = 0;
    return cell;
  } else if (indexPath.section == LANGUAGE) {
    cell = [self normalCellFromTableView:tableView];
    cell.textLabel.text = TGLoc(@"CHANGE_LANGUAGE_TITLE");
    cell.detailTextLabel.text = @"";
    cell.imageView.image = [UIImage systemImageNamed:@"globe"];
    cell.imageView.tintColor = [self dynamicColorBW];
    cell.accessoryView = nil;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    return cell;
  } else if (indexPath.section == MESSAGE_DATA) {
    cell = [tableView dequeueReusableCellWithIdentifier:@"messageDataCell"];
    if (!cell) {
      cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                   reuseIdentifier:@"messageDataCell"];
      cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
      cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
      cell.textLabel.adjustsFontForContentSizeCategory = YES;
      cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    }
    cell.textLabel.text = self.isClearingMessageData
        ? TGLoc(@"MESSAGE_DATA_CLEARING") : TGLoc(@"MESSAGE_DATA_CLEAR_TITLE");
    cell.detailTextLabel.text = TGLoc(@"MESSAGE_DATA_CLEAR_SUBTITLE");
    cell.textLabel.textColor = self.isClearingMessageData ? UIColor.secondaryLabelColor : UIColor.systemRedColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.image = [UIImage systemImageNamed:@"trash"];
    cell.imageView.tintColor = UIColor.systemRedColor;
    cell.imageView.isAccessibilityElement = NO;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.userInteractionEnabled = !self.isClearingMessageData;
    cell.isAccessibilityElement = YES;
    cell.accessibilityLabel = cell.textLabel.text;
    cell.accessibilityHint = cell.detailTextLabel.text;
    cell.accessibilityTraits = UIAccessibilityTraitButton |
        (self.isClearingMessageData ? UIAccessibilityTraitNotEnabled : 0);
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    if (self.isClearingMessageData) {
      UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
      [spinner startAnimating];
      cell.accessoryView = spinner;
    }
    return cell;
  } else if (indexPath.section == CREDITS) {
    cell = [self normalCellFromTableView:tableView];
    if (indexPath.row == 0) {
      cell.textLabel.text = @"TGExtra";
      cell.detailTextLabel.text = @"Developer";
      cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
      NSData *imageData = [[NSData alloc] initWithBase64EncodedString:CHOCOPNG options:NSDataBase64DecodingIgnoreUnknownCharacters];
      UIImage *rawImage = [UIImage imageWithData:imageData];
      UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(40, 40)];
      UIImage *thumb = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) { [rawImage drawInRect:CGRectMake(0, 0, 40, 40)]; }];
      cell.imageView.image = thumb;
      cell.imageView.layer.cornerRadius = 8;
      cell.imageView.layer.masksToBounds = YES;
      cell.accessoryView = nil;
    } else if (indexPath.row == 1) {
      cell.textLabel.text = TGLoc(@"DISCLAIMER");
      cell.detailTextLabel.text = @"A note from developer";
      cell.imageView.image = [UIImage systemImageNamed:@"note.text"];
      cell.imageView.tintColor = [self dynamicColorBW];
      cell.accessoryView = nil;
      cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    return cell;
  }

  return cell;
}

#pragma mark - UITableViewDelegate

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

  // Row 1 of File Picker Fix is the "clear cache" action. Without this branch
  // -clearFilePickerFixCache was never reachable and tapping the row did nothing.
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
    [self confirmClearMessageData];
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

#pragma mark - Ghost Exceptions

// Swipe-to-delete is only offered on real entries, never on the empty-state row.
- (BOOL)tableView:(UITableView *)tableView
    canEditRowAtIndexPath:(NSIndexPath *)indexPath {
  return indexPath.section == GHOST_EXCEPTIONS &&
         [TGExtraGhostExceptions all].count > 0;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
  return indexPath.section == GHOST_EXCEPTIONS
             ? UITableViewCellEditingStyleDelete
             : UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
  if (editingStyle != UITableViewCellEditingStyleDelete) return;
  if (indexPath.section != GHOST_EXCEPTIONS) return;

  NSArray<NSDictionary *> *exceptions = [TGExtraGhostExceptions all];
  if (indexPath.row >= (NSInteger)exceptions.count) return;

  NSNumber *peerId = exceptions[indexPath.row][kTGExtraGhostExceptionId];
  [TGExtraGhostExceptions removePeerId:peerId.longLongValue];
  // Removing the last entry swaps the row for the empty-state row rather than
  // deleting it, so the section is reloaded instead of the row animated out.
  [self reloadGhostExceptions];
}

- (void)tableView:(UITableView *)tableView
    accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section != GHOST_EXCEPTIONS) return;

  NSArray<NSDictionary *> *exceptions = [TGExtraGhostExceptions all];
  if (indexPath.row >= (NSInteger)exceptions.count) return;

  [self showRenamePromptForException:exceptions[indexPath.row]];
}

- (void)reloadGhostExceptions {
  [self.tableView
        reloadSections:[NSIndexSet indexSetWithIndex:GHOST_EXCEPTIONS]
      withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)showRenamePromptForException:(NSDictionary *)entry {
  NSNumber *peerId = entry[kTGExtraGhostExceptionId];

  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:TGLoc(@"GHOST_EXCEPTIONS_RENAME_TITLE")
                       message:TGLoc(@"GHOST_EXCEPTIONS_RENAME_MESSAGE")
                preferredStyle:UIAlertControllerStyleAlert];

  [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
    field.text = entry[kTGExtraGhostExceptionCustom];
    field.placeholder = [TGExtraGhostExceptions displayNameForEntry:entry];
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
  }];

  [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"CANCEL")
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  __weak typeof(self) weakSelf = self;
  [alert addAction:[UIAlertAction
                       actionWithTitle:TGLoc(@"SAVE")
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
                                 NSString *newName = alert.textFields.firstObject.text;
                                 // An empty field clears the rename and falls
                                 // back to the profile name.
                                 [TGExtraGhostExceptions setCustomName:newName
                                                          forPeerId:peerId.longLongValue];
                                 [weakSelf reloadGhostExceptions];
                               }]];

  [self presentViewController:alert animated:YES completion:nil];
}

- (void)openProfileForException:(NSDictionary *)entry {
  NSString *username = entry[kTGExtraGhostExceptionUsername];
  NSNumber *peerId = entry[kTGExtraGhostExceptionId];

  // A username resolves reliably; the numeric form only works for peers
  // Telegram already knows about, which is why it is the fallback.
  NSString *urlString =
      username.length
          ? [NSString stringWithFormat:@"tg://resolve?domain=%@", username]
          : [NSString stringWithFormat:@"tg://openmessage?user_id=%@", peerId];

  NSURL *url = [NSURL URLWithString:urlString];
  if (!url) return;

  // The TGExtra menu is modal — it has to go away before the profile can show
  // underneath it.
  [self dismissViewControllerAnimated:YES
                           completion:^{
                             TGExtraOpenTelegramURL(url);
                           }];
}

#pragma mark - Settings

- (void)switchChanged:(UISwitch *)sender {
  NSInteger adjustedTag = sender.tag - 1000;
  NSInteger section = adjustedTag / 1000;
  NSInteger row = adjustedTag % 1000;

  NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row inSection:section];
  NSString *switchKey = [self switchKeyForIndexPath:indexPath];

  if (switchKey) {
    if ([switchKey isEqualToString:kGhostModeEnabled] && sender.isOn) {
      if (![self anyGhostSubFeatureEnabled]) {
        [sender setOn:NO animated:YES];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kGhostModeEnabled];

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:TGLoc(@"GHOST_MODE_SECTION_HEADER")
                                                                       message:TGLoc(@"GHOST_MODE_NEEDS_SUBFEATURE")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"OK") style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
      }
    }

    [[NSUserDefaults standardUserDefaults] setBool:sender.isOn
                                            forKey:switchKey];
    if (!TGExtraSavePreferences()) {
      TGExtraShowToast(TGLoc(@"SETTINGS_SAVE_FAILED"));
    }
    // Names the key each row actually writes — the quickest way to catch a
    // section/row mapping that has drifted out of step with the labels.
    tgextraDiag("switch section=%ld row=%ld key=%{public}@ value=%d",
             (long)section, (long)row, switchKey, sender.isOn);
  } else {
    tgextraDiag("switch section=%ld row=%ld has NO KEY", (long)section, (long)row);
  }
}

// Single source of truth for the Ghost Mode sub-feature toggles: their order
// here is their row order in the expanded section, and -anyGhostSubFeatureEnabled
// reads the same array rather than repeating the list.
+ (NSArray<NSString *> *)ghostSubFeatureKeys {
  static NSArray<NSString *> *keys = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    keys = @[
      kDisableOnlineStatus, kDisableTypingStatus, kDisableRecordingVideoStatus,
      kDisableUploadingVideoStatus, kDisableRecordingVoiceStatus,
      kDisableUploadingVoiceStatus, kDisableUploadingPhotoStatus,
      kDisableUploadingFileStatus, kDisableChoosingLocationStatus,
      kDisableChoosingContactStatus, kDisablePlayingGameStatus,
      kDisableRecordingRoundVideoStatus, kDisableUploadingRoundVideoStatus,
      kDisableSpeakingInGroupCallStatus, kDisableChoosingStickerStatus,
      kDisableEmojiInteractionStatus, kDisableEmojiAcknowledgementStatus,
      kDisableMessageReadReceipt, kDisableReactionReadReceipt,
      kDisableMentionReadReceipt, kDisableStoriesReadReceipt
    ];
  });
  return keys;
}

- (NSString *)switchKeyForIndexPath:(NSIndexPath *)indexPath {
  // Sections are matched by enum, never by literal index — adding a section
  // used to silently shift every mapping below it.
  switch (indexPath.section) {
  case GHOST_MODE: {
    if (indexPath.row == 0) return kGhostModeEnabled;
    if (indexPath.row < 2) return nil;

    NSInteger ghostRow = indexPath.row - 2;
    NSArray<NSString *> *keys = [TGExtra ghostSubFeatureKeys];
    if (ghostRow < 0 || ghostRow >= (NSInteger)keys.count) return nil;
    return keys[ghostRow];
  }
  case MISC:
    switch (indexPath.row) {
    case 0:
      return kDisableAllAds;
    case 1:
      return kDisableForwardRestriction;
    case 2:
      return kAntiRevoke;
    case 3:
      return kAntiAutoDelete;
    case 4:
      return kDisableScreenshotNotification;
    case 5:
      return kAntiSelfDestruct;
    case 6:
      return kAntiEdit;
    case 7:
      return kHideDisappearingLabel;
    case 8:
      return kVideoToVoice;
    case 9:
      return kIgnorePrivateChatCopyProtection;
    case 10:
      return kSwiftgramPro;
    default:
      return nil;
    }
  case FILE_FIXER:
    if (indexPath.row == 0) return FILE_PICKER_FIX_KEY;
    return nil;
  case FAKE_LOCATION:
    return FAKE_LOCATION_ENABLED_KEY;
  default:
    return nil;
  }
}

- (NSString *)sizeOfUglyFileFixDirectory {
  NSString *uglyFixDirectory =
      [NSTemporaryDirectory() stringByAppendingPathComponent:FILE_PICKER_PATH];

  // Calculate size of it recursively
  unsigned long long totalSize = 0;
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSArray *contents = [fileManager subpathsAtPath:uglyFixDirectory];

  for (NSString *path in contents) {
    NSString *fullPath = [uglyFixDirectory stringByAppendingPathComponent:path];
    BOOL isDirectory;
    if ([fileManager fileExistsAtPath:fullPath isDirectory:&isDirectory]) {
      if (!isDirectory) {
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:fullPath
                                                                 error:nil];
        totalSize += [attributes fileSize];
      }
    }
  }

  // Format the size into MB or GB
  NSString *formattedSize;
  if (totalSize >= 1024 * 1024 * 1024) { // if the size is >= 1GB
    formattedSize = [NSString
        stringWithFormat:@"%.2f GB", totalSize / (1024.0 * 1024.0 * 1024.0)];
  } else {
    formattedSize =
        [NSString stringWithFormat:@"%.2f MB", totalSize / (1024.0 * 1024.0)];
  }
  return formattedSize;
}

- (BOOL)anyGhostSubFeatureEnabled {
  for (NSString *key in [TGExtra ghostSubFeatureKeys]) {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:key])
      return YES;
  }
  return NO;
}

- (void)showDebugLog {
  NSString *logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/tgextra_debug.txt"];
  NSString *logContent = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];

  if (!logContent || logContent.length == 0) {
    logContent = [NSString stringWithFormat:@"Log empty or not found.\nPath: %@", logPath];
  } else if (logContent.length > 3000) {
    logContent = [NSString stringWithFormat:@"...(last 3000 chars)\n%@",
                  [logContent substringFromIndex:logContent.length - 3000]];
  }

  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"Debug Log"
                       message:logContent
                preferredStyle:UIAlertControllerStyleAlert];

  [alert addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
    [UIPasteboard generalPasteboard].string = logContent;
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
    [@"" writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];

  [self presentViewController:alert animated:YES completion:nil];
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

- (void)confirmClearMessageData {
  if (self.isClearingMessageData) return;
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:TGLoc(@"MESSAGE_DATA_CLEAR_TITLE")
                       message:TGLoc(@"MESSAGE_DATA_CLEAR_CONFIRM")
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"CANCEL")
      style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:TGLoc(@"MESSAGE_DATA_CLEAR_TITLE")
      style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        self.isClearingMessageData = YES;
        NSIndexSet *section = [NSIndexSet indexSetWithIndex:MESSAGE_DATA];
        [self.tableView reloadSections:section withRowAnimation:UITableViewRowAnimationNone];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
          [TLParser clearMessageData];
          dispatch_async(dispatch_get_main_queue(), ^{
            self.isClearingMessageData = NO;
            [self.tableView reloadSections:section withRowAnimation:UITableViewRowAnimationNone];
            TGExtraShowToast(TGLoc(@"MESSAGE_DATA_CLEARED"));
          });
        });
      }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearFilePickerFixCache {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:TGLoc(@"CACHE_CLEAR_WARNING_TITLE")
                       message:TGLoc(@"CACHE_CLEAR_WARNING_MESSAGE")
                preferredStyle:UIAlertControllerStyleAlert];

  UIAlertAction *okAction = [UIAlertAction
      actionWithTitle:TGLoc(@"OK")
                style:UIAlertActionStyleDestructive
              handler:^(UIAlertAction *action) {
                NSString *uglyFixDirectory = [NSTemporaryDirectory()
                    stringByAppendingPathComponent:
                        @"TGExtraFileFixUsingSomeUglyHacks"];

                NSError *error = nil;
                [[NSFileManager defaultManager]
                    removeItemAtPath:uglyFixDirectory
                               error:&error];

                if (error) {
                  NSLog(@"Failed to remove cache directory: %@",
                        error.localizedDescription);
                } else {
                  NSLog(@"Successfully cleared cache: %@", uglyFixDirectory);
                }

                self.cacheSize = @"Cleared";

                // Reload section or row as needed
                dispatch_async(dispatch_get_main_queue(), ^{
                  NSIndexSet *section =
                      [NSIndexSet indexSetWithIndex:FILE_FIXER];
                  [self.tableView
                        reloadSections:section
                      withRowAnimation:UITableViewRowAnimationAutomatic];
                });
              }];

  UIAlertAction *cancelAction =
      [UIAlertAction actionWithTitle:TGLoc(@"CANCEL")
                               style:UIAlertActionStyleCancel
                             handler:nil];

  [alert addAction:cancelAction];
  [alert addAction:okAction];

  [self presentViewController:alert animated:YES completion:nil];
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter]
      removeObserver:self
                name:@"LanguageChangedNotification"
              object:nil];

  [[NSNotificationCenter defaultCenter] removeObserver:self
                                                  name:@"TGExtralocationChanged"
                                                object:nil];
}

@end
