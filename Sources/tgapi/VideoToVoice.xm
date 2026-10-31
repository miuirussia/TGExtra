#import "Compatibility.h"
#import "Headers.h"
#import "UI/Headers.h"
#import "VoiceSelection.h"
#import "VideoAudioExtractor.h"
#import <objc/message.h>

typedef id (^TGExtraDescriptionGenerator)(id, NSAttributedString *, NSString *, NSString *);

%group TGExtraVoiceSend
%hook TGMediaAssetsController

+ (NSArray *)resultSignalsForSelectionContext:(id)selectionContext
                               editingContext:(id)editingContext
                                       intent:(NSInteger)intent
                                  currentItem:(id)currentItem
                                  storeAssets:(bool)storeAssets
                                convertToJpeg:(bool)convertToJpeg
                         descriptionGenerator:(TGExtraDescriptionGenerator)descriptionGenerator
                             saveEditedPhotos:(bool)saveEditedPhotos {
    if ((!tgextraVideoToVoiceEnabled() && !tgextraVideoToRoundEnabled()) || !descriptionGenerator) return %orig;

    NSSet<NSString *> *voiceItems = tgextraVideoToVoiceEnabled() ? tgextraVoiceItems(editingContext) : [NSSet set];
    NSSet<NSString *> *roundItems = tgextraVideoToRoundEnabled() ? tgextraRoundItems(editingContext) : [NSSet set];
    if (voiceItems.count == 0 && roundItems.count == 0) return %orig;
    TGExtraDescriptionGenerator wrapped =
        ^id(id dict, NSAttributedString *caption, NSString *hash, NSString *uniqueId) {
            NSString *identifier = uniqueId;
            if (!identifier && [dict isKindOfClass:NSDictionary.class]) {
                identifier = tgextraVoiceItemIdentifier(dict[@"asset"] ?: dict[@"url"]);
            }
            BOOL round = identifier && [roundItems containsObject:identifier];
            if (!identifier || (!round && ![voiceItems containsObject:identifier])) {
                return descriptionGenerator(dict, caption, hash, uniqueId);
            }
            NSString *type = [dict isKindOfClass:NSDictionary.class] ? dict[@"type"] : nil;
            if (![type isKindOfClass:NSString.class] ||
                !([type isEqualToString:@"video"] || [type isEqualToString:@"cameraVideo"])) {
                return descriptionGenerator(dict, caption, hash, uniqueId);
            }
            NSDictionary *rewritten = nil;
            @try {
                rewritten = round ? tgextraRewriteToRound(dict, editingContext)
                                  : tgextraRewriteToVoice(dict, editingContext);
            } @catch (NSException *e) {
                tgextraDiag("v2v: rewrite threw — %{public}s", e.reason.UTF8String ?: "?");
            }
            if (!rewritten) {
                TGExtraShowToast([TGExtraLocalization localizedStringForKey:
                    round ? @"VIDEO_TO_ROUND_FAILED" : @"VIDEO_TO_VOICE_FAILED"]);
                return nil;
            }
            return descriptionGenerator(rewritten, caption, hash, uniqueId);
        };

    return %orig(selectionContext, editingContext, intent, currentItem, storeAssets,
                 convertToJpeg, wrapped, saveEditedPhotos);
}

%end
%end

%ctor {
    Class cls = objc_getClass("TGMediaAssetsController");
    Method send = class_getClassMethod(cls, NSSelectorFromString(@"resultSignalsForSelectionContext:editingContext:intent:currentItem:storeAssets:convertToJpeg:descriptionGenerator:saveEditedPhotos:"));
    if (send && method_getNumberOfArguments(send) == 10) {
        %init(TGExtraVoiceSend);
        TGExtraRecordHookStatus(@"Voice send", @"installed");
    } else {
        TGExtraRecordHookStatus(@"Voice send", @"unavailable: picker send interface");
    }
}
