#import "EmbeddedLangs.h"
#import "Headers.h"
#import <dlfcn.h>
#import <objc/runtime.h>

// ============================================================
// TGExtraBundlePath() — shared function used by TGExtraLocalization
// and LanguageSelector to find TGExtra.bundle.
//
// Search order:
//  1. Next to the dylib via dladdr (covers Frameworks/ layout)
//  2. Parent of dylib directory (app bundle root)
//  3. Two levels up (some nested layouts)
//  4. Classic jailbreak path via jbroot()
//  5. NSBundle.mainBundle.bundlePath (IPA embed)
//  6. NSBundle.mainBundle.resourcePath (fallback)
// ============================================================
NSString *TGExtraBundlePath(void) {
  static NSString *cachedPath = nil;
  static dispatch_once_t token;
  dispatch_once(&token, ^{
    NSFileManager *fm = [NSFileManager defaultManager];

    // 1. Fallback to dylib-relative path (dladdr)
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (dladdr((const void *)TGExtraBundlePath, &info) && info.dli_fname) {
      NSString *dylibPath = [NSString stringWithUTF8String:info.dli_fname];
      NSString *dylibDir = [dylibPath stringByDeletingLastPathComponent];

      NSArray *candidates = @[
        [dylibDir stringByAppendingPathComponent:@"TGExtra.bundle"],
        [[dylibDir stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"TGExtra.bundle"],
        [[[dylibDir stringByDeletingLastPathComponent]
            stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"TGExtra.bundle"]
      ];

      for (NSString *c in candidates) {
        if ([fm fileExistsAtPath:c]) {
          cachedPath = c;
          return;
        }
      }
    }

    // 2. Classic jailbreak path
    NSString *jbPath = [NSString
        stringWithFormat:@"%@/TGExtra.bundle",
                         jbroot(@"/Library/Application Support/TGExtra")];
    if ([fm fileExistsAtPath:jbPath]) {
      cachedPath = jbPath;
      return;
    }

    // 3. Final desperate scan in the main bundle's subdirectories
    NSString *bundlePath = [NSBundle mainBundle].bundlePath;
    NSArray *subDirs = @[ @"TGExtra.bundle", @"Frameworks/TGExtra.bundle" ];
    for (NSString *sub in subDirs) {
      NSString *path = [bundlePath stringByAppendingPathComponent:sub];
      if ([fm fileExistsAtPath:path]) {
        cachedPath = path;
        return;
      }
    }
  });
  return cachedPath;
}

// Private interface to store our own strings dict
@interface TGExtraLocalization ()
@property(nonatomic, strong) NSDictionary *strings;
@end

@implementation TGExtraLocalization

+ (instancetype)shared {
  static TGExtraLocalization *instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    instance = [TGExtraLocalization new];
    [instance loadDefault];
  });
  return instance;
}

// Which of the ten languages TGExtra ships comes closest to what the device is set
// to, or nil when none does.
//
// This only ever decides the *initial* value. Once someone picks a language in
// the tweak it is written to TGExtraLanguage and this is never consulted again — an
// explicit choice outranks a guess, which is the whole point.
//
// It matters most for the one screen a user cannot come back to: the first-run
// alert that explains how to open the tweak at all. Defaulting that to English
// meant its translations were written for a screen nobody would ever see them
// on, since TGExtraLanguage is by definition unset the first time it appears.
static NSString *TGExtraLanguageMatchingDevice(void) {
  NSString *preferred = [NSLocale preferredLanguages].firstObject;
  if (preferred.length == 0) return nil;
  NSString *tag = [preferred lowercaseString];

  // Chinese first: the script matters more than the region, and the region is
  // not always there to read (zh-Hans, zh-Hant-TW, zh-HK).
  if ([tag hasPrefix:@"zh"]) {
    BOOL traditional = [tag containsString:@"hant"] || [tag containsString:@"tw"] ||
                       [tag containsString:@"hk"] || [tag containsString:@"mo"];
    return traditional ? @"tw" : @"cn";
  }

  // Everything else keys off the base subtag. TGExtra spells Vietnamese "vn", which
  // is not the ISO code the system reports.
  NSString *base = [tag componentsSeparatedByString:@"-"].firstObject;
  if ([base isEqualToString:@"vi"]) return @"vn";
  NSArray *shipped = @[ @"ar", @"ja", @"en", @"es", @"it", @"ru", @"fr" ];
  return [shipped containsObject:base] ? base : nil;
}

- (void)loadDefault {
  NSString *lang =
      [[NSUserDefaults standardUserDefaults] stringForKey:@"TGExtraLanguage"]
          ?: TGExtraLanguageMatchingDevice() ?: @"en";

  NSString *path = [[TGExtraBundlePath() stringByAppendingPathComponent:
      [lang stringByAppendingString:@".lproj"]] stringByAppendingPathComponent:@"Localizable.strings"];
  NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path] ?: GetAllTranslations(lang);
  if (!dict || dict.count == 0) {
    // Unknown language code — reset to English so next launch doesn't repeat
    [[NSUserDefaults standardUserDefaults] setObject:@"en"
                                              forKey:@"TGExtraLanguage"];
    lang = @"en";
    dict = GetAllTranslations(@"en");
  }

  self.strings = dict;

  if (dict && dict.count > 0) {
    self.localization =
        [[objc_getClass("TGLocalization") alloc] initWithVersion:96929692
                                                            code:lang
                                                            dict:dict
                                                        isActive:NO];
  }
}

+ (NSString *)localizedStringForKey:(NSString *)key {
  if (!key)
    return nil;

  // 1. Direct dict lookup from loaded bundle file — always most accurate
  NSString *result = [TGExtraLocalization shared].strings[key];
  if (result)
    return result;

  // 2. Fallback to TGLocalization wrapper
  result = [[TGExtraLocalization shared].localization get:key];
  if (result && ![result isEqualToString:key])
    return result;

  // 3. Hardcoded English fallback — guarantees readable UI even without a
  // bundle
  static NSDictionary *sBuiltinEnglish = nil;
  static dispatch_once_t sOnce;
  dispatch_once(&sOnce, ^{
    sBuiltinEnglish = GetAllTranslations(@"en");
  });

  result = sBuiltinEnglish[key];
  return result ?: key;
}

@end
