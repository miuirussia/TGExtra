public extension Api {
    enum ExportedNoPaidMessagesToken: TypeConstructorDescription {
        public class Cons_exportedNoPaidMessagesToken: TypeConstructorDescription {
            public var flags: Int32
            public var token: String
            public var url: String
            public var expires: Int32?
            public init(flags: Int32, token: String, url: String, expires: Int32?) {
                self.flags = flags
                self.token = token
                self.url = url
                self.expires = expires
            }
            public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
                return ("exportedNoPaidMessagesToken", [("flags", ConstructorParameterDescription(self.flags)), ("token", ConstructorParameterDescription(self.token)), ("url", ConstructorParameterDescription(self.url)), ("expires", ConstructorParameterDescription(self.expires))])
            }
        }
        case exportedNoPaidMessagesToken(Cons_exportedNoPaidMessagesToken)

        public func serialize(_ buffer: Buffer, _ boxed: Swift.Bool) {
            switch self {
            case .exportedNoPaidMessagesToken(let _data):
                if boxed {
                    buffer.appendInt32(1767755842)
                }
                serializeInt32(_data.flags, buffer: buffer, boxed: false)
                serializeString(_data.token, buffer: buffer, boxed: false)
                serializeString(_data.url, buffer: buffer, boxed: false)
                if Int(_data.flags) & Int(1 << 0) != 0 {
                    serializeInt32(_data.expires!, buffer: buffer, boxed: false)
                }
                break
            }
        }

        public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
            switch self {
            case .exportedNoPaidMessagesToken(let _data):
                return ("exportedNoPaidMessagesToken", [("flags", ConstructorParameterDescription(_data.flags)), ("token", ConstructorParameterDescription(_data.token)), ("url", ConstructorParameterDescription(_data.url)), ("expires", ConstructorParameterDescription(_data.expires))])
            }
        }

        public static func parse_exportedNoPaidMessagesToken(_ reader: BufferReader) -> ExportedNoPaidMessagesToken? {
            var _1: Int32?
            _1 = reader.readInt32()
            var _2: String?
            _2 = parseString(reader)
            var _3: String?
            _3 = parseString(reader)
            var _4: Int32?
            if Int(_1 ?? 0) & Int(1 << 0) != 0 {
                _4 = reader.readInt32()
            }
            let _c1 = _1 != nil
            let _c2 = _2 != nil
            let _c3 = _3 != nil
            let _c4 = (Int(_1 ?? 0) & Int(1 << 0) == 0) || _4 != nil
            if _c1 && _c2 && _c3 && _c4 {
                return Api.ExportedNoPaidMessagesToken.exportedNoPaidMessagesToken(Cons_exportedNoPaidMessagesToken(flags: _1!, token: _2!, url: _3!, expires: _4))
            }
            else {
                return nil
            }
        }
    }
}
public extension Api {
    enum InputTonConnectOauthSession: TypeConstructorDescription {
        public class Cons_inputTonConnectOauthSession: TypeConstructorDescription {
            public var sessionId: Int64
            public var challengeAnswer: Buffer
            public var body: Buffer
            public var proof: Api.WalletOwnershipProof
            public init(sessionId: Int64, challengeAnswer: Buffer, body: Buffer, proof: Api.WalletOwnershipProof) {
                self.sessionId = sessionId
                self.challengeAnswer = challengeAnswer
                self.body = body
                self.proof = proof
            }
            public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
                return ("inputTonConnectOauthSession", [("sessionId", ConstructorParameterDescription(self.sessionId)), ("challengeAnswer", ConstructorParameterDescription(self.challengeAnswer)), ("body", ConstructorParameterDescription(self.body)), ("proof", ConstructorParameterDescription(self.proof))])
            }
        }
        case inputTonConnectOauthSession(Cons_inputTonConnectOauthSession)

        public func serialize(_ buffer: Buffer, _ boxed: Swift.Bool) {
            switch self {
            case .inputTonConnectOauthSession(let _data):
                if boxed {
                    buffer.appendInt32(1654613710)
                }
                serializeInt64(_data.sessionId, buffer: buffer, boxed: false)
                serializeBytes(_data.challengeAnswer, buffer: buffer, boxed: false)
                serializeBytes(_data.body, buffer: buffer, boxed: false)
                _data.proof.serialize(buffer, true)
                break
            }
        }

        public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
            switch self {
            case .inputTonConnectOauthSession(let _data):
                return ("inputTonConnectOauthSession", [("sessionId", ConstructorParameterDescription(_data.sessionId)), ("challengeAnswer", ConstructorParameterDescription(_data.challengeAnswer)), ("body", ConstructorParameterDescription(_data.body)), ("proof", ConstructorParameterDescription(_data.proof))])
            }
        }

        public static func parse_inputTonConnectOauthSession(_ reader: BufferReader) -> InputTonConnectOauthSession? {
            var _1: Int64?
            _1 = reader.readInt64()
            var _2: Buffer?
            _2 = parseBytes(reader)
            var _3: Buffer?
            _3 = parseBytes(reader)
            var _4: Api.WalletOwnershipProof?
            if let signature = reader.readInt32() {
                _4 = Api.parse(reader, signature: signature) as? Api.WalletOwnershipProof
            }
            let _c1 = _1 != nil
            let _c2 = _2 != nil
            let _c3 = _3 != nil
            let _c4 = _4 != nil
            if _c1 && _c2 && _c3 && _c4 {
                return Api.InputTonConnectOauthSession.inputTonConnectOauthSession(Cons_inputTonConnectOauthSession(sessionId: _1!, challengeAnswer: _2!, body: _3!, proof: _4!))
            }
            else {
                return nil
            }
        }
    }
}
public extension Api {
    enum InputWalletCardSticker: TypeConstructorDescription {
        public class Cons_inputWalletCardSticker: TypeConstructorDescription {
            public var coordinates: Api.MediaAreaCoordinates
            public var nftAddress: String
            public init(coordinates: Api.MediaAreaCoordinates, nftAddress: String) {
                self.coordinates = coordinates
                self.nftAddress = nftAddress
            }
            public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
                return ("inputWalletCardSticker", [("coordinates", ConstructorParameterDescription(self.coordinates)), ("nftAddress", ConstructorParameterDescription(self.nftAddress))])
            }
        }
        case inputWalletCardSticker(Cons_inputWalletCardSticker)

        public func serialize(_ buffer: Buffer, _ boxed: Swift.Bool) {
            switch self {
            case .inputWalletCardSticker(let _data):
                if boxed {
                    buffer.appendInt32(1474250151)
                }
                _data.coordinates.serialize(buffer, true)
                serializeString(_data.nftAddress, buffer: buffer, boxed: false)
                break
            }
        }

        public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
            switch self {
            case .inputWalletCardSticker(let _data):
                return ("inputWalletCardSticker", [("coordinates", ConstructorParameterDescription(_data.coordinates)), ("nftAddress", ConstructorParameterDescription(_data.nftAddress))])
            }
        }

        public static func parse_inputWalletCardSticker(_ reader: BufferReader) -> InputWalletCardSticker? {
            var _1: Api.MediaAreaCoordinates?
            if let signature = reader.readInt32() {
                _1 = Api.parse(reader, signature: signature) as? Api.MediaAreaCoordinates
            }
            var _2: String?
            _2 = parseString(reader)
            let _c1 = _1 != nil
            let _c2 = _2 != nil
            if _c1 && _c2 {
                return Api.InputWalletCardSticker.inputWalletCardSticker(Cons_inputWalletCardSticker(coordinates: _1!, nftAddress: _2!))
            }
            else {
                return nil
            }
        }
    }
}
public extension Api {
    indirect enum ShareTheme: TypeConstructorDescription {
        public class Cons_inputShareThemeGift: TypeConstructorDescription {
            public var stargift: Api.InputSavedStarGift
            public init(stargift: Api.InputSavedStarGift) {
                self.stargift = stargift
            }
            public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
                return ("inputShareThemeGift", [("stargift", ConstructorParameterDescription(self.stargift))])
            }
        }
        public class Cons_shareThemeEmojiBackdrop: TypeConstructorDescription {
            public var flags: Int32
            public var backdropId: Int32?
            public var emojis: [Api.Reaction]?
            public init(flags: Int32, backdropId: Int32?, emojis: [Api.Reaction]?) {
                self.flags = flags
                self.backdropId = backdropId
                self.emojis = emojis
            }
            public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
                return ("shareThemeEmojiBackdrop", [("flags", ConstructorParameterDescription(self.flags)), ("backdropId", ConstructorParameterDescription(self.backdropId)), ("emojis", ConstructorParameterDescription(self.emojis))])
            }
        }
        public class Cons_shareThemeGift: TypeConstructorDescription {
            public var stargift: Api.StarGift
            public init(stargift: Api.StarGift) {
                self.stargift = stargift
            }
            public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
                return ("shareThemeGift", [("stargift", ConstructorParameterDescription(self.stargift))])
            }
        }
        case inputShareThemeGift(Cons_inputShareThemeGift)
        case shareThemeDefault
        case shareThemeEmojiBackdrop(Cons_shareThemeEmojiBackdrop)
        case shareThemeGift(Cons_shareThemeGift)

        public func serialize(_ buffer: Buffer, _ boxed: Swift.Bool) {
            switch self {
            case .inputShareThemeGift(let _data):
                if boxed {
                    buffer.appendInt32(1069099867)
                }
                _data.stargift.serialize(buffer, true)
                break
            case .shareThemeDefault:
                if boxed {
                    buffer.appendInt32(-1783830449)
                }
                break
            case .shareThemeEmojiBackdrop(let _data):
                if boxed {
                    buffer.appendInt32(1689466081)
                }
                serializeInt32(_data.flags, buffer: buffer, boxed: false)
                if Int(_data.flags) & Int(1 << 0) != 0 {
                    serializeInt32(_data.backdropId!, buffer: buffer, boxed: false)
                }
                if Int(_data.flags) & Int(1 << 1) != 0 {
                    buffer.appendInt32(481674261)
                    buffer.appendInt32(Int32(_data.emojis!.count))
                    for item in _data.emojis! {
                        item.serialize(buffer, true)
                    }
                }
                break
            case .shareThemeGift(let _data):
                if boxed {
                    buffer.appendInt32(-336796051)
                }
                _data.stargift.serialize(buffer, true)
                break
            }
        }

        public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
            switch self {
            case .inputShareThemeGift(let _data):
                return ("inputShareThemeGift", [("stargift", ConstructorParameterDescription(_data.stargift))])
            case .shareThemeDefault:
                return ("shareThemeDefault", [])
            case .shareThemeEmojiBackdrop(let _data):
                return ("shareThemeEmojiBackdrop", [("flags", ConstructorParameterDescription(_data.flags)), ("backdropId", ConstructorParameterDescription(_data.backdropId)), ("emojis", ConstructorParameterDescription(_data.emojis))])
            case .shareThemeGift(let _data):
                return ("shareThemeGift", [("stargift", ConstructorParameterDescription(_data.stargift))])
            }
        }

        public static func parse_inputShareThemeGift(_ reader: BufferReader) -> ShareTheme? {
            var _1: Api.InputSavedStarGift?
            if let signature = reader.readInt32() {
                _1 = Api.parse(reader, signature: signature) as? Api.InputSavedStarGift
            }
            let _c1 = _1 != nil
            if _c1 {
                return Api.ShareTheme.inputShareThemeGift(Cons_inputShareThemeGift(stargift: _1!))
            }
            else {
                return nil
            }
        }
        public static func parse_shareThemeDefault(_ reader: BufferReader) -> ShareTheme? {
            return Api.ShareTheme.shareThemeDefault
        }
        public static func parse_shareThemeEmojiBackdrop(_ reader: BufferReader) -> ShareTheme? {
            var _1: Int32?
            _1 = reader.readInt32()
            var _2: Int32?
            if Int(_1 ?? 0) & Int(1 << 0) != 0 {
                _2 = reader.readInt32()
            }
            var _3: [Api.Reaction]?
            if Int(_1 ?? 0) & Int(1 << 1) != 0 {
                if let _ = reader.readInt32() {
                    _3 = Api.parseVector(reader, elementSignature: 0, elementType: Api.Reaction.self)
                }
            }
            let _c1 = _1 != nil
            let _c2 = (Int(_1 ?? 0) & Int(1 << 0) == 0) || _2 != nil
            let _c3 = (Int(_1 ?? 0) & Int(1 << 1) == 0) || _3 != nil
            if _c1 && _c2 && _c3 {
                return Api.ShareTheme.shareThemeEmojiBackdrop(Cons_shareThemeEmojiBackdrop(flags: _1!, backdropId: _2, emojis: _3))
            }
            else {
                return nil
            }
        }
        public static func parse_shareThemeGift(_ reader: BufferReader) -> ShareTheme? {
            var _1: Api.StarGift?
            if let signature = reader.readInt32() {
                _1 = Api.parse(reader, signature: signature) as? Api.StarGift
            }
            let _c1 = _1 != nil
            if _c1 {
                return Api.ShareTheme.shareThemeGift(Cons_shareThemeGift(stargift: _1!))
            }
            else {
                return nil
            }
        }
    }
}
public extension Api {
    enum ShareThemeBackdropOption: TypeConstructorDescription {
        public class Cons_shareThemeBackdropOption: TypeConstructorDescription {
            public var backdropId: Int32
            public var name: String
            public var centerColor: Int32
            public var edgeColor: Int32
            public var patternColor: Int32
            public var textColor: Int32
            public init(backdropId: Int32, name: String, centerColor: Int32, edgeColor: Int32, patternColor: Int32, textColor: Int32) {
                self.backdropId = backdropId
                self.name = name
                self.centerColor = centerColor
                self.edgeColor = edgeColor
                self.patternColor = patternColor
                self.textColor = textColor
            }
            public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
                return ("shareThemeBackdropOption", [("backdropId", ConstructorParameterDescription(self.backdropId)), ("name", ConstructorParameterDescription(self.name)), ("centerColor", ConstructorParameterDescription(self.centerColor)), ("edgeColor", ConstructorParameterDescription(self.edgeColor)), ("patternColor", ConstructorParameterDescription(self.patternColor)), ("textColor", ConstructorParameterDescription(self.textColor))])
            }
        }
        case shareThemeBackdropOption(Cons_shareThemeBackdropOption)

        public func serialize(_ buffer: Buffer, _ boxed: Swift.Bool) {
            switch self {
            case .shareThemeBackdropOption(let _data):
                if boxed {
                    buffer.appendInt32(1170331218)
                }
                serializeInt32(_data.backdropId, buffer: buffer, boxed: false)
                serializeString(_data.name, buffer: buffer, boxed: false)
                serializeInt32(_data.centerColor, buffer: buffer, boxed: false)
                serializeInt32(_data.edgeColor, buffer: buffer, boxed: false)
                serializeInt32(_data.patternColor, buffer: buffer, boxed: false)
                serializeInt32(_data.textColor, buffer: buffer, boxed: false)
                break
            }
        }

        public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
            switch self {
            case .shareThemeBackdropOption(let _data):
                return ("shareThemeBackdropOption", [("backdropId", ConstructorParameterDescription(_data.backdropId)), ("name", ConstructorParameterDescription(_data.name)), ("centerColor", ConstructorParameterDescription(_data.centerColor)), ("edgeColor", ConstructorParameterDescription(_data.edgeColor)), ("patternColor", ConstructorParameterDescription(_data.patternColor)), ("textColor", ConstructorParameterDescription(_data.textColor))])
            }
        }

        public static func parse_shareThemeBackdropOption(_ reader: BufferReader) -> ShareThemeBackdropOption? {
            var _1: Int32?
            _1 = reader.readInt32()
            var _2: String?
            _2 = parseString(reader)
            var _3: Int32?
            _3 = reader.readInt32()
            var _4: Int32?
            _4 = reader.readInt32()
            var _5: Int32?
            _5 = reader.readInt32()
            var _6: Int32?
            _6 = reader.readInt32()
            let _c1 = _1 != nil
            let _c2 = _2 != nil
            let _c3 = _3 != nil
            let _c4 = _4 != nil
            let _c5 = _5 != nil
            let _c6 = _6 != nil
            if _c1 && _c2 && _c3 && _c4 && _c5 && _c6 {
                return Api.ShareThemeBackdropOption.shareThemeBackdropOption(Cons_shareThemeBackdropOption(backdropId: _1!, name: _2!, centerColor: _3!, edgeColor: _4!, patternColor: _5!, textColor: _6!))
            }
            else {
                return nil
            }
        }
    }
}
public extension Api {
    enum ShareThemeBackdrops: TypeConstructorDescription {
        public class Cons_shareThemeBackdrops: TypeConstructorDescription {
            public var hash: Int32
            public var backdrops: [Api.ShareThemeBackdropOption]
            public init(hash: Int32, backdrops: [Api.ShareThemeBackdropOption]) {
                self.hash = hash
                self.backdrops = backdrops
            }
            public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
                return ("shareThemeBackdrops", [("hash", ConstructorParameterDescription(self.hash)), ("backdrops", ConstructorParameterDescription(self.backdrops))])
            }
        }
        case shareThemeBackdrops(Cons_shareThemeBackdrops)
        case shareThemeBackdropsNotModified

        public func serialize(_ buffer: Buffer, _ boxed: Swift.Bool) {
            switch self {
            case .shareThemeBackdrops(let _data):
                if boxed {
                    buffer.appendInt32(-1427448608)
                }
                serializeInt32(_data.hash, buffer: buffer, boxed: false)
                buffer.appendInt32(481674261)
                buffer.appendInt32(Int32(_data.backdrops.count))
                for item in _data.backdrops {
                    item.serialize(buffer, true)
                }
                break
            case .shareThemeBackdropsNotModified:
                if boxed {
                    buffer.appendInt32(2050977279)
                }
                break
            }
        }

        public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
            switch self {
            case .shareThemeBackdrops(let _data):
                return ("shareThemeBackdrops", [("hash", ConstructorParameterDescription(_data.hash)), ("backdrops", ConstructorParameterDescription(_data.backdrops))])
            case .shareThemeBackdropsNotModified:
                return ("shareThemeBackdropsNotModified", [])
            }
        }

        public static func parse_shareThemeBackdrops(_ reader: BufferReader) -> ShareThemeBackdrops? {
            var _1: Int32?
            _1 = reader.readInt32()
            var _2: [Api.ShareThemeBackdropOption]?
            if let _ = reader.readInt32() {
                _2 = Api.parseVector(reader, elementSignature: 0, elementType: Api.ShareThemeBackdropOption.self)
            }
            let _c1 = _1 != nil
            let _c2 = _2 != nil
            if _c1 && _c2 {
                return Api.ShareThemeBackdrops.shareThemeBackdrops(Cons_shareThemeBackdrops(hash: _1!, backdrops: _2!))
            }
            else {
                return nil
            }
        }
        public static func parse_shareThemeBackdropsNotModified(_ reader: BufferReader) -> ShareThemeBackdrops? {
            return Api.ShareThemeBackdrops.shareThemeBackdropsNotModified
        }
    }
}
public extension Api.payments {
    enum StarGiftDepositPayload: TypeConstructorDescription {
        public class Cons_starGiftDepositPayload: TypeConstructorDescription {
            public var nftAddress: String
            public var payload: Buffer
            public var amount: Int64
            public init(nftAddress: String, payload: Buffer, amount: Int64) {
                self.nftAddress = nftAddress
                self.payload = payload
                self.amount = amount
            }
            public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
                return ("starGiftDepositPayload", [("nftAddress", ConstructorParameterDescription(self.nftAddress)), ("payload", ConstructorParameterDescription(self.payload)), ("amount", ConstructorParameterDescription(self.amount))])
            }
        }
        case starGiftDepositPayload(Cons_starGiftDepositPayload)

        public func serialize(_ buffer: Buffer, _ boxed: Swift.Bool) {
            switch self {
            case .starGiftDepositPayload(let _data):
                if boxed {
                    buffer.appendInt32(1918612715)
                }
                serializeString(_data.nftAddress, buffer: buffer, boxed: false)
                serializeBytes(_data.payload, buffer: buffer, boxed: false)
                serializeInt64(_data.amount, buffer: buffer, boxed: false)
                break
            }
        }

        public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
            switch self {
            case .starGiftDepositPayload(let _data):
                return ("starGiftDepositPayload", [("nftAddress", ConstructorParameterDescription(_data.nftAddress)), ("payload", ConstructorParameterDescription(_data.payload)), ("amount", ConstructorParameterDescription(_data.amount))])
            }
        }

        public static func parse_starGiftDepositPayload(_ reader: BufferReader) -> StarGiftDepositPayload? {
            var _1: String?
            _1 = parseString(reader)
            var _2: Buffer?
            _2 = parseBytes(reader)
            var _3: Int64?
            _3 = reader.readInt64()
            let _c1 = _1 != nil
            let _c2 = _2 != nil
            let _c3 = _3 != nil
            if _c1 && _c2 && _c3 {
                return Api.payments.StarGiftDepositPayload.starGiftDepositPayload(Cons_starGiftDepositPayload(nftAddress: _1!, payload: _2!, amount: _3!))
            }
            else {
                return nil
            }
        }
    }
}
public extension Api.wallet {
    enum Card: TypeConstructorDescription {
        public class Cons_card: TypeConstructorDescription {
            public var flags: Int32
            public var stickers: [Api.wallet.CardSticker]?
            public var bgNftItem: Api.wallet.NftItem?
            public var address: String
            public var balance: Int64
            public init(flags: Int32, stickers: [Api.wallet.CardSticker]?, bgNftItem: Api.wallet.NftItem?, address: String, balance: Int64) {
                self.flags = flags
                self.stickers = stickers
                self.bgNftItem = bgNftItem
                self.address = address
                self.balance = balance
            }
            public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
                return ("card", [("flags", ConstructorParameterDescription(self.flags)), ("stickers", ConstructorParameterDescription(self.stickers)), ("bgNftItem", ConstructorParameterDescription(self.bgNftItem)), ("address", ConstructorParameterDescription(self.address)), ("balance", ConstructorParameterDescription(self.balance))])
            }
        }
        case card(Cons_card)

        public func serialize(_ buffer: Buffer, _ boxed: Swift.Bool) {
            switch self {
            case .card(let _data):
                if boxed {
                    buffer.appendInt32(-1898953807)
                }
                serializeInt32(_data.flags, buffer: buffer, boxed: false)
                if Int(_data.flags) & Int(1 << 0) != 0 {
                    buffer.appendInt32(481674261)
                    buffer.appendInt32(Int32(_data.stickers!.count))
                    for item in _data.stickers! {
                        item.serialize(buffer, true)
                    }
                }
                if Int(_data.flags) & Int(1 << 1) != 0 {
                    _data.bgNftItem!.serialize(buffer, true)
                }
                serializeString(_data.address, buffer: buffer, boxed: false)
                serializeInt64(_data.balance, buffer: buffer, boxed: false)
                break
            }
        }

        public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
            switch self {
            case .card(let _data):
                return ("card", [("flags", ConstructorParameterDescription(_data.flags)), ("stickers", ConstructorParameterDescription(_data.stickers)), ("bgNftItem", ConstructorParameterDescription(_data.bgNftItem)), ("address", ConstructorParameterDescription(_data.address)), ("balance", ConstructorParameterDescription(_data.balance))])
            }
        }

        public static func parse_card(_ reader: BufferReader) -> Card? {
            var _1: Int32?
            _1 = reader.readInt32()
            var _2: [Api.wallet.CardSticker]?
            if Int(_1 ?? 0) & Int(1 << 0) != 0 {
                if let _ = reader.readInt32() {
                    _2 = Api.parseVector(reader, elementSignature: 0, elementType: Api.wallet.CardSticker.self)
                }
            }
            var _3: Api.wallet.NftItem?
            if Int(_1 ?? 0) & Int(1 << 1) != 0 {
                if let signature = reader.readInt32() {
                    _3 = Api.parse(reader, signature: signature) as? Api.wallet.NftItem
                }
            }
            var _4: String?
            _4 = parseString(reader)
            var _5: Int64?
            _5 = reader.readInt64()
            let _c1 = _1 != nil
            let _c2 = (Int(_1 ?? 0) & Int(1 << 0) == 0) || _2 != nil
            let _c3 = (Int(_1 ?? 0) & Int(1 << 1) == 0) || _3 != nil
            let _c4 = _4 != nil
            let _c5 = _5 != nil
            if _c1 && _c2 && _c3 && _c4 && _c5 {
                return Api.wallet.Card.card(Cons_card(flags: _1!, stickers: _2, bgNftItem: _3, address: _4!, balance: _5!))
            }
            else {
                return nil
            }
        }
    }
}
public extension Api.wallet {
    enum CardSticker: TypeConstructorDescription {
        public class Cons_cardSticker: TypeConstructorDescription {
            public var coordinates: Api.MediaAreaCoordinates
            public var nft: Api.wallet.NftItem
            public init(coordinates: Api.MediaAreaCoordinates, nft: Api.wallet.NftItem) {
                self.coordinates = coordinates
                self.nft = nft
            }
            public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
                return ("cardSticker", [("coordinates", ConstructorParameterDescription(self.coordinates)), ("nft", ConstructorParameterDescription(self.nft))])
            }
        }
        case cardSticker(Cons_cardSticker)

        public func serialize(_ buffer: Buffer, _ boxed: Swift.Bool) {
            switch self {
            case .cardSticker(let _data):
                if boxed {
                    buffer.appendInt32(-218035014)
                }
                _data.coordinates.serialize(buffer, true)
                _data.nft.serialize(buffer, true)
                break
            }
        }

        public func descriptionFields() -> (String, [(String, ConstructorParameterDescription)]) {
            switch self {
            case .cardSticker(let _data):
                return ("cardSticker", [("coordinates", ConstructorParameterDescription(_data.coordinates)), ("nft", ConstructorParameterDescription(_data.nft))])
            }
        }

        public static func parse_cardSticker(_ reader: BufferReader) -> CardSticker? {
            var _1: Api.MediaAreaCoordinates?
            if let signature = reader.readInt32() {
                _1 = Api.parse(reader, signature: signature) as? Api.MediaAreaCoordinates
            }
            var _2: Api.wallet.NftItem?
            if let signature = reader.readInt32() {
                _2 = Api.parse(reader, signature: signature) as? Api.wallet.NftItem
            }
            let _c1 = _1 != nil
            let _c2 = _2 != nil
            if _c1 && _c2 {
                return Api.wallet.CardSticker.cardSticker(Cons_cardSticker(coordinates: _1!, nft: _2!))
            }
            else {
                return nil
            }
        }
    }
}
