import Foundation

@objc(TGExtraRecordingControls)
final class TGExtraRecordingControls: NSObject {
    @objc static func fromNode(_ node: Any) -> [String: Any] {
        var controls: [String: Any] = [:]
        for name in ["micButton", "micButtonBackgroundView", "micButtonTintMaskView",
                     "sendContainerNode", "expandMediaInputButton", "expandMediaInputButtonBackgroundView"] {
            if let value = RenderedMessageReader.storedField(name, in: node) {
                controls[name] = RenderedMessageReader.unwrapOptional(value)
            }
        }
        return controls
    }
}
