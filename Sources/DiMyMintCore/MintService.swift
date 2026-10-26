import Crypto
import Foundation
import DiMyPaymentTypes

public struct MintConfiguration: Sendable {
    public let mintKeyID: String

    public init(mintKeyID: String = "dev-mint-key-1") {
        self.mintKeyID = mintKeyID
    }
}

public struct SpentEntry: Codable, Hashable, Sendable {
    public let serial: String
    public let bundleHash: String
    public let merchantID: String
    public let spentAt: Date

    public init(serial: String, bundleHash: String, merchantID: String, spentAt: Date) {
        self.serial = serial
        self.bundleHash = bundleHash
        self.merchantID = merchantID
        self.spentAt = spentAt
    }
}

public protocol SpentSetStore: Sendable {
    func contains(serial: String) async throws -> Bool
    func insert(serial: String, bundleHash: String, merchantID: String) async throws
}

public actor InMemorySpentSetStore: SpentSetStore {
    private var entries: [String: SpentEntry] = [:]

    public init() {}

    public func contains(serial: String) async throws -> Bool {
        entries[serial] != nil
    }

    public func insert(serial: String, bundleHash: String, merchantID: String) async throws {
        entries[serial] = SpentEntry(
            serial: serial,
            bundleHash: bundleHash,
            merchantID: merchantID,
            spentAt: Date()
        )
    }

    public func count() -> Int {
        entries.count
    }
}

public protocol MintSigner: Sendable {
    func signBlindedMessage(_ blindedMessage: String, mintKeyID: String) -> String
    func signReceipt(
        bundleHash: String,
        merchantID: String,
        merchantCreditRef: String,
        issuedAt: Date,
        mintKeyID: String
    ) -> String
}

public struct DevelopmentMintSigner: MintSigner {
    public init() {}

    public func signBlindedMessage(_ blindedMessage: String, mintKeyID: String) -> String {
        digestHex("blind|\(mintKeyID)|\(blindedMessage)")
    }

    public func signReceipt(
        bundleHash: String,
        merchantID: String,
        merchantCreditRef: String,
        issuedAt: Date,
        mintKeyID: String
    ) -> String {
        let ts = ISO8601DateFormatter().string(from: issuedAt)
        return digestHex("receipt|\(mintKeyID)|\(merchantID)|\(merchantCreditRef)|\(bundleHash)|\(ts)")
    }

    private func digestHex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct MintMetrics: Codable, Hashable, Sendable {
    public let issuedLiabilitiesMinorUnits: UInt64
    public let redeemedMinorUnits: UInt64
    public let outstandingMinorUnits: UInt64

    public init(issuedLiabilitiesMinorUnits: UInt64, redeemedMinorUnits: UInt64, outstandingMinorUnits: UInt64) {
        self.issuedLiabilitiesMinorUnits = issuedLiabilitiesMinorUnits
        self.redeemedMinorUnits = redeemedMinorUnits
        self.outstandingMinorUnits = outstandingMinorUnits
    }
}

public actor MintService {
    private let configuration: MintConfiguration
    private let spentSetStore: any SpentSetStore
    private let signer: any MintSigner

    private var issuedLiabilitiesMinorUnits: UInt64 = 0
    private var redeemedMinorUnits: UInt64 = 0

    public init(
        configuration: MintConfiguration = MintConfiguration(),
        spentSetStore: any SpentSetStore = InMemorySpentSetStore(),
        signer: any MintSigner = DevelopmentMintSigner()
    ) {
        self.configuration = configuration
        self.spentSetStore = spentSetStore
        self.signer = signer
    }

    public func issue(_ request: IssueRequest) async throws -> IssueResponse {
        let signatures = request.requests.map { item in
            BlindSignature(
                denomMinorUnits: item.denomMinorUnits,
                blindedSignature: signer.signBlindedMessage(item.blindedMessage, mintKeyID: item.mintKeyID),
                mintKeyID: item.mintKeyID
            )
        }

        let debitedMinorUnits = request.requests.reduce(0) { $0 + $1.denomMinorUnits }
        issuedLiabilitiesMinorUnits += debitedMinorUnits

        return IssueResponse(
            signatures: signatures,
            debitedMinorUnits: debitedMinorUnits,
            issuedAt: Date()
        )
    }

    public func redeem(_ request: RedeemRequest) async throws -> RedeemResponse {
        let expectedHash = try BundleHasher.hash(bundle: request.bundle)
        guard expectedHash == request.bundleHash else {
            return .rejected(.invalidBundleHash)
        }

        for coin in request.bundle.coins {
            if coin.signature.isEmpty {
                return .rejected(.invalidCoinSignature)
            }

            let alreadySpent = try await spentSetStore.contains(serial: coin.serial)
            if alreadySpent {
                return .rejected(.doubleSpend)
            }
        }

        for coin in request.bundle.coins {
            try await spentSetStore.insert(
                serial: coin.serial,
                bundleHash: request.bundleHash,
                merchantID: request.merchantID
            )
        }

        redeemedMinorUnits += request.bundle.totalMinorUnits

        let issuedAt = Date()
        let merchantCreditRef = UUID().uuidString
        let signature = signer.signReceipt(
            bundleHash: request.bundleHash,
            merchantID: request.merchantID,
            merchantCreditRef: merchantCreditRef,
            issuedAt: issuedAt,
            mintKeyID: configuration.mintKeyID
        )

        let receipt = SpendReceipt(
            bundleHash: request.bundleHash,
            merchantCreditRef: merchantCreditRef,
            merchantID: request.merchantID,
            mintKeyID: configuration.mintKeyID,
            issuedAt: issuedAt,
            signature: signature
        )

        return .accepted(receipt)
    }

    public func metrics() -> MintMetrics {
        MintMetrics(
            issuedLiabilitiesMinorUnits: issuedLiabilitiesMinorUnits,
            redeemedMinorUnits: redeemedMinorUnits,
            outstandingMinorUnits: issuedLiabilitiesMinorUnits &- redeemedMinorUnits
        )
    }
}
