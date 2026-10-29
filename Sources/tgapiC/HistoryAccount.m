#import "include/Tweak.h"

NSString *TGExtraHistoryAccountForPath(NSString *path) {
    if (![path isKindOfClass:NSString.class]) return nil;
    for (NSString *component in path.pathComponents.reverseObjectEnumerator) {
        if (![component hasPrefix:@"account-"]) continue;
        NSString *identifier = [component substringFromIndex:8];
        if (identifier.length == 0 ||
            [identifier rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return nil;
        return component;
    }
    return nil;
}

NSString *TGExtraHistoryAccountForMTProto(id mtProto) {
    @try {
        id usage = [mtProto valueForKey:@"usageCalculationInfo"];
        return TGExtraHistoryAccountForPath([usage valueForKey:@"filePath"]);
    } @catch (NSException *exception) {
        return nil;
    }
}

NSString *TGExtraHistoryAccountForRequestService(id service) {
    @try {
        return TGExtraHistoryAccountForMTProto([service valueForKey:@"mtProto"]);
    } @catch (NSException *exception) {
        return nil;
    }
}

static NSMapTable *historyRequestServices(void) {
    static NSMapTable *services;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ services = [NSMapTable weakToWeakObjectsMapTable]; });
    return services;
}

void TGExtraSetHistoryRequestService(id request, id service) {
    if (!request) return;
    NSMapTable *services = historyRequestServices();
    @synchronized(services) {
        if (service) [services setObject:service forKey:request];
        else [services removeObjectForKey:request];
    }
}

NSString *TGExtraHistoryAccountForRequest(id request) {
    if (!request) return nil;
    NSMapTable *services = historyRequestServices();
    id service;
    @synchronized(services) { service = [services objectForKey:request]; }
    return TGExtraHistoryAccountForRequestService(service);
}
