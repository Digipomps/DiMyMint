import Crypto
import Foundation

public enum PaymentProvider: String, Codable, Sendable {
    case stripe
    case vipps
}

public enum ProviderPaymentStatus: String, Codable, Sendable {
    case initiated
    case authorized
    case captured
    case failed
    case partiallyRefunded
    case refunded
    case disputed
    case reversed
    case settled
}

public enum CashEventType: String, Codable, Sendable {
    case paymentInitiated = "payment_initiated"
    case paymentAuthorized = "payment_authorized"
    case paymentCaptured = "payment_captured"
    case paymentFailed = "payment_failed"
    case paymentRefunded = "payment_refunded"
    case paymentDisputed = "payment_disputed"
    case paymentReversed = "payment_reversed"
    case providerFeeReported = "provider_fee_reported"
    case settlementPaid = "settlement_paid"
}

public enum WalletEventType: String, Codable, Sendable {
    case walletCreditGranted = "wallet_credit_granted"
    case walletCreditReversed = "wallet_credit_reversed"
    case walletReserved = "wallet_reserved"
    case walletReservationReleased = "wallet_reservation_released"
    case walletConsumed = "wallet_consumed"
    case walletExpired = "wallet_expired"
    case walletWriteoff = "wallet_writeoff"
    case mintIssued = "mint_issued"
    case mintIssueReversed = "mint_issue_reversed"
    case mintRedeemed = "mint_redeemed"
    case serviceDelivered = "service_delivered"
}

public enum ProductTaxBehavior: String, Codable, Sendable {
    case inclusive
    case exclusive
    case exempt
}

public struct ProductCatalogItem: Codable, Hashable, Sendable {
    public let productID: String
    public let productType: String
    public let title: String
    public let unitPriceNOKOre: Int64
    public let taxCode: String
    public let taxBehavior: ProductTaxBehavior
    public let isActive: Bool

    public init(
        productID: String,
        productType: String,
        title: String,
        unitPriceNOKOre: Int64,
        taxCode: String,
        taxBehavior: ProductTaxBehavior,
        isActive: Bool = true
    ) {
        self.productID = productID
        self.productType = productType
        self.title = title
        self.unitPriceNOKOre = unitPriceNOKOre
        self.taxCode = taxCode
        self.taxBehavior = taxBehavior
        self.isActive = isActive
    }
}

public struct StoredWallet: Codable, Hashable, Sendable {
    public let walletID: UUID
    public let customerID: String
    public let currency: String
    public let status: String
    public let createdAt: Date

    public init(
        walletID: UUID = UUID(),
        customerID: String,
        currency: String = "NOK",
        status: String = "active",
        createdAt: Date = Date()
    ) {
        self.walletID = walletID
        self.customerID = customerID
        self.currency = currency
        self.status = status
        self.createdAt = createdAt
    }
}

public struct WalletBalanceProjection: Codable, Hashable, Sendable {
    public let walletID: UUID
    public let unitName: String
    public let availableUnits: Int64
    public let reservedUnits: Int64
    public let consumedUnits: Int64
    public let availableNOKOre: Int64
    public let reservedNOKOre: Int64
    public let consumedNOKOre: Int64
    public let updatedAt: Date

    public init(
        walletID: UUID,
        unitName: String = "NOK_ORE",
        availableUnits: Int64 = 0,
        reservedUnits: Int64 = 0,
        consumedUnits: Int64 = 0,
        availableNOKOre: Int64 = 0,
        reservedNOKOre: Int64 = 0,
        consumedNOKOre: Int64 = 0,
        updatedAt: Date = Date()
    ) {
        self.walletID = walletID
        self.unitName = unitName
        self.availableUnits = availableUnits
        self.reservedUnits = reservedUnits
        self.consumedUnits = consumedUnits
        self.availableNOKOre = availableNOKOre
        self.reservedNOKOre = reservedNOKOre
        self.consumedNOKOre = consumedNOKOre
        self.updatedAt = updatedAt
    }
}

public enum WalletReservationStatus: String, Codable, Sendable {
    case active
    case released
    case consumed
    case expired
    case cancelled
}

public struct WalletReservationRecord: Codable, Hashable, Sendable {
    public let reservationID: UUID
    public let walletID: UUID
    public let customerID: String
    public let quoteID: UUID?
    public let resourceID: String?
    public let status: WalletReservationStatus
    public let reservedUnitName: String
    public let reservedUnitAmount: Int64
    public let reservedNOKOre: Int64
    public let createdAt: Date
    public let updatedAt: Date
    public let expiresAt: Date?
    public let releasedAt: Date?

    public init(
        reservationID: UUID = UUID(),
        walletID: UUID,
        customerID: String,
        quoteID: UUID?,
        resourceID: String?,
        status: WalletReservationStatus = .active,
        reservedUnitName: String = "NOK_ORE",
        reservedUnitAmount: Int64,
        reservedNOKOre: Int64,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        expiresAt: Date?,
        releasedAt: Date? = nil
    ) {
        self.reservationID = reservationID
        self.walletID = walletID
        self.customerID = customerID
        self.quoteID = quoteID
        self.resourceID = resourceID
        self.status = status
        self.reservedUnitName = reservedUnitName
        self.reservedUnitAmount = reservedUnitAmount
        self.reservedNOKOre = reservedNOKOre
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.expiresAt = expiresAt
        self.releasedAt = releasedAt
    }

    public func with(status: WalletReservationStatus, releasedAt: Date? = nil) -> WalletReservationRecord {
        WalletReservationRecord(
            reservationID: reservationID,
            walletID: walletID,
            customerID: customerID,
            quoteID: quoteID,
            resourceID: resourceID,
            status: status,
            reservedUnitName: reservedUnitName,
            reservedUnitAmount: reservedUnitAmount,
            reservedNOKOre: reservedNOKOre,
            createdAt: createdAt,
            updatedAt: Date(),
            expiresAt: expiresAt,
            releasedAt: releasedAt ?? self.releasedAt
        )
    }
}

public struct PriceQuoteRecord: Codable, Hashable, Sendable {
    public let quoteID: UUID
    public let walletID: UUID
    public let customerID: String
    public let productID: String
    public let resourceID: String?
    public let quantity: Int
    public let amountNOKOre: Int64
    public let unitName: String
    public let unitAmount: Int64
    public let taxCode: String
    public let taxBehavior: ProductTaxBehavior
    public let expiresAt: Date
    public let createdAt: Date

    public init(
        quoteID: UUID = UUID(),
        walletID: UUID,
        customerID: String,
        productID: String,
        resourceID: String?,
        quantity: Int,
        amountNOKOre: Int64,
        unitName: String = "NOK_ORE",
        unitAmount: Int64,
        taxCode: String,
        taxBehavior: ProductTaxBehavior,
        expiresAt: Date,
        createdAt: Date = Date()
    ) {
        self.quoteID = quoteID
        self.walletID = walletID
        self.customerID = customerID
        self.productID = productID
        self.resourceID = resourceID
        self.quantity = quantity
        self.amountNOKOre = amountNOKOre
        self.unitName = unitName
        self.unitAmount = unitAmount
        self.taxCode = taxCode
        self.taxBehavior = taxBehavior
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }
}

public struct ProviderPaymentRecord: Codable, Hashable, Sendable {
    public let providerPaymentID: UUID
    public let provider: PaymentProvider
    public let providerPaymentRef: String
    public let walletID: UUID
    public let customerID: String
    public let quoteID: UUID
    public let requestedAmountNOKOre: Int64
    public let status: ProviderPaymentStatus
    public let checkoutURL: String?
    public let createdAt: Date

    public init(
        providerPaymentID: UUID = UUID(),
        provider: PaymentProvider,
        providerPaymentRef: String,
        walletID: UUID,
        customerID: String,
        quoteID: UUID,
        requestedAmountNOKOre: Int64,
        status: ProviderPaymentStatus,
        checkoutURL: String?,
        createdAt: Date = Date()
    ) {
        self.providerPaymentID = providerPaymentID
        self.provider = provider
        self.providerPaymentRef = providerPaymentRef
        self.walletID = walletID
        self.customerID = customerID
        self.quoteID = quoteID
        self.requestedAmountNOKOre = requestedAmountNOKOre
        self.status = status
        self.checkoutURL = checkoutURL
        self.createdAt = createdAt
    }

    public func with(
        status: ProviderPaymentStatus,
        requestedAmountNOKOre: Int64? = nil
    ) -> ProviderPaymentRecord {
        ProviderPaymentRecord(
            providerPaymentID: providerPaymentID,
            provider: provider,
            providerPaymentRef: providerPaymentRef,
            walletID: walletID,
            customerID: customerID,
            quoteID: quoteID,
            requestedAmountNOKOre: requestedAmountNOKOre ?? self.requestedAmountNOKOre,
            status: status,
            checkoutURL: checkoutURL,
            createdAt: createdAt
        )
    }
}

public struct ProviderEventRecord: Codable, Hashable, Sendable {
    public let providerEventID: UUID
    public let provider: PaymentProvider
    public let providerEventRef: String
    public let providerPaymentRef: String?
    public let eventType: String
    public let signatureVerified: Bool
    public let occurredAt: Date
    public let payloadSHA256: String
    public let rawBody: Data
    public let headers: [String: String]
    public let createdAt: Date

    public init(
        providerEventID: UUID = UUID(),
        provider: PaymentProvider,
        providerEventRef: String,
        providerPaymentRef: String?,
        eventType: String,
        signatureVerified: Bool,
        occurredAt: Date,
        payloadSHA256: String,
        rawBody: Data,
        headers: [String: String],
        createdAt: Date = Date()
    ) {
        self.providerEventID = providerEventID
        self.provider = provider
        self.providerEventRef = providerEventRef
        self.providerPaymentRef = providerPaymentRef
        self.eventType = eventType
        self.signatureVerified = signatureVerified
        self.occurredAt = occurredAt
        self.payloadSHA256 = payloadSHA256
        self.rawBody = rawBody
        self.headers = headers
        self.createdAt = createdAt
    }
}

public struct CashEventRecord: Codable, Hashable, Sendable {
    public let cashEventID: UUID
    public let providerPaymentID: UUID
    public let providerEventID: UUID
    public let walletID: UUID
    public let customerID: String
    public let provider: PaymentProvider
    public let eventType: CashEventType
    public let grossAmountNOKOre: Int64
    public let feeAmountNOKOre: Int64
    public let netAmountNOKOre: Int64
    public let occurredAt: Date

    public init(
        cashEventID: UUID = UUID(),
        providerPaymentID: UUID,
        providerEventID: UUID,
        walletID: UUID,
        customerID: String,
        provider: PaymentProvider,
        eventType: CashEventType,
        grossAmountNOKOre: Int64,
        feeAmountNOKOre: Int64 = 0,
        netAmountNOKOre: Int64,
        occurredAt: Date
    ) {
        self.cashEventID = cashEventID
        self.providerPaymentID = providerPaymentID
        self.providerEventID = providerEventID
        self.walletID = walletID
        self.customerID = customerID
        self.provider = provider
        self.eventType = eventType
        self.grossAmountNOKOre = grossAmountNOKOre
        self.feeAmountNOKOre = feeAmountNOKOre
        self.netAmountNOKOre = netAmountNOKOre
        self.occurredAt = occurredAt
    }
}

public struct WalletEventRecord: Codable, Hashable, Sendable {
    public let valueEventID: UUID
    public let walletID: UUID
    public let customerID: String
    public let quoteID: UUID?
    public let cashEventID: UUID?
    public let reservationID: UUID?
    public let eventType: WalletEventType
    public let unitName: String
    public let unitAmount: Int64
    public let nokReferenceAmountOre: Int64
    public let occurredAt: Date

    public init(
        valueEventID: UUID = UUID(),
        walletID: UUID,
        customerID: String,
        quoteID: UUID?,
        cashEventID: UUID?,
        reservationID: UUID? = nil,
        eventType: WalletEventType,
        unitName: String = "NOK_ORE",
        unitAmount: Int64,
        nokReferenceAmountOre: Int64,
        occurredAt: Date = Date()
    ) {
        self.valueEventID = valueEventID
        self.walletID = walletID
        self.customerID = customerID
        self.quoteID = quoteID
        self.cashEventID = cashEventID
        self.reservationID = reservationID
        self.eventType = eventType
        self.unitName = unitName
        self.unitAmount = unitAmount
        self.nokReferenceAmountOre = nokReferenceAmountOre
        self.occurredAt = occurredAt
    }
}

public struct CreateQuoteRequest: Codable, Hashable, Sendable {
    public let customerID: String
    public let walletID: UUID?
    public let productID: String
    public let resourceID: String?
    public let quantity: Int
    public let providerPreference: PaymentProvider?

    public init(
        customerID: String,
        walletID: UUID? = nil,
        productID: String,
        resourceID: String? = nil,
        quantity: Int = 1,
        providerPreference: PaymentProvider? = nil
    ) {
        self.customerID = customerID
        self.walletID = walletID
        self.productID = productID
        self.resourceID = resourceID
        self.quantity = quantity
        self.providerPreference = providerPreference
    }
}

public struct CreateQuoteResponse: Codable, Hashable, Sendable {
    public let quoteID: UUID
    public let walletID: UUID
    public let customerID: String
    public let productID: String
    public let resourceID: String?
    public let amountNOKOre: Int64
    public let unitName: String
    public let unitAmount: Int64
    public let taxCode: String
    public let taxBehavior: ProductTaxBehavior
    public let expiresAt: Date

    public init(record: PriceQuoteRecord) {
        self.quoteID = record.quoteID
        self.walletID = record.walletID
        self.customerID = record.customerID
        self.productID = record.productID
        self.resourceID = record.resourceID
        self.amountNOKOre = record.amountNOKOre
        self.unitName = record.unitName
        self.unitAmount = record.unitAmount
        self.taxCode = record.taxCode
        self.taxBehavior = record.taxBehavior
        self.expiresAt = record.expiresAt
    }
}

public struct CreatePaymentSessionRequest: Codable, Hashable, Sendable {
    public let quoteID: UUID
    public let provider: PaymentProvider
    public let returnURL: String
    public let cancelURL: String

    public init(quoteID: UUID, provider: PaymentProvider, returnURL: String, cancelURL: String) {
        self.quoteID = quoteID
        self.provider = provider
        self.returnURL = returnURL
        self.cancelURL = cancelURL
    }
}

public struct CreatePaymentSessionResponse: Codable, Hashable, Sendable {
    public let providerPaymentID: UUID
    public let provider: PaymentProvider
    public let providerPaymentRef: String
    public let status: ProviderPaymentStatus
    public let checkoutURL: String

    public init(record: ProviderPaymentRecord, checkoutURL: String) {
        self.providerPaymentID = record.providerPaymentID
        self.provider = record.provider
        self.providerPaymentRef = record.providerPaymentRef
        self.status = record.status
        self.checkoutURL = checkoutURL
    }
}

public struct WalletSummaryResponse: Codable, Hashable, Sendable {
    public let walletID: UUID
    public let customerID: String
    public let currency: String
    public let status: String
    public let createdAt: Date

    public init(wallet: StoredWallet) {
        self.walletID = wallet.walletID
        self.customerID = wallet.customerID
        self.currency = wallet.currency
        self.status = wallet.status
        self.createdAt = wallet.createdAt
    }
}

public struct WalletBalanceResponse: Codable, Hashable, Sendable {
    public let walletID: UUID
    public let unitName: String
    public let availableUnits: Int64
    public let reservedUnits: Int64
    public let consumedUnits: Int64
    public let availableNOKOre: Int64
    public let reservedNOKOre: Int64
    public let consumedNOKOre: Int64
    public let updatedAt: Date

    public init(projection: WalletBalanceProjection) {
        self.walletID = projection.walletID
        self.unitName = projection.unitName
        self.availableUnits = projection.availableUnits
        self.reservedUnits = projection.reservedUnits
        self.consumedUnits = projection.consumedUnits
        self.availableNOKOre = projection.availableNOKOre
        self.reservedNOKOre = projection.reservedNOKOre
        self.consumedNOKOre = projection.consumedNOKOre
        self.updatedAt = projection.updatedAt
    }
}

public struct CreateWalletReservationRequest: Codable, Hashable, Sendable {
    public let quoteID: UUID
    public let resourceID: String?

    public init(quoteID: UUID, resourceID: String? = nil) {
        self.quoteID = quoteID
        self.resourceID = resourceID
    }
}

public struct WalletReservationResponse: Codable, Hashable, Sendable {
    public let reservationID: UUID
    public let walletID: UUID
    public let customerID: String
    public let quoteID: UUID?
    public let resourceID: String?
    public let status: WalletReservationStatus
    public let reservedUnitName: String
    public let reservedUnitAmount: Int64
    public let reservedNOKOre: Int64
    public let expiresAt: Date?
    public let releasedAt: Date?

    public init(record: WalletReservationRecord) {
        self.reservationID = record.reservationID
        self.walletID = record.walletID
        self.customerID = record.customerID
        self.quoteID = record.quoteID
        self.resourceID = record.resourceID
        self.status = record.status
        self.reservedUnitName = record.reservedUnitName
        self.reservedUnitAmount = record.reservedUnitAmount
        self.reservedNOKOre = record.reservedNOKOre
        self.expiresAt = record.expiresAt
        self.releasedAt = record.releasedAt
    }
}

public struct ReleaseWalletReservationRequest: Codable, Hashable, Sendable {
    public let reason: String?

    public init(reason: String? = nil) {
        self.reason = reason
    }
}

public struct StripeWebhookAcknowledgement: Codable, Hashable, Sendable {
    public let accepted: Bool
    public let alreadyProcessed: Bool
    public let providerEventRef: String
    public let effect: String

    public init(
        accepted: Bool,
        alreadyProcessed: Bool,
        providerEventRef: String,
        effect: String
    ) {
        self.accepted = accepted
        self.alreadyProcessed = alreadyProcessed
        self.providerEventRef = providerEventRef
        self.effect = effect
    }
}

public enum FundingServiceError: Error {
    case inactiveProduct(String)
    case invalidQuantity(Int)
    case invalidAmount(Int64)
    case quoteExpired(UUID)
    case unknownProduct(String)
    case unknownQuote(UUID)
    case unknownWallet(UUID)
    case unknownReservation(UUID)
    case quoteWalletMismatch(quoteID: UUID, walletID: UUID)
    case insufficientWalletBalance(walletID: UUID, availableNOKOre: Int64, requiredNOKOre: Int64)
    case reservationNotActive(UUID)
    case missingWebhookSignature
    case invalidStripeEventPayload
    case unknownProviderPaymentRef(String)
}

public enum FundingHashing {
    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
