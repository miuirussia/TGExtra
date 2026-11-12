#!/usr/bin/env python3
"""Exercise the modern editor bridge, UIKit controls and native round descriptions."""
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
if sys.platform != 'darwin':
    print('SKIP modern video conversion: Mac Catalyst requires macOS')
    raise SystemExit(0)
sdk = Path(subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip())
frameworks = sdk / 'System/iOSSupport/System/Library/Frameworks'
if not (frameworks / 'UIKit.framework/Headers/UIKit.h').exists():
    print('SKIP modern video conversion: Mac Catalyst requires Xcode')
    raise SystemExit(0)

source = (ROOT / 'Sources/tgapi/VideoToRound.m').read_text()
builder = source[source.index('@interface NSObject (TGExtraRoundVideoAdjustments)'):source.index('NSDictionary *tgextraRewriteToRound')]
with tempfile.TemporaryDirectory(prefix='tgextra-modern-video-') as directory:
    work = Path(directory)
    header = work / 'Harness.h'
    header.write_text('#import <UIKit/UIKit.h>\n#import "VideoConversion.h"\n'
                      'NSDictionary *testRoundDescription(NSDictionary *dict, NSURL *url, double duration);\n')
    support = work / 'Harness.m'
    support.write_text(r'''
#import "Harness.h"
@interface TGVideoEditAdjustments : NSObject
@property NSDictionary *values;
+ (id)editAdjustmentsWithDictionary:(NSDictionary *)dictionary;
- (bool)sendAsTelescope;
@end
@implementation TGVideoEditAdjustments
+ (id)editAdjustmentsWithDictionary:(NSDictionary *)dictionary {
    TGVideoEditAdjustments *value = [self new]; value.values = dictionary; return value;
}
- (bool)sendAsTelescope { return [self.values[@"sendAsTelescope"] boolValue]; }
@end
''' + builder + '\nNSDictionary *testRoundDescription(NSDictionary *dict, NSURL *url, double duration) { return tgextraRoundVideoDescription(dict, url, duration); }\n')
    main = work / 'main.swift'
    main.write_text(r'''
import Foundation
import UIKit
import ObjectiveC
import tgapiC

let clipId = UUID().uuidString + String(repeating: "-video", count: 10)

@objc(TLParser) final class TLParser: NSObject {
    @objc static func roundVideoChatSupported() -> Bool { true }
}
final class MediaItem: NSObject {
    @objc let uniqueIdentifier: String
    init(_ id: String) { uniqueIdentifier = id }
}
final class Editing: NSObject {
    var values: [String: NSObject] = [:]
    @objc(adjustmentsForItem:) func adjustments(_ item: MediaItem) -> NSObject? { values[item.uniqueIdentifier] }
    @objc(setAdjustments:forItem:) func set(_ value: NSObject?, item: MediaItem) { values[item.uniqueIdentifier] = value }
}
final class Selection: NSObject {
    let ids = [clipId, "other"]
    @objc func selectedItemsIdentifiers() -> NSOrderedSet { NSOrderedSet(array: ids) }
}
struct Dimensions { let width: Int32 = 1920; let height: Int32 = 1080 }
struct Values {
    let originalDimensions = Dimensions()
    let videoTrimRange: Range<Double>? = 2.0..<5.5
    var sgSendAsTelescope = false
}
struct Entry { var values: Values?; var thumbnail: NSObject? = nil }
final class Store { var entries = [clipId: Entry(values: Values()), "other": Entry(values: Values())] }
final class Resolver {
    let selectionContext = Selection()
    let items: [String: NSObject] = ["other": MediaItem("other")]
    let lookup: (String) -> NSObject? = { MediaItem($0) }
}
final class Captions { let editingContext = Editing(); let resolver = Resolver() }
struct Item { let uniqueId: String }
final class Source { let items = [Item(uniqueId: clipId), Item(uniqueId: "other")] }
final class Page { let itemsSource = Source(); var currentIndex = 0 }
final class Editor { var values = Values() }
enum Subject { case video(String) }
func tap(_ button: UIButton) {
    for target in button.allTargets {
        guard let object = target.base as? NSObject else { continue }
        for action in button.actions(forTarget: object, forControlEvent: .touchUpInside) ?? [] {
            _ = object.perform(NSSelectorFromString(action))
        }
    }
}
final class TestButton: UIButton {
    override func sendActions(for controlEvents: UIControl.Event) { tap(self) }
}
final class Node: NSObject {
    let isGallery = true
    let pageModel = Page()
    let mediaEditor = Editor()
    let subject = Subject.video("test.mp4")
    let activeTool: String? = nil
    let isSending = false, isInvalidated = false, isInterfaceHiddenBySwipe = false, isEditingCaption = false
    let selectionCheckButton: UIView? = nil
    var sgTelescopeButton: UIButton? = TestButton(type: .custom)
    @objc func toggleNative() { mediaEditor.values.sgSendAsTelescope.toggle() }
}
typealias Send = (String, Bool, Int32?, @escaping () -> Void) -> Bool
struct Gallery { var send: Send }
final class Controller: NSObject {
    let captions = Captions()
    let store = Store()
    let gallery: Gallery?
    init(_ send: @escaping Send) { gallery = Gallery(send: send) }
}
let suite = "TGExtraModern-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
method_setImplementation(class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard))!, imp_implementationWithBlock({ (_: AnyObject) -> UserDefaults in defaults } as @convention(block) (AnyObject) -> UserDefaults))
defaults.set(true, forKey: "TGExtraVideoToVoice")
defaults.set(true, forKey: "TGExtraVideoToRound")
let root = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
let node = Node()
node.sgTelescopeButton!.addTarget(node, action: #selector(Node.toggleNative), for: .touchUpInside)
var checkSend: Send = { _, _, _, _ in true }
let owner = NSObject()
let controller = Controller { [owner] id, silent, time, complete in
    withExtendedLifetime(owner) { checkSend(id, silent, time, complete) }
}
precondition(ModernVideoConversion.show(on: controller, node: node, view: root))
let buttons = root.subviews.compactMap { $0 as? UIButton }
precondition(buttons.count == 2)
let voice = buttons.first { $0.accessibilityLabel == "VIDEO_TO_VOICE_TITLE" }!
let round = buttons.first { $0.accessibilityLabel == "VIDEO_TO_ROUND_TITLE" }!
precondition(!voice.isHidden && !round.isHidden && !voice.frame.intersects(round.frame))
precondition(voice.frame.width == 44 && round.frame.width == 44)
checkSend = { _, _, _, done in
    precondition(controller.store.entries.count == 2 && controller.captions.editingContext.values.isEmpty)
    done(); return true
}
precondition(controller.gallery!.send(clipId, false, nil, {}))
tap(voice)
precondition(voice.isSelected && !round.isSelected)
var pending: (() -> Void)?
checkSend = { id, silent, time, done in
    precondition(id == clipId && silent && time == 123)
    precondition(controller.store.entries[clipId] == nil && controller.store.entries["other"] != nil)
    let adjusted = controller.captions.editingContext.values[clipId]!
    let fields = adjusted.value(forKey: "values") as! [String: Any]
    precondition(fields["trimStart"] as? Double == 2 && fields["trimEnd"] as? Double == 5.5)
    pending = done; return true
}
precondition(controller.gallery!.send(clipId, true, 123, {}))
precondition(controller.store.entries[clipId] == nil, "Keep legacy classification until asynchronous send mapping completes")
pending?()
precondition(controller.store.entries[clipId]?.values?.videoTrimRange == 2.0..<5.5)
precondition(controller.captions.editingContext.values.isEmpty)
checkSend = { _, _, _, _ in false }
precondition(!controller.gallery!.send(clipId, false, nil, {}))
precondition(controller.store.entries.count == 2 && controller.captions.editingContext.values.isEmpty)
// A native round selection takes priority, even before the refresh timer fires.
node.toggleNative()
controller.store.entries[clipId]!.values!.sgSendAsTelescope = true
checkSend = { _, _, _, _ in precondition(controller.store.entries.count == 2); return true }
precondition(controller.gallery!.send(clipId, false, nil, {}))
precondition(node.mediaEditor.values.sgSendAsTelescope)
controller.store.entries[clipId]!.values!.sgSendAsTelescope = false
tap(voice)
precondition(!node.mediaEditor.values.sgSendAsTelescope && voice.isSelected)
tap(round)
precondition(round.isSelected && !voice.isSelected)
node.pageModel.currentIndex = 1
precondition(ModernVideoConversion.show(on: controller, node: node, view: root))
precondition(!round.isSelected && !voice.isSelected && root.subviews.count == 2)
for size in [CGSize(width: 320, height: 568), CGSize(width: 844, height: 390)] {
    root.frame.size = size
    precondition(ModernVideoConversion.show(on: controller, node: node, view: root))
    precondition(root.bounds.contains(round.frame) && root.bounds.contains(voice.frame))
}
precondition(!ModernVideoConversion.show(on: NSObject(), node: node, view: root))
precondition(HostValueWriter.replacing("entries", in: controller.store, with: 42) == nil)
let description = testRoundDescription(["type": "video", "asset": NSObject(), "groupedId": 12], URL(fileURLWithPath: "/tmp/round.mp4"), 3.5)!
precondition(description["type"] as? String == "video" && description["asset"] == nil && description["groupedId"] == nil)
let native = description["adjustments"] as! NSObject
let nativeFields = native.value(forKey: "values") as! [String: Any]
precondition(nativeFields["sendAsTelescope"] as? Bool == true && description["duration"] as? Double == 3.5)
ModernVideoConversion.hide(on: controller)
precondition(root.subviews.isEmpty)
defaults.removePersistentDomain(forName: suite)
print("PASS modern video conversion: actual runtime field types, native-mode priority, independent UIKit controls, per-item adapter routing, trim, async completion, failures and native round descriptions")
''')
    target = f'{platform.machine()}-apple-ios15.0-macabi'
    common = ['-target', target, '-isysroot', str(sdk), '-iframework', str(frameworks), '-fobjc-arc', '-Werror',
              '-DTGEXTRA_TESTING', '-I' + str(ROOT / 'Sources/tgapi'), '-I' + str(ROOT / 'Sources/tgapiC/include')]
    objects = []
    for index, source in enumerate([support, ROOT / 'Sources/tgapi/VoiceSelection.m', ROOT / 'Sources/tgapi/ModernVideoBridge.m']):
        output = work / f'{index}.o'
        subprocess.run(['xcrun', 'clang', *common, '-c', str(source), '-o', str(output)], check=True)
        objects.append(str(output))
    binary = work / 'modern-video'
    subprocess.run(['xcrun', 'swiftc', '-target', target, '-sdk', str(sdk), '-F', str(frameworks),
                    '-I' + str(ROOT / 'Sources/tgapiC/include'), '-import-objc-header', str(header),
                    str(ROOT / 'Sources/tgapi/HostValueReader.swift'), str(ROOT / 'Sources/tgapi/HostValueWriter.swift'),
                    str(ROOT / 'Sources/tgapi/ModernVideoConversion.swift'), str(main), *objects,
                    '-framework', 'UIKit', '-framework', 'Foundation', '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
