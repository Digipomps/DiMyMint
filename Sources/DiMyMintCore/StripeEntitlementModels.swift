import Foundation

/// V0 products are service-local, non-transferable and non-redeemable.
/// A confirmed payment is evidence for a later Agreement-authorized issuance;
/// it is never an access capability by itself.
public enum EntitlementProductKind: String, Codable, Hashable, Sendable {
    case accessEntitlement = "access_entitlement"
    case usageQuota = "usage_quota"
}

public struct EntitlementCheckoutOrder: Codable, Hashable, Sendable {
    public let orderID: String
    public let subjectID: String
    public let agreementID: String
    public let productKind: EntitlementProductKind
    public let amountMinor: Int64
    public let currency: String
    public let successURL: String
    public let cancelURL: String

    public init(
        orderID: String,
        subjectID: String,
        agreementID: String,
        productKind: EntitlementProductKind,
        amountMinor: Int64,
        currency: String,
        successURL: String,
        cancelURL: String
    ) {
        self.orderID = orderID
        self.subjectID = subjectID
        self.agreementID = agreementID
        self.productKind = productKind
        self.amountMinor = amountMinor
        self.currency = currency
        self.successURL = successURL
        self.cancelURL = cancelURL
    }
}

public enum StripeEntitlementPaymentState: String, Codable, Hashable, Sendable {
    case creating
    case awaitingPayment = "awaiting_payment"
    case paymentPending = "payment_pending"
    case paymentConfirmed = "payment_confirmed"
    case paymentFailed = "payment_failed"
}

public struct StripeEntitlementCheckoutSession: Codable, Hashable, Sendable {
    public let providerSessionID: String
    public let checkoutURL: String
    public let orderID: String
    public let bindingSHA256: String
    public let idempotencyKey: String

    public init(
        providerSessionID: String,
        checkoutURL: String,
        orderID: String,
        bindingSHA256: String,
        idempotencyKey: String
    ) {
        self.providerSessionID = providerSessionID
        self.checkoutURL = checkoutURL
        self.orderID = orderID
        self.bindingSHA256 = bindingSHA256
        self.idempotencyKey = idempotencyKey
    }
}

public struct StripeEntitlementOrderRecord: Codable, Hashable, Sendable {
    public let order: EntitlementCheckoutOrder
    public let providerAccountID: String
    public let bindingSHA256: String
    public let idempotencyKey: String
    public let providerSessionID: String?
    public let checkoutURL: String?
    public let state: StripeEntitlementPaymentState
    public let createdAt: Date
    public let lastProviderEventCreatedAt: Date?

    public init(
        order: EntitlementCheckoutOrder,
        providerAccountID: String,
        bindingSHA256: String,
        idempotencyKey: String,
        providerSessionID: String? = nil,
        checkoutURL: String? = nil,
        state: StripeEntitlementPaymentState = .creating,
        createdAt: Date = Date(),
        lastProviderEventCreatedAt: Date? = nil
    ) {
        self.order = order
        self.providerAccountID = providerAccountID
        self.bindingSHA256 = bindingSHA256
        self.idempotencyKey = idempotencyKey
        self.providerSessionID = providerSessionID
        self.checkoutURL = checkoutURL
        self.state = state
        self.createdAt = createdAt
        self.lastProviderEventCreatedAt = lastProviderEventCreatedAt
    }

    func attaching(_ session: StripeEntitlementCheckoutSession) -> Self {
        Self(
            order: order,
            providerAccountID: providerAccountID,
            bindingSHA256: bindingSHA256,
            idempotencyKey: idempotencyKey,
            providerSessionID: session.providerSessionID,
            checkoutURL: session.checkoutURL,
            state: .awaitingPayment,
            createdAt: createdAt,
            lastProviderEventCreatedAt: lastProviderEventCreatedAt
        )
    }

    func applying(_ event: VerifiedStripeEntitlementEvent) -> Self {
        Self(
            order: order,
            providerAccountID: providerAccountID,
            bindingSHA256: bindingSHA256,
            idempotencyKey: idempotencyKey,
            providerSessionID: providerSessionID,
            checkoutURL: checkoutURL,
            state: event.requestedState,
            createdAt: createdAt,
            lastProviderEventCreatedAt: event.providerCreatedAt
        )
    }
}

public struct VerifiedStripeEntitlementEvent: Hashable, Sendable {
    public let providerEventID: String
    public let providerEventType: String
    public let providerCreatedAt: Date
    public let signatureTimestamp: Int64
    public let payloadSHA256: String
    public let deliverySHA256: String
    public let orderID: String
    public let providerSessionID: String
    public let providerAccountID: String
    public let bindingSHA256: String
    public let subjectID: String
    public let agreementID: String
    public let productKind: EntitlementProductKind
    public let amountMinor: Int64
    public let currency: String
    public let requestedState: StripeEntitlementPaymentState

    public init(
        providerEventID: String,
        providerEventType: String,
        providerCreatedAt: Date,
        signatureTimestamp: Int64,
        payloadSHA256: String,
        deliverySHA256: String,
        orderID: String,
        providerSessionID: String,
        providerAccountID: String,
        bindingSHA256: String,
        subjectID: String,
        agreementID: String,
        productKind: EntitlementProductKind,
        amountMinor: Int64,
        currency: String,
        requestedState: StripeEntitlementPaymentState
    ) {
        self.providerEventID = providerEventID
        self.providerEventType = providerEventType
        self.providerCreatedAt = providerCreatedAt
        self.signatureTimestamp = signatureTimestamp
        self.payloadSHA256 = payloadSHA256
        self.deliverySHA256 = deliverySHA256
        self.orderID = orderID
        self.providerSessionID = providerSessionID
        self.providerAccountID = providerAccountID
        self.bindingSHA256 = bindingSHA256
        self.subjectID = subjectID
        self.agreementID = agreementID
        self.productKind = productKind
        self.amountMinor = amountMinor
        self.currency = currency
        self.requestedState = requestedState
    }
}

public enum StripeEntitlementEventAdmission: String, Codable, Hashable, Sendable {
    case accepted
    case duplicate
    case economicDuplicate = "economic_duplicate"
    case pending
}

public struct StripeEntitlementEventAdmissionResult: Hashable, Sendable {
    public let admission: StripeEntitlementEventAdmission
    public let order: StripeEntitlementOrderRecord

    public init(admission: StripeEntitlementEventAdmission, order: StripeEntitlementOrderRecord) {
        self.admission = admission
        self.order = order
    }
}

public struct StripeEntitlementWebhookResult: Codable, Hashable, Sendable {
    public let providerEventID: String
    public let orderID: String
    public let providerSessionID: String
    public let state: StripeEntitlementPaymentState
    public let admission: StripeEntitlementEventAdmission
    public let mayRequestEntitlementIssuance: Bool
}

public protocol StripeEntitlementProviderStore: Sendable {
    func reserveOrder(_ order: StripeEntitlementOrderRecord) async throws -> StripeEntitlementOrderRecord
    func attachSession(
        _ session: StripeEntitlementCheckoutSession,
        toOrderID orderID: String
    ) async throws -> StripeEntitlementOrderRecord
    func order(orderID: String) async throws -> StripeEntitlementOrderRecord?
    func admitVerifiedEvent(
        _ event: VerifiedStripeEntitlementEvent
    ) async throws -> StripeEntitlementEventAdmissionResult
}

public enum StripeEntitlementProviderError: Error, Equatable {
    case invalidConfiguration(String)
    case liveModeForbidden
    case invalidOrder
    case orderConflict
    case unknownOrder
    case providerSessionConflict
    case providerNetworkFailure
    case providerRejected(Int)
    case invalidProviderResponse
    case missingWebhookSignature
    case invalidWebhookSignature
    case webhookTimestampOutsideTolerance
    case invalidWebhookPayload
    case webhookBindingMismatch
    case unsupportedProviderEvent
    case paymentIncomplete
    case providerEventConflict
    case replayedDelivery
    case outOfOrderEvent
    case persistenceFailure
}
