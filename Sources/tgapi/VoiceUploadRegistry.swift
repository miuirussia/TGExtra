import Foundation

extension TLParser {
    struct VoiceUpload {
        let duration: Int32
        let waveform: Data?
    }

    static let voiceQueue = DispatchQueue(label: "com.tgextra.voiceUploads",
                                                  attributes: .concurrent)

    static var _voiceUploads = [String: VoiceUpload]()

    static var _voiceOrder = [String]()

    @objc static func registerVoiceUpload(withFileName fileName: String,
                                          duration: Int,
                                          waveform: NSData?) {
        guard !fileName.isEmpty else { return }
        let entry = VoiceUpload(duration: Int32(max(1, duration)),
                                waveform: waveform as Data?)
        voiceQueue.async(flags: .barrier) {
            if _voiceUploads[fileName] == nil { _voiceOrder.append(fileName) }
            _voiceUploads[fileName] = entry
            while _voiceOrder.count > 32 {
                _voiceUploads.removeValue(forKey: _voiceOrder.removeFirst())
            }
        }
    }

    static func voiceUpload(forFileName name: String) -> VoiceUpload? {
        var result: VoiceUpload?
        voiceQueue.sync { result = _voiceUploads[name] }
        return result
    }
}
