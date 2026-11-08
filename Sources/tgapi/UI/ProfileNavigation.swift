import Foundation
import tgapiC

@objc(TGExtraProfileNavigation)
final class ProfileNavigation: NSObject {
    @objc(loadProfileForPeerId:fromNode:completion:)
    static func loadProfile(peerId: NSNumber, fromNode node: Any,
                            completion: @escaping ((() -> Bool)?) -> Void) {
        // Use the settings screen's account and native profile action, never a
        // shared context that may have been captured from another account.
        func reject(_ reason: String) {
            TGExtraLogProfileFailure(peerId.int64Value, reason)
            completion(nil)
        }
        guard peerId.int64Value > 0 else {
            reject("invalid user ID")
            return
        }
        guard TGExtraProfileLookupAvailable() else {
            reject("native lookup exports unavailable")
            return
        }
        guard let interaction = HostValueReader.storedField("_interaction", in: node),
              let action = HostValueReader.storedField("openPeerInfo", in: interaction) else {
            reject("native profile action missing")
            return
        }
        let signature = String(reflecting: type(of: action))
        guard signature == "(TelegramCore.EnginePeer, Swift.Bool) -> ()" else {
            reject("unsupported native profile action signature: \(signature)")
            return
        }
        guard let data = HostValueReader.storedField("data", in: node),
              let samplePeer = HostValueReader.storedField("peer", in: data) else {
            reject("source peer data unavailable")
            return
        }
        guard let context = HostValueReader.storedField("context", in: node),
              let account = HostValueReader.storedField("account", in: context),
              let postbox = HostValueReader.storedField("postbox", in: account),
              String(reflecting: type(of: postbox)) == "Postbox.Postbox" else {
            reject("source account Postbox unavailable or incompatible")
            return
        }
        guard let navigation = navigationController(for: node) else {
            reject("source navigation controller unavailable")
            return
        }
        let sample = HostValueReader.unwrapOptional(samplePeer)
        let peerType = type(of: sample)
        guard String(reflecting: peerType) == "TelegramCore.EnginePeer", compatiblePeerId(in: sample) else {
            reject("unsupported native peer or PeerId layout")
            return
        }
        let open = nativeActionWords(action)

        func load<Peer>(_: Peer.Type) {
            // EnginePeer is a one-word native enum. The host initializer below
            // constructs it, and its real value witnesses manage its lifetime.
            guard MemoryLayout<Peer>.size == MemoryLayout<UInt>.size else {
                reject("unsupported native EnginePeer size: \(MemoryLayout<Peer>.size)")
                return
            }
            func lookup(refreshIfMissing: Bool) {
                let request = ProfileLookupRequest { transaction in
                    let result = UnsafeMutablePointer<Peer>.allocate(capacity: 1)
                    guard TGExtraCopyProfilePeer(transaction, peerId.int64Value, result) else {
                        result.deallocate()
                        DispatchQueue.main.async {
                            guard refreshIfMissing else {
                                reject("user not found in source account after server lookup by ID")
                                return
                            }
                            refreshProfile(peerId: peerId.int64Value, context: context) { failure in
                                if let failure = failure { reject(failure) }
                                else { lookup(refreshIfMissing: false) }
                            }
                        }
                        return
                    }
                    let peer = result.move()
                    result.deallocate()
                    DispatchQueue.main.async {
                        completion {
                            guard let previous = (navigation.value(forKey: "viewControllers") as? [NSObject])?.last else {
                                TGExtraLogProfileFailure(peerId.int64Value, "navigation stack unavailable")
                                return false
                            }
                            withExtendedLifetime((node, action)) {
                                withUnsafePointer(to: peer) {
                                    TGExtraInvokeProfileAction(open.function, open.context, $0)
                                }
                            }
                            let current = (navigation.value(forKey: "viewControllers") as? [NSObject])?.last
                            let opened = current != nil && current !== previous
                            if !opened {
                                TGExtraLogProfileFailure(peerId.int64Value, "native profile action did not open a controller")
                            }
                            return opened
                        }
                    }
                }
                withExtendedLifetime((postbox, request)) {
                    TGExtraRunProfileLookup(Unmanaged.passUnretained(postbox as AnyObject).toOpaque(),
                        Unmanaged.passUnretained(request).toOpaque(),
                        unsafeBitCast(Void.self, to: UnsafeRawPointer.self))
                }
            }
            lookup(refreshIfMissing: true)
        }
        _openExistential(peerType, do: load)
    }

    private static func refreshProfile(peerId: Int64, context: Any,
                                       completion: @escaping (String?) -> Void) {
        guard TGExtraProfileRefreshAvailable(),
              let engine = HostValueReader.storedField("engine", in: context),
              String(reflecting: type(of: engine)) == "TelegramCore.TelegramEngine" else {
            completion("user not found in source account; native server lookup by ID unavailable")
            return
        }
        guard let referenceType = _typeByName("12TelegramCore13PeerReferenceO") else {
            completion("native PeerReference metadata unavailable")
            return
        }
        func referenceLayout<Value>(_: Value.Type) -> Bool {
            MemoryLayout<Value>.size == 17 && MemoryLayout<Value>.alignment == 8
        }
        guard _openExistential(referenceType, do: referenceLayout) else {
            completion("unsupported native PeerReference layout")
            return
        }
        let request = ProfileRefreshRequest(completion: completion)
        withExtendedLifetime((engine, request)) {
            request.token = TGExtraRefreshProfilePeer(Unmanaged.passUnretained(engine as AnyObject).toOpaque(),
                peerId, Unmanaged.passUnretained(request).toOpaque())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak request] in
            request?.finish("server lookup by ID timed out")
        }
    }

    private static func compatiblePeerId(in peer: Any) -> Bool {
        guard let payload = Mirror(reflecting: peer).children.first?.value,
              let id = HostValueReader.storedField("id", in: payload),
              String(reflecting: type(of: id)) == "Postbox.PeerId" else { return false }
        let fields = Array(Mirror(reflecting: id).children)
        guard fields.map({ $0.label ?? "" }) == ["namespace", "id"] else { return false }
        // The native getPeer call lowers this struct to UInt32 and Int64.
        // Reject a future reordered or widened ID before entering that ABI.
        func nativeSize<Value>(_ value: Value) -> Int { MemoryLayout<Value>.size }
        let idSize = _openExistential(id, do: nativeSize)
        let namespaceSize = _openExistential(fields[0].value, do: nativeSize)
        let valueSize = _openExistential(fields[1].value, do: nativeSize)
        return idSize == 16 && namespaceSize == 4 && valueSize == 8
    }

    private static func navigationController(for node: Any) -> NSObject? {
        guard let value = HostValueReader.storedField("controller", in: node),
              let controller = HostValueReader.unwrapOptional(value) as? NSObject,
              controller.responds(to: NSSelectorFromString("navigationController")),
              let navigation = controller.value(forKey: "navigationController") as? NSObject,
              navigation.responds(to: NSSelectorFromString("viewControllers")) else { return nil }
        return navigation
    }

    private struct NativeActionWords {
        let function: UnsafeRawPointer
        let context: UnsafeRawPointer?
    }

    private static func nativeActionWords(_ action: Any) -> NativeActionWords {
        // Invoke the concrete host closure ABI. Casting to a generic function
        // would change the enum argument from a register to an indirect value.
        // A thick function occupies two words in Any's inline value buffer.
        return withUnsafeBytes(of: action) {
            NativeActionWords(function: $0.load(as: UnsafeRawPointer.self),
                context: $0.load(fromByteOffset: MemoryLayout<UInt>.size, as: UnsafeRawPointer?.self))
        }
    }
}

private final class ProfileLookupRequest {
    let body: (UnsafeMutableRawPointer) -> Void
    init(body: @escaping (UnsafeMutableRawPointer) -> Void) { self.body = body }
}

private final class ProfileRefreshRequest {
    var token: UnsafeMutableRawPointer?
    private var completion: ((String?) -> Void)?

    init(completion: @escaping (String?) -> Void) { self.completion = completion }

    func finish(_ failure: String?) {
        guard let completion = completion else { return }
        self.completion = nil
        if let token = token {
            self.token = nil
            TGExtraDisposeProfileRefresh(token)
        }
        completion(failure)
    }
}

@_cdecl("TGExtraProfileRefreshFinished")
func profileRefreshFinished(_ context: UnsafeMutableRawPointer, _ success: Bool) {
    let request = Unmanaged<ProfileRefreshRequest>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        request.finish(success ? nil : "server lookup by ID failed; user inaccessible or access hash required")
    }
}

@_cdecl("TGExtraProfileLookupBody")
func profileLookupBody(_ context: UnsafeMutableRawPointer, _ transaction: UnsafeMutableRawPointer) {
    Unmanaged<ProfileLookupRequest>.fromOpaque(context).takeUnretainedValue().body(transaction)
}
