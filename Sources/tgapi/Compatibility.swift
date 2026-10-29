import Foundation
import ObjectiveC
import tgapiC

extension TLParser {
    @objc static func compatibilityReport() -> String {
        var lines = ["TGExtra compatibility"]
        if let schema = HostSchema.shared {
            lines.append("Host schema: TLS1 v3, \(schema.constructors.count) constructors, \(schema.functions.count) methods")
            let missing = TLMethodID.allCases.filter { $0.id == nil }.map(\.rawValue)
            lines.append("Outgoing methods: " + (missing.isEmpty ? "all recognized" : "missing " + missing.joined(separator: ", ")))
        } else {
            lines.append("Host schema unavailable: protocol policies are inactive")
        }
        lines.append("Native TL decoder: " + (nativeTLAvailable() ? "active" : "unavailable; byte codec used when schema is available"))
        lines.append("Rust bridge: " + TGExtraRustCompatibilityStatus())
        let hooks = TGExtraInstalledHookStatuses() ?? [:]
        for name in hooks.keys.sorted() { lines.append("\(name) hook: \(hooks[name]!)") }
        let interfaces: [(String, [String], String)] = [
            ("MtProtoKit requests", ["MTRequest"], "setPayload:metadata:shortMetadata:responseParser:"),
            ("MtProtoKit submission", ["MTRequestMessageService"], "addRequest:"),
            ("Message badges / paid media", ["_ASDisplayView"], "asyncdisplaykit_node"),
            ("Double-tap reactions", ["Display.TapLongTapOrDoubleTapGestureRecognizer"], "touchesBegan:withEvent:"),
            ("Recording button", ["ChatTextInputMediaRecordingButton.ChatTextInputMediaRecordingButton", "TelegramUI.ChatTextInputMediaRecordingButton"], "micButtonInteractionBegan"),
            ("Voice preview", ["TGMediaPickerGalleryInterfaceView"], "itemFocused:itemView:"),
            ("Private copy protection", ["TelegramUI.ChatPresentationInterfaceState", "ChatPresentationInterfaceState.ChatPresentationInterfaceState"], "copyProtectionEnabled"),
            ("tlottie", ["TLottieAnimation"], "initWithData:fitzModifier:colorReplacements:"),
        ]
        for (name, classes, selector) in interfaces {
            let available = classes.contains { class_getInstanceMethod(NSClassFromString($0), NSSelectorFromString(selector)) != nil }
            lines.append("\(name) interface: \(available ? "present" : "unavailable")")
        }
        lines.append("Private Swift fields still require client validation. Standalone true-flag bits are reviewed mappings; TLS1 does not describe them.")
        return lines.joined(separator: "\n")
    }
}
