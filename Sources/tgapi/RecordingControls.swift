import Foundation

@objc(TGExtraRecordingControls)
final class TGExtraRecordingControls: NSObject {
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
}
