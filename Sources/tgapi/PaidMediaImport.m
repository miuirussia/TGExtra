#ifdef TGEXTRA_TESTING
#import "PaidMediaPhotoMocks.h"
#else
#import <Photos/Photos.h>
#endif
#import "PaidMedia.h"
#import "StoryVideoExport.h"

static void importMediaOnce(NSURL *url, BOOL video, void (^completion)(NSString *, NSError *)) {
    __block NSString *identifier = nil;
    [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
        PHAssetChangeRequest *request = video
            ? [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:url]
            : [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:url];
        request.creationDate = NSDate.date;
        identifier = request.placeholderForCreatedAsset.localIdentifier;
    } completionHandler:^(BOOL success, NSError *error) {
        if (error || !success || !identifier.length) {
            error = error ?: [NSError errorWithDomain:@"TGExtra.PaidMedia.Photos" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"Photos did not create an asset"}];
            identifier = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(identifier, error); });
    }];
}

void TGExtraImportPaidMedia(NSURL *url, BOOL video, void (^completion)(NSString *, NSError *)) {
    importMediaOnce(url, video, ^(NSString *identifier, NSError *error) {
        BOOL invalidResource = NO;
        if (@available(iOS 15.0, *)) {
            invalidResource = [error.domain isEqualToString:PHPhotosErrorDomain] &&
                error.code == PHPhotosErrorInvalidResource;
        }
        BOOL noAsset = [error.domain isEqualToString:@"TGExtra.PaidMedia.Photos"];
        if (!video || !error || !(invalidResource || noAsset)) {
            completion(identifier, error);
            return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSURL *converted = TGExtraExportStoryVideo(url);
            if (!converted) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
                return;
            }
            importMediaOnce(converted, YES, ^(NSString *convertedIdentifier, NSError *conversionError) {
                [NSFileManager.defaultManager removeItemAtURL:converted error:NULL];
                completion(convertedIdentifier, conversionError);
            });
        });
    });
}
