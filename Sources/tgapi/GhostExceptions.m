#import "GhostExceptions.h"
#import "Constants.h"

NSString *const kTGExtraGhostExceptionId = @"id";
NSString *const kTGExtraGhostExceptionName = @"name";
NSString *const kTGExtraGhostExceptionUsername = @"username";
NSString *const kTGExtraGhostExceptionCustom = @"customName";

NSString *const kTGExtraGhostExceptionsChangedNotification =
    @"TGExtraGhostExceptionsChanged";

BOOL TGExtraIsGhostException(int64_t userId) {
  return userId > 0 && [TGExtraGhostExceptions containsPeerId:userId];
}

@implementation TGExtraGhostExceptions

// One lock guards both caches. Contention is negligible: reads only happen for
// requests that already passed the Ghost Mode gate, and writes only happen when
// the user taps something.
static NSObject *sLock = nil;
static NSMutableArray<NSDictionary *> *sEntries = nil;
static NSSet<NSNumber *> *sIdCache = nil;

+ (void)initialize {
  if (self == [TGExtraGhostExceptions class]) {
    sLock = [NSObject new];
  }
}

// Must be called with sLock held.
static void loadIfNeeded(void) {
  if (sEntries)
    return;

  NSArray *stored =
      [[NSUserDefaults standardUserDefaults] arrayForKey:kGhostExceptions];
  sEntries = [NSMutableArray array];

  for (id entry in stored) {
    // Defensive: a malformed defaults value must not take the tweak down.
    if (![entry isKindOfClass:[NSDictionary class]])
      continue;
    NSNumber *peerId = entry[kTGExtraGhostExceptionId];
    if (![peerId isKindOfClass:[NSNumber class]])
      continue;
    [sEntries addObject:entry];
  }

  NSMutableSet *ids = [NSMutableSet set];
  for (NSDictionary *entry in sEntries) {
    [ids addObject:entry[kTGExtraGhostExceptionId]];
  }
  sIdCache = ids;
}

// Must be called with sLock held.
static void persist(void) {
  NSMutableSet *ids = [NSMutableSet set];
  for (NSDictionary *entry in sEntries) {
    [ids addObject:entry[kTGExtraGhostExceptionId]];
  }
  sIdCache = ids;

  [[NSUserDefaults standardUserDefaults] setObject:[sEntries copy]
                                            forKey:kGhostExceptions];
  TGExtraSavePreferences();

  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kTGExtraGhostExceptionsChangedNotification
                      object:nil];
  });
}

// Must be called with sLock held. Returns NSNotFound when absent.
static NSUInteger indexOfPeerId(int64_t peerId) {
  for (NSUInteger i = 0; i < sEntries.count; i++) {
    if ([sEntries[i][kTGExtraGhostExceptionId] longLongValue] == peerId) {
      return i;
    }
  }
  return NSNotFound;
}

+ (BOOL)containsPeerId:(int64_t)peerId {
  if (peerId == 0)
    return NO;
  @synchronized(sLock) {
    loadIfNeeded();
    return [sIdCache containsObject:@(peerId)];
  }
}

+ (void)addPeerId:(int64_t)peerId
             name:(NSString *)name
         username:(NSString *)username {
  if (peerId == 0)
    return;

  @synchronized(sLock) {
    loadIfNeeded();

    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[kTGExtraGhostExceptionId] = @(peerId);
    if (name.length)
      entry[kTGExtraGhostExceptionName] = name;
    if (username.length)
      entry[kTGExtraGhostExceptionUsername] = username;

    NSUInteger existing = indexOfPeerId(peerId);
    if (existing != NSNotFound) {
      // Re-adding refreshes name/username but keeps any manual rename.
      NSString *custom = sEntries[existing][kTGExtraGhostExceptionCustom];
      if (custom.length)
        entry[kTGExtraGhostExceptionCustom] = custom;
      sEntries[existing] = entry;
    } else {
      [sEntries addObject:entry];
    }

    persist();
  }
}

+ (void)removePeerId:(int64_t)peerId {
  @synchronized(sLock) {
    loadIfNeeded();
    NSUInteger index = indexOfPeerId(peerId);
    if (index == NSNotFound)
      return;
    [sEntries removeObjectAtIndex:index];
    persist();
  }
}

+ (void)setCustomName:(NSString *)customName forPeerId:(int64_t)peerId {
  @synchronized(sLock) {
    loadIfNeeded();
    NSUInteger index = indexOfPeerId(peerId);
    if (index == NSNotFound)
      return;

    NSMutableDictionary *entry = [sEntries[index] mutableCopy];
    NSString *trimmed = [customName
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
    if (trimmed.length) {
      entry[kTGExtraGhostExceptionCustom] = trimmed;
    } else {
      [entry removeObjectForKey:kTGExtraGhostExceptionCustom];
    }

    sEntries[index] = entry;
    persist();
  }
}

+ (NSArray<NSDictionary *> *)all {
  @synchronized(sLock) {
    loadIfNeeded();
    return [sEntries copy];
  }
}

+ (NSString *)displayNameForEntry:(NSDictionary *)entry {
  NSString *custom = entry[kTGExtraGhostExceptionCustom];
  if (custom.length)
    return custom;

  NSString *name = entry[kTGExtraGhostExceptionName];
  if (name.length)
    return name;

  NSString *username = entry[kTGExtraGhostExceptionUsername];
  if (username.length)
    return [@"@" stringByAppendingString:username];

  return [NSString
      stringWithFormat:@"ID %@", entry[kTGExtraGhostExceptionId] ?: @"?"];
}

@end
