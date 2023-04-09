import Foundation
import NIOFoundationCompat

public enum RequestBody {
    
    public struct CreateDM: Sendable, Codable, ValidatablePayload {
        public var recipient_id: String
        
        @inlinable
        public init(recipient_id: String) {
            self.recipient_id = recipient_id
        }
        
        public func validations() -> Validation { }
    }
    
    /// An attachment object, but for sending.
    /// https://discord.com/developers/docs/resources/channel#attachment-object
    public struct AttachmentSend: Sendable, Codable, ValidatablePayload {
        /// When sending, `id` is the index of this attachment in the `files` you provide.
        public var id: String
        public var filename: String?
        public var description: String?
        public var content_type: String?
        public var size: Int?
        public var url: String?
        public var proxy_url: String?
        public var height: Int?
        public var width: Int?
        public var ephemeral: Bool?
        
        /// `index` is the index of this attachment in the `files` you provide.
        public init(index: UInt, filename: String? = nil, description: String? = nil, content_type: String? = nil, size: Int? = nil, url: String? = nil, proxy_url: String? = nil, height: Int? = nil, width: Int? = nil, ephemeral: Bool? = nil) {
            self.id = "\(index)"
            self.filename = filename
            self.description = description
            self.content_type = content_type
            self.size = size
            self.url = url
            self.proxy_url = proxy_url
            self.height = height
            self.width = width
            self.ephemeral = ephemeral
        }
        
        public func validations() -> Validation {
            validateCharacterCountDoesNotExceed(description, max: 1_024, name: "description")
        }
    }
    
    /// https://discord.com/developers/docs/interactions/receiving-and-responding#interaction-response-object
    public struct InteractionResponse: Sendable, Codable, MultipartEncodable, ValidatablePayload {
        
        /// https://discord.com/developers/docs/interactions/receiving-and-responding#interaction-response-object-interaction-callback-type
        public enum Kind: Int, Sendable, Codable, ToleratesIntDecodeMarker {
            /// For ping-pong.
            case pong = 1
            /// Normal response.
            case channelMessageWithSource = 4
            /// Accepts a message to answer later. Shows a loading indicator.
            case deferredChannelMessageWithSource = 5
            /// Accepts a message to answer later. Doesn't show any loading indicators.
            case deferredUpdateMessage = 6
            /// Edit a message.
            case updateMessage = 7
            /// Auto-complete result for application commands.
            case applicationCommandAutoCompleteResult = 8
            /// A modal.
            case modal = 9
        }
        
        /// https://discord.com/developers/docs/interactions/receiving-and-responding#interaction-response-object-interaction-callback-data-structure
        public struct CallbackData: Sendable, Codable, MultipartEncodable, ValidatablePayload {
            public var tts: Bool?
            public var content: String?
            public var embeds: [Embed]?
            public var allowedMentions: DiscordChannel.AllowedMentions?
            public var flags: IntBitField<DiscordChannel.Message.Flag>?
            public var components: [Interaction.ActionRow]?
            public var attachments: [AttachmentSend]?
            public var files: [RawFile]?
            
            enum CodingKeys: String, CodingKey {
                case tts
                case content
                case embeds
                case allowedMentions
                case flags
                case components
                case attachments
            }
            
            public init(tts: Bool? = nil, content: String? = nil, embeds: [Embed]? = nil, allowedMentions: DiscordChannel.AllowedMentions? = nil, flags: [DiscordChannel.Message.Flag]? = nil, components: [Interaction.ActionRow]? = nil, attachments: [AttachmentSend]? = nil, files: [RawFile]? = nil) {
                self.tts = tts
                self.content = content
                self.embeds = embeds
                self.allowedMentions = allowedMentions
                self.flags = flags.map { .init($0) }
                self.components = components
                self.attachments = attachments
                self.files = files
            }
            
            public func validations() -> Validation {
                validateElementCountDoesNotExceed(embeds, max: 10, name: "embeds")
                allowedMentions?.validations()
                validateOnlyContains(
                    flags?.values,
                    name: "flags",
                    reason: "Can only contain 'suppressEmbeds' and 'ephemeral'",
                    where: { [.suppressEmbeds, .ephemeral].contains($0) }
                )
                attachments?.validations()
                embeds?.validations()
            }
        }
        
        enum CodingKeys: String, CodingKey {
            case type
            case data
        }
        
        public var type: Kind
        public var data: CallbackData?
        public var files: [RawFile]? {
            data?.files
        }
        
        public init(type: Kind, data: CallbackData? = nil) {
            self.type = type
            self.data = data
        }
        
        public func validations() -> Validation {
            data?.validations()
        }
    }
    
    public struct ImageData: Sendable, Codable {
        public var file: RawFile
        
        public init(file: RawFile) {
            self.file = file
        }
        
        public init(from decoder: Decoder) throws {
            let string = try String(from: decoder)
            guard let file = ImageData.decodeFromString(string) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "'\(string)' can't be decoded into a file"
                ))
            }
            self.file = file
        }
        
        public func encode(to encoder: Encoder) throws {
            guard let string = self.encodeToString() else {
                throw EncodingError.invalidValue(
                    file, .init(
                        codingPath: encoder.codingPath,
                        debugDescription: "Can't base64 encode the file"
                    )
                )
            }
            var container = encoder.singleValueContainer()
            try container.encode(string)
        }
        
        static func decodeFromString(_ string: String) -> RawFile? {
            var filename: String?
            guard string.hasPrefix("data:") else {
                return nil
            }
            guard let semicolon = string.firstIndex(of: ";") else {
                return nil
            }
            let type = string[string.startIndex..<semicolon].dropFirst(5)
            let typeComps = type.split(separator: "/", maxSplits: 1)
            if typeComps.count == 2,
               let ext = fileExtensionMediaTypeMapping.first(
                where: { $1.0 == typeComps[0] && $1.1 == typeComps[1] }
               )?.key {
                filename = "unknown.\(ext)"
            }
            guard string[semicolon...].hasPrefix(";base64,") else {
                return nil
            }
            let encodedString = string[semicolon...].dropFirst(8)
            guard let data = Data(base64Encoded: String(encodedString)) else {
                return nil
            }
            return .init(data: .init(data: data), filename: filename ?? "unknown")
        }
        
        func encodeToString() -> String? {
            guard let type = file.type else { return nil }
            let data = Data(buffer: file.data, byteTransferStrategy: .noCopy)
            let encoded = data.base64EncodedString()
            return "data:\(type);base64,\(encoded)"
        }
    }
    
    /// https://discord.com/developers/docs/resources/guild#create-guild-role-json-params
    public struct CreateGuildRole: Sendable, Codable, ValidatablePayload {
        public var name: String?
        public var permissions: StringBitField<Permission>?
        public var color: DiscordColor?
        public var hoist: Bool?
        public var icon: ImageData?
        public var unicode_emoji: String?
        public var mentionable: Bool?
        
        /// `icon` and `unicode_emoji` require `roleIcons` guild feature,
        /// which most guild don't have.
        /// No fields are required. If you send an empty payload, you'll get a basic role
        /// with a name like "new role".
        public init(name: String? = nil, permissions: [Permission]? = nil, color: DiscordColor? = nil, hoist: Bool? = nil, icon: ImageData? = nil, unicode_emoji: String? = nil, mentionable: Bool? = nil) {
            self.name = name
            self.permissions = permissions.map { .init($0) }
            self.color = color
            self.hoist = hoist
            self.icon = icon
            self.unicode_emoji = unicode_emoji
            self.mentionable = mentionable
        }
        
        public func validations() -> Validation {
            validateCharacterCountDoesNotExceed(name, max: 1_000, name: "name")
        }
    }
    
    /// https://discord.com/developers/docs/resources/channel#create-message-jsonform-params
    public struct CreateMessage: Sendable, Codable, MultipartEncodable, ValidatablePayload {
        public var content: String?
        public var nonce: StringOrInt?
        public var tts: Bool?
        public var embeds: [Embed]?
        public var allowed_mentions: DiscordChannel.AllowedMentions?
        public var message_reference: DiscordChannel.Message.MessageReference?
        public var components: [Interaction.ActionRow]?
        public var sticker_ids: [String]?
        public var files: [RawFile]?
        public var attachments: [AttachmentSend]?
        public var flags: IntBitField<DiscordChannel.Message.Flag>?
        
        enum CodingKeys: String, CodingKey {
            case content
            case nonce
            case tts
            case embeds
            case allowed_mentions
            case message_reference
            case components
            case sticker_ids
            case attachments
            case flags
        }
        
        public init(content: String? = nil, nonce: StringOrInt? = nil, tts: Bool? = nil, embeds: [Embed]? = nil, allowed_mentions: DiscordChannel.AllowedMentions? = nil, message_reference: DiscordChannel.Message.MessageReference? = nil, components: [Interaction.ActionRow]? = nil, sticker_ids: [String]? = nil, files: [RawFile]? = nil, attachments: [AttachmentSend]? = nil, flags: [DiscordChannel.Message.Flag]? = nil) {
            self.content = content
            self.nonce = nonce
            self.tts = tts
            self.embeds = embeds
            self.allowed_mentions = allowed_mentions
            self.message_reference = message_reference
            self.components = components
            self.sticker_ids = sticker_ids
            self.files = files
            self.attachments = attachments
            self.flags = flags.map { .init($0) }
        }
        
        public func validations() -> Validation {
            validateElementCountDoesNotExceed(embeds, max: 10, name: "embeds")
            validateElementCountDoesNotExceed(sticker_ids, max: 3, name: "sticker_ids")
            validateCharacterCountDoesNotExceed(content, max: 2_000, name: "content")
            validateCharacterCountDoesNotExceed(nonce?.asString, max: 25, name: "nonce")
            allowed_mentions?.validations()
            validateAtLeastOneIsNotEmpty(
                content?.isEmpty,
                embeds?.isEmpty,
                sticker_ids?.isEmpty,
                components?.isEmpty,
                files?.isEmpty,
                names: "content", "embeds", "sticker_ids", "components", "files"
            )
            validateCombinedCharacterCountDoesNotExceed(
                embeds?.reduce(into: 0, { $0 += $1.contentLength }),
                max: 6_000,
                names: "embeds"
            )
            validateOnlyContains(
                flags?.values,
                name: "flags",
                reason: "Can only contain 'suppressEmbeds' or 'suppressNotifications'",
                where: { [.suppressEmbeds, .suppressNotifications].contains($0) }
            )
            attachments?.validations()
            embeds?.validations()
        }
    }
    
    /// https://discord.com/developers/docs/resources/channel#edit-message-jsonform-params
    public struct EditMessage: Sendable, Codable, MultipartEncodable, ValidatablePayload {
        public var content: String?
        public var embeds: [Embed]?
        public var flags: IntBitField<DiscordChannel.Message.Flag>?
        public var allowed_mentions: DiscordChannel.AllowedMentions?
        public var components: [Interaction.ActionRow]?
        public var files: [RawFile]?
        public var attachments: [AttachmentSend]?
        
        enum CodingKeys: String, CodingKey {
            case content
            case embeds
            case flags
            case allowed_mentions
            case components
            case attachments
        }
        
        public init(content: String? = nil, embeds: [Embed]? = nil, flags: [DiscordChannel.Message.Flag]? = nil, allowed_mentions: DiscordChannel.AllowedMentions? = nil, components: [Interaction.ActionRow]? = nil, files: [RawFile]? = nil, attachments: [AttachmentSend]? = nil) {
            self.content = content
            self.embeds = embeds
            self.flags = flags.map { .init($0) }
            self.allowed_mentions = allowed_mentions
            self.components = components
            self.files = files
            self.attachments = attachments
        }
        
        public func validations() -> Validation {
            validateElementCountDoesNotExceed(embeds, max: 10, name: "embeds")
            validateCharacterCountDoesNotExceed(content, max: 2_000, name: "content")
            validateCombinedCharacterCountDoesNotExceed(
                embeds?.reduce(into: 0, { $0 += $1.contentLength }),
                max: 6_000,
                names: "embeds"
            )
            validateOnlyContains(
                flags?.values,
                name: "flags",
                reason: "Can only contain 'suppressEmbeds'",
                where: { $0 == .suppressEmbeds }
            )
            allowed_mentions?.validations()
            attachments?.validations()
            embeds?.validations()
        }
    }
    
    /// https://discord.com/developers/docs/resources/webhook#execute-webhook-jsonform-params
    public struct ExecuteWebhook: Sendable, Codable, MultipartEncodable, ValidatablePayload {
        public var content: String?
        public var username: String?
        public var avatar_url: String?
        public var tts: Bool?
        public var embeds: [Embed]?
        public var allowed_mentions: DiscordChannel.AllowedMentions?
        public var components: [Interaction.ActionRow]?
        public var files: [RawFile]?
        public var attachments: [AttachmentSend]?
        public var flags: IntBitField<DiscordChannel.Message.Flag>?
        public var thread_name: String?
        
        enum CodingKeys: CodingKey {
            case content
            case username
            case avatar_url
            case tts
            case embeds
            case allowed_mentions
            case components
            case attachments
            case flags
            case thread_name
        }
        
        public init(content: String? = nil, username: String? = nil, avatar_url: String? = nil, tts: Bool? = nil, embeds: [Embed]? = nil, allowed_mentions: DiscordChannel.AllowedMentions? = nil, components: [Interaction.ActionRow]? = nil, files: [RawFile]? = nil, attachments: [AttachmentSend]? = nil, flags: IntBitField<DiscordChannel.Message.Flag>? = nil, thread_name: String? = nil) {
            self.content = content
            self.username = username
            self.avatar_url = avatar_url
            self.tts = tts
            self.embeds = embeds
            self.allowed_mentions = allowed_mentions
            self.components = components
            self.files = files
            self.attachments = attachments
            self.flags = flags
            self.thread_name = thread_name
        }
        
        public func validations() -> Validation {
            validateElementCountDoesNotExceed(embeds, max: 10, name: "embeds")
            validateCharacterCountDoesNotExceed(content, max: 2_000, name: "content")
            validateAtLeastOneIsNotEmpty(
                content?.isEmpty, components?.isEmpty, files?.isEmpty, embeds?.isEmpty,
                names: "content", "components", "files", "embeds"
            )
            validateCombinedCharacterCountDoesNotExceed(
                embeds?.reduce(into: 0, { $0 += $1.contentLength }),
                max: 6_000,
                names: "embeds"
            )
            validateOnlyContains(
                flags?.values,
                name: "flags",
                reason: "Can only contain 'suppressEmbeds'",
                where: { $0 == .suppressEmbeds }
            )
            allowed_mentions?.validations()
            attachments?.validations()
            embeds?.validations()
        }
    }
    
    /// https://discord.com/developers/docs/resources/webhook#create-webhook-json-params
    public struct CreateWebhook: Sendable, Codable, ValidatablePayload {
        public var name: String
        public var avatar: ImageData?
        
        public init(name: String, avatar: ImageData? = nil) {
            self.name = name
            self.avatar = avatar
        }
        
        public func validations() -> Validation {
            validateCharacterCountInRange(name, min: 1, max: 80, name: "name")
            validateCaseInsensitivelyDoesNotContain(
                name,
                name: "name",
                values: ["clyde", "discord"],
                reason: "name can't contain 'clyde' or 'discord' (case-insensitive)"
            )
        }
    }
    
    /// https://discord.com/developers/docs/resources/webhook#modify-webhook-with-token
    public struct ModifyWebhook: Sendable, Codable, ValidatablePayload {
        public var name: String?
        public var avatar: ImageData?
        
        public init(name: String? = nil, avatar: ImageData? = nil) {
            self.name = name
            self.avatar = avatar
        }
        
        public func validations() -> Validation { }
    }
    
    /// https://discord.com/developers/docs/resources/webhook#modify-webhook-json-params
    public struct ModifyGuildWebhook: Sendable, Codable, ValidatablePayload {
        public var name: String?
        public var avatar: ImageData?
        public var channel_id: String?
        
        public init(name: String, avatar: ImageData? = nil, channel_id: String? = nil) {
            self.name = name
            self.avatar = avatar
            self.channel_id = channel_id
        }
        
        public func validations() -> Validation { }
    }
    
    /// https://discord.com/developers/docs/resources/webhook#edit-webhook-message-jsonform-params
    public struct EditWebhookMessage: Sendable, Codable, MultipartEncodable, ValidatablePayload {
        public var content: String?
        public var embeds: [Embed]?
        public var allowed_mentions: DiscordChannel.AllowedMentions?
        public var components: [Interaction.ActionRow]?
        public var files: [RawFile]?
        public var attachments: [AttachmentSend]?
        
        enum CodingKeys: String, CodingKey {
            case content
            case embeds
            case allowed_mentions
            case components
            case attachments
        }
        
        public init(content: String? = nil, embeds: [Embed]? = nil, allowed_mentions: DiscordChannel.AllowedMentions? = nil, components: [Interaction.ActionRow]? = nil, files: [RawFile]? = nil, attachments: [AttachmentSend]? = nil) {
            self.content = content
            self.embeds = embeds
            self.allowed_mentions = allowed_mentions
            self.components = components
            self.files = files
            self.attachments = attachments
        }
        
        public func validations() -> Validation {
            validateElementCountDoesNotExceed(embeds, max: 10, name: "embeds")
            validateCharacterCountDoesNotExceed(content, max: 2_000, name: "content")
            validateCombinedCharacterCountDoesNotExceed(
                embeds?.reduce(into: 0, { $0 += $1.contentLength }),
                max: 6_000,
                names: "embeds"
            )
            allowed_mentions?.validations()
            attachments?.validations()
            embeds?.validations()
        }
    }
    
    public struct CreateThreadFromMessage: Sendable, Codable, ValidatablePayload {
        public var name: String
        public var auto_archive_duration: DiscordChannel.AutoArchiveDuration?
        public var rate_limit_per_user: Int?
        
        public init(
            name: String,
            auto_archive_duration: DiscordChannel.AutoArchiveDuration? = nil,
            rate_limit_per_user: Int? = nil
        ) {
            self.name = name
            self.auto_archive_duration = auto_archive_duration
            self.rate_limit_per_user = rate_limit_per_user
        }
        
        public func validations() -> Validation {
            validateCharacterCountInRange(name, min: 1, max: 100, name: "name")
            validateNumberInRange(
                rate_limit_per_user,
                min: 0,
                max: 21_600,
                name: "rate_limit_per_user"
            )
        }
    }
    
    public struct CreateThreadWithoutMessage: Sendable, Codable, ValidatablePayload {
        public var name: String
        public var auto_archive_duration: DiscordChannel.AutoArchiveDuration?
        public var type: ThreadKind
        public var invitable: Bool?
        public var rate_limit_per_user: Int?
        
        public init(
            name: String,
            auto_archive_duration: DiscordChannel.AutoArchiveDuration? = nil,
            type: ThreadKind,
            invitable: Bool? = nil,
            rate_limit_per_user: Int? = nil
        ) {
            self.name = name
            self.auto_archive_duration = auto_archive_duration
            self.type = type
            self.invitable = invitable
            self.rate_limit_per_user = rate_limit_per_user
        }
        
        public func validations() -> Validation {
            validateCharacterCountInRange(name, min: 1, max: 100, name: "name")
            validateNumberInRange(
                rate_limit_per_user,
                min: 0,
                max: 21_600,
                name: "rate_limit_per_user"
            )
        }
    }
    
    public struct CreateThreadInForumChannel: Sendable, Codable, ValidatablePayload {
        
        /// https://discord.com/developers/docs/resources/channel#start-thread-in-forum-channel-forum-thread-message-params-object
        public struct ForumMessage: Sendable, Codable, MultipartEncodable, ValidatablePayload {
            public var content: String?
            public var embeds: [Embed]?
            public var allowed_mentions: DiscordChannel.AllowedMentions?
            public var components: [Interaction.ActionRow]?
            public var sticker_ids: [String]?
            public var files: [RawFile]?
            public var attachments: [AttachmentSend]?
            public var flags: IntBitField<DiscordChannel.Message.Flag>?
            
            enum CodingKeys: String, CodingKey {
                case content
                case embeds
                case allowed_mentions
                case components
                case sticker_ids
                case attachments
                case flags
            }
            
            public init(content: String? = nil, embeds: [Embed]? = nil, allowed_mentions: DiscordChannel.AllowedMentions? = nil, components: [Interaction.ActionRow]? = nil, sticker_ids: [String]? = nil, files: [RawFile]? = nil, attachments: [AttachmentSend]? = nil, flags: [DiscordChannel.Message.Flag]? = nil) {
                self.content = content
                self.embeds = embeds
                self.allowed_mentions = allowed_mentions
                self.components = components
                self.sticker_ids = sticker_ids
                self.files = files
                self.attachments = attachments
                self.flags = flags.map { .init($0) }
            }
            
            public func validations() -> Validation {
                validateElementCountDoesNotExceed(embeds, max: 10, name: "embeds")
                validateElementCountDoesNotExceed(sticker_ids, max: 3, name: "sticker_ids")
                validateCharacterCountDoesNotExceed(content, max: 2_000, name: "content")
                allowed_mentions?.validations()
                validateAtLeastOneIsNotEmpty(
                    content?.isEmpty,
                    embeds?.isEmpty,
                    sticker_ids?.isEmpty,
                    components?.isEmpty,
                    files?.isEmpty,
                    names: "content", "embeds", "sticker_ids", "components", "files"
                )
                validateCombinedCharacterCountDoesNotExceed(
                    embeds?.reduce(into: 0, { $0 += $1.contentLength }),
                    max: 6_000,
                    names: "embeds"
                )
                validateOnlyContains(
                    flags?.values,
                    name: "flags",
                    reason: "Can only contain 'suppressEmbeds' or 'suppressNotifications'",
                    where: { [.suppressEmbeds, .suppressNotifications].contains($0) }
                )
                attachments?.validations()
                embeds?.validations()
            }
        }
        
        public var name: String
        public var auto_archive_duration: DiscordChannel.AutoArchiveDuration?
        public var rate_limit_per_user: Int?
        public var message: ForumMessage
        public var applied_tags: [String]?
        
        public init(
            name: String,
            auto_archive_duration: DiscordChannel.AutoArchiveDuration? = nil,
            rate_limit_per_user: Int? = nil,
            message: ForumMessage,
            applied_tags: [String]? = nil
        ) {
            self.name = name
            self.auto_archive_duration = auto_archive_duration
            self.rate_limit_per_user = rate_limit_per_user
            self.message = message
            self.applied_tags = applied_tags
        }
        
        public func validations() -> Validation {
            validateCharacterCountInRange(name, min: 1, max: 100, name: "name")
            validateNumberInRange(
                rate_limit_per_user,
                min: 0,
                max: 21_600,
                name: "rate_limit_per_user"
            )
            self.message.validations()
        }
    }
    
    public struct ApplicationCommandCreate: Sendable, Codable, ValidatablePayload {
        public var name: String
        public var name_localizations: DiscordLocaleDict<String>?
        public var description: String?
        public var description_localizations: DiscordLocaleDict<String>?
        public var options: [ApplicationCommand.Option]?
        public var default_member_permissions: StringBitField<Permission>?
        public var dm_permission: Bool?
        public var type: ApplicationCommand.Kind?
        public var nsfw: Bool?
        
        public init(name: String, name_localizations: [DiscordLocale: String]? = nil, description: String? = nil, description_localizations: [DiscordLocale: String]? = nil, options: [ApplicationCommand.Option]? = nil, default_member_permissions: [Permission]? = nil, dm_permission: Bool? = nil, type: ApplicationCommand.Kind? = nil, nsfw: Bool? = nil) {
            self.name = name
            self.name_localizations = .init(name_localizations)
            self.description = description
            self.description_localizations = .init(description_localizations)
            self.options = options
            self.default_member_permissions = default_member_permissions.map({ .init($0) })
            self.dm_permission = dm_permission
            self.type = type
            self.nsfw = nsfw
        }
        
        public func validations() -> Validation {
            validateHasPrecondition(
                condition: options.containsAnything,
                allowedIf: (type ?? .chatInput) == .chatInput,
                name: "options",
                reason: "'options' is only allowed if 'type' is 'chatInput'"
            )
            validateHasPrecondition(
                condition: description.containsAnything
                || (description_localizations?.values).containsAnything,
                allowedIf: (type ?? .chatInput) == .chatInput,
                name: "description+description_localizations",
                reason: "'description' or 'description_localizations' are only allowed if 'type' is 'chatInput'"
            )
            validateElementCountDoesNotExceed(options, max: 25, name: "options")
            validateCharacterCountInRange(name, min: 1, max: 32, name: "name")
            validateCharacterCountDoesNotExceed(description, max: 100, name: "description")
            for (_, value) in name_localizations?.values ?? [:] {
                validateCharacterCountInRange(value, min: 1, max: 32, name: "name_localizations.name")
            }
            for (_, value) in description_localizations?.values ?? [:] {
                validateCharacterCountInRange(value, min: 1, max: 32, name: "description_localizations.name")
            }
            options?.validations()
        }
    }
    
    public struct ApplicationCommandEdit: Sendable, Codable, ValidatablePayload {
        public var name: String?
        public var name_localizations: DiscordLocaleDict<String>?
        public var description: String?
        public var description_localizations: DiscordLocaleDict<String>?
        public var options: [ApplicationCommand.Option]?
        public var default_member_permissions: StringBitField<Permission>?
        public var dm_permission: Bool?
        public var nsfw: Bool?
        
        public init(name: String? = nil, name_localizations: [DiscordLocale: String]? = nil, description: String? = nil, description_localizations: [DiscordLocale: String]? = nil, options: [ApplicationCommand.Option]? = nil, default_member_permissions: [Permission]? = nil, dm_permission: Bool? = nil, nsfw: Bool? = nil) {
            self.name = name
            self.name_localizations = .init(name_localizations)
            self.description = description
            self.description_localizations = .init(description_localizations)
            self.options = options
            self.default_member_permissions = default_member_permissions.map({ .init($0) })
            self.dm_permission = dm_permission
            self.nsfw = nsfw
        }
        
        public func validations() -> Validation {
            validateElementCountDoesNotExceed(options, max: 25, name: "options")
            validateCharacterCountInRange(name, min: 1, max: 32, name: "name")
            validateCharacterCountDoesNotExceed(description, max: 100, name: "description")
            for (_, value) in name_localizations?.values ?? [:] {
                validateCharacterCountInRange(value, min: 1, max: 32, name: "name_localizations.name")
            }
            for (_, value) in description_localizations?.values ?? [:] {
                validateCharacterCountInRange(value, min: 1, max: 32, name: "description_localizations.name")
            }
            options?.validations()
        }
    }
    
    public struct EditApplicationCommandPermissions: Sendable, Codable, ValidatablePayload {
        public var permissions: [GuildApplicationCommandPermissions.Permission]
        
        public init(permissions: [GuildApplicationCommandPermissions.Permission]) {
            self.permissions = permissions
        }
        
        public func validations() -> Validation { }
    }
}
