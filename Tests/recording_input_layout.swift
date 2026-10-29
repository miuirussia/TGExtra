import Foundation
import UIKit

@_silgen_name("TGExtraBindRecordingInput")
func bindRecordingInput(_ node: AnyObject)
@_silgen_name("TGExtraLayoutRecordingInput")
func layoutRecordingInput(_ background: UIView)

final class LayoutNode: NSObject {
    @objc let view = UIView()
}

final class LayoutActions: NSObject {
    @objc let view = UIView()
    let micButton = UIView()
    let micButtonBackgroundView = UIView()
    let micButtonTintMaskView = UIView()
    let sendContainerNode = LayoutNode()
    let expandMediaInputButton = UIButton()
    let expandMediaInputButtonBackgroundView = UIView()
}

final class LegacyInputBackdrop: UIView {
    let backdropLayer = CALayer()
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(backdropLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class InputGlass: UIView {
    let nativeParamsView = UIView()
    let nativeView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    let contentContainer = UIView()
    let maskContainerView = UIView()
    let maskContentView = UIView()
    let foregroundView = UIImageView()
    let shadowView = UIImageView()
    let legacyView = LegacyInputBackdrop()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(nativeParamsView)
        nativeParamsView.addSubview(nativeView)
        addSubview(contentContainer)
        addSubview(legacyView)
        addSubview(foregroundView)
        addSubview(shadowView)
        foregroundView.mask = maskContainerView
        maskContainerView.addSubview(maskContentView)
        layer.cornerRadius = 20
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutRecordingInput(self)
    }
}

final class InputAccessory: UIButton {
    let tintMask = UIView()
}

final class InputPanel: NSObject {
    @objc let view = UIView()
    let textInputContainerBackgroundView = InputGlass()
    let textInputBackgroundNode = LayoutNode()
    let textInputNodeClippingContainer = UIView()
    let accessoryPanelContainer = UIView()
    let mediaActionButtons = LayoutActions()
    let sendActionButtons = LayoutActions()
    var isUpdating = false
    var validLayout: (CGFloat, CGFloat, CGFloat)?
    var customRightAction: String?
    var customSecondaryRightAction: String?
    var starReactionButton: NSObject?
    var liveMicrophoneButton: NSObject?
    let accessory = InputAccessory()
    var accessoryItemButtons: [(String, InputAccessory)] = []
    let editorContainer = UIView()
    let editor = UITextView()

    override init() {
        super.init()
        accessoryItemButtons = [("input", accessory)]
        view.addSubview(textInputBackgroundNode.view)
        view.addSubview(textInputContainerBackgroundView)
        view.addSubview(mediaActionButtons.view)
        view.addSubview(sendActionButtons.view)
        let content = textInputContainerBackgroundView.nativeView.contentView
        content.addSubview(accessoryPanelContainer)
        content.addSubview(textInputNodeClippingContainer)
        content.addSubview(accessory)
        textInputContainerBackgroundView.maskContentView.addSubview(accessory.tintMask)
        textInputNodeClippingContainer.addSubview(editorContainer)
        editorContainer.addSubview(editor)
    }

    func nativeLayout(width: CGFloat, trailingInset: CGFloat = 8, hasText: Bool = false,
                      hasExpand: Bool = false, fullWidth: Bool = false) {
        isUpdating = true
        defer { isUpdating = false }
        view.frame = CGRect(x: 0, y: 0, width: width, height: 64)
        validLayout = (width, 0, trailingInset - 8)
        let slot: CGFloat = hasText || fullWidth ? 0 : 46
        let frame = CGRect(x: 54, y: 10, width: width - trailingInset - 54 - slot, height: 40)
        let background = textInputContainerBackgroundView
        background.frame = frame
        for part in [background.nativeParamsView, background.nativeView,
                     background.nativeView.contentView, background.contentContainer,
                     background.maskContentView, background.legacyView, accessoryPanelContainer,
                     textInputNodeClippingContainer, editorContainer] {
            part.frame = CGRect(origin: .zero, size: frame.size)
        }
        background.legacyView.backdropLayer.frame = CGRect(origin: .zero, size: frame.size)
        editor.frame = CGRect(x: 13, y: 0, width: frame.width - 26, height: 40)
        background.maskContainerView.frame = CGRect(x: 0, y: 0, width: frame.width + 64, height: 104)
        background.maskContentView.frame.origin = CGPoint(x: 32, y: 32)
        for part in [background.foregroundView, background.shadowView] {
            part.frame = CGRect(x: -32, y: -32, width: frame.width + 64, height: 104)
        }
        textInputBackgroundNode.view.frame = frame
        mediaActionButtons.view.frame = CGRect(x: hasText ? width + 8 : frame.maxX + 6,
                                              y: 10, width: 40, height: 40)
        sendActionButtons.view.transform = hasText ? .identity : CGAffineTransform(scaleX: 0.001, y: 0.001)
        sendActionButtons.sendContainerNode.view.alpha = 1
        mediaActionButtons.expandMediaInputButtonBackgroundView.alpha = hasExpand ? 1 : 0
        accessory.frame = CGRect(x: frame.width - 36, y: 0, width: 30, height: 40)
        accessory.tintMask.frame = accessory.frame
    }
}

@main enum RecordingInputLayoutTests {
    static func main() {
        for width: CGFloat in [320, 375, 430, 844, 1024] {
            for inset: CGFloat in [8, 52] {
                let panel = InputPanel()
                panel.nativeLayout(width: width, trailingInset: inset)
                bindRecordingInput(panel)
                let background = panel.textInputContainerBackgroundView
                let oldWidth = background.bounds.width
                let oldAccessoryX = panel.accessory.frame.minX
                let oldEditorWidth = panel.editor.bounds.width
                // Force real UIKit autoresizing when a parent grows.
                background.nativeParamsView.autoresizingMask = [.flexibleWidth]
                background.nativeView.autoresizingMask = [.flexibleWidth]
                let widthAnimation = CABasicAnimation(keyPath: "bounds.size")
                widthAnimation.fromValue = NSValue(cgSize: background.bounds.size)
                widthAnimation.duration = 1
                background.layer.add(widthAnimation, forKey: "bounds.size")
                layoutRecordingInput(background)
                precondition(abs(background.frame.maxX - (width - inset)) < 0.01, "Fill the removed slot, retaining safe insets")
                for part in [background.nativeParamsView, background.nativeView,
                             background.nativeView.contentView, panel.textInputNodeClippingContainer,
                             background.legacyView, panel.editorContainer] {
                    precondition(abs(part.bounds.width - (oldWidth + 46)) < 0.01, "Keep glass, editor and clip in sync")
                }
                precondition(background.legacyView.backdropLayer.bounds.width == oldWidth + 46)
                precondition(background.foregroundView.bounds.width == oldWidth + 110)
                precondition(background.layer.animation(forKey: "bounds.size") == nil, "Discard stale gap animations")
                precondition(abs(panel.editor.bounds.width - (oldEditorWidth + 46)) < 0.01)
                precondition(abs(panel.accessory.frame.minX - (oldAccessoryX + 46)) < 0.01)
                precondition(panel.accessory.frame == panel.accessory.tintMask.frame, "Icon and tint mask move together")
                precondition(background.layer.cornerRadius == 20, "Do not scale corner radii or icons")
                let after = background.frame
                background.layoutIfNeeded()
                layoutRecordingInput(background)
                precondition(background.frame == after, "Repeated layout cannot accumulate extra width")
                panel.nativeLayout(width: width, trailingInset: inset, hasText: true)
                let textFrame = background.frame
                layoutRecordingInput(background)
                precondition(background.frame == textFrame, "Keep native send/text layout")
                panel.nativeLayout(width: width, trailingInset: inset)
                layoutRecordingInput(background)
                precondition(abs(background.frame.maxX - (width - inset)) < 0.01, "Reclaim the slot after clearing text")
                panel.nativeLayout(width: width, trailingInset: inset, hasExpand: true)
                let expandFrame = background.frame
                layoutRecordingInput(background)
                precondition(background.frame == expandFrame, "Reserve the media keyboard's expand button")
                panel.nativeLayout(width: width, trailingInset: inset, fullWidth: true)
                let fullFrame = background.frame
                layoutRecordingInput(background)
                precondition(background.frame == fullFrame, "Do not extend a field already expanded by Swiftgram")
                panel.nativeLayout(width: width, trailingInset: inset)
                for action in ["custom", "stars", "live", "updating", "send"] {
                    panel.customRightAction = action == "custom" ? "empty" : nil
                    panel.starReactionButton = action == "stars" ? NSObject() : nil
                    panel.liveMicrophoneButton = action == "live" ? NSObject() : nil
                    panel.isUpdating = action == "updating"
                    panel.sendActionButtons.view.transform = action == "send" ? .identity : CGAffineTransform(scaleX: 0.001, y: 0.001)
                    let before = background.frame
                    layoutRecordingInput(background)
                    precondition(background.frame == before, "Preserve other controls and active native layout")
                }
            }
        }
        let unbound = InputGlass(frame: CGRect(x: 10, y: 0, width: 200, height: 40))
        layoutRecordingInput(unbound)
        precondition(unbound.bounds.width == 200, "Leave unrelated glass views alone")
        print("PASS real UIKit recording-slot layout: phone/tablet/landscape, safe insets, glass, editor, masks, autoresizing, text/empty transitions and other controls")
    }
}

