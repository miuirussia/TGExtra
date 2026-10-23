import Foundation

func testAppleContentSettings() {
    flags()
    defer { flags() }
    let functionID = NSNumber(value: Int32(0x61e3f854))
    let key = "ignore_restriction_reasons"
    func strings(_ values: [String]) -> Api.JSONValue {
        .jsonArray(.init(value: values.map { .jsonString(.init(value: $0)) }))
    }
    func field(_ key: String, _ value: Api.JSONValue) -> Api.JSONObjectValue {
        .jsonObjectValue(.init(key: key, value: value))
    }
    let unrelated: Api.JSONValue = .jsonObject(.init(value: [
        field("enabled", .jsonBool(.init(value: .boolTrue))),
        field("limit", .jsonNumber(.init(value: 123))),
        field("platforms", strings(["ios", "android"]))
    ]))
    func config(_ reasons: [String]?) -> NSData {
        var fields = [field("unrelated_config", unrelated)]
        if let reasons = reasons { fields.append(field(key, strings(reasons))) }
        return serialized(Api.help.AppConfig.appConfig(.init(hash: 123456, config: .jsonObject(.init(value: fields)))))
    }
    func values(_ bytes: NSData) -> [String: Api.JSONValue] {
        guard case let .appConfig(value) = parsed(bytes, as: Api.help.AppConfig.self),
              case let .jsonObject(object) = value.config else { fatalError("Expected app config") }
        check(value.hash == 123456, "Content settings retain the real server hash")
        return Dictionary(uniqueKeysWithValues: object.value.map { entry in
            guard case let .jsonObjectValue(field) = entry else { fatalError("Expected JSON field") }
            return (field.key, field.value)
        })
    }
    for existing in [nil, [], ["server_reason"], ["server_reason", "appleterms"]] as [[String]?] {
        for forwarding in [false, true] {
            if forwarding { flags("disableForwardRestriction") } else { flags() }
            let bytes = config(existing)
            let patched = response(bytes, functionID: functionID, account: nil)!
            let fields = values(patched)
            guard case let .jsonArray(array)? = fields[key] else { fatalError("Expected ignore list") }
            let reasons = array.value.map { item -> String in
                guard case let .jsonString(string) = item else { fatalError("Expected reason string") }
                return string.value
            }
            check(reasons == (existing ?? []) + ["appleterms", "appleterms-ios"].filter { !(existing ?? []).contains($0) },
                  "Client-side Apple rules are ignored without losing server exceptions or adding duplicates")
            check(serialized(fields["unrelated_config"]!) == serialized(unrelated),
                  "Unrelated app configuration stays byte-for-byte intact")
            check(response(patched, functionID: functionID) == nil, "Content configuration rewrites are idempotent")
            let packed = Buffer()
            packed.appendInt32(0x3072cfa1)
            serializeBytes(Buffer(data: gzip(bytes as Data)), buffer: packed, boxed: false)
            check(response(packed.makeData() as NSData, functionID: functionID) == patched,
                  "Compressed content configuration is patched too")
        }
    }
    check(response(config(["appleterms", "appleterms-ios"]), functionID: functionID) == nil,
          "An existing complete ignore list is unchanged")
    check(response(serialized(Api.help.AppConfig.appConfigNotModified), functionID: functionID) == nil,
          "A not-modified response never replaces the stored config with fabricated data")
    let request = Api.functions.help.getAppConfig(hash: 123456).1.makeData() as NSData
    let fresh = Api.functions.help.getAppConfig(hash: 0).1.makeData() as NSData
    check(TLParser.rewriteAppConfigRequest(request) == fresh,
          "Existing installations request a full app config instead of retaining cached Apple rules")
    check(TLParser.rewriteAppConfigRequest(fresh) == nil, "Full config requests are already current")
    for length in 0..<request.length {
        check(TLParser.rewriteAppConfigRequest((request as Data).prefix(length) as NSData) == nil,
              "Incomplete config requests pass through")
    }
    check(TLParser.rewriteAppConfigRequest((request as Data + Data([0, 0, 0, 0])) as NSData) == nil,
          "Unknown config request extensions pass through")
    check(TLParser.rewriteAppConfigRequest(serialized(Api.updates.State.state(.init(pts: 1, qts: 0, date: 0, seq: 1, unreadCount: 0)))) == nil,
          "Other payloads are not rewritten as app config requests")

    // These are rules the actual 13.0 renderer blocks; "sensitive" is already
    // ignored by PlatformRestrictionMatching and cannot reproduce this defect.
    flags()
    let photo = Api.MessageMedia.messageMediaPhoto(.init(flags: 1, photo: .photoEmpty(.init(id: 19)), ttlSeconds: nil, video: nil))
    for reason in ["appleterms", "appleterms-ios", "another-platform-rule"] {
        for platform in ["ios", "all"] {
            let source = message(89300, peer: .peerChannel(.init(channelId: 77)), text: "Actual post contents", media: photo)
            messageData(source).flags |= (1 << 22) | (1 << 26)
            messageData(source).restrictionReason = [.restrictionReason(.init(platform: platform, reason: reason,
                text: "This message couldn't be displayed on your device.\nappleterms-ios"))]
            let expected = message(89300, peer: .peerChannel(.init(channelId: 77)), text: "Actual post contents", media: photo)
            messageData(expected).flags |= 1 << 26
            let wraps: [(Api.Message) -> Any] = [
                { $0 },
                { Api.Update.updateNewChannelMessage(.init(message: $0, pts: 1, ptsCount: 1)) },
                { Api.messages.Messages.channelMessages(.init(flags: 0, pts: 1, count: 1, offsetIdOffset: nil,
                    messages: [$0], topics: [], chats: [], users: [])) },
                { Api.Updates.updates(.init(updates: [.updateNewChannelMessage(.init(message: $0, pts: 1, ptsCount: 1))],
                    users: [], chats: [], date: 1234, seq: 1)) }
            ]
            for wrap in wraps {
                check(strip(serialized(wrap(source)), account: nil) == serialized(wrap(expected)),
                      "Live/history messages strip \(reason) for \(platform), retaining actual text, media and forwarding flags")
            }
        }
    }
    print("PASS Apple content settings, full-config refresh, gzip, existing config and live/history message bodies")
}
