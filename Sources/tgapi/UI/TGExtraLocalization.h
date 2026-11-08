#import <Foundation/Foundation.h>

@class TGLocalization;
@interface TGExtraLocalization : NSObject
@property (nonatomic, strong) TGLocalization *localization;
@property (nonatomic, copy, readonly) NSString *languageCode;
+ (instancetype)shared;
+ (NSString *)localizedStringForKey:(NSString *)key;
@end

@interface TGExtraLocalization (Loading)
- (void)loadDefault;
@end
