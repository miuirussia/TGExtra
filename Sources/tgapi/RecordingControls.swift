import Foundation

@objc(TGExtraRecordingControls)
final class TGExtraRecordingControls: NSObject {
    private static func field(_ name: String, in value: Any) -> Any? {
        guard let stored = HostValueReader.storedField(name, in: value) else { return nil }
        let mirror = Mirror(reflecting: stored)
        if mirror.displayStyle == .optional && mirror.children.isEmpty { return nil }
        return HostValueReader.unwrapOptional(stored)
    }

    @objc static func fromNode(_ node: Any) -> [String: Any] {
        var controls: [String: Any] = [:]
        for name in ["micButton", "micButtonBackgroundView", "micButtonTintMaskView",
                     "sendContainerNode", "expandMediaInputButton", "expandMediaInputButtonBackgroundView"] {
            if let value = HostValueReader.storedField(name, in: node) {
                controls[name] = HostValueReader.unwrapOptional(value)
            }
        }
        return controls
    }

    @objc static func inputLayoutFromNode(_ node: Any) -> [String: Any] {
        var layout: [String: Any] = [:]
        for name in ["textInputContainerBackgroundView", "textInputBackgroundNode",
                     "textInputNodeClippingContainer", "accessoryPanelContainer",
                     "mediaActionButtons", "sendActionButtons", "isUpdating"] {
            layout[name] = field(name, in: node)
        }
        layout["hasOtherRightAction"] = ["customRightAction", "customSecondaryRightAction",
                                         "starReactionButton", "liveMicrophoneButton"]
            .contains { field($0, in: node) != nil }
        if let validLayout = field("validLayout", in: node),
           let rightInset = field(".2", in: validLayout) as? CGFloat {
            layout["rightInset"] = rightInset
        }
        var accessories: [Any] = []
        if let buttons = field("accessoryItemButtons", in: node) as? [Any] {
            for entry in buttons {
                guard let button = field(".1", in: entry) else { continue }
                accessories.append(button)
                if let mask = field("tintMask", in: button) { accessories.append(mask) }
            }
        }
        layout["accessories"] = accessories
        return layout
    }

    @objc static func backgroundPartsFromView(_ view: Any) -> [Any] {
        // Both native glass and Telegram's image/backdrop fallback have their
        // own bounds. Resizing only the outer view leaves the visible capsule short.
        var parts: [Any] = []
        for name in ["nativeParamsView", "nativeView", "legacyView", "legacyHighlightContainerView",
                     "foregroundView", "shadowView", "maskContainerView", "maskContentView",
                     "contentContainer", "innerBackgroundView"] {
            if let part = field(name, in: view) { parts.append(part) }
        }
        if let legacy = field("legacyView", in: view),
           let backdrop = field("backdropLayer", in: legacy) { parts.append(backdrop) }
        return parts
    }
}
