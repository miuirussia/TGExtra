#import <Foundation/Foundation.h>

// Per-peer opt-out from Ghost Mode.
//
// A peer on this list keeps seeing your real typing indicators and read
// receipts, while Ghost Mode stays in force for everyone else.
//
// Scope is deliberately limited to *user* peers. Two reasons:
//   1. account.updateStatus (online status) carries no peer at the protocol
//      level, so an "exception" there would broadcast your online state to
//      everybody — the exact opposite of what Ghost Mode is for.
//   2. Restricting to users keeps peer IDs unambiguous: TelegramCore's
//      CloudUser namespace is 0, so a user's client-side PeerId equals the raw
//      MTProto user_id. Channels pack a namespace into the high bits and would
//      need normalisation to match.
//
// Thread safety: containsPeerId: is called from -[MTRequest setPayload:...],
// which runs on the MTProto queue rather than the main thread. The backing set
// is cached in memory and every access goes through one lock, so the hot path
// never touches NSUserDefaults.

// Entry dictionary keys.
extern NSString *const kTGExtraGhostExceptionId;       // NSNumber (int64_t)
extern NSString *const kTGExtraGhostExceptionName;     // NSString, from the profile
extern NSString *const kTGExtraGhostExceptionUsername; // NSString, without "@"
extern NSString *const kTGExtraGhostExceptionCustom;   // NSString, user-supplied rename

// Posted on the main thread whenever the list changes.
extern NSString *const kTGExtraGhostExceptionsChangedNotification;

@interface TGExtraGhostExceptions : NSObject

+ (BOOL)containsPeerId:(int64_t)peerId;

+ (void)addPeerId:(int64_t)peerId
             name:(NSString *)name
         username:(NSString *)username;

+ (void)removePeerId:(int64_t)peerId;

// Passing nil or an empty string clears the rename and falls back to the
// profile name.
+ (void)setCustomName:(NSString *)customName forPeerId:(int64_t)peerId;

+ (NSArray<NSDictionary *> *)all;

@end
