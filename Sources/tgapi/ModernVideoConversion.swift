#if canImport(UIKit)
import Foundation
import UIKit
import Photos
import tgapiC

private typealias ModernVideoSend = (String, Bool, Int32?, @escaping () -> Void) -> Bool
private var modernVideoStateKey: UInt8 = 0

private final class ModernSendCapture {
    let call: ModernVideoSend
    init(_ call: @escaping ModernVideoSend) { self.call = call }
}
private final class ModernCompletionCapture {
    let call: () -> Void
    init(_ call: @escaping () -> Void) { self.call = call }
}
private final class ModernNativeCompletion {
    let function: UnsafeRawPointer
    let context: UnsafeMutableRawPointer?
    init(function: UnsafeRawPointer, context: UnsafeMutableRawPointer?) {
        self.function = function; self.context = context
        TGExtraRetainModernVideoContext(context)
    }
    deinit { TGExtraReleaseModernVideoContext(context) }
    func call() { TGExtraInvokeModernVideoCompletion(function, context) }
}
@_cdecl("TGExtraModernVideoSend")
func modernVideoSend(_ context: UnsafeMutableRawPointer, _ identifier: UnsafeRawPointer, _ silent: Bool,
                             _ time: UInt64, _ completion: UnsafeRawPointer, _ completionContext: UnsafeMutableRawPointer?) -> Bool {
    let capture = Unmanaged<ModernSendCapture>.fromOpaque(context).takeUnretainedValue()
    let done = ModernNativeCompletion(function: completion, context: completionContext)
    let id = identifier.assumingMemoryBound(to: String.self).pointee
    return capture.call(id, silent, time & (1 << 32) == 0 ? Int32(bitPattern: UInt32(truncatingIfNeeded: time)) : nil, { done.call() })
}
@_cdecl("TGExtraModernVideoCompleted")
func modernVideoCompleted(_ context: UnsafeMutableRawPointer) {
    Unmanaged<ModernCompletionCapture>.fromOpaque(context).takeUnretainedValue().call()
}

private struct ModernNativeFunction {
    let owner: Any
    func withWords<R>(_ body: (UnsafeRawPointer, UnsafeMutableRawPointer?) -> R) -> R {
        withUnsafeBytes(of: owner) {
            body($0.load(as: UnsafeRawPointer.self), $0.load(fromByteOffset: MemoryLayout<UInt>.size, as: UnsafeMutableRawPointer?.self))
        }
    }
    func send(_ id: String, _ silent: Bool, _ time: Int32?, _ complete: @escaping () -> Void) -> Bool {
        let capture = ModernCompletionCapture(complete)
        return withExtendedLifetime(capture) {
            withUnsafePointer(to: id) { pointer in
                withWords { TGExtraInvokeModernVideoSend($0, $1, pointer, silent,
                    time.map { UInt64(UInt32(bitPattern: $0)) } ?? (1 << 32), Unmanaged.passUnretained(capture).toOpaque()) }
            }
        }
    }
    func lookup(_ id: String) -> NSObject? {
        withUnsafePointer(to: id) { pointer in withWords { TGExtraInvokeModernVideoLookup($0, $1, pointer) as? NSObject } }
    }
    func asset(_ index: Int) -> PHAsset? { withWords { TGExtraInvokeModernVideoAsset($0, $1, index) as? PHAsset } }
}

private func videoField(_ name: String, _ value: Any) -> Any? {
    guard let stored = HostValueReader.storedField(name, in: value) else { return nil }
    let mirror = Mirror(reflecting: stored)
    return mirror.displayStyle == .optional ? mirror.children.first?.value : stored
}

private final class ModernVideoItem: NSObject {
    @objc let editingContext: NSObject
    @objc let uniqueIdentifier: String
    init(context: NSObject, identifier: String) {
        editingContext = context
        uniqueIdentifier = identifier
    }
}

@objc(TGExtraModernVideoConversion)
final class ModernVideoConversion: NSObject {
    private weak var controller: NSObject?
    private weak var node: AnyObject?
    private weak var root: UIView?
    private let context: NSObject
    private let resolver: Any
    private let store: AnyObject
    private let originalSend: ModernNativeFunction
    private var timer: Timer?
    private var restorePending: (() -> Void)?
    private var generation = 0
    private let voice = UIButton(type: .custom)
    private let round = UIButton(type: .custom)

    private init(controller: NSObject, node: AnyObject, context: NSObject, resolver: Any,
                 store: AnyObject, send: ModernNativeFunction) {
        self.controller = controller; self.node = node
        self.context = context; self.resolver = resolver; self.store = store; originalSend = send
        super.init()
        for (button, symbol, action, key) in [(voice, "waveform", #selector(voicePressed), "VIDEO_TO_VOICE_TITLE"),
                                             (round, "video.circle", #selector(roundPressed), "VIDEO_TO_ROUND_TITLE")] {
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.tintColor = .white
            button.layer.cornerRadius = 22
            button.accessibilityLabel = TGExtraModernVideoString(key)
            button.addTarget(self, action: action, for: .touchUpInside)
        }
    }

    @objc static func show(on controller: NSObject, node: AnyObject, view: UIView) -> Bool {
        if let state = objc_getAssociatedObject(controller, &modernVideoStateKey) as? ModernVideoConversion {
            state.attach(view)
            return true
        }
        guard videoField("isGallery", node) as? Bool == true,
              let captions = videoField("captions", controller),
              let context = videoField("editingContext", captions) as? NSObject,
              let resolver = videoField("resolver", captions),
              let store = videoField("store", controller), Mirror(reflecting: store).displayStyle == .class,
              videoField("entries", store) is HostStringDictionary,
              let gallery = videoField("gallery", controller),
              let sendValue = videoField("send", gallery), type(of: sendValue) == ModernVideoSend.self else { return false }
        let send = ModernNativeFunction(owner: sendValue)
        let state = ModernVideoConversion(controller: controller, node: node, context: context,
                                          resolver: resolver, store: store as AnyObject, send: send)
        let wrapped: ModernVideoSend = { [weak state] id, silent, time, complete in
            guard let state else { return send.send(id, silent, time, complete) }
            return state.send(id, silent: silent, time: time, complete: complete)
        }
        let capture = ModernSendCapture(wrapped)
        guard let updated = HostValueWriter.access("send", in: gallery, type: ModernVideoSend.self,
            size: 2 * MemoryLayout<UInt>.size, alignment: MemoryLayout<UInt>.alignment, body: {
                TGExtraInstallModernVideoSend($0, Unmanaged.passUnretained(capture).toOpaque())
            })?.0,
              HostValueWriter.replacing("gallery", in: controller, with: HostValueWriter.optional(updated)) != nil else { return false }
        objc_setAssociatedObject(controller, &modernVideoStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        state.attach(view)
        return true
    }

    @objc static func hide(on controller: NSObject) {
        guard let state = objc_getAssociatedObject(controller, &modernVideoStateKey) as? ModernVideoConversion else { return }
        state.timer?.invalidate(); state.timer = nil
        state.voice.removeFromSuperview(); state.round.removeFromSuperview()
        state.root = nil
    }

    private func attach(_ view: UIView) {
        root = view
        view.addSubview(voice); view.addSubview(round)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.update() }
        update()
    }

    deinit { timer?.invalidate() }

    private func identifier() -> String? {
        guard let node, let model = videoField("pageModel", node),
              let index = videoField("currentIndex", model) as? Int,
              let source = videoField("itemsSource", model) else { return nil }
        if let items = videoField("items", source) as? [Any], items.indices.contains(index) {
            return videoField("uniqueId", items[index]) as? String
        }
        if let asset = videoField("asset", source), type(of: asset) == ((Int) -> PHAsset).self,
           let count = videoField("assetCount", source) as? Int, index >= 0, index < count {
            let reversed = videoField("reversed", source) as? Bool ?? false
            return ModernNativeFunction(owner: asset).asset(reversed ? count - index - 1 : index)?.localIdentifier
        }
        return nil
    }

    private func item(_ id: String) -> NSObject? {
        if let items = videoField("items", resolver) as? [String: NSObject], let item = items[id] { return item }
        guard let lookup = videoField("lookup", resolver), type(of: lookup) == ((String) -> NSObject?).self else { return nil }
        return ModernNativeFunction(owner: lookup).lookup(id)
    }

    private func nativeRoundIsOn() -> Bool {
        guard let node, let editor = videoField("mediaEditor", node), let values = videoField("values", editor) else { return false }
        return videoField("sgSendAsTelescope", values) as? Bool == true
    }

    private func update() {
        guard let root, let node else { return }
        voice.isHidden = true; round.isHidden = true
        guard let id = identifier(), let subject = videoField("subject", node),
              let source = Mirror(reflecting: subject).children.first,
              source.label == "video" || (source.value as? PHAsset)?.mediaType == .video,
              videoField("activeTool", node) == nil,
              !["isSending", "isInvalidated", "isInterfaceHiddenBySwipe", "isEditingCaption"].contains(where: { videoField($0, node) as? Bool == true }) else { return }
        let item = ModernVideoItem(context: context, identifier: id)
        if nativeRoundIsOn() { tgextraClearConversionItem(item) }
        voice.isHidden = !tgextraVideoToVoiceEnabled()
        round.isHidden = !tgextraVideoToRoundEnabled()
        voice.isSelected = tgextraVoiceItems(context).contains(id)
        round.isSelected = tgextraRoundItems(context).contains(id)
        for button in [voice, round] {
            button.backgroundColor = button.isSelected ? .systemBlue : UIColor(white: 0, alpha: 0.5)
            button.accessibilityValue = button.isSelected ? "On" : "Off"
            root.bringSubviewToFront(button)
        }
        let safe = root.safeAreaInsets
        var x = root.bounds.maxX - safe.right - 52
        var y = safe.top + 68
        if let check = videoField("selectionCheckButton", node) as? UIView, check.superview != nil, !check.isHidden {
            let frame = root.convert(check.bounds, from: check)
            x = frame.midX - 22; y = frame.maxY + 8
        }
        x = max(safe.left + 8, min(x, root.bounds.maxX - safe.right - 52))
        y = max(safe.top + 8, min(y, root.bounds.maxY - safe.bottom - 112))
        voice.frame = CGRect(x: x, y: y, width: 44, height: 44)
        round.frame = CGRect(x: x, y: y + (voice.isHidden ? 0 : 52), width: 44, height: 44)
    }

    @objc private func voicePressed() { toggle(round: false) }
    @objc private func roundPressed() { toggle(round: true) }

    private func toggle(round: Bool) {
        guard let node, let id = identifier() else { return }
        if nativeRoundIsOn() {
            guard let nativeButton = videoField("sgTelescopeButton", node) as? UIButton else { return }
            nativeButton.sendActions(for: .touchUpInside)
            guard !nativeRoundIsOn() else { return }
        }
        let item = ModernVideoItem(context: context, identifier: id)
        if round { _ = tgextraToggleRoundItem(item) } else { _ = tgextraToggleVoiceItem(item) }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        update()
    }

    private func send(_ id: String, silent: Bool, time: Int32?, complete: @escaping () -> Void) -> Bool {
        restorePending?(); restorePending = nil
        var ids = Set<String>()
        if tgextraVideoToVoiceEnabled() { ids.formUnion(tgextraVoiceItems(context)) }
        if tgextraVideoToRoundEnabled() { ids.formUnion(tgextraRoundItems(context)) }
        let selection = videoField("selectionContext", resolver)
        ids.formIntersection(Set(TGExtraSelectedVideoIdentifiers(selection)).union([id]))
        guard !ids.isEmpty else { return originalSend.send(id, silent, time, complete) }
        guard let rawEntries = videoField("entries", store), let entries = rawEntries as? HostStringDictionary else { return false }
        // saveCurrentItemEdits runs before this callback. Preserve its trim and
        // route only selected conversions through the host's legacy-item adapter.
        var previous: [(NSObject, Any?)] = []
        var prepared: [(NSObject, Any)] = []
        for key in ids {
            guard let item = item(key) else { return false }
            let values = entries.hostEntries[key].flatMap { videoField("values", $0) }
            if values.flatMap({ videoField("sgSendAsTelescope", $0) as? Bool }) == true {
                tgextraClearConversionItem(ModernVideoItem(context: context, identifier: key))
                ids.remove(key)
                continue
            }
            var dictionary: [String: Any] = ["preset": 3]
            if let values {
                if let size = videoField("originalDimensions", values),
                   let w = videoField("width", size) as? Int32, let h = videoField("height", size) as? Int32 {
                    dictionary["originalSize"] = NSValue(cgSize: CGSize(width: Int(w), height: Int(h)))
                }
                if let range = videoField("videoTrimRange", values) as? Range<Double> {
                    dictionary["trimStart"] = range.lowerBound; dictionary["trimEnd"] = range.upperBound
                }
            }
            guard let adjustments = TGExtraVideoAdjustments(dictionary) else { return false }
            previous.append((item, TGExtraGetVideoAdjustments(context, item)))
            prepared.append((item, adjustments))
        }
        guard !ids.isEmpty else { return originalSend.send(id, silent, time, complete) }
        let context = self.context
        let restore = { [weak store] in
            if let store, let current = videoField("entries", store) as? HostStringDictionary {
                _ = HostValueWriter.replacing("entries", in: store, with: current.restoring(rawEntries, keys: ids))
            }
            for (item, adjustments) in previous { _ = TGExtraSetVideoAdjustments(context, item, adjustments) }
        }
        for (item, adjustments) in prepared {
            guard TGExtraSetVideoAdjustments(context, item, adjustments) else { restore(); return false }
        }
        guard HostValueWriter.replacing("entries", in: store, with: entries.removing(ids)) != nil else { restore(); return false }
        restorePending = restore
        generation += 1
        let token = generation
        let result = originalSend.send(id, silent, time) { [weak self] in
            if let self {
                if self.generation == token { self.restorePending?(); self.restorePending = nil }
            } else { restore() }
            complete()
        }
        if !result { restorePending?(); restorePending = nil }
        return result
    }
}
#endif
