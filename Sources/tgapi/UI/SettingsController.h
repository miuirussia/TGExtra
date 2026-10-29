#import "Headers.h"
#import "SettingsRows.h"
#import "SettingsCells.h"
#import "../Headers.h"
#import "../GhostExceptions.h"
#import "../PeerInfoStore.h"

#define TGLoc(key) [TGExtraLocalization localizedStringForKey:(key)]

@interface TGExtra ()
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic) BOOL isGhostModeExpanded;
@property(nonatomic) BOOL isClearingMessageData;
- (UIColor *)dynamicColorBW;
@end

@interface TGExtra (TableCells)
- (UITableViewCell *)settingsCellForTableView:(UITableView *)tableView indexPath:(NSIndexPath *)indexPath;
@end

@interface TGExtra (Changes)
- (void)applyChanges;
- (void)switchChanged:(UISwitch *)sender;
- (BOOL)anyGhostSubFeatureEnabled;
- (NSString *)switchKeyForIndexPath:(NSIndexPath *)indexPath;
@end

@interface TGExtra (GhostExceptions)
- (void)reloadGhostExceptions;
- (void)openProfileForException:(NSDictionary *)entry;
- (void)showRenamePromptForException:(NSDictionary *)entry;
@end

@interface TGExtra (DebugLog)
- (void)showDebugLog;
@end

@interface TGExtra (Maintenance)
- (void)confirmClearMessageData;
- (void)clearFilePickerFixCache;
@end
