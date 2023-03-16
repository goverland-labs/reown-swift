import WalletConnectNetworking
import WalletConnectIdentity
import Foundation

class PushRequestResponder {
    enum Errors: Error {
        case recordForIdNotFound
        case malformedRequestParams
    }
    private let keyserverURL: URL
    private let identityClient: IdentityClient
    private let networkingInteractor: NetworkInteracting
    private let kms: KeyManagementService
    private let rpcHistory: RPCHistory
    private let logger: ConsoleLogging
    private let subscriptionsStore: CodableStore<PushSubscription>
    // Keychain shared with UNNotificationServiceExtension in order to decrypt PNs
    private let groupKeychainStorage: KeychainStorageProtocol


    init(keyserverURL: URL,
         networkingInteractor: NetworkInteracting,
         identityClient: IdentityClient,
         logger: ConsoleLogging,
         kms: KeyManagementService,
         groupKeychainStorage: KeychainStorageProtocol,
         rpcHistory: RPCHistory,
         subscriptionsStore: CodableStore<PushSubscription>
    ) {
        self.keyserverURL = keyserverURL
        self.identityClient = identityClient
        self.networkingInteractor = networkingInteractor
        self.logger = logger
        self.kms = kms
        self.groupKeychainStorage = groupKeychainStorage
        self.rpcHistory = rpcHistory
        self.subscriptionsStore = subscriptionsStore
    }

    func respond(requestId: RPCID) async throws {
        logger.debug("Approving Push Proposal")

        let requestRecord = try getRecord(requestId: requestId)
        let peerPublicKey = try getPeerPublicKey(for: requestRecord)
        let responseTopic = peerPublicKey.rawRepresentation.sha256().toHexString()

        let keys = try generateAgreementKeys(peerPublicKey: peerPublicKey)
        let pushTopic = keys.derivedTopic()
        let requestParams = try requestRecord.request.params!.get(PushRequestParams.self)

        try kms.setAgreementSecret(keys, topic: responseTopic)

        logger.debug("PushRequestResponder: responding on response topic \(responseTopic) \(pushTopic)")

        try kms.setAgreementSecret(keys, topic: pushTopic)

        try groupKeychainStorage.add(keys, forKey: pushTopic)

        logger.debug("Subscribing to push topic: \(pushTopic)")

        try await networkingInteractor.subscribe(topic: pushTopic)

        let response = try createJWTResponse(requestId: requestId, subscriptionAccount: requestParams.account, dappUrl: requestParams.metadata.url)

        let pushSubscription = PushSubscription(topic: pushTopic, account: requestParams.account, relay: RelayProtocolOptions(protocol: "irn", data: nil), metadata: requestParams.metadata)

        subscriptionsStore.set(pushSubscription, forKey: pushTopic)

        try await networkingInteractor.respond(topic: responseTopic, response: response, protocolMethod: PushRequestProtocolMethod(), envelopeType: .type1(pubKey: keys.publicKey.rawRepresentation))

        kms.deletePrivateKey(for: keys.publicKey.hexRepresentation)
    }

    func respondError(requestId: RPCID) async throws {
        logger.debug("PushRequestResponder - rejecting rush request")
        let requestRecord = try getRecord(requestId: requestId)
        let pairingTopic = requestRecord.topic

        try await networkingInteractor.respondError(topic: pairingTopic, requestId: requestId, protocolMethod: PushRequestProtocolMethod(), reason: PushError.rejected)
    }

    private func createJWTResponse(requestId: RPCID, subscriptionAccount: Account, dappUrl: String) throws -> RPCResponse {
        let jwtPayload = AcceptSubscriptionJWTPayload(keyserver: keyserverURL, subscriptionAccount: subscriptionAccount, dappUrl: dappUrl)
        let wrapper = try identityClient.signAndCreateWrapper(
            payload: jwtPayload,
            account: subscriptionAccount
        )
        return RPCResponse(id: requestId, result: wrapper)
    }

    private func getRecord(requestId: RPCID) throws -> RPCHistory.Record {
        guard let record = rpcHistory.get(recordId: requestId)
        else { throw Errors.recordForIdNotFound }
        return record
    }

    private func getPeerPublicKey(for record: RPCHistory.Record) throws -> AgreementPublicKey {
        guard let params = try record.request.params?.get(PushRequestParams.self)
        else { throw Errors.malformedRequestParams }

        let peerPublicKey = try AgreementPublicKey(hex: params.publicKey)
        return peerPublicKey
    }

    private func generateAgreementKeys(peerPublicKey: AgreementPublicKey) throws -> AgreementKeys {
        let selfPubKey = try kms.createX25519KeyPair()
        let keys = try kms.performKeyAgreement(selfPublicKey: selfPubKey, peerPublicKey: peerPublicKey.hexRepresentation)
        return keys
    }
}
