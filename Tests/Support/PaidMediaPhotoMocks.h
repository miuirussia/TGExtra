#import <Foundation/Foundation.h>

extern NSString *const PHPhotosErrorDomain;
enum { PHPhotosErrorInvalidResource = 3302 };

@interface PHObjectPlaceholder : NSObject
@property NSString *localIdentifier;
@end

@interface PHAssetChangeRequest : NSObject
@property NSDate *creationDate;
@property PHObjectPlaceholder *placeholderForCreatedAsset;
+ (instancetype)creationRequestForAssetFromVideoAtFileURL:(NSURL *)url;
+ (instancetype)creationRequestForAssetFromImageAtFileURL:(NSURL *)url;
@end

@interface PHPhotoLibrary : NSObject
+ (instancetype)sharedPhotoLibrary;
- (void)performChanges:(dispatch_block_t)changes completionHandler:(void (^)(BOOL, NSError *))completion;
@end
