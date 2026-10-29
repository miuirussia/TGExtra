#import <Foundation/Foundation.h>

@interface TGExtraFilePickerCache : NSObject
+ (void)sizeWithCompletion:(void (^)(NSString *))completion;
+ (void)clearWithCompletion:(void (^)(NSError *))completion;
@end
