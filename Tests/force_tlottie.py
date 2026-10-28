#!/usr/bin/env python3
"""Run the production hook through Swift's RLottieInstance protocol witness."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
HEADER = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
NS_ASSUME_NONNULL_BEGIN
@interface RLottieInstance : NSObject
@property (nonatomic, readonly) int32_t frameCount;
@property (nonatomic, readonly) int32_t frameRate;
@property (nonatomic, readonly) double duration;
@property (nonatomic, readonly) CGSize dimensions;
- (nullable instancetype)initWithData:(NSData *)data fitzModifier:(int32_t)modifier
    colorReplacements:(nullable NSDictionary *)colors cacheKey:(NSString *)cacheKey;
- (void)renderFrameWithIndex:(int32_t)index into:(uint8_t *)buffer
    width:(int32_t)width height:(int32_t)height bytesPerRow:(int32_t)stride;
@end
void TestSetup(void);
void TestSetEnabled(BOOL enabled);
BOOL TestEnabled(void);
NSUInteger TestOriginalCalls(void);
NSUInteger TestTLottieCalls(void);
NSUInteger TestLiveInstances(void);
NSData *TestLastData(void);
NSDictionary * _Nullable TestLastColors(void);
NSString * _Nullable TestLastCacheKey(void);
NS_ASSUME_NONNULL_END
'''
HOST = r'''
#import "Host.h"
#import "Constants.h"
#import <objc/runtime.h>
static NSUInteger originalCalls, tlottieCalls, liveInstances;
static NSData *lastData;
static NSDictionary *lastColors;
static NSString *lastCacheKey;
@interface TestDefaults : NSUserDefaults
@property BOOL forceTLottie;
@end
@implementation TestDefaults
- (BOOL)boolForKey:(NSString *)key { return self.forceTLottie; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { self.forceTLottie = value; }
@end
static NSUserDefaults *testDefaults;
void TestSetup(void) {
    testDefaults = [TestDefaults new];
    Method getter = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
    method_setImplementation(getter, imp_implementationWithBlock(^id(id cls) { return testDefaults; }));
}
void TestSetEnabled(BOOL enabled) { [testDefaults setBool:enabled forKey:kForceTLottie]; }
BOOL TestEnabled(void) { return [testDefaults boolForKey:kForceTLottie]; }
NSUInteger TestOriginalCalls(void) { return originalCalls; }
NSUInteger TestTLottieCalls(void) { return tlottieCalls; }
NSUInteger TestLiveInstances(void) { return liveInstances; }
NSData *TestLastData(void) { return lastData; }
NSDictionary *TestLastColors(void) { return lastColors; }
NSString *TestLastCacheKey(void) { return lastCacheKey; }
@implementation RLottieInstance
+ (id)allocWithZone:(NSZone *)zone {
    id instance = [super allocWithZone:zone];
    if (instance) liveInstances++;
    return instance;
}
- (instancetype)initWithData:(NSData *)data fitzModifier:(int32_t)modifier
    colorReplacements:(NSDictionary *)colors cacheKey:(NSString *)cacheKey {
    if ((self = [super init])) {
        originalCalls++;
        lastData = data; lastColors = colors; lastCacheKey = cacheKey;
        if (!data.length) return nil;
    }
    return self;
}
- (int32_t)frameCount { return 30; }
- (int32_t)frameRate { return 30; }
- (double)duration { return 1.0; }
- (CGSize)dimensions { return CGSizeMake(32, 32); }
- (void)renderFrameWithIndex:(int32_t)index into:(uint8_t *)buffer
    width:(int32_t)width height:(int32_t)height bytesPerRow:(int32_t)stride {
    NSCAssert(width == 2 && height == 1 && stride == 12, @"Preserve render arguments and padding");
    buffer[0] = 0x11; buffer[1] = index;
}
- (void)dealloc { liveInstances--; }
@end
#ifdef MISSING_TLOTTIE
#define TLottieAnimation UnavailableTLottieAnimation
#endif
#ifdef INCOMPATIBLE_TLOTTIE
typedef double TestFitzModifier;
#else
typedef int32_t TestFitzModifier;
#endif
@interface TLottieAnimation : NSObject
@property int32_t modifier;
@end
@implementation TLottieAnimation
+ (id)allocWithZone:(NSZone *)zone {
    id instance = [super allocWithZone:zone];
    if (instance) liveInstances++;
    return instance;
}
- (instancetype)initWithData:(NSData *)data fitzModifier:(TestFitzModifier)modifier
    colorReplacements:(NSDictionary *)colors {
    if ((self = [super init])) {
        tlottieCalls++;
        lastData = data; lastColors = colors; lastCacheKey = nil;
        self.modifier = modifier;
        if (!data.length) return nil;
    }
    return self;
}
- (int32_t)frameCount { return self.modifier + 1; }
- (int32_t)frameRate { return 60; }
- (double)duration { return 1.5; }
- (CGSize)dimensions { return CGSizeMake(128, 64); }
- (void)renderFrameWithIndex:(int32_t)index into:(uint8_t *)buffer
    width:(int32_t)width height:(int32_t)height bytesPerRow:(int32_t)stride {
    NSCAssert(width == 2 && height == 1 && stride == 12, @"Preserve render arguments and padding");
    buffer[0] = 0xAB; buffer[1] = index;
}
- (void)dealloc { liveInstances--; }
@end
'''
SWIFT = r'''
import Foundation
import CoreGraphics
protocol HostLottie: AnyObject {
    var frameCount: Int32 { get }
    var frameRate: Int32 { get }
    var duration: Double { get }
    var dimensions: CGSize { get }
    func renderFrame(with index: Int32, into buffer: UnsafeMutablePointer<UInt8>,
                     width: Int32, height: Int32, bytesPerRow: Int32)
}
extension RLottieInstance: HostLottie {}
TestSetup()
precondition(!TestEnabled(), "Fresh installs must leave the renderer choice unchanged")
let supported = CommandLine.arguments[1] == "supported"
let data = Data([1, 2, 3])
let colors: [AnyHashable: Any] = [NSNumber(value: 0xFF000000): NSNumber(value: 0xFFFFFFFF)]
for enabled in [false, true, false] {
    TestSetEnabled(enabled)
    autoreleasepool {
        let instance = RLottieInstance(data: data, fitzModifier: 5,
                                      colorReplacements: colors, cacheKey: "cache-key")!
        // This is the client's statically selected RLottieInstance witness,
        // even when the Objective-C initializer returns a TLottieAnimation.
        let renderer: any HostLottie = instance
        let forced = supported && enabled
        precondition(renderer.frameCount == (forced ? 6 : 30), "Preserve Fitz modifier")
        precondition(renderer.frameRate == (forced ? 60 : 30))
        precondition(renderer.duration == (forced ? 1.5 : 1.0))
        precondition(renderer.dimensions == (forced ? CGSize(width: 128, height: 64) : CGSize(width: 32, height: 32)))
        precondition(TestLastData() == data)
        precondition((TestLastColors()! as NSDictionary).isEqual(to: colors))
        precondition(TestLastCacheKey() == (forced ? nil : "cache-key"))
        var buffer = [UInt8](repeating: 0xCC, count: 12)
        buffer.withUnsafeMutableBufferPointer {
            renderer.renderFrame(with: 4, into: $0.baseAddress!, width: 2, height: 1, bytesPerRow: 12)
        }
        precondition(buffer[0] == (forced ? 0xAB : 0x11) && buffer[1] == 4)
        precondition(buffer[8...] == [0xCC, 0xCC, 0xCC, 0xCC])
    }
    precondition(TestLiveInstances() == 0, "Release the original receiver and replacement exactly once")
}
precondition(TestOriginalCalls() == (supported ? 2 : 3))
precondition(TestTLottieCalls() == (supported ? 1 : 0))
for enabled in [true, false] {
    TestSetEnabled(enabled)
    autoreleasepool {
        precondition(RLottieInstance(data: Data(), fitzModifier: 0, colorReplacements: nil, cacheKey: "") == nil)
        precondition(RLottieInstance(data: data, fitzModifier: 0, colorReplacements: nil, cacheKey: "") != nil)
        precondition(TestLastColors() == nil)
    }
    precondition(TestLiveInstances() == 0)
}
print("PASS forced tlottie: \(CommandLine.arguments[1]), Swift witnesses, arguments, off/on/off, parse failure and ARC lifetime")
'''

with tempfile.TemporaryDirectory(prefix='tgextra-tlottie-') as tmp:
    work = Path(tmp)
    (work / 'Host.h').write_text(HEADER)
    (work / 'Host.m').write_text(HOST)
    (work / 'main.swift').write_text(SWIFT)
    hook = work / 'hook.o'
    subprocess.run(['clang', '-fobjc-arc', '-Werror', '-c',
                    str(ROOT / 'Sources/tgapi/ForceTLottie.m'), '-o', str(hook)], check=True)
    for mode, flags in [('supported', []), ('missing', ['-DMISSING_TLOTTIE']),
                        ('incompatible', ['-DINCOMPATIBLE_TLOTTIE'])]:
        host = work / 'host.o'
        subprocess.run(['clang', '-fobjc-arc', '-Werror', *flags,
                        '-I' + str(ROOT / 'Sources/tgapi'), '-c', str(work / 'Host.m'),
                        '-o', str(host)], check=True)
        binary = work / mode
        subprocess.run(['swiftc', '-O', '-import-objc-header', str(work / 'Host.h'),
                        str(work / 'main.swift'), str(host), str(hook), '-o', str(binary)], check=True)
        subprocess.run([str(binary), mode], check=True)
