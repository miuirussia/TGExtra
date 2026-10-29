#import "include/NativeTL.h"
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/loader.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#define TGE_FUNCTION(raw, type) ((type)ptrauth_sign_unauthenticated((raw), ptrauth_key_function_pointer, 0))
#else
#define TGE_FUNCTION(raw, type) ((type)(raw))
#endif

typedef struct {
    const char *name;
    uint8_t kind, elementKind, optional, boxed, bare;
    int8_t flagsIndex;
    uint8_t flagBit, presenceBit;
    uint16_t typeIndex, constructorIndex;
    uint32_t offset;
} TGEField;
typedef struct {
    const char *name;
    uint32_t signature;
    uint16_t typeIndex, caseIndex, fieldCount;
    uint32_t instanceSize;
    int32_t presentOffset;
    const TGEField *fields;
    void *state;
} TGEConstructor;
typedef struct { const uint8_t *bytes; size_t length, offset; } TGEReader;
typedef void *(*TGEParseConstructor)(TGEReader *, int32_t, uint16_t);
typedef void *(*TGEParseResult)(TGEReader *, const void *);
_Static_assert(sizeof(TGEField) == 24 && sizeof(TGEConstructor) == 48 && sizeof(TGEReader) == 24, "TLS1 v3 ABI");

static TGEParseConstructor originalConstructor;
static TGEParseResult originalResult;
static TGExtraNativeProcessor processPacket;
static NSData *knownIds, *interestingTypes;
static _Atomic(BOOL) enabled;
static Class nativeRootClass;
static NSString *const packetKey = @"TGExtra.NativeTL.packet";

@interface TGENativePacket : NSObject
@property NSData *data;
@property NSString *account;
@property NSData *request;
@property int32_t function;
@end
@implementation TGENativePacket
@end

static __thread NSUInteger parseDepth;
static __thread BOOL suppressCallbacks;

static const TGEConstructor *constructorOf(id object) {
    return *(const TGEConstructor **)((uint8_t *)(__bridge void *)object + 16);
}

@implementation TGExtraNativeObject {
    id _object;
}
- (instancetype)initWithObject:(id)object {
    Class root = nativeRootClass ?: objc_lookUpClass("TLObject");
    if (!root || object_getClass(object) != root || class_getInstanceSize(root) != 24) return nil;
    const TGEConstructor *info = constructorOf(object);
    if (!info || info->fieldCount > 256 || info->instanceSize < 24 ||
        (info->fieldCount && !info->fields)) return nil;
    if ((self = [super init])) _object = object;
    return self;
}
- (id)object { return _object; }
- (uint32_t)constructorId { return constructorOf(_object)->signature; }
- (uint16_t)typeIndex { return constructorOf(_object)->typeIndex; }
- (uint16_t)fieldCount { return constructorOf(_object)->fieldCount; }
- (const TGEField *)field:(NSInteger)index {
    const TGEConstructor *info = constructorOf(_object);
    if (index < 0 || index >= info->fieldCount) return NULL;
    const TGEField *field = &info->fields[index];
    size_t width = field->kind == 0 ? 4 : (field->kind == 2 ? 32 : 8);
    if (field->kind > 7 || field->offset < 24 || field->offset > info->instanceSize ||
        width > info->instanceSize - field->offset) return NULL;
    return field;
}
- (const void *)scalarAtIndex:(NSInteger)index {
    const TGEField *field = [self field:index];
    if (!field || field->kind > 3) return NULL;
    uint8_t *base = (__bridge void *)_object;
    const TGEConstructor *info = constructorOf(_object);
    if (field->optional) {
        if (info->presentOffset < 24 || info->presentOffset + 8 > info->instanceSize || field->presenceBit >= 64) return NULL;
        uint64_t present; memcpy(&present, base + info->presentOffset, 8);
        if (!(present & (UINT64_C(1) << field->presenceBit))) return NULL;
    }
    return base + field->offset;
}
- (id)valueAtIndex:(NSInteger)index {
    const TGEField *field = [self field:index];
    if (!field) return nil;
    uint8_t *base = (__bridge void *)_object;
    const TGEConstructor *info = constructorOf(_object);
    if (field->optional && field->kind <= 3) {
        if (info->presentOffset < 24 || info->presentOffset + 8 > info->instanceSize || field->presenceBit >= 64) return nil;
        uint64_t present; memcpy(&present, base + info->presentOffset, 8);
        if (!(present & (UINT64_C(1) << field->presenceBit))) return nil;
    }
    switch (field->kind) {
        case 0: { int32_t value; memcpy(&value, base + field->offset, 4); return @(value); }
        case 1: { int64_t value; memcpy(&value, base + field->offset, 8); return @(value); }
        case 2: return [NSData dataWithBytes:base + field->offset length:32];
        case 3: { double value; memcpy(&value, base + field->offset, 8); return @(value); }
        default: {
            __unsafe_unretained id value;
            memcpy(&value, base + field->offset, sizeof(value));
            return value;
        }
    }
}
- (BOOL)canSetValue:(id)value atIndex:(NSInteger)index {
    const TGEField *field = [self field:index];
    if (!field || (!value && !field->optional)) return NO;
    const TGEConstructor *info = constructorOf(_object);
    if (field->optional && field->kind <= 3 &&
        (info->presentOffset < 24 || info->presentOffset + 8 > info->instanceSize || field->presenceBit >= 64)) return NO;
    if (!value) return YES;
    switch (field->kind) {
        case 0: case 1: case 3: return [value isKindOfClass:NSNumber.class];
        case 2: return [value isKindOfClass:NSData.class] && [value length] == 32;
        case 4: return [value isKindOfClass:NSString.class];
        case 5: return [value isKindOfClass:NSData.class];
        case 6: return object_getClass(value) == nativeRootClass &&
            (field->typeIndex == UINT16_MAX || constructorOf(value)->typeIndex == field->typeIndex);
        case 7:
            if (field->elementKind <= 1) return [value isKindOfClass:NSData.class] && [value length] % (field->elementKind == 0 ? 4 : 8) == 0;
            if (![value isKindOfClass:NSArray.class]) return NO;
            for (id item in value) {
                if (field->elementKind == 6 && (object_getClass(item) != nativeRootClass ||
                    (field->typeIndex != UINT16_MAX && constructorOf(item)->typeIndex != field->typeIndex))) return NO;
                if (field->elementKind == 4 && ![item isKindOfClass:NSString.class]) return NO;
                if (field->elementKind == 5 && ![item isKindOfClass:NSData.class]) return NO;
            }
            return YES;
    }
    return NO;
}
- (BOOL)setValue:(id)value atIndex:(NSInteger)index {
    const TGEField *field = [self field:index];
    if (![self canSetValue:value atIndex:index]) return NO;
    const TGEConstructor *info = constructorOf(_object);
    uint8_t *base = (__bridge void *)_object;
    if (field->kind <= 3) {
        if (value && field->kind != 2 && ![value isKindOfClass:NSNumber.class]) return NO;
        if (field->kind == 2 && value && (![value isKindOfClass:NSData.class] || [value length] != 32)) return NO;
        if (field->optional) {
            if (info->presentOffset < 24 || info->presentOffset + 8 > info->instanceSize || field->presenceBit >= 64) return NO;
            uint64_t *present = (void *)(base + info->presentOffset);
            if (value) *present |= UINT64_C(1) << field->presenceBit;
            else *present &= ~(UINT64_C(1) << field->presenceBit);
        }
        if (field->kind == 0) { int32_t scalar = [value intValue]; memcpy(base + field->offset, &scalar, 4); }
        else if (field->kind == 1) { int64_t scalar = [value longLongValue]; memcpy(base + field->offset, &scalar, 8); }
        else if (field->kind == 2) { if (value) memcpy(base + field->offset, [value bytes], 32); else memset(base + field->offset, 0, 32); }
        else { double scalar = [value doubleValue]; memcpy(base + field->offset, &scalar, 8); }
    } else {
        void *previous;
        memcpy(&previous, base + field->offset, sizeof(previous));
        void *retained = (__bridge_retained void *)value;
        memcpy(base + field->offset, &retained, sizeof(retained));
        id releasing = (__bridge_transfer id)previous;
        (void)releasing;
    }
    return YES;
}
@end

BOOL TGExtraNativeReady(void) { return enabled; }

id TGExtraNativePacket(NSData *data, NSString *account, int32_t function, NSData *request) {
    if (!enabled || data.length < 4) return nil;
    int32_t signature; memcpy(&signature, data.bytes, 4);
    BOOL known = signature == 481674261;
    const uint32_t *ids = knownIds.bytes;
    NSUInteger low = 0, high = knownIds.length / 4;
    while (low < high) {
        NSUInteger mid = low + (high - low) / 2;
        if (ids[mid] < (uint32_t)signature) low = mid + 1; else high = mid;
    }
    if (low < knownIds.length / 4 && ids[low] == (uint32_t)signature) known = YES;
    if (!known) return nil;
    TGENativePacket *packet = [TGENativePacket new];
    packet.data = data; packet.account = account; packet.function = function; packet.request = request;
    return packet;
}
id TGExtraNativeBegin(id packet) {
    NSMutableDictionary *thread = NSThread.currentThread.threadDictionary;
    id previous = thread[packetKey];
    if (packet) thread[packetKey] = packet; else [thread removeObjectForKey:packetKey];
    return previous;
}
void TGExtraNativeEnd(id previous) { TGExtraNativeBegin(previous); }

static BOOL matches(TGENativePacket *packet, TGEReader *reader) {
    if (!packet || !reader || !reader->bytes || reader->offset > reader->length || reader->length != packet.data.length) return NO;
    return reader->bytes == packet.data.bytes || !memcmp(reader->bytes, packet.data.bytes, reader->length);
}
static void *parseNative(TGEReader *reader, int32_t signature, uint16_t expected, const void *functionInfo) {
    if (suppressCallbacks || !enabled) return functionInfo ? originalResult(reader, functionInfo) : originalConstructor(reader, signature, expected);
    TGENativePacket *packet = nil;
    BOOL root = parseDepth == 0;
    if (root) {
        packet = NSThread.currentThread.threadDictionary[packetKey];
        if (!matches(packet, reader)) packet = nil;
    }
    parseDepth++;
    void *value;
    @try {
        value = functionInfo ? originalResult(reader, functionInfo) : originalConstructor(reader, signature, expected);
    } @finally {
        parseDepth--;
        if (root) {
            if (packet) [NSThread.currentThread.threadDictionary removeObjectForKey:packetKey];
        }
    }
    if (!root || !packet) return value;
    [NSThread.currentThread.threadDictionary removeObjectForKey:packetKey];
    if (!value || reader->offset != reader->length) return value;
    id owning = (__bridge_transfer id)value;
    id result = processPacket(owning, packet.data, packet.account, packet.function, packet.request);
    return (__bridge_retained void *)(result ?: owning);
}

__attribute__((visibility("default")))
void *TGExtraNativeConstructorBridge(void *reader, int32_t signature, uint16_t expected, void *original) {
    if (!enabled) return TGE_FUNCTION(original, TGEParseConstructor)(reader, signature, expected);
    return parseNative(reader, signature, expected, NULL);
}
__attribute__((visibility("default")))
void *TGExtraNativeResultBridge(void *reader, const void *info, void *original) {
    if (!enabled) return TGE_FUNCTION(original, TGEParseResult)(reader, info);
    return parseNative(reader, 0, 0, info);
}

id TGExtraNativeCreate(NSData *wire) {
    if (!originalConstructor || wire.length < 4) return nil;
    int32_t signature; memcpy(&signature, wire.bytes, 4);
    TGEReader reader = {wire.bytes, wire.length, 4};
    BOOL previous = suppressCallbacks; suppressCallbacks = YES;
    void *result;
    @try { result = originalConstructor(&reader, signature, UINT16_MAX); }
    @finally { suppressCallbacks = previous; }
    id owning = (__bridge_transfer id)result;
    return reader.offset == reader.length ? owning : nil;
}

#import "NativeTLProfile.inc"

static BOOL configMatches(NSDictionary *config, NSData *uuid, uintptr_t constructor, uintptr_t result) {
    return [config[@"ABI"] integerValue] == 1 && [config[@"UUID"] isEqual:uuid] &&
        [config[@"constructor"] unsignedLongLongValue] == constructor &&
        [config[@"result"] unsignedLongLongValue] == result;
}

#ifdef TGEXTRA_TESTING
BOOL TGExtraNativeTestConfig(NSDictionary *config, NSData *uuid, uintptr_t constructor, uintptr_t result) {
    return configMatches(config, uuid, constructor, result);
}
void TGExtraNativeTestInstall(void *constructor, void *result, TGExtraNativeProcessor processor) {
    nativeRootClass = objc_lookUpClass("TLObject");
    originalConstructor = TGE_FUNCTION(constructor, TGEParseConstructor);
    originalResult = TGE_FUNCTION(result, TGEParseResult);
    if (processor) processPacket = [processor copy];
    enabled = processPacket && constructor && result;
}
#endif

static BOOL codeMatches(const uint32_t *code, const uint32_t pattern[][2], size_t count) {
    for (size_t i = 0; i < count; i++) if ((code[i] & pattern[i][1]) != pattern[i][0]) return NO;
    return YES;
}
static void *constructorHook(TGEReader *reader, int32_t signature, uint16_t expected) { return parseNative(reader, signature, expected, NULL); }
static void *resultHook(TGEReader *reader, const void *info) { return parseNative(reader, 0, 0, info); }

BOOL TGExtraNativeInstall(NSData *ids, NSData *types, TGExtraNativeProcessor processor) {
    knownIds = [ids copy]; interestingTypes = [types copy]; processPacket = [processor copy];
#ifdef TGEXTRA_TESTING
    return NO; // Tests install the real fixture engine explicitly.
#else
    Class root = nativeRootClass ?: objc_lookUpClass("TLObject");
    Ivar infoIvar = root ? class_getInstanceVariable(root, "_tl_info") : NULL;
    Dl_info image;
    if (!root || class_getInstanceSize(root) != 24 || !infoIvar || ivar_getOffset(infoIvar) != 16 ||
        !dladdr((__bridge void *)root, &image) || !image.dli_fbase) return NO;
    const struct mach_header_64 *header = image.dli_fbase;
    if (header->magic != MH_MAGIC_64 || header->sizeofcmds > 1024 * 1024) return NO;
    const uint8_t *command = (const void *)(header + 1), *end = command + header->sizeofcmds;
    const uint8_t *text = NULL; size_t textLength = 0; NSData *uuid;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if ((size_t)(end-command) < sizeof(struct load_command)) return NO;
        const struct load_command *load = (const void *)command;
        if (load->cmdsize < sizeof(*load) || load->cmdsize > (size_t)(end-command)) return NO;
        if (load->cmd == LC_UUID && load->cmdsize == sizeof(struct uuid_command)) {
            uuid = [NSData dataWithBytes:((const struct uuid_command *)load)->uuid length:16];
        }
        if (load->cmd == LC_SEGMENT_64 && load->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment = (const void *)load;
            if (!strncmp(segment->segname, "__TEXT", 16)) {
                const struct section_64 *sections = (const void *)(segment + 1);
                if (segment->nsects > (load->cmdsize - sizeof(*segment)) / sizeof(*sections)) return NO;
                for (uint32_t j = 0; j < segment->nsects; j++) if (!strncmp(sections[j].sectname, "__text", 16)) {
                    text = (const uint8_t *)image.dli_fbase + sections[j].offset;
                    textLength = (size_t)sections[j].size;
                }
            }
        }
        command += load->cmdsize;
    }
    if (!text || textLength < 1816 || textLength > 256 * 1024 * 1024) return NO;
    const uint8_t *constructor = NULL, *result = NULL;
    for (size_t offset = 0; offset + 1816 <= textLength; offset += 4) {
        const uint32_t *candidate = (const void *)(text + offset);
        if (candidate[0] != native_constructor[0][0] ||
            !codeMatches(candidate, native_constructor, sizeof(native_constructor)/sizeof(*native_constructor))) continue;
        if (!codeMatches((const void *)(text+offset+1704), native_result, sizeof(native_result)/sizeof(*native_result))) continue;
        if (!codeMatches((const void *)(text+offset+524), native_body, sizeof(native_body)/sizeof(*native_body))) continue;
        if (constructor) return NO;
        constructor = text + offset; result = constructor + 1704;
    }
    if (!constructor) return NO;
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"TGExtraNativeTL.plist"]];
    BOOL patched = configMatches(config, uuid, (uintptr_t)constructor - (uintptr_t)image.dli_fbase,
        (uintptr_t)result - (uintptr_t)image.dli_fbase);
    if (patched) {
        if (!dlsym(RTLD_DEFAULT, "TGExtraNativeConstructorBridge") || !dlsym(RTLD_DEFAULT, "TGExtraNativeResultBridge")) return NO;
        for (NSString *name in @[@"constructor", @"result"]) {
            NSUInteger count = 1;
            uintptr_t target = (uintptr_t)image.dli_fbase + [config[[@"bridge." stringByAppendingString:name]] unsignedLongLongValue];
            for (NSUInteger i = 0; i < count; i++) {
                NSNumber *at = config[[name stringByAppendingFormat:@"Call%lu", (unsigned long)i]];
                uintptr_t pc = (uintptr_t)image.dli_fbase + at.unsignedLongLongValue;
                if (!at || pc < (uintptr_t)text || pc + 4 > (uintptr_t)text + textLength) return NO;
                uint32_t word; memcpy(&word, (void *)pc, 4);
                int64_t delta = ((int64_t)(word & 0x3ffffff) << 38) >> 36;
                if ((word & 0x7c000000) != 0x14000000 || pc + delta != target) return NO;
            }
        }
        originalConstructor = TGE_FUNCTION((void *)constructor, TGEParseConstructor);
        originalResult = TGE_FUNCTION((void *)result, TGEParseResult);
    } else {
        void (*hook)(void *, void *, void **) = dlsym(RTLD_DEFAULT, "MSHookFunction");
        if (!hook) return NO;
        hook((void *)constructor, (void *)constructorHook, (void **)&originalConstructor);
        if (!originalConstructor) return NO;
        hook((void *)result, (void *)resultHook, (void **)&originalResult);
        if (!originalResult) return NO;
    }
    nativeRootClass = root;
    enabled = YES;
    return YES;
#endif
}

static NSData *nativeRules;
static uint16_t nativeUserType;
void TGExtraNativeSetRules(NSData *rules, uint16_t userType) { nativeRules = [rules copy]; nativeUserType = userType; }
static BOOL applyRules(id object, const uint32_t *rules, NSUInteger ruleCount, id privateUser, TGExtraNativeSettings settings) {
    const TGEConstructor *info = constructorOf(object);
    uint8_t *base = (__bridge void *)object;
    for (NSUInteger i = 0; i + 5 <= ruleCount * 5; i += 5) {
        if (rules[i] != info->signature || (settings & rules[i+2]) != rules[i+2]) continue;
        if (rules[i+2] == TGExtraNativeSettingsBypassForwarding && privateUser) continue;
        if (rules[i+2] == TGExtraNativeSettingsBypassPrivateCopy && object != privateUser) continue;
        uint16_t flagsIndex = rules[i+1] & 65535, valueIndex = rules[i+1] >> 16;
        if (flagsIndex >= info->fieldCount || info->fields[flagsIndex].kind != 0) return NO;
        uint32_t *flags = (void *)(base + info->fields[flagsIndex].offset);
        if (!(*flags & rules[i+3])) continue;
        *flags &= ~rules[i+3];
        if (rules[i+4]) {
            if (valueIndex >= info->fieldCount) return NO;
            const TGEField *field = &info->fields[valueIndex];
            if (field->kind <= 3) {
                if (info->presentOffset < 24 || field->presenceBit >= 64) return NO;
                *(uint64_t *)(base + info->presentOffset) &= ~(UINT64_C(1) << field->presenceBit);
            } else {
                void *previous;
                memcpy(&previous, base + field->offset, sizeof(previous));
                memset(base + field->offset, 0, sizeof(previous));
                id releasing = (__bridge_transfer id)previous;
                (void)releasing;
            }
        }
    }
    return YES;
}

typedef struct { uint32_t signature; uint64_t children; uint32_t firstRule, ruleCount; BOOL overflow; } TGEVisitPlan;
static NSData *visitTypeData;
static const uint32_t *visitOffsets;
static NSUInteger visitTypeCount, visitPlanCount;
static TGEVisitPlan *visitPlans;
static const uint32_t *compiledRules;

void TGExtraNativeSetTraversal(NSData *offsetData, NSData *planData) {
    visitTypeData = [offsetData copy]; visitOffsets = visitTypeData.bytes;
    visitTypeCount = visitTypeData.length / 4;
    visitPlanCount = planData.length / 16;
    free(visitPlans); visitPlans = calloc(visitPlanCount, sizeof(*visitPlans));
    const uint32_t *source = planData.bytes;
    compiledRules = nativeRules.bytes;
    for (NSUInteger i = 0; i < visitPlanCount; i++) {
        visitPlans[i].signature = source[i*4];
        visitPlans[i].children = source[i*4+1] | (uint64_t)source[i*4+2] << 32;
        visitPlans[i].overflow = source[i*4+3] != 0;
        for (NSUInteger rule = 0; rule < nativeRules.length / 20; rule++) if (compiledRules[rule*5] == source[i*4]) {
            if (!visitPlans[i].ruleCount) visitPlans[i].firstRule = (uint32_t)rule;
            visitPlans[i].ruleCount++;
        }
    }
}
static const TGEVisitPlan *visitPlan(const TGEConstructor *info) {
    if (!visitPlans || info->typeIndex + 1 >= visitTypeCount) return NULL;
    uint32_t first = visitOffsets[info->typeIndex], last = visitOffsets[info->typeIndex+1];
    if (info->caseIndex >= last-first || first + info->caseIndex >= visitPlanCount) return NULL;
    const TGEVisitPlan *plan = &visitPlans[first + info->caseIndex];
    return plan->signature == info->signature ? plan : NULL;
}
static id privateCopyUser(id root, TGExtraNativeSettings settings) {
    id privateUser;
    if ((settings & TGExtraNativeSettingsBypassPrivateCopy) && object_getClass(root) == nativeRootClass) {
        const TGEConstructor *info = constructorOf(root);
        if (!strcmp(info->name, "userFull")) {
            for (uint16_t i = 0; i < info->fieldCount; i++) {
                if (!strcmp(info->fields[i].name, "flags2")) privateUser = root;
                if (!strcmp(info->fields[i].name, "fullUser")) {
                    __unsafe_unretained id value;
                    memcpy(&value, (uint8_t *)(__bridge void *)root + info->fields[i].offset, sizeof(value));
                    privateUser = value;
                }
            }
        }
    }

    return privateUser;
}
static void visitObject(id object, NSMutableArray *objects, NSMutableArray *users, id privateUser,
                        TGExtraNativeSettings settings, BOOL apply, NSUInteger depth) {
    if (!object || depth >= 128 || object_getClass(object) != nativeRootClass) return;
    const TGEConstructor *info = constructorOf(object);
    const TGEVisitPlan *plan = visitPlan(info);
    if (!plan) return;
    const uint8_t *types = interestingTypes.bytes;
    if (info->typeIndex >= interestingTypes.length || !types[info->typeIndex]) return;
    if (apply) {
        if (plan->ruleCount) applyRules(object, compiledRules + plan->firstRule*5, plan->ruleCount, privateUser, settings);
        if (info->typeIndex == nativeUserType) [users addObject:object];
    } else if (types[info->typeIndex] & 1) [objects addObject:object];
    uint64_t children = plan->children;
    const uint8_t *base = (__bridge void *)object;
    for (uint16_t n = 0; n < info->fieldCount; n++) {
        uint16_t index;
        if (plan->overflow) index = n;
        else {
            if (!children) break;
            index = (uint16_t)__builtin_ctzll(children);
            children &= children - 1;
        }
        const TGEField *field = &info->fields[index];
        if (field->kind != 6 && !(field->kind == 7 && field->elementKind == 6)) continue;
        __unsafe_unretained id value;
        memcpy(&value, base + field->offset, sizeof(value));
        if (!value) continue;
        if (field->kind == 6) visitObject(value, objects, users, privateUser, settings, apply, depth + 1);
        else for (id child in value) visitObject(child, objects, users, privateUser, settings, apply, depth + 1);
    }
}
static NSArray *visitRoot(id root, BOOL apply, TGExtraNativeSettings settings) {
    NSMutableArray *objects = apply ? nil : [NSMutableArray new];
    NSMutableArray *users = apply ? [NSMutableArray new] : nil;
    id privateUser = apply ? privateCopyUser(root, settings) : nil;
    if (object_getClass(root) == nativeRootClass) visitObject(root, objects, users, privateUser, settings, apply, 0);
    else if ([root isKindOfClass:NSArray.class]) for (id child in root) visitObject(child, objects, users, privateUser, settings, apply, 0);
    return apply ? users : objects;
}
NSArray *TGExtraNativeObjects(id root) { return visitRoot(root, NO, 0); }
NSArray *TGExtraNativeApplyRoot(id root, TGExtraNativeSettings settings) { return visitRoot(root, YES, settings); }
