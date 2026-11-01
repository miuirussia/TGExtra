#import "../Headers.h"
#import "MessageBadges.h"
%ctor {
    TGExtraRestorePreferences();
    [TLParser loadPersistedIds];
    TGExtraStartMessageBadges();
}
