#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, PHAssetResourceType) {
    PHAssetResourceTypePhoto = 1,
    PHAssetResourceTypeVideo = 2,
    PHAssetResourceTypePairedVideo = 9,
};

@interface PHAssetResourceCreationOptions : NSObject <NSCopying>
@property (nonatomic) BOOL shouldMoveFile;
@end

@interface PHAssetChangeRequest : NSObject
+ (instancetype)creationRequestForAssetFromVideoAtFileURL:(NSURL *)url;
@end

@interface PHAssetCreationRequest : PHAssetChangeRequest
- (void)addResourceWithType:(PHAssetResourceType)type fileURL:(NSURL *)url
                   options:(PHAssetResourceCreationOptions *)options;
- (void)addResourceWithType:(PHAssetResourceType)type data:(NSData *)data
                   options:(PHAssetResourceCreationOptions *)options;
@end

@interface PHPhotoLibrary : NSObject
@property (nonatomic) BOOL failImport;
@property (nonatomic, copy) NSArray<NSDictionary *> *imports;
- (void)performChanges:(dispatch_block_t)changes completionHandler:(void (^)(BOOL, NSError *))completion;
- (BOOL)performChangesAndWait:(dispatch_block_t)changes error:(NSError **)error;
@end
