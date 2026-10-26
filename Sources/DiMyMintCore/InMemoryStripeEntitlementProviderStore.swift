import Foundation

public actor InMemoryStripeEntitlementProviderStore: StripeEntitlementProviderStore {
    private var orders: [String: StripeEntitlementOrderRecord] = [:]
    private var events: [String: VerifiedStripeEntitlementEvent] = [:]
    private var eventIDByDelivery: [String: String] = [:]

    public init() {}

    public func reserveOrder(_ order: StripeEntitlementOrderRecord) throws -> StripeEntitlementOrderRecord {
        if let existing = orders[order.order.orderID] {
            guard existing.bindingSHA256 == order.bindingSHA256,
                  existing.idempotencyKey == order.idempotencyKey else {
                throw StripeEntitlementProviderError.orderConflict
            }
            return existing
        }
        orders[order.order.orderID] = order
        return order
    }

    public func attachSession(
        _ session: StripeEntitlementCheckoutSession,
        toOrderID orderID: String
    ) throws -> StripeEntitlementOrderRecord {
        guard let existing = orders[orderID],
              existing.bindingSHA256 == session.bindingSHA256,
              existing.idempotencyKey == session.idempotencyKey else {
            throw StripeEntitlementProviderError.orderConflict
        }
        if let sessionID = existing.providerSessionID {
            guard sessionID == session.providerSessionID,
                  existing.checkoutURL == session.checkoutURL else {
                throw StripeEntitlementProviderError.providerSessionConflict
            }
            return existing
        }
        guard !orders.values.contains(where: { $0.providerSessionID == session.providerSessionID }) else {
            throw StripeEntitlementProviderError.providerSessionConflict
        }
        let attached = existing.attaching(session)
        orders[orderID] = attached
        return attached
    }

    public func order(orderID: String) -> StripeEntitlementOrderRecord? {
        orders[orderID]
    }

    public func admitVerifiedEvent(
        _ event: VerifiedStripeEntitlementEvent
    ) throws -> StripeEntitlementEventAdmissionResult {
        if let existing = events[event.providerEventID] {
            guard Self.sameProviderEvent(existing, event) else {
                throw StripeEntitlementProviderError.providerEventConflict
            }
            if let deliveredEventID = eventIDByDelivery[event.deliverySHA256],
               deliveredEventID != event.providerEventID {
                throw StripeEntitlementProviderError.replayedDelivery
            }
            guard let order = orders[event.orderID] else {
                throw StripeEntitlementProviderError.unknownOrder
            }
            eventIDByDelivery[event.deliverySHA256] = event.providerEventID
            return StripeEntitlementEventAdmissionResult(admission: .duplicate, order: order)
        }
        guard eventIDByDelivery[event.deliverySHA256] == nil else {
            throw StripeEntitlementProviderError.replayedDelivery
        }
        guard let order = orders[event.orderID] else {
            throw StripeEntitlementProviderError.unknownOrder
        }
        guard order.providerAccountID == event.providerAccountID,
              order.providerSessionID == event.providerSessionID,
              order.bindingSHA256 == event.bindingSHA256 else {
            throw StripeEntitlementProviderError.providerSessionConflict
        }
        guard order.lastProviderEventCreatedAt.map({ event.providerCreatedAt > $0 }) ?? true else {
            throw StripeEntitlementProviderError.outOfOrderEvent
        }

        if order.state == .paymentConfirmed, event.requestedState == .paymentConfirmed {
            events[event.providerEventID] = event
            eventIDByDelivery[event.deliverySHA256] = event.providerEventID
            let updated = order.applying(event)
            orders[event.orderID] = updated
            return StripeEntitlementEventAdmissionResult(admission: .economicDuplicate, order: updated)
        }
        guard Self.transitionAllowed(from: order.state, to: event.requestedState) else {
            throw StripeEntitlementProviderError.outOfOrderEvent
        }

        events[event.providerEventID] = event
        eventIDByDelivery[event.deliverySHA256] = event.providerEventID
        let updated = order.applying(event)
        orders[event.orderID] = updated
        return StripeEntitlementEventAdmissionResult(
            admission: event.requestedState == .paymentPending ? .pending : .accepted,
            order: updated
        )
    }

    private static func transitionAllowed(
        from: StripeEntitlementPaymentState,
        to: StripeEntitlementPaymentState
    ) -> Bool {
        switch (from, to) {
        case (.awaitingPayment, .paymentPending),
             (.awaitingPayment, .paymentConfirmed),
             (.awaitingPayment, .paymentFailed),
             (.paymentPending, .paymentConfirmed),
             (.paymentPending, .paymentFailed):
            return true
        default:
            return false
        }
    }

    private static func sameProviderEvent(
        _ lhs: VerifiedStripeEntitlementEvent,
        _ rhs: VerifiedStripeEntitlementEvent
    ) -> Bool {
        lhs.providerEventID == rhs.providerEventID &&
            lhs.providerEventType == rhs.providerEventType &&
            lhs.providerCreatedAt == rhs.providerCreatedAt &&
            lhs.payloadSHA256 == rhs.payloadSHA256 &&
            lhs.orderID == rhs.orderID &&
            lhs.providerSessionID == rhs.providerSessionID &&
            lhs.providerAccountID == rhs.providerAccountID &&
            lhs.bindingSHA256 == rhs.bindingSHA256 &&
            lhs.subjectID == rhs.subjectID &&
            lhs.agreementID == rhs.agreementID &&
            lhs.productKind == rhs.productKind &&
            lhs.amountMinor == rhs.amountMinor &&
            lhs.currency == rhs.currency &&
            lhs.requestedState == rhs.requestedState
    }
}
