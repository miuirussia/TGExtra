import Foundation

// The setting → condition → field-change mapping for TL message policies.
// Account lookup, message classification and persistence remain in TLParser.
enum MessagePatches {
    enum Setting: String, CaseIterable {
        case preventAutoDelete = "TGExtraAntiAutoDelete"
        case preventMediaSelfDestruct = "TGExtraAntiSelfDestruct"
        case bypassForwarding = "disableForwardRestriction"
        case bypassPrivateCopy = "TGExtraIgnorePrivateChatCopyProtection"
        case keepDeletedMessages = "TGExtraAntiRevoke"
        case keepEditHistory = "TGExtraAntiEdit"
        case hideDisappearingLabel = "TGExtraHideDisappearingLabel"
        case videoToVoice = "TGExtraVideoToVoice"
        case ghostMode = "TGExtraGhostModeEnabled"
        case hideMentionReads = "disableMentionReadReceipt"
        case hideReactionReads = "disableReactionReadReceipt"
    }

    // disableForwardRestriction forces reserialization of prepared copies.
    // Other message edits also reserialize those copies, including the legacy
    // unconditional noforwards preparation, even when this switch is off.
    static func shouldReserialize(changed: Bool, settings: Settings = .init()) -> Bool {
        changed || settings.bypassForwarding
    }

    struct Settings {
        var defaults: UserDefaults = .standard
        func enabled(_ setting: Setting) -> Bool { defaults.bool(forKey: setting.rawValue) }
        var preventAutoDelete: Bool { enabled(.preventAutoDelete) }
        var preventMediaSelfDestruct: Bool { enabled(.preventMediaSelfDestruct) }
        var bypassForwarding: Bool { enabled(.bypassForwarding) }
        var bypassPrivateCopy: Bool { enabled(.bypassPrivateCopy) }
        var keepDeletedMessages: Bool { enabled(.keepDeletedMessages) }
        // Anti-Edit records revisions; it never replaces the received message text.
        var keepEditHistory: Bool { enabled(.keepEditHistory) }
        var hideDisappearingLabel: Bool { enabled(.hideDisappearingLabel) }
        var videoToVoice: Bool { enabled(.videoToVoice) }
        var ghostMode: Bool { enabled(.ghostMode) }
        var hideMentionReads: Bool { enabled(.hideMentionReads) }
        var hideReactionReads: Bool { enabled(.hideReactionReads) }
        var protectsAnyDeletions: Bool { keepDeletedMessages || preventMediaSelfDestruct || preventAutoDelete }
        var tracksContentReads: Bool { hideMentionReads || hideReactionReads || preventMediaSelfDestruct }
        var filtersContentReceipts: Bool { preventMediaSelfDestruct || (ghostMode && (hideMentionReads || hideReactionReads)) }
        var processesMessages: Bool {
            protectsAnyDeletions || bypassForwarding || bypassPrivateCopy || keepEditHistory || tracksContentReads
        }

        // Timer switches protect deletion only for previously classified messages.
        func protectsDeletion(disappearing: Bool, autoDelete: Bool) -> Bool {
            keepDeletedMessages || (preventMediaSelfDestruct && disappearing) || (preventAutoDelete && autoDelete)
        }

        // readMessageContents request IDs: media protection precedes Ghost
        // exceptions; unknown classifications stay blocked while required.
        func allowsContentReceipt(disappearing: Bool?, mention: Bool?, reaction: Bool?,
                                  classified: Bool, ghostException: Bool) -> Bool {
            if preventMediaSelfDestruct && disappearing != false { return false }
            let mentions = ghostMode && hideMentionReads
            let reactions = ghostMode && hideReactionReads
            guard mentions || reactions else { return true }
            guard classified else { return false }
            if ghostException { return true }
            return !(mentions && (mention ?? true)) && !(reactions && (reaction ?? true))
        }
    }

    // UNCONDITIONAL: original-byte content access and decoded-copy preparation.
    // Call after validating a complete response or a known prefix with opaque peers.
    static func prepareDecodedObjects(in reader: BufferReader) {
        for record in reader.parsedRecords {
            switch record.typeName + "." + record.constructorName {
            case "Chat.channel", "Message.message", "User.user":
                let patch = TLDataPatch(record, rule: "always: iOS content restrictions")
                if let presence = patch.presenceFlag(for: "restrictionReason"),
                   patch.removeOptionalField("restrictionReason") {
                    reader.replaceFlags(of: record, field: presence.field)
                    reader.removeFieldBytes(of: record, field: "restrictionReason")
                }
            default: break
            }
            switch record.typeName + "." + record.constructorName {
            case "Chat.channel", "Chat.chat", "Message.message", "StoryItem.storyItem":
                // Legacy behavior: prepare ONLY the decoded copy. This records
                // no original-byte edit; TLParser still controls reserialization.
                TLDataPatch(record, rule: "always: decoded forwarding preparation").clearFlag(.noForwards)
            default: break
            }
        }
    }

    // UNCONDITIONAL: preserve server settings and add the iOS ignore reasons.
    static func allowIOSContent(in config: Api.help.AppConfig) -> Bool {
        guard case let .appConfig(data) = config,
              case let .jsonObject(object) = data.config else { return false }
        let reasons = ["appleterms", "appleterms-ios"]
        let key = "ignore_restriction_reasons"
        var entries = object.value
        let index = entries.lastIndex {
            if case let .jsonObjectValue(field) = $0 { return field.key == key }
            return false
        }
        var values: [Api.JSONValue] = []
        if let index = index, case let .jsonObjectValue(field) = entries[index],
           case let .jsonArray(array) = field.value { values = array.value }
        let existing = Set(values.compactMap { value -> String? in
            if case let .jsonString(string) = value { return string.value }
            return nil
        })
        let missing = reasons.filter { !existing.contains($0) }
        guard !missing.isEmpty else { return false }
        values += missing.map { .jsonString(.init(value: $0)) }
        let entry = Api.JSONObjectValue.jsonObjectValue(.init(key: key, value: .jsonArray(.init(value: values))))
        if let index = index { entries[index] = entry } else { entries.append(entry) }
        return TLDataPatch(data.record, rule: "always: iOS content settings")
            .replaceField("config", Api.JSONValue.jsonObject(.init(value: entries)))
    }

    // UNCONDITIONAL: a nonzero config hash could retain old iOS restrictions.
    static func refreshContentConfigurationRequest(_ payload: NSData) -> NSData? {
        guard payload.length == 8 else { return nil }
        let reader = BufferReader(Buffer(nsData: payload))
        guard reader.readInt32() == 0x61e3f854, let hash = reader.readInt32(), hash != 0 else { return nil }
        return Api.functions.help.getAppConfig(hash: 0).1.makeValidData() as NSData?
    }

    // TGExtraAntiAutoDelete + an existing timer → remove ttlPeriod.
    // Compact updates also clear media_unread, matching the existing policy.
    @discardableResult
    static func removeAutoDeleteTimer(from record: TLRecord, settings: Settings = .init()) -> Bool {
        guard settings.preventAutoDelete, record.fields["ttlPeriod"] != nil else { return false }
        let patch = TLDataPatch(record, rule: Setting.preventAutoDelete.rawValue)
        switch record.typeName + "." + record.constructorName {
        case "Message.message", "Message.messageService":
            return patch.removeOptionalField("ttlPeriod")
        case "Updates.updateShortMessage", "Updates.updateShortChatMessage", "Updates.updateShortSentMessage":
            let removed = patch.removeOptionalField("ttlPeriod")
            let cleared = patch.clearFlag(.mediaUnread)
            return removed || cleared
        default: return false
        }
    }

    // TGExtraAntiSelfDestruct + photo/document TTL → remove ttlSeconds.
    @discardableResult
    static func removeMediaTimer(from record: TLRecord, settings: Settings = .init()) -> Bool {
        guard settings.preventMediaSelfDestruct else { return false }
        switch record.typeName + "." + record.constructorName {
        case "MessageMedia.messageMediaPhoto", "MessageMedia.messageMediaDocument":
            return TLDataPatch(record, rule: Setting.preventMediaSelfDestruct.rawValue).removeOptionalField("ttlSeconds")
        default: return false
        }
    }

    // disableForwardRestriction → clear noforwards.
    // Existing exception: compact incoming updates also do this for AntiSelfDestruct.
    @discardableResult
    static func removeForwardingProtection(from record: TLRecord, settings: Settings = .init()) -> Bool {
        let constructor = record.typeName + "." + record.constructorName
        let compact = constructor == "Updates.updateShortMessage" || constructor == "Updates.updateShortChatMessage"
        guard settings.bypassForwarding || (compact && settings.preventMediaSelfDestruct) else { return false }
        let reason = settings.bypassForwarding ? Setting.bypassForwarding : Setting.preventMediaSelfDestruct
        return TLDataPatch(record, rule: reason.rawValue).clearFlag(.noForwards)
    }

    // TGExtraIgnorePrivateChatCopyProtection → clear BOTH private-copy flags.
    @discardableResult
    static func removePrivateCopyProtection(from record: TLRecord, settings: Settings = .init()) -> Bool {
        guard settings.bypassPrivateCopy else { return false }
        let patch = TLDataPatch(record, rule: Setting.bypassPrivateCopy.rawValue)
        let mine = patch.clearFlag(.noForwardsMyEnabled)
        let peer = patch.clearFlag(.noForwardsPeerEnabled)
        return mine || peer
    }

    // Return true for a handled full-user response, even if its flags were clear.
    // Other chats in that response retain their original forwarding bytes.
    static func patchPrivateCopyResponse(_ result: Any, reader: BufferReader, settings: Settings = .init()) -> Bool {
        guard settings.bypassPrivateCopy else { return false }
        let user: TLRecord
        if let fullUser = result as? Api.UserFull, case let .userFull(data) = fullUser {
            user = data.record
        } else if let response = result as? Api.users.UserFull, case let .userFull(data) = response,
                  case let .userFull(fullUser) = data.fullUser {
            user = fullUser.record
        } else { return false }
        if removePrivateCopyProtection(from: user, settings: settings) { reader.replaceFlags(of: user, field: "flags2") }
        return true
    }

    // Known disappearing marker → clear media_unread. The label switch only
    // controls message text/entities; it never disables media protection.
    static func markDisappearingMessage(_ message: Api.Message, observedDisappearing: Bool, settings: Settings = .init()) {
        guard observedDisappearing, case let .message(data) = message else { return }
        let patch = TLDataPatch(message.record, rule: "observed disappearing media")
        patch.clearFlag(.mediaUnread)
        guard !settings.hideDisappearingLabel else { return }
        let marker = "dissapearing message "
        var text = data.message
        var entities = data.entities ?? []
        if !text.contains("dissapearing message") {
            if text.hasPrefix("⏱️ ") { text.removeFirst(3) }
            let offset = Int32(marker.count)
            for entity in entities {
                if let current = entity.record.fields["offset"] as? Int32 {
                    TLDataPatch(entity.record, rule: "disappearing label offsets").replaceField("offset", current + offset)
                }
            }
            let length = Int32(marker.count - 1)
            entities.insert(.messageEntityItalic(.init(offset: 0, length: length)), at: 0)
            entities.insert(.messageEntitySpoiler(.init(offset: 0, length: length)), at: 0)
            text = marker + text
        }
        let label = TLDataPatch(message.record, rule: "observed disappearing media; !" + Setting.hideDisappearingLabel.rawValue)
        label.replaceField("message", text)
        label.setOptionalField("entities", entities)
    }

    // IDs have already been classified by Settings.protectsDeletion. Preserve
    // count, pts and pts_count; only the protected IDs become zero.
    @discardableResult
    static func replaceDeletionIds(in record: TLRecord, keeping ids: [Int32], settings: Settings = .init()) -> Bool {
        guard settings.protectsAnyDeletions, record.typeName == "Update" else { return false }
        let field: String
        switch record.constructorName {
        case "updateDeleteMessages", "updateDeleteChannelMessages", "updateDeleteScheduledMessages", "updateDeleteQuickReplyMessages":
            field = "messages"
        case "updateDeleteEphemeralMessages": field = "ids"
        default: return false
        }
        if record.constructorName == "updateDeleteScheduledMessages", record.fields["sentMessages"] != nil { return false }
        guard let original = record.fields[field] as? [Int32], original.count == ids.count,
              zip(original, ids).allSatisfy({ $0.0 == $0.1 || $0.1 == 0 }) else { return false }
        let keys: [Setting] = [.keepDeletedMessages, .preventMediaSelfDestruct, .preventAutoDelete]
        let reason = keys.filter { settings.enabled($0) }.map(\.rawValue).joined(separator: " || ")
        return TLDataPatch(record, rule: reason).replaceField(field, ids)
    }

    // TGExtraAntiRevoke + channel-history pruning → a zero-pts deletion no-op.
    static func suppressChannelHistoryPruning(_ update: Api.Update, settings: Settings = .init()) -> Api.Update? {
        guard settings.keepDeletedMessages, case .updateChannelAvailableMessages = update else { return nil }
        return .updateDeleteMessages(.init(messages: [], pts: 0, ptsCount: 0))
    }

    // TGExtraVideoToVoice + a file registered by our extraction pipeline →
    // replace document attributes with the voice attribute built from that file.
    @discardableResult
    static func replaceVoiceAttributes(in record: TLRecord, attributes: [Api.DocumentAttribute], registeredUpload: Bool,
                                       settings: Settings = .init()) -> Bool {
        guard settings.videoToVoice, registeredUpload, record.typeName == "InputMedia",
              record.constructorName == "inputMediaUploadedDocument" else { return false }
        return TLDataPatch(record, rule: Setting.videoToVoice.rawValue).replaceField("attributes", attributes)
    }
}
