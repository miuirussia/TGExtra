import Foundation

extension TLParser {
    struct VoiceUpload {
        let duration: Int32
        let waveform: Data?
    }

    static let voiceQueue = DispatchQueue(label: "com.tgextra.voiceUploads",
                                                  attributes: .concurrent)

    static var _voiceUploads = [String: VoiceUpload]()

    @objc static func registerVoiceUpload(withFileName fileName: String,
                                          duration: Int,
                                          waveform: NSData?) {
        guard !fileName.isEmpty else { return }
        let entry = VoiceUpload(duration: Int32(max(1, duration)),
                                waveform: waveform as Data?)
        voiceQueue.async(flags: .barrier) {
            // Telegram may prepare or retry uploads after the entire picker batch is converted.
            // Keep registrations for this session instead of evicting pending uploads by count.
            _voiceUploads[fileName] = entry
        }
    }

    static func voiceUpload(forFileName name: String) -> VoiceUpload? {
        var result: VoiceUpload?
        voiceQueue.sync { result = _voiceUploads[name] }
        return result
    }
}
