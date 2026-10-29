#import "../GhostExceptions.h"

static inline NSString *ghostExceptionDisplayName(NSDictionary *entry) {
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

