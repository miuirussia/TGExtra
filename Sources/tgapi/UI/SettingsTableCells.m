#import "SettingsController.h"
#import "FilePickerCache.h"
#import "Icons.h"
#import "GhostExceptionDisplayName.h"

@implementation TGExtra (TableCells)

- (UITableViewCell *)settingsCellForTableView:(UITableView *)tableView indexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell;

  TGExtraSettingRow *setting = [TGExtraSettingRow rowForSection:indexPath.section row:indexPath.row];
  if (setting) {
    cell = TGExtraSwitchSettingsCell(tableView);
    cell.textLabel.text = TGLoc(setting.titleKey);
    cell.detailTextLabel.text = TGLoc(setting.subtitleKey);
    cell.imageView.image = setting.icon.length ? [UIImage systemImageNamed:setting.icon] : nil;
    cell.imageView.tintColor = [self dynamicColorBW];
    cell.accessoryType = UITableViewCellAccessoryNone;
    UISwitch *toggle = [cell.accessoryView isKindOfClass:UISwitch.class] ? (UISwitch *)cell.accessoryView : [UISwitch new];
    toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:setting.key];
    toggle.enabled = YES;
    toggle.accessibilityLabel = cell.textLabel.text;
    [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    toggle.tag = 1000 + indexPath.section * 1000 + indexPath.row;
    cell.accessoryView = toggle;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    return cell;
  }

  if (indexPath.section == GHOST_MODE) {
    cell = TGExtraNormalSettingsCell(tableView);
    cell.textLabel.text = TGLoc(@"ADVANCED_SETTINGS_TITLE");
    cell.detailTextLabel.text = self.isGhostModeExpanded ? TGLoc(@"ADVANCED_SETTINGS_HIDE") : TGLoc(@"ADVANCED_SETTINGS_SHOW");
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.accessoryView = nil;
    cell.imageView.image = [UIImage systemImageNamed:@"slider.horizontal.3"];
    cell.imageView.tintColor = [self dynamicColorBW];
    return cell;
  } else if (indexPath.section == GHOST_EXCEPTIONS) {
    cell = TGExtraNormalSettingsCell(tableView);
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

    if (indexPath.row >= (NSInteger)exceptions.count) return cell;

    NSDictionary *entry = exceptions[indexPath.row];

    if (!((NSString *)entry[kTGExtraGhostExceptionName]).length &&
        !((NSString *)entry[kTGExtraGhostExceptionUsername]).length) {
      NSNumber *peerId = entry[kTGExtraGhostExceptionId];
      NSDictionary *cached = [TGExtraPeerInfoStore cachedPeerInfoForId:peerId];
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

    cell.textLabel.text = ghostExceptionDisplayName(entry);

    NSString *username = entry[kTGExtraGhostExceptionUsername];
    cell.detailTextLabel.text =
        username.length ? [@"@" stringByAppendingString:username]
                        : [NSString stringWithFormat:@"ID %@",
                                                     entry[kTGExtraGhostExceptionId]];

    cell.imageView.image = [UIImage systemImageNamed:@"person.crop.circle.badge.checkmark"];
    cell.imageView.tintColor = [UIColor systemGreenColor];
    cell.accessoryType = UITableViewCellAccessoryDetailDisclosureButton;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;

  } else if (indexPath.section == FILE_FIXER) {
    cell = TGExtraNormalSettingsCell(tableView);
    cell.textLabel.text = TGLoc(@"CLEAR_FILE_PICKER_CACHE_TITLE");
    cell.detailTextLabel.text = TGLoc(@"CLEAR_FILE_PICKER_CACHE_SUBTITLE");
    cell.imageView.image = [UIImage systemImageNamed:@"trash"];
    cell.imageView.tintColor = [UIColor redColor];
    UIActivityIndicatorView *loadingIcon = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [loadingIcon startAnimating];
    cell.accessoryView = loadingIcon;
    [TGExtraFilePickerCache sizeWithCompletion:^(NSString *size) {
      UITableViewCell *currentCell = [tableView cellForRowAtIndexPath:indexPath];
      if (currentCell == cell && [cell.textLabel.text isEqualToString:TGLoc(@"CLEAR_FILE_PICKER_CACHE_TITLE")]) {
        UILabel *label = [UILabel new];
        label.text = size;
        [label sizeToFit];
        cell.accessoryView = label;
      }
    }];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    return cell;
  } else if (indexPath.section == FAKE_LOCATION) {
    if (indexPath.row == 1) {
      cell = TGExtraNormalSettingsCell(tableView);
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
    cell = TGExtraNormalSettingsCell(tableView);
    cell.textLabel.text = TGLoc(@"CHANGE_LANGUAGE_TITLE");
    cell.detailTextLabel.text = @"";
    cell.imageView.image = [UIImage systemImageNamed:@"globe"];
    cell.imageView.tintColor = [self dynamicColorBW];
    cell.accessoryView = nil;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    return cell;
  } else if (indexPath.section == MESSAGE_DATA) {
    if (indexPath.row == 1) {
      cell = TGExtraNormalSettingsCell(tableView);
      cell.textLabel.text = TGLoc(@"DEBUG_LOG_TITLE");
      cell.detailTextLabel.text = TGLoc(@"DEBUG_LOG_SUBTITLE");
      cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
      cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
      cell.textLabel.adjustsFontForContentSizeCategory = YES;
      cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
      cell.textLabel.textColor = UIColor.labelColor;
      cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
      cell.textLabel.numberOfLines = 0;
      cell.detailTextLabel.numberOfLines = 0;
      cell.imageView.image = [UIImage systemImageNamed:@"doc.text.magnifyingglass"];
      cell.imageView.tintColor = [self dynamicColorBW];
      cell.imageView.isAccessibilityElement = NO;
      cell.accessoryView = nil;
      cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
      cell.isAccessibilityElement = YES;
      cell.accessibilityLabel = cell.textLabel.text;
      cell.accessibilityHint = cell.detailTextLabel.text;
      cell.accessibilityTraits = UIAccessibilityTraitButton;
      return cell;
    }
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
    cell = TGExtraNormalSettingsCell(tableView);
    if (indexPath.row == 0) {
      cell.textLabel.text = TGLoc(@"DEVELOPED_BY");
      cell.detailTextLabel.text = TGLoc(@"ORIGINAL_IDEA_BY");
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

@end
