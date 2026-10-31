#import <Foundation/Foundation.h>

@interface TGExtraTemporaryFiles : NSObject
+ (void)didCopyFromURL:(NSURL *)source toURL:(NSURL *)destination;
+ (void)removeAbandonedExports;
+ (void)usageWithCompletion:(void (^)(NSUInteger, unsigned long long, NSError *))completion;
+ (void)clearWithCompletion:(void (^)(NSError *))completion;
@end
