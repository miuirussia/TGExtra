#import "EmbeddedLangs.h"
#import "Headers.h"
#import <dlfcn.h>
#import <objc/runtime.h>

NSString *TGExtraBundlePath(void) {
  static NSString *cachedPath = nil;
  static dispatch_once_t token;
  dispatch_once(&token, ^{
    NSFileManager *fm = [NSFileManager defaultManager];

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

    NSString *jbPath = [NSString
        stringWithFormat:@"%@/TGExtra.bundle",
                         jbroot(@"/Library/Application Support/TGExtra")];
    if ([fm fileExistsAtPath:jbPath]) {
      cachedPath = jbPath;
      return;
    }

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

@interface TGExtraLocalization ()
@property(nonatomic, strong) NSDictionary *strings;
@property(nonatomic, copy, readwrite) NSString *languageCode;
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

static NSString *TGExtraLanguageMatchingDevice(void) {
  NSString *preferred = [NSLocale preferredLanguages].firstObject;
  if (preferred.length == 0) return nil;
  NSString *tag = [preferred lowercaseString];

  if ([tag hasPrefix:@"zh"]) {
    BOOL traditional = [tag containsString:@"hant"] || [tag containsString:@"tw"] ||
                       [tag containsString:@"hk"] || [tag containsString:@"mo"];
    return traditional ? @"tw" : @"cn";
  }

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
    [[NSUserDefaults standardUserDefaults] setObject:@"en"
                                              forKey:@"TGExtraLanguage"];
    lang = @"en";
    dict = GetAllTranslations(@"en");
  }

  self.languageCode = lang;
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

  NSString *result = [TGExtraLocalization shared].strings[key];
  if (result)
    return result;

  result = [[TGExtraLocalization shared].localization get:key];
  if (result && ![result isEqualToString:key])
    return result;

  static NSDictionary *sBuiltinEnglish = nil;
  static dispatch_once_t sOnce;
  dispatch_once(&sOnce, ^{
    sBuiltinEnglish = GetAllTranslations(@"en");
  });

  result = sBuiltinEnglish[key];
  return result ?: key;
}

@end
