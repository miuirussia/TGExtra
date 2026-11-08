#import "Headers.h"
#import "VideoAudioExtractor.h"
#import "UI/TGExtraLocalization.h"

void TGExtraShowToast(NSString *text);

bool shouldFixFilePicker() {
	return [[NSUserDefaults standardUserDefaults] boolForKey:FILE_PICKER_FIX_KEY];
}

%hook LegacyMediaPickerDocumentViewController

- (id)initForOpeningContentTypes:(id)types  asCopy:(BOOL)copy {
	if (!shouldFixFilePicker()) {
		return %orig;
	}

	return %orig(types, YES);
}

- (id)initWithDocumentTypes:(id)types  inMode:(NSUInteger)mode {
	if (!shouldFixFilePicker()) {
		return %orig;
	}

	return %orig(types, 0); // Copy Mode
}

%end

static NSURL *TGExtraRelocatePickedFile(NSURL *url) {
    if (!url.isFileURL) return url;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:FILE_PICKER_PATH]];
    NSURL *directory = [root URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSError *error = nil;
    if (![manager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
        customLog(@"[TGExtra] Cannot create picker cache: %@", error);
        return url;
    }
    NSURL *destination = [directory URLByAppendingPathComponent:url.lastPathComponent];
    if ([manager moveItemAtURL:url toURL:destination error:&error]) return destination;
    [manager removeItemAtURL:directory error:NULL];
    customLog(@"[TGExtra] Cannot relocate picked file: %@", error);
    return url;
}

static void TGExtraPreparePickedFiles(NSArray<NSURL *> *urls, void (^completion)(NSArray<NSURL *> *)) {
    NSMutableArray<NSURL *> *scoped = [NSMutableArray new];
    for (NSURL *url in urls) if ([url startAccessingSecurityScopedResource]) [scoped addObject:url];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *prepared = [NSMutableArray new];
        NSMutableArray<NSURL *> *exports = [NSMutableArray new];
        @autoreleasepool {
            for (NSURL *url in urls) {
                NSURL *converted = TGExtraConvertAudioFile(url);
                if (!converted) {
                    TGExtraShowToast([TGExtraLocalization localizedStringForKey:@"AUDIO_TO_VOICE_FAILED"]);
                    for (NSURL *file in exports) [NSFileManager.defaultManager removeItemAtURL:file.URLByDeletingLastPathComponent error:NULL];
                    [prepared removeAllObjects];
                    break;
                }
                if (converted != url) [exports addObject:converted];
                [prepared addObject:shouldFixFilePicker() && converted == url ? TGExtraRelocatePickedFile(converted) : converted];
            }
        }
        for (NSURL *url in scoped) [url stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(prepared); });
    });
}

%hook LegacyMediaPickerUIICloudFileController

- (void)documentPicker:(id)picker didPickDocumentAtURL:(NSURL *)url {
    if (url && [NSUserDefaults.standardUserDefaults boolForKey:kAudioToVoice] && [TLParser audioFileVoiceChatSupported]) {
        void (*original)(id, SEL, id, NSURL *) = &%orig;
        TGExtraPreparePickedFiles(@[url], ^(NSArray<NSURL *> *prepared) {
            if (prepared.count) original(self, _cmd, picker, prepared.firstObject);
        });
        return;
    }
    if (!shouldFixFilePicker() || !url) {
        %orig;
        return;
    }
    %orig(picker, TGExtraRelocatePickedFile(url));
}

- (void)documentPicker:(id)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if ([NSUserDefaults.standardUserDefaults boolForKey:kAudioToVoice] && [TLParser audioFileVoiceChatSupported]) {
        void (*original)(id, SEL, id, NSArray *) = &%orig;
        TGExtraPreparePickedFiles(urls, ^(NSArray<NSURL *> *prepared) { original(self, _cmd, picker, prepared); });
        return;
    }
    if (!shouldFixFilePicker()) {
        %orig;
        return;
    }
    NSMutableArray<NSURL *> *relocated = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) [relocated addObject:TGExtraRelocatePickedFile(url)];
    %orig(picker, relocated);
}

%end

%hook NSURL

- (BOOL)startAccessingSecurityScopedResource {
	if (!shouldFixFilePicker()) {
		return %orig;
	}

    if ([self.path containsString:FILE_PICKER_PATH]) {
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:self.path]) {
            return YES;
        } else {
            return NO;
        }
    }
    return %orig;
}

%end

__attribute__((constructor))
static void initFileHooks() {
	if (![[NSUserDefaults standardUserDefaults] boolForKey:FILE_PICKER_FIX_KEY] &&
        ![[NSUserDefaults standardUserDefaults] boolForKey:kAudioToVoice]) {
		return;
	}

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),	^{

		unsigned int numClasses = 0;
		Class *classes = objc_copyClassList(&numClasses);
		if (!classes) return;

		Class DocumentPickerViewController = Nil;
		Class LegacyICloudFileController = Nil;

		for (unsigned int i = 0; i < numClasses; i++) {
			Class cls = classes[i];
			NSString *className = NSStringFromClass(cls);

			if ([className containsString:@"LegacyMediaPickerUI"]) {
				if ([className containsString:@"DocumentPickerViewController"]) {
					DocumentPickerViewController = cls;
				} else if ([className containsString:@"LegacyICloudFileController"]) {
					LegacyICloudFileController = cls;
				}
			}
		}

		free(classes);

		if (DocumentPickerViewController && LegacyICloudFileController) {
			%init(
				LegacyMediaPickerDocumentViewController = DocumentPickerViewController,
				LegacyMediaPickerUIICloudFileController = LegacyICloudFileController
			);
		} else {
			customLog(@"Failed to find required classes.");
		}
	});
}
