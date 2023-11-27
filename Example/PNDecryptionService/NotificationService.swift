import UserNotifications
import Web3Wallet
import WalletConnectNotify
import Intents
import Mixpanel

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNNotificationContent?
    private let notifyTags: [UInt] = [4002]
    private let w3wTags: [UInt] = [1100, 1108, 3000]

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        self.bestAttemptContent = request.content

        log("didReceive(_:) fired")
        

        if let content = bestAttemptContent,
           let topic = content.userInfo["topic"] as? String,
           let ciphertext = content.userInfo["message"] as? String,
           let tag = content.userInfo["tag"] as? UInt {

            if notifyTags.contains(tag) {
                let mutableContent = handleNotifyNotification(content: content, topic: topic, ciphertext: ciphertext)
                contentHandler(mutableContent)
            } else if w3wTags.contains(tag) {
                let mutableContent = handleWeb3WalletNotification(content: content, topic: topic, tag: tag, ciphertext: ciphertext)
                contentHandler(mutableContent)
            } else {
                // Handle default case
            }
        }
    }

    private func handleWeb3WalletNotification(content: UNNotificationContent, topic: String, tag: UInt, ciphertext: String) -> UNMutableNotificationContent {

        do {
            let web3WalletDecryptionService = try Web3WalletDecryptionService(groupIdentifier: "group.com.walletconnect.sdk")

//            let rpcRequest = try web3WalletDecryptionService.decryptMessage(topic: topic, ciphertext: ciphertext)

            let metadata = web3WalletDecryptionService.getMetadata(topic: topic)

            let mutableContent = content.mutableCopy() as! UNMutableNotificationContent

            mutableContent.title = "rpcRequest.method"

            mutableContent.subtitle = metadata?.url ?? ""

            return mutableContent
        } catch {
            let mutableContent = content.mutableCopy() as! UNMutableNotificationContent
            mutableContent.title = "Error"
            mutableContent.body = error.localizedDescription

            return mutableContent
        }
    }


    private func handleNotifyNotification(content: UNNotificationContent, topic: String, ciphertext: String) -> UNMutableNotificationContent {
        do {
            let service = NotifyDecryptionService(groupIdentifier: "group.com.walletconnect.sdk")
            let (pushMessage, account) = try service.decryptMessage(topic: topic, ciphertext: ciphertext)

            log("message decrypted", account: account, topic: topic, message: pushMessage)

            let updatedContent = handle(content: content, pushMessage: pushMessage, topic: topic)

            let mutableContent = updatedContent.mutableCopy() as! UNMutableNotificationContent
            mutableContent.title = pushMessage.title
            mutableContent.subtitle = pushMessage.url
            mutableContent.body = pushMessage.body

            log("message handled", account: account, topic: topic, message: pushMessage)

            return mutableContent
        } catch {
            log("error: \(error.localizedDescription)")

            let mutableContent = content.mutableCopy() as! UNMutableNotificationContent
            mutableContent.title = "Error"
            mutableContent.body = error.localizedDescription

            return mutableContent
        }
    }


    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }


}

private extension NotificationService {

    func handle(content: UNNotificationContent, pushMessage: NotifyMessage, topic: String) -> UNNotificationContent {
        do {
            let iconUrl = try pushMessage.icon.asURL()

            let senderThumbnailImageData = try Data(contentsOf: iconUrl)
            let senderThumbnailImageFileUrl = try downloadAttachment(data: senderThumbnailImageData, fileName: iconUrl.lastPathComponent)
            let senderThumbnailImageFileData = try Data(contentsOf: senderThumbnailImageFileUrl)
            let senderAvatar = INImage(imageData: senderThumbnailImageFileData)

            var personNameComponents = PersonNameComponents()
            personNameComponents.nickname = pushMessage.title

            let senderPerson = INPerson(
                personHandle: INPersonHandle(value: topic, type: .unknown),
                nameComponents: personNameComponents,
                displayName: pushMessage.title,
                image: senderAvatar,
                contactIdentifier: nil,
                customIdentifier: topic,
                isMe: false,
                suggestionType: .none
            )

            let selfPerson = INPerson(
                personHandle: INPersonHandle(value: "0", type: .unknown),
                nameComponents: nil,
                displayName: nil,
                image: nil,
                contactIdentifier: nil,
                customIdentifier: nil,
                isMe: true,
                suggestionType: .none
            )

            let incomingMessagingIntent = INSendMessageIntent(
                recipients: [selfPerson],
                outgoingMessageType: .outgoingMessageText,
                content: pushMessage.body,
                speakableGroupName: nil,
                conversationIdentifier: pushMessage.type,
                serviceName: nil,
                sender: senderPerson,
                attachments: []
            )

            incomingMessagingIntent.setImage(senderAvatar, forParameterNamed: \.sender)

            let interaction = INInteraction(intent: incomingMessagingIntent, response: nil)
            interaction.direction = .incoming
            interaction.donate(completion: nil)

            return try content.updating(from: incomingMessagingIntent)
        } 
        catch {
            return content
        }
    }

    func downloadAttachment(data: Data, fileName: String) throws -> URL {
        let fileManager = FileManager.default
        let tmpSubFolderName = ProcessInfo.processInfo.globallyUniqueString
        let tmpSubFolderURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(tmpSubFolderName, isDirectory: true)

        try fileManager.createDirectory(at: tmpSubFolderURL, withIntermediateDirectories: true, attributes: nil)

        let fileURL = tmpSubFolderURL.appendingPathComponent(fileName)
        try data.write(to: fileURL)

        return fileURL
    }

    func log(_ event: String, account: Account? = nil, topic: String? = nil, message: NotifyMessage? = nil) {
        let keychain = GroupKeychainStorage(serviceIdentifier: "group.com.walletconnect.sdk")
        
        guard let clientId: String = try? keychain.read(key: "clientId") else {
            return
        }

        guard let token = InputConfig.mixpanelToken, !token.isEmpty  else { return }

        Mixpanel.initialize(token: token, trackAutomaticEvents: true)

        if let account {
            let mixpanel = Mixpanel.mainInstance()
            mixpanel.alias = account.absoluteString
            mixpanel.identify(distinctId: clientId)
            mixpanel.people.set(properties: ["$name": account.absoluteString, "account": account.absoluteString])
        }

        Mixpanel.mainInstance().track(
            event: "💬 APNS: " + event,
            properties: [
                "title": message?.title,
                "body": message?.body,
                "icon": message?.icon,
                "url": message?.url,
                "type": message?.type,
                "topic": topic,
                "source": "NotificationService"
            ]
        )
    }
}
