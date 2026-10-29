import Foundation

extension TLParser {
    static func stripTTLUpdates(_ updates: [Api.Update]) -> ([Api.Update], Bool) {
        var modified = false
        let result = updates.map { update -> Api.Update in
            let (stripped, changed) = stripTTLUpdate(update)
            if changed {
                modified = true
            }
            return stripped
        }
        return (result, modified)
    }

    static func stripTTLUpdate(_ update: Api.Update) -> (Api.Update, Bool) {
        let (rewritten, changed) = rewriteTTLUpdate(update)
        if changed { rewritten.record.retainUnwrittenFields(from: update.record) }
        return (rewritten, changed)
    }

    static func rewriteTTLUpdate(_ update: Api.Update) -> (Api.Update, Bool) {
        switch update {
        case let .updateMessageReactions(data):
            noteContentReadState(id: data.msgId, peer: peerKey(data.peer), reaction: hasUnreadReactions(data.reactions))
            return (update, false)
        case let .updateNewMessage(data):
            cacheMessage(data.message)
            trackMessageVersions(data.message)
            let (strippedMsg, changed) = stripTTLMessage(data.message)
            if !changed {
                return (update, false)
            }
            return (.updateNewMessage(Api.Update.Cons_updateNewMessage(message: strippedMsg, pts: data.pts, ptsCount: data.ptsCount)), true)
        case let .updateNewChannelMessage(data):
            cacheMessage(data.message)
            trackMessageVersions(data.message)
            let (strippedMsg, changed) = stripTTLMessage(data.message)
            if !changed {
                return (update, false)
            }
            return (.updateNewChannelMessage(Api.Update.Cons_updateNewChannelMessage(message: strippedMsg, pts: data.pts, ptsCount: data.ptsCount)), true)
        case let .updateEditMessage(data):
            cacheMessage(data.message)
            diag("updateEditMessage seen, antiEdit=\(packetSettings.keepEditHistory)")
            trackMessageVersions(data.message, allowUndatedEdit: true)
            let (message, changed) = stripTTLMessage(data.message)
            return (.updateEditMessage(.init(message: message, pts: data.pts, ptsCount: data.ptsCount)), changed)
        case let .updateEditChannelMessage(data):
            cacheMessage(data.message)
            diag("updateEditChannelMessage seen, antiEdit=\(packetSettings.keepEditHistory)")
            trackMessageVersions(data.message, allowUndatedEdit: true)
            let (message, changed) = stripTTLMessage(data.message)
            return (.updateEditChannelMessage(.init(message: message, pts: data.pts, ptsCount: data.ptsCount)), changed)
        case let .updateNewScheduledMessage(data):
            return withNamespace(3) {
                trackMessageVersions(data.message, allowUndatedEdit: true)
                let (message, changed) = stripTTLMessage(data.message)
                return (.updateNewScheduledMessage(.init(message: message)), changed)
            }
        case let .updateQuickReplyMessage(data):
            return withNamespace(5) {
                trackMessageVersions(data.message, allowUndatedEdit: true)
                let (message, changed) = stripTTLMessage(data.message)
                return (.updateQuickReplyMessage(.init(message: message)), changed)
            }
        case let .updateDeleteScheduledMessages(data):
            guard data.sentMessages == nil else { return (update, false) }
            return withNamespace(3) {
                guard let kept = neutralizeDeletions(data.messages, peer: peerKey(data.peer)) else { return (update, false) }
                MessagePatches.replaceDeletionIds(in: update.record, keeping: kept, settings: packetSettings)
                return (update, true)
            }
        case let .updateDeleteQuickReplyMessages(data):
            return withNamespace(5) {
                guard let kept = neutralizeDeletions(data.messages, peer: cloudScope) else { return (update, false) }
                MessagePatches.replaceDeletionIds(in: update.record, keeping: kept, settings: packetSettings)
                return (update, true)
            }
        case let .updateNewEphemeralMessage(data):
            let changed = patchEphemeralMessage(data.message, isEdit: false)
            return (update, changed)
        case let .updateEditEphemeralMessage(data):
            let changed = patchEphemeralMessage(data.message, isEdit: true)
            return (update, changed)
        case let .updateDeleteEphemeralMessages(data):
            var ids = data.ids
            for namespace: Int32 in [7, 8] {
                let kept = withNamespace(namespace) { neutralizeDeletions(data.ids, peer: peerKey(data.peer)) ?? data.ids }
                ids = zip(ids, kept).map { $0 == 0 || $1 == 0 ? 0 : $0 }
            }
            let changed = MessagePatches.replaceDeletionIds(in: update.record, keeping: ids, settings: packetSettings)
            return (update, changed)
        case let .updateChannelAvailableMessages(data):
            guard let noDeletion = MessagePatches.suppressChannelHistoryPruning(update, settings: packetSettings) else { return (update, false) }
            if let account = processingHistoryAccount, data.availableMinId > 0 {
                loadMarkers()
                let peer = -(1_000_000_000_000 + data.channelId)
                let key = MessageKey(account: account, peer: peer, id: 0)
                messageMarkers[key] = max(messageMarkers[key, default: 0], Int(data.availableMinId))
                pinChannelSnapshots(account: account, peer: peer, through: data.availableMinId)
                persistMarkers(key)
                loadSnapshots()
                if !snapshots.isEmpty { writeSnapshots() }
                let maxId = data.availableMinId
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("TGExtraMessageDeletedRealtime"), object: nil,
                        userInfo: ["maxId": NSNumber(value: maxId), "account": account,
                                   "peer": NSNumber(value: peer), "namespace": NSNumber(value: 0)])
                }
            }
            return (noDeletion, true)
        case let .updateDeleteMessages(data):
            guard let kept = neutralizeDeletions(data.messages, peer: cloudScope) else { return (update, false) }
            MessagePatches.replaceDeletionIds(in: update.record, keeping: kept, settings: packetSettings)
            return (update, true)
        case let .updateDeleteChannelMessages(data):
            let channelPeer = -(1_000_000_000_000 + data.channelId)
            guard let kept = neutralizeDeletions(data.messages, peer: channelPeer) else { return (update, false) }
            MessagePatches.replaceDeletionIds(in: update.record, keeping: kept, settings: packetSettings)
            return (update, true)
        default:
            return (update, false)
        }
    }

    static func patchEphemeralMessage(_ message: Api.EphemeralMessage, isEdit: Bool) -> Bool {
        guard case let .ephemeralMessage(data) = message else { return false }
        guard let peer = data.peerId else {
            guard let media = data.media else { return false }
            return stripTTLMedia(media, messageId: 0, scope: 0)
        }
        let namespace: Int32 = data.flags & (1 << 5) != 0 ? 9 : (data.anchorMsgId == nil ? 7 : 8)
        return withNamespace(namespace) {
            let own = isOwnAuthor(data.fromId, account: processingHistoryAccount)
            if own {
                discardOwnEditHistory(id: data.id, peer: peerKey(peer), account: processingHistoryAccount, namespace: namespace)
            }
            if packetSettings.keepEditHistory && isOwnIdKnown && !own {
                let text = data.richMessage.map { richText($0) }.flatMap { $0.isEmpty ? nil : $0 } ?? data.message
                if recordText(text, forId: data.id, peer: peerKey(peer), editDate: nil, allowUndatedEdit: isEdit,
                              content: revisionContent(entities: data.entities, media: data.media, rich: data.richMessage)),
                   let account = processingHistoryAccount {
                    let id = data.id
                    let peerId = peerKey(peer)
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(name: NSNotification.Name("TGExtraMessageEditedRealtime"), object: nil,
                            userInfo: ["ids": [NSNumber(value: id)], "peer": NSNumber(value: peerId),
                                       "account": account, "namespace": NSNumber(value: namespace)])
                    }
                }
            }
            return data.media.map { stripTTLMedia($0, messageId: data.id, scope: peerKey(peer)) } ?? false
        }
    }

    static func neutralizeDeletions(_ ids: [Int32], peer: Int64) -> [Int32]? {
        let settings = packetSettings
        guard settings.protectsAnyDeletions else { return nil }
        let kept = ids.map { id -> Int32 in
            guard id != 0 else { return 0 }
            let bits = settings.keepDeletedMessages ? 0 : markerBits(id: id, peer: peer, account: processingHistoryAccount, namespace: processingNamespace)
            let protected = settings.protectsDeletion(disappearing: bits & disappearingMarker != 0,
                                                     autoDelete: bits & autoDeleteMarker != 0)
            return protected ? 0 : id
        }
        let live = zip(ids, kept).compactMap { original, replacement in
            original != 0 && replacement == 0 ? original : nil
        }
        live.forEach { addDeletedId($0, peer: peer, account: processingHistoryAccount, namespace: processingNamespace) }
        guard kept != ids else { return nil }
        loadSnapshots()
        if !snapshots.isEmpty { writeSnapshots() }

        if let account = processingHistoryAccount {
            let saved = live.map { NSNumber(value: $0) }
            let namespace = processingNamespace
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("TGExtraMessageDeletedRealtime"), object: nil,
                    userInfo: ["ids": saved, "account": account, "peer": NSNumber(value: peer),
                               "namespace": NSNumber(value: namespace)])
            }
        }
        diag("anti-revoke: neutralised \(live.count) deletion(s) in the parsed path")
        return kept
    }
}
