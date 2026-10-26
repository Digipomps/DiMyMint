import DiMyMintCore
import Foundation

public actor PostgresStripeEntitlementProviderStore: StripeEntitlementProviderStore {
    private let client: any PostgresClient

    public init(client: any PostgresClient) {
        self.client = client
    }

    public func reserveOrder(
        _ record: StripeEntitlementOrderRecord
    ) async throws -> StripeEntitlementOrderRecord {
        let checkoutOrder = record.order
        let insert = """
        insert into stripe_entitlement_checkout_orders (
            order_id, subject_id, agreement_id, product_kind, provider, provider_mode,
            provider_account_id, binding_sha256, idempotency_key, amount_minor,
            currency, success_url, cancel_url, non_transferable, cash_out,
            external_acceptance, state, created_at
        ) values (
            $1, $2, $3, $4, 'stripe', 'test', $5, $6, $7, $8, $9,
            $10, $11, true, false, false, 'creating', $12
        ) on conflict (order_id) do nothing
        """
        try await client.execute(
            sql: insert,
            binds: [
                .string(checkoutOrder.orderID),
                .string(checkoutOrder.subjectID),
                .string(checkoutOrder.agreementID),
                .string(checkoutOrder.productKind.rawValue),
                .string(record.providerAccountID),
                .string(record.bindingSHA256),
                .string(record.idempotencyKey),
                .int64(checkoutOrder.amountMinor),
                .string(checkoutOrder.currency.uppercased()),
                .string(checkoutOrder.successURL),
                .string(checkoutOrder.cancelURL),
                .timestamp(record.createdAt)
            ]
        )
        guard let stored = try await order(orderID: checkoutOrder.orderID) else {
            throw StripeEntitlementProviderError.persistenceFailure
        }
        guard stored.bindingSHA256 == record.bindingSHA256,
              stored.idempotencyKey == record.idempotencyKey,
              stored.providerAccountID == record.providerAccountID else {
            throw StripeEntitlementProviderError.orderConflict
        }
        return stored
    }

    public func attachSession(
        _ session: StripeEntitlementCheckoutSession,
        toOrderID orderID: String
    ) async throws -> StripeEntitlementOrderRecord {
        let update = """
        update stripe_entitlement_checkout_orders
        set provider_session_id = $2,
            checkout_url = $3,
            state = 'awaiting_payment',
            updated_at = now()
        where order_id = $1
          and binding_sha256 = $4
          and idempotency_key = $5
          and provider_session_id is null
          and state = 'creating'
        returning \(Self.orderColumns)
        """
        let rows = try await client.query(
            sql: update,
            binds: [
                .string(orderID),
                .string(session.providerSessionID),
                .string(session.checkoutURL),
                .string(session.bindingSHA256),
                .string(session.idempotencyKey)
            ]
        )
        if let row = rows.first {
            return try decodeOrder(row)
        }
        guard let stored = try await order(orderID: orderID) else {
            throw StripeEntitlementProviderError.unknownOrder
        }
        guard stored.providerSessionID == session.providerSessionID,
              stored.checkoutURL == session.checkoutURL,
              stored.bindingSHA256 == session.bindingSHA256,
              stored.idempotencyKey == session.idempotencyKey else {
            throw StripeEntitlementProviderError.providerSessionConflict
        }
        return stored
    }

    public func order(orderID: String) async throws -> StripeEntitlementOrderRecord? {
        let sql = """
        select \(Self.orderColumns)
        from stripe_entitlement_checkout_orders
        where order_id = $1
        """
        let rows = try await client.query(sql: sql, binds: [.string(orderID)])
        return try rows.first.map(decodeOrder)
    }

    public func admitVerifiedEvent(
        _ event: VerifiedStripeEntitlementEvent
    ) async throws -> StripeEntitlementEventAdmissionResult {
        let sql = """
        select admit_stripe_entitlement_provider_event(
            $1, $2, $3, $4, $5, $6, $7, $8,
            $9, $10, $11, $12, $13, $14, $15, $16
        ) as admission
        """
        let rows = try await client.query(
            sql: sql,
            binds: [
                .string(event.providerEventID),
                .string(event.providerEventType),
                .timestamp(event.providerCreatedAt),
                .int64(event.signatureTimestamp),
                .string(event.payloadSHA256),
                .string(event.deliverySHA256),
                .string(event.orderID),
                .string(event.providerSessionID),
                .string(event.providerAccountID),
                .string(event.bindingSHA256),
                .string(event.subjectID),
                .string(event.agreementID),
                .string(event.productKind.rawValue),
                .int64(event.amountMinor),
                .string(event.currency.uppercased()),
                .string(event.requestedState.rawValue)
            ]
        )
        guard let rawAdmission = rows.first?.string("admission") else {
            throw StripeEntitlementProviderError.persistenceFailure
        }
        switch rawAdmission {
        case "provider_event_conflict":
            throw StripeEntitlementProviderError.providerEventConflict
        case "replayed_delivery":
            throw StripeEntitlementProviderError.replayedDelivery
        case "out_of_order":
            throw StripeEntitlementProviderError.outOfOrderEvent
        case "binding_mismatch":
            throw StripeEntitlementProviderError.webhookBindingMismatch
        case "unknown_order":
            throw StripeEntitlementProviderError.unknownOrder
        default:
            break
        }
        guard let admission = StripeEntitlementEventAdmission(rawValue: rawAdmission),
              let stored = try await order(orderID: event.orderID) else {
            throw StripeEntitlementProviderError.persistenceFailure
        }
        return StripeEntitlementEventAdmissionResult(admission: admission, order: stored)
    }

    private static let orderColumns = """
    order_id, subject_id, agreement_id, product_kind, provider_account_id,
    binding_sha256, idempotency_key, provider_session_id, checkout_url,
    amount_minor, currency, success_url, cancel_url, state, created_at,
    last_provider_event_created_at
    """

    private func decodeOrder(_ row: PostgresRow) throws -> StripeEntitlementOrderRecord {
        guard let orderID = row.string("order_id"),
              let subjectID = row.string("subject_id"),
              let agreementID = row.string("agreement_id"),
              let rawKind = row.string("product_kind"),
              let kind = EntitlementProductKind(rawValue: rawKind),
              let accountID = row.string("provider_account_id"),
              let binding = row.string("binding_sha256"),
              let idempotencyKey = row.string("idempotency_key"),
              let amount = row.int64("amount_minor"),
              let currency = row.string("currency"),
              let successURL = row.string("success_url"),
              let cancelURL = row.string("cancel_url"),
              let rawState = row.string("state"),
              let state = StripeEntitlementPaymentState(rawValue: rawState),
              let createdAt = row.timestamp("created_at") else {
            throw StripeEntitlementProviderError.persistenceFailure
        }
        return StripeEntitlementOrderRecord(
            order: EntitlementCheckoutOrder(
                orderID: orderID,
                subjectID: subjectID,
                agreementID: agreementID,
                productKind: kind,
                amountMinor: amount,
                currency: currency,
                successURL: successURL,
                cancelURL: cancelURL
            ),
            providerAccountID: accountID,
            bindingSHA256: binding,
            idempotencyKey: idempotencyKey,
            providerSessionID: row.string("provider_session_id"),
            checkoutURL: row.string("checkout_url"),
            state: state,
            createdAt: createdAt,
            lastProviderEventCreatedAt: row.timestamp("last_provider_event_created_at")
        )
    }
}
