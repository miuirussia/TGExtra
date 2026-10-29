import Foundation

extension TLParser {
    static func rewriteDecoded(_ result: Any, settings: MessagePatches.Settings) -> (Any, Bool) {
        var modified = false
        var newResult: Any = result

        if let updates = result as? Api.Updates {
            switch updates {
            case let .updates(data):
                let (stripped, anyStripped) = stripTTLUpdates(data.updates)
                let (newChats, anyChatsChanged) = stripNoForwardsFromChats(data.chats)
                if anyStripped || anyChatsChanged {
                    newResult = Api.Updates.updates(Api.Updates.Cons_updates(updates: stripped, users: data.users, chats: newChats, date: data.date, seq: data.seq))
                    modified = true
                }
            case let .updateShort(data):
                let (stripped, changed) = stripTTLUpdate(data.update)
                if changed {
                    newResult = Api.Updates.updateShort(Api.Updates.Cons_updateShort(update: stripped, date: data.date))
                    modified = true
                }
            case let .updateShortMessage(data):
                noteContentReadState(id: data.id, peer: data.userId,
                                     mention: data.flags & (1 << 4) != 0 && data.flags & (1 << 5) != 0,
                                     reaction: false, disappearingMedia: false)
                recordShortFormOriginal(id: data.id, text: data.message,
                                        peer: data.userId, entities: data.entities, outgoing: data.flags & (1 << 1) != 0)
                let before = updates.record.changes.count
                if data.ttlPeriod != nil { recordTimedId(data.id, scope: cloudScope, disappearing: false) }
                MessagePatches.removeAutoDeleteTimer(from: updates.record, settings: packetSettings)
                MessagePatches.removeForwardingProtection(from: updates.record, settings: packetSettings)
                modified = before != updates.record.changes.count
            case let .updateShortChatMessage(data):
                noteContentReadState(id: data.id, peer: -data.chatId,
                                     mention: data.flags & (1 << 4) != 0 && data.flags & (1 << 5) != 0,
                                     reaction: false, disappearingMedia: false)
                recordShortFormOriginal(id: data.id, text: data.message,
                                        peer: -data.chatId, entities: data.entities,
                                        outgoing: data.flags & (1 << 1) != 0 || isOwnAuthor(.peerUser(.init(userId: data.fromId)), account: processingHistoryAccount))
                let before = updates.record.changes.count
                if data.ttlPeriod != nil { recordTimedId(data.id, scope: cloudScope, disappearing: false) }
                MessagePatches.removeAutoDeleteTimer(from: updates.record, settings: packetSettings)
                MessagePatches.removeForwardingProtection(from: updates.record, settings: packetSettings)
                modified = before != updates.record.changes.count
            case let .updateShortSentMessage(data):
                let before = updates.record.changes.count
                if data.ttlPeriod != nil { recordTimedId(data.id, scope: cloudScope, disappearing: false) }
                MessagePatches.removeAutoDeleteTimer(from: updates.record, settings: packetSettings)
                MessagePatches.removeForwardingProtection(from: updates.record, settings: packetSettings)
                let mediaChanged = data.media.map { stripTTLMedia($0, messageId: data.id, scope: cloudScope) } ?? false
                modified = mediaChanged || before != updates.record.changes.count
            case let .updatesCombined(data):
                let (stripped, anyStripped) = stripTTLUpdates(data.updates)
                let (newChats, anyChatsChanged) = stripNoForwardsFromChats(data.chats)
                if anyStripped || anyChatsChanged {
                    newResult = Api.Updates.updatesCombined(Api.Updates.Cons_updatesCombined(updates: stripped, users: data.users, chats: newChats, date: data.date, seqStart: data.seqStart, seq: data.seq))
                    modified = true
                }
            default:
                break
            }
        } else if let msgs = result as? Api.messages.Messages {
            switch msgs {
            case let .messages(data):
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    newResult = Api.messages.Messages.messages(Api.messages.Messages.Cons_messages(messages: p.messages, topics: data.topics, chats: p.chats, users: data.users))
                    modified = true
                }
            case let .messagesSlice(data):
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    newResult = Api.messages.Messages.messagesSlice(Api.messages.Messages.Cons_messagesSlice(flags: data.flags, count: data.count, nextRate: data.nextRate, offsetIdOffset: data.offsetIdOffset, searchFlood: data.searchFlood, messages: p.messages, topics: data.topics, chats: p.chats, users: data.users))
                    modified = true
                }
            case let .channelMessages(data):
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    newResult = Api.messages.Messages.channelMessages(Api.messages.Messages.Cons_channelMessages(flags: data.flags, pts: data.pts, count: data.count, offsetIdOffset: data.offsetIdOffset, messages: p.messages, topics: data.topics, chats: p.chats, users: data.users))
                    modified = true
                }
            default:
                break
            }
        } else if let difference = result as? Api.updates.Difference {
            switch difference {
            case let .difference(data):
                let p = patchMessageBatch(data.newMessages, chats: data.chats)
                let (otherUpdates, changedUpdates) = stripTTLUpdates(data.otherUpdates)
                if p.changed || changedUpdates {
                    newResult = Api.updates.Difference.difference(Api.updates.Difference.Cons_difference(newMessages: p.messages, newEncryptedMessages: data.newEncryptedMessages, otherUpdates: otherUpdates, chats: p.chats, users: data.users, state: data.state))
                    modified = true
                }
            case let .differenceSlice(data):
                let p = patchMessageBatch(data.newMessages, chats: data.chats)
                let (otherUpdates, changedUpdates) = stripTTLUpdates(data.otherUpdates)
                if p.changed || changedUpdates {
                    newResult = Api.updates.Difference.differenceSlice(Api.updates.Difference.Cons_differenceSlice(newMessages: p.messages, newEncryptedMessages: data.newEncryptedMessages, otherUpdates: otherUpdates, chats: p.chats, users: data.users, intermediateState: data.intermediateState))
                    modified = true
                }
            default:
                break
            }
        } else if let difference = result as? Api.updates.ChannelDifference {
            switch difference {
            case let .channelDifference(data):
                let p = patchMessageBatch(data.newMessages, chats: data.chats)
                let (otherUpdates, changedUpdates) = stripTTLUpdates(data.otherUpdates)
                if p.changed || changedUpdates {
                    diag("channelDifference patched — \(p.messages.count) message(s), \(otherUpdates.count) update(s)")
                    newResult = Api.updates.ChannelDifference.channelDifference(Api.updates.ChannelDifference.Cons_channelDifference(flags: data.flags, pts: data.pts, timeout: data.timeout, newMessages: p.messages, otherUpdates: otherUpdates, chats: p.chats, users: data.users))
                    modified = true
                }
            case let .channelDifferenceTooLong(data):
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    diag("channelDifferenceTooLong patched — \(p.messages.count) message(s)")
                    newResult = Api.updates.ChannelDifference.channelDifferenceTooLong(Api.updates.ChannelDifference.Cons_channelDifferenceTooLong(flags: data.flags, timeout: data.timeout, dialog: data.dialog, messages: p.messages, chats: p.chats, users: data.users))
                    modified = true
                }
            default:
                break
            }
        } else if let chatFull = result as? Api.messages.ChatFull {
            switch chatFull {
            case let .chatFull(data):
                let (newFullChat, changedFull) = stripNoForwardsFromFullChat(data.fullChat)
                let (newChats, changedChats) = stripNoForwardsFromChats(data.chats)
                if changedFull || changedChats {
                    newResult = Api.messages.ChatFull.chatFull(Api.messages.ChatFull.Cons_chatFull(fullChat: newFullChat, chats: newChats, users: data.users))
                    modified = true
                }
            case .other: break
            }
        } else if let chats = result as? Api.messages.Chats {
            switch chats {
            case let .chats(data):
                let (newChats, changed) = stripNoForwardsFromChats(data.chats)
                if changed {
                    newResult = Api.messages.Chats.chats(Api.messages.Chats.Cons_chats(chats: newChats))
                    modified = true
                }
            case let .chatsSlice(data):
                let (newChats, changed) = stripNoForwardsFromChats(data.chats)
                if changed {
                    newResult = Api.messages.Chats.chatsSlice(Api.messages.Chats.Cons_chatsSlice(count: data.count, chats: newChats))
                    modified = true
                }
            case .other: break
            }
        } else if let update = result as? Api.Update {
            let (stripped, changed) = stripTTLUpdate(update)
            if changed {
                newResult = stripped
                modified = true
            }
        } else if let message = result as? Api.Message {
            cacheMessage(message)
            trackMessageVersions(message)
            let (stripped, changed) = stripTTLMessage(message)
            if changed {
                newResult = stripped
                modified = true
            }
        } else if let discussion = result as? Api.messages.DiscussionMessage {
            if case let .discussionMessage(data) = discussion {
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    newResult = Api.messages.DiscussionMessage.discussionMessage(.init(flags: data.flags,
                        messages: p.messages, maxId: data.maxId, readInboxMaxId: data.readInboxMaxId,
                        readOutboxMaxId: data.readOutboxMaxId, unreadCount: data.unreadCount, chats: p.chats, users: data.users))
                    modified = true
                }
            }
        } else if let peerDialogs = result as? Api.messages.PeerDialogs {
            if case let .peerDialogs(data) = peerDialogs {
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    newResult = Api.messages.PeerDialogs.peerDialogs(.init(dialogs: data.dialogs,
                        messages: p.messages, chats: p.chats, users: data.users, state: data.state))
                    modified = true
                }
            }
        } else if let welcome = result as? Api.ephemeral.WelcomeMessages {
            if case let .welcomeMessages(data) = welcome {
                for message in data.messages {
                    if patchEphemeralMessage(message, isEdit: true) { modified = true }
                }
            }
        } else if let dialogs = result as? Api.messages.Dialogs {
            switch dialogs {
            case let .dialogs(data):
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    newResult = Api.messages.Dialogs.dialogs(.init(dialogs: data.dialogs, messages: p.messages, chats: p.chats, users: data.users))
                    modified = true
                }
            case let .dialogsSlice(data):
                let p = patchMessageBatch(data.messages, chats: data.chats)
                if p.changed {
                    newResult = Api.messages.Dialogs.dialogsSlice(.init(count: data.count, dialogs: data.dialogs, messages: p.messages, chats: p.chats, users: data.users))
                    modified = true
                }
            default: break
            }
        }

        if let original = Api.record(result), let replacement = Api.record(newResult), original !== replacement {
            replacement.retainUnwrittenFields(from: original)
        }
        return (newResult, modified)
    }
}
