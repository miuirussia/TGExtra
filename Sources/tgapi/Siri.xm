#import <Foundation/Foundation.h>
#import <Intents/Intents.h>

%hook INPreferences
- (long long)_siriAuthorizationStatus {
  return 2;
}
%end
