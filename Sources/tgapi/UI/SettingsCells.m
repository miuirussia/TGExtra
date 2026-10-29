#import "SettingsCells.h"

void TGExtraResetSettingsCell(UITableViewCell *cell) {
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.userInteractionEnabled = YES;
    cell.alpha = 1.0;
    cell.isAccessibilityElement = YES;
    cell.accessibilityLabel = nil;
    cell.accessibilityHint = nil;
    cell.accessibilityValue = nil;
    cell.accessibilityTraits = UIAccessibilityTraitNone;
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.imageView.image = nil;
    cell.imageView.tintColor = UIColor.labelColor;
    cell.imageView.layer.cornerRadius = 0;
    cell.imageView.layer.masksToBounds = NO;
    cell.imageView.isAccessibilityElement = NO;
}

static UITableViewCell *settingsCell(UITableView *tableView, NSString *identifier) {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
    TGExtraResetSettingsCell(cell);
    return cell;
}

UITableViewCell *TGExtraNormalSettingsCell(UITableView *tableView) {
    return settingsCell(tableView, @"normalCell");
}

UITableViewCell *TGExtraSwitchSettingsCell(UITableView *tableView) {
    return settingsCell(tableView, @"switchCell");
}
