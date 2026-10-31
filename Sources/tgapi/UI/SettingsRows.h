#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, TABLE_VIEW_SECTIONS) {
  GHOST_MODE = 0,
  GHOST_EXCEPTIONS,
  FAKE_LOCATION,
  MESSAGE_HISTORY,
  CONTENT_ACCESS,
  MEDIA,
  INTERFACE,
  TOOLS,
  LANGUAGE,
  CREDITS,
  SECTION_COUNT,
};

@interface TGExtraSettingRow : NSObject
@property(nonatomic, copy, readonly) NSString *key;
@property(nonatomic, copy, readonly) NSString *titleKey;
@property(nonatomic, copy, readonly) NSString *subtitleKey;
@property(nonatomic, copy, readonly) NSString *icon;
+ (NSArray<TGExtraSettingRow *> *)featureRowsForSection:(NSInteger)section;
+ (NSArray<TGExtraSettingRow *> *)ghostRows;
+ (TGExtraSettingRow *)rowForSection:(NSInteger)section row:(NSInteger)row;
@end
