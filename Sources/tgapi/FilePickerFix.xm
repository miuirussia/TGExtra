#import "Headers.h"

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

// Give each selection its own directory so equal file names cannot collide.
// A failed relocation leaves the host's original URL available to its handler.
static NSURL *TGExtraRelocatePickedFile(NSURL *url) {
    if (!url.isFileURL) return url;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:FILE_PICKER_PATH]];
    NSURL *directory = [root URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSError *error = nil;
    if (![manager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
        customLog2(@"[TGExtra] Cannot create picker cache: %@", error);
        return url;
    }
    NSURL *destination = [directory URLByAppendingPathComponent:url.lastPathComponent];
    if ([manager moveItemAtURL:url toURL:destination error:&error]) return destination;
    [manager removeItemAtURL:directory error:NULL];
    customLog2(@"[TGExtra] Cannot relocate picked file: %@", error);
    return url;
}

%hook LegacyMediaPickerUIICloudFileController

- (void)documentPicker:(id)picker didPickDocumentAtURL:(NSURL *)url {
    if (!shouldFixFilePicker() || !url) {
        %orig;
        return;
    }
    %orig(picker, TGExtraRelocatePickedFile(url));
}

- (void)documentPicker:(id)picker didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
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
	// Nothing to install when the fix is off, and the scan below walks every
	// class in the process — tens of thousands of them, holding the runtime
	// lock the main thread is also using while it loads classes during launch.
	if (![[NSUserDefaults standardUserDefaults] boolForKey:FILE_PICKER_FIX_KEY]) {
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
			customLog2(@"Failed to find required classes.");
		}
	});
}
