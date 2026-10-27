#import <TelegramApiObjC/TelegramApiObjC.h>
#import <TelegramApiObjC/TLSchema.h>
#import "../Sources/tgapiC/include/NativeTL.h"

extern TLObject *TGEFixtureRawConstructor(TLReader *, int32_t, uint16_t) NS_RETURNS_RETAINED;
extern id TGEFixtureRawResult(TLReader *, const TLFunctionInfo *) NS_RETURNS_RETAINED;
static _Atomic(uint64_t) parseCount;
void TGExtraNativeFixtureDidParse(void) { parseCount++; }
extern void *NativeTL_constructor(void *, int32_t, uint16_t);
extern void *NativeTL_result(void *, const void *);
// Production iPatch redirects roots only; recursive calls stay in the engine.
TLObject *TLParseConstructor(TLReader *reader, int32_t signature, uint16_t expected) {
    return TGEFixtureRawConstructor(reader, signature, expected);
}
id TLParseFunctionResult(TLReader *reader, const TLFunctionInfo *info) {
    return TGEFixtureRawResult(reader, info);
}
void TGExtraNativeFixtureEnable(void) {
    TGExtraNativeTestInstall((void *)TGEFixtureRawConstructor, (void *)TGEFixtureRawResult, nil);
}
uint64_t TGExtraNativeFixtureParseCount(void) { return parseCount; }
int64_t TGExtraNativeFixtureLiveCount(void) { return TLObjectLiveCount(); }
id TGExtraNativeFixtureDecode(NSData *data, NSString *account, int32_t function, NSData *request, BOOL patch) {
    id packet = patch ? TGExtraNativePacket(data, account, function, request) : nil;
    id previous = TGExtraNativeBegin(packet);
    TLReader reader = {data.bytes, data.length, 0};
    id object;
    @try {
        const TLFunctionInfo *info = NULL;
        if (function) for (uint32_t i = 0; i < TLApiSchemaTable()->functionCount; i++) {
            if (TLApiFunctionAt(i)->constructor.constructorId == (uint32_t)function) { info = TLApiFunctionAt(i); break; }
        }
        if (info) object = patch ? (id)NativeTL_result(&reader, info) : TGEFixtureRawResult(&reader, info);
        else if (data.length >= 4) {
            int32_t signature; memcpy(&signature, data.bytes, 4); reader.offset = 4;
            object = patch ? (id)NativeTL_constructor(&reader, signature, TLAnyTypeIndex) :
                TGEFixtureRawConstructor(&reader, signature, TLAnyTypeIndex);
        }
    } @finally { TGExtraNativeEnd(previous); }
    if (!object || reader.offset != data.length) { [object release]; return nil; }
    return object;
}
NSData *TGExtraNativeFixtureParse(NSData *data, NSString *account, int32_t function, NSData *request, BOOL patch) {
    id object = TGExtraNativeFixtureDecode(data, account, function, request, patch);
    if (!object) return nil;
    TLWriter writer = {0};
    if ([object isKindOfClass:NSArray.class]) {
        int32_t header[] = {481674261, (int32_t)[object count]};
        NSMutableData *result = [NSMutableData dataWithBytes:header length:8];
        for (TLObject *user in object) {
            TLSerialize(user, &writer, true);
            [result appendBytes:writer.bytes length:writer.length];
            writer.length = 0;
        }
        TLWriterFree(&writer); [object release]; return result;
    }
    TLSerialize(object, &writer, true);
    NSData *result = [NSData dataWithBytes:writer.bytes length:writer.length];
    TLWriterFree(&writer); [object release]; return result;
}
