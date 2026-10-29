#import <Foundation/Foundation.h>

// Keep section identifiers shared by the data source and targeted reloads.
typedef NS_ENUM(NSInteger, TABLE_VIEW_SECTIONS) {
  GHOST_MODE = 0,
  GHOST_EXCEPTIONS,
  MESSAGE_HISTORY,
  CONTENT_ACCESS,
  MEDIA,
  INTERFACE,
  FAKE_LOCATION,
  FILE_FIXER,
  MESSAGE_DATA,
  LANGUAGE,
  CREDITS,
  SECTION_COUNT,
};

// A switch's preference, localized text and icon travel together.
@interface TGExtraSettingRow : NSObject
@property(nonatomic, copy, readonly) NSString *key;
@property(nonatomic, copy, readonly) NSString *titleKey;
@property(nonatomic, copy, readonly) NSString *subtitleKey;
@property(nonatomic, copy, readonly) NSString *icon;
+ (NSArray<TGExtraSettingRow *> *)featureRowsForSection:(NSInteger)section;
+ (NSArray<TGExtraSettingRow *> *)ghostRows;
+ (TGExtraSettingRow *)rowForSection:(NSInteger)section row:(NSInteger)row;
@end
