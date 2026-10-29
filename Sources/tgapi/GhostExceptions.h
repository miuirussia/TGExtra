#import <Foundation/Foundation.h>

extern NSString *const kTGExtraGhostExceptionId;       // NSNumber (int64_t)
extern NSString *const kTGExtraGhostExceptionName;     // NSString, from the profile
extern NSString *const kTGExtraGhostExceptionUsername; // NSString, without "@"
extern NSString *const kTGExtraGhostExceptionCustom;   // NSString, user-supplied rename

extern NSString *const kTGExtraGhostExceptionsChangedNotification;

@interface TGExtraGhostExceptions : NSObject

+ (BOOL)containsPeerId:(int64_t)peerId;

+ (void)addPeerId:(int64_t)peerId
             name:(NSString *)name
         username:(NSString *)username;

+ (void)removePeerId:(int64_t)peerId;

+ (void)setCustomName:(NSString *)customName forPeerId:(int64_t)peerId;

+ (NSArray<NSDictionary *> *)all;

@end
