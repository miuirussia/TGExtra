import Foundation
import os

extension TLParser {
    static let diagLog = OSLog(subsystem: "com.choco.tg", category: "diag")

    static let diagEnabled = false

    static func diag(_ message: String) {
        guard diagEnabled else { return }
        os_log("[TGExtraDiag] %{public}@", log: diagLog, type: .default, message)
    }

    static var seenSignatures = Set<Int32>()

    static let signatureQueue = DispatchQueue(label: "com.tgextra.diagSignatures")

    static func diagSignature(_ signature: Int32) {
        guard diagEnabled else { return }
        signatureQueue.sync {
            guard seenSignatures.count < 60, seenSignatures.insert(signature).inserted else { return }
            diag(String(format: "tl-in 0x%08X", UInt32(bitPattern: signature)))
        }
    }

    static var loggedApiMessages = Set<String>()

    static func installApiLogger() {
        guard diagEnabled else { return }
        setTelegramApiLogger { message in
            signatureQueue.sync {
                guard loggedApiMessages.count < 60,
                      loggedApiMessages.insert(message).inserted else { return }
                diag("api-layer: \(message)")
            }
        }
    }

    static var unparsedSignatures = Set<Int32>()

    static func diagUnparsed(_ signature: Int32) {
        guard diagEnabled else { return }
        signatureQueue.sync {
            guard unparsedSignatures.count < 40, unparsedSignatures.insert(signature).inserted else { return }
            diag(String(format: "tl-UNPARSED 0x%08X", UInt32(bitPattern: signature)))
        }
    }
}
