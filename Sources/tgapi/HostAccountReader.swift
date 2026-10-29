import Foundation
import tgapiC

enum HostAccountReader {
    static func account(in wrapped: Any, depth: Int = 0) -> String? {
        guard depth <= 6 else { return nil }
        var mirror: Mirror? = Mirror(reflecting: HostValueReader.unwrapOptional(wrapped))
        while let current = mirror {
            for child in current.children {
                if child.label == "basePath", let path = child.value as? String,
                   let resolved = TGExtraHistoryAccountForPath(path) { return resolved }
                if ["item", "context", "account"].contains(child.label ?? ""),
                   let resolved = account(in: child.value, depth: depth + 1) { return resolved }
            }
            mirror = current.superclassMirror
        }
        return nil
    }
}
