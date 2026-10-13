#import "TestSupport.h"
#import "../../Sources/tgapi/Headers.h"
#import "../../Sources/tgapi/GhostExceptions.h"
#import <objc/runtime.h>

// Every test write stays in memory, including writes from Swift queues.
@interface MemoryDefaults : NSUserDefaults
@property NSMutableDictionary *values;
@end
@implementation MemoryDefaults
- (instancetype)init { if ((self = [super init])) _values = [NSMutableDictionary new]; return self; }
- (id)objectForKey:(NSString *)key { @synchronized(self) { return self.values[key]; } }
- (void)setObject:(id)value forKey:(NSString *)key { @synchronized(self) { self.values[key] = value; } }
- (void)removeObjectForKey:(NSString *)key { @synchronized(self) { [self.values removeObjectForKey:key]; } }
- (BOOL)boolForKey:(NSString *)key { return [[self objectForKey:key] boolValue]; }
- (NSInteger)integerForKey:(NSString *)key { return [[self objectForKey:key] integerValue]; }
- (NSString *)stringForKey:(NSString *)key { return [self objectForKey:key]; }
- (NSArray *)arrayForKey:(NSString *)key { return [self objectForKey:key]; }
- (NSDictionary *)dictionaryForKey:(NSString *)key { return [self objectForKey:key]; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setDouble:(double)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { [self setObject:@(value) forKey:key]; }
- (NSDictionary *)dictionaryRepresentation { @synchronized(self) { return self.values.copy; } }
@end

NSUserDefaults *TGExtraUseTestDefaults(void) {
    static MemoryDefaults *defaults;
    defaults = [MemoryDefaults new];
    Method method = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
    method_setImplementation(method, imp_implementationWithBlock(^id(id cls) { return defaults; }));
    return defaults;
}

@implementation MTRequest
- (void)setPayload:(NSData *)payload metadata:(id)metadata shortMetadata:(id)shortMetadata responseParser:(id (^)(NSData *))responseParser {
    _payload = payload; _metadata = metadata; _shortMetadata = shortMetadata; _responseParser = [responseParser copy];
}
@end
void customLog(NSString *format, ...) {}
void customLog2(NSString *format, ...) {}
extern void TGExtraMigrateDefaults(NSUserDefaults *defaults);

static NSData *typingPayload(int64_t user, int32_t action) {
    NSMutableData *data = [NSMutableData new];
    int32_t constructor = kMessagesSetTypingAction, flags = 0, peer = -571955892;
    int64_t hash = 42;
    [data appendBytes:&constructor length:4]; [data appendBytes:&flags length:4];
    [data appendBytes:&peer length:4]; [data appendBytes:&user length:8];
    [data appendBytes:&hash length:8]; [data appendBytes:&action length:4];
    return data;
}
void TGExtraTestHandlersAndMigration(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:YES forKey:kDisableTypingStatus];
    [defaults setBool:NO forKey:kDisableAllAds];
    [defaults setObject:@"ru" forKey:@"TGExtraLanguage"];
    [defaults setDouble:12.34 forKey:FAKE_LATITUDE_KEY];
    TGExtraMigrateDefaults(defaults);
    NSCAssert([defaults boolForKey:kGhostModeEnabled], @"Preserve existing ghost settings");
    NSCAssert(![defaults boolForKey:kDisableAllAds], @"Do not overwrite explicit ads setting");
    NSCAssert([[defaults stringForKey:@"TGExtraLanguage"] isEqual:@"ru"], @"Preserve language");
    TGExtraMigrateDefaults(defaults);
    NSCAssert([defaults boolForKey:kDisableTypingStatus], @"Migration is idempotent");
    MemoryDefaults *old = [MemoryDefaults new];
    [old setBool:YES forKey:kDisableOnlineStatus];
    TGExtraMigrateDefaults(old);
    NSCAssert([old boolForKey:kDisableAllAds], @"Migrate the shared ads key");
    [old setBool:NO forKey:kDisableAllAds];
    NSCAssert([old boolForKey:kDisableOnlineStatus], @"Ads and online status are independent");

    [TGExtraGhostExceptions addPeerId:123 name:@"Test" username:@"test"];
    MTRequest *request = [MTRequest new];
    handleSetTyping(request, typingPayload(123, kActionIDTyping));
    NSCAssert(!request.fakeData, @"An exception sees typing");
    handleSetTyping(request, typingPayload(456, kActionIDTyping));
    NSCAssert(request.fakeData, @"Other peers do not see typing");
    request.fakeData = nil;
    NSData *valid = typingPayload(456, kActionIDTyping);
    for (NSUInteger length = 0; length < valid.length; length++) {
        handleSetTyping(request, [valid subdataWithRange:NSMakeRange(0, length)]);
        NSCAssert(!request.fakeData, @"Truncated requests pass through");
    }
    [defaults setBool:NO forKey:kGhostModeEnabled];
    handleSetTyping(request, valid);
    NSCAssert(!request.fakeData, @"Master toggle disables filtering");
    [defaults setBool:YES forKey:kGhostModeEnabled];
    [defaults setBool:YES forKey:kDisableOnlineStatus];
    int32_t online[] = {kAccountUpdateOnlineStatus, (int32_t)0xbc799737};
    handleOnlineStatus(request, [NSData dataWithBytes:online length:sizeof(online)]);
    NSCAssert(request.fakeData, @"Online status remains hidden even with exceptions");
    request.fakeData = nil;
    [defaults setBool:YES forKey:kDisableScreenshotNotification];
    handleSendScreenshotNotification(request, valid);
    NSCAssert(request.fakeData.length > 4, @"Screenshot response is Updates, not Bool");
    [TGExtraGhostExceptions removePeerId:123];
    [defaults setBool:NO forKey:kDisableScreenshotNotification];
    NSLog(@"PASS defaults migration, ghost exceptions and request handlers");
}
