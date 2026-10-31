#!/usr/bin/env python3
"""Exercise the production conversion buttons and touch routing with real UIKit."""
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

if sys.platform != 'darwin':
    print('SKIP video preview: Mac Catalyst requires macOS')
    sys.exit(0)

ROOT = Path(__file__).resolve().parent.parent
sdk = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip())
frameworks = sdk / 'System/iOSSupport/System/Library/Frameworks'
if not (frameworks / 'UIKit.framework/Headers/UIKit.h').exists():
    print('SKIP video preview: set DEVELOPER_DIR to Xcode with Mac Catalyst')
    sys.exit(0)
source = (ROOT / 'Sources/tgapi/VideoConversionPreview.xm').read_text()
helpers = source[source.index('@interface TGMediaPickerGalleryInterfaceView'):source.index('%group')]
hooks = source[source.index('- (void)itemFocused:'):source.index('%end')]
hooks = hooks.replace('return %orig;', 'return [super hitTest:point withEvent:event];').replace('%orig;', '')
support = r'''
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "Constants.h"
#import "VoiceSelection.h"
static BOOL roundSupported = YES;
@interface TLParser : NSObject
+ (BOOL)roundVideoChatSupported;
@end
@implementation TLParser
+ (BOOL)roundVideoChatSupported { return roundSupported; }
@end
#define tgextraDiag(...) ((void)0)
static void TGExtraShowToast(NSString *text) {}
@interface TGExtraLocalization : NSObject
+ (NSString *)localizedStringForKey:(NSString *)key;
@end
@implementation TGExtraLocalization
+ (NSString *)localizedStringForKey:(NSString *)key { return key; }
@end
@interface TestVideoItem : NSObject
@property id editingContext;
@property NSString *uniqueIdentifier;
@end
@implementation TestVideoItem @end
@interface TestPhotoItem : TestVideoItem @end
@implementation TestPhotoItem @end
'''
tests = r'''
int main(void) { @autoreleasepool {
    NSString *suite = [@"TGExtraPreview-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    method_setImplementation(class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults)),
        imp_implementationWithBlock(^id(id cls) { return defaults; }));
    TestPreview *preview = [[TestPreview alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    TestVideoItem *item = [TestVideoItem new]; item.editingContext = [NSObject new]; item.uniqueIdentifier = @"clip";
    [preview itemFocused:item itemView:nil];
    NSCAssert(![preview viewWithTag:kTGExtraVoiceButtonTag] && ![preview viewWithTag:kTGExtraRoundButtonTag], @"Buttons default off");
    [defaults setBool:YES forKey:kVideoToRound];
    [preview layoutSubviews];
    UIButton *round = (id)[preview viewWithTag:kTGExtraRoundButtonTag];
    NSCAssert(round && !round.hidden && !round.selected, @"Show round button independently of voice");
    NSCAssert(round.frame.size.width >= 44 && [round.accessibilityLabel isEqual:@"VIDEO_TO_ROUND_TITLE"], @"Touch size and accessibility");
    [defaults setBool:YES forKey:kVideoToVoice];
    [preview layoutSubviews];
    UIButton *voice = (id)[preview viewWithTag:kTGExtraVoiceButtonTag];
    NSCAssert(!voice.hidden && CGRectGetMinY(round.frame) - CGRectGetMaxY(voice.frame) >= 8, @"Buttons do not overlap");
    NSCAssert([[round actionsForTarget:[TGExtraVoiceToggleTarget shared] forControlEvent:UIControlEventTouchUpInside] containsObject:@"handleRoundTap:"], @"Round action is wired");
    for (UIButton *button in @[voice, round]) {
        CGPoint point = [button convertPoint:CGPointMake(22, 22) toView:preview];
        NSCAssert([preview hitTest:point withEvent:nil] == button, @"Production touch routing reaches each button");
    }
    [[TGExtraVoiceToggleTarget shared] handleRoundTap:round]; [preview layoutSubviews];
    NSCAssert(round.selected && !voice.selected, @"Round tap selects round mode");
    [[TGExtraVoiceToggleTarget shared] handleTap:voice]; [preview layoutSubviews];
    NSCAssert(voice.selected && !round.selected, @"Voice tap clears round state immediately on layout");
    [[TGExtraVoiceToggleTarget shared] handleRoundTap:round]; [preview layoutSubviews];
    NSCAssert(round.selected && !voice.selected, @"Round tap clears voice state");
    roundSupported = NO;
    [preview layoutSubviews];
    NSCAssert(round.hidden && !voice.hidden && !tgextraVideoToRoundEnabled(), @"Secret chats hide round conversion without disabling voice conversion");
    roundSupported = YES;
    [preview layoutSubviews];
    NSCAssert(!round.hidden && round.selected, @"Cloud chats restore round conversion and retain their selection");
    TestVideoItem *second = [TestVideoItem new]; second.editingContext = item.editingContext; second.uniqueIdentifier = @"other";
    [preview itemFocused:second itemView:nil];
    NSCAssert(!round.selected && !voice.selected, @"Other clips start off");
    [preview itemFocused:item itemView:nil];
    NSCAssert(round.selected, @"Returning restores clip selection");
    TestPhotoItem *photo = [TestPhotoItem new]; photo.editingContext = item.editingContext; photo.uniqueIdentifier = @"photo";
    [preview itemFocused:photo itemView:nil];
    NSCAssert(round.hidden && voice.hidden, @"Photos hide controls even with a valid editing context");
    [preview itemFocused:[NSObject new] itemView:nil];
    NSCAssert(round.hidden && voice.hidden, @"Unsupported items hide controls");
    [preview itemFocused:item itemView:nil];
    [defaults setBool:NO forKey:kVideoToRound]; [preview layoutSubviews];
    NSCAssert(round.hidden && !voice.hidden, @"Feature settings hide each button independently");
    [defaults setBool:YES forKey:kVideoToRound];
    for (NSValue *size in @[[NSValue valueWithCGSize:CGSizeMake(320, 568)], [NSValue valueWithCGSize:CGSizeMake(844, 390)]]) {
        preview.frame = (CGRect){CGPointZero, size.CGSizeValue}; [preview layoutSubviews];
        NSCAssert(CGRectContainsRect(preview.bounds, round.frame) && CGRectContainsRect(preview.bounds, voice.frame) &&
                  !CGRectIntersectsRect(round.frame, voice.frame), @"Buttons fit small screens and landscape");
    }
    [defaults removePersistentDomainForName:suite];
    puts("PASS UIKit video preview: independent settings, per-clip state, mutually exclusive buttons, hit testing, accessibility and landscape");
} return 0; }
'''
with tempfile.TemporaryDirectory(prefix='tgextra-video-preview-') as tmp:
    path = Path(tmp)
    harness = path / 'preview.m'
    harness.write_text(support + helpers + '@interface TestPreview : UIView @end\n@implementation TestPreview\n' + hooks + '@end\n' + tests)
    binary = path / 'preview'
    subprocess.run(['xcrun', 'clang', '-target', f'{platform.machine()}-apple-ios15.0-macabi',
        '-isysroot', str(sdk), '-iframework', str(frameworks), '-fobjc-arc', '-Werror',
        '-Wno-deprecated-declarations', '-framework', 'UIKit', '-framework', 'Foundation',
        '-framework', 'QuartzCore', '-framework', 'CoreGraphics', '-I' + str(ROOT / 'Sources/tgapi'), str(harness),
        str(ROOT / 'Sources/tgapi/VoiceSelection.m'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
