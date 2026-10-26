import Foundation
import XCTest
@testable import DiMyMintCore
@testable import DiMyMintPersistence

@available(macOS 13.0, *)
final class PostgresStripeEntitlementProviderIntegrationTests: XCTestCase {
    func testAtomicReplayConcurrencyAndOutOfOrderContract() async throws {
        guard let databaseURL = ProcessInfo.processInfo.environment["DIMYMINT_TEST_POSTGRES_URL"],
              !databaseURL.isEmpty else {
            throw XCTSkip("Set DIMYMINT_TEST_POSTGRES_URL for the disposable PostgreSQL contract gate.")
        }

        let client = try await PostgresNIOClientAdapter.connect(databaseURL: databaseURL)
        try await client.ensureRequiredTablesExist([
            "stripe_entitlement_checkout_orders",
            "stripe_entitlement_provider_events",
            "stripe_entitlement_event_deliveries"
        ])
        let store = PostgresStripeEntitlementProviderStore(client: client)
        let suffix = UUID().uuidString.lowercased()
        let orderID = "order-\(suffix)"
        let compactSuffix = suffix.replacingOccurrences(of: "-", with: "")
        let binding = compactSuffix + compactSuffix
        let digestTail = String(binding.dropFirst())
        let record = StripeEntitlementOrderRecord(
            order: EntitlementCheckoutOrder(
                orderID: orderID,
                subjectID: "subject-\(suffix)",
                agreementID: "agreement-\(suffix)",
                productKind: .accessEntitlement,
                amountMinor: 1_250,
                currency: "NOK",
                successURL: "https://haven.example/success",
                cancelURL: "https://haven.example/cancel"
            ),
            providerAccountID: "acct_haven_test",
            bindingSHA256: binding,
            idempotencyKey: "haven-entitlement-\(binding)",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let session = StripeEntitlementCheckoutSession(
            providerSessionID: "cs_test_\(suffix)",
            checkoutURL: "https://checkout.stripe.com/c/pay/cs_test_\(suffix)",
            orderID: orderID,
            bindingSHA256: binding,
            idempotencyKey: record.idempotencyKey
        )
        _ = try await store.reserveOrder(record)
        _ = try await store.attachSession(session, toOrderID: orderID)

        let firstEvent = makeEvent(
            eventID: "evt_\(suffix)_1",
            payload: "b\(digestTail)",
            delivery: "c\(digestTail)",
            createdAt: 1_750_000_001,
            record: record,
            session: session
        )
        let admissions = try await withThrowingTaskGroup(
            of: StripeEntitlementEventAdmission.self,
            returning: [StripeEntitlementEventAdmission].self
        ) { group in
            for _ in 0..<16 {
                group.addTask {
                    let concurrentStore = PostgresStripeEntitlementProviderStore(client: client)
                    return try await concurrentStore.admitVerifiedEvent(firstEvent).admission
                }
            }
            var values: [StripeEntitlementEventAdmission] = []
            for try await admission in group {
                values.append(admission)
            }
            return values
        }
        XCTAssertEqual(admissions.filter { $0 == .accepted }.count, 1)
        XCTAssertEqual(admissions.filter { $0 == .duplicate }.count, 15)

        let economicDuplicate = makeEvent(
            eventID: "evt_\(suffix)_2",
            payload: "d\(digestTail)",
            delivery: "e\(digestTail)",
            createdAt: 1_750_000_002,
            record: record,
            session: session
        )
        let duplicateResult = try await store.admitVerifiedEvent(economicDuplicate)
        XCTAssertEqual(duplicateResult.admission, .economicDuplicate)
        XCTAssertEqual(duplicateResult.order.state, .paymentConfirmed)

        let conflictingEvent = makeEvent(
            eventID: firstEvent.providerEventID,
            payload: "f\(digestTail)",
            delivery: "0\(digestTail)",
            createdAt: 1_750_000_001,
            record: record,
            session: session
        )
        await assertThrows(.providerEventConflict) {
            _ = try await store.admitVerifiedEvent(conflictingEvent)
        }

        let outOfOrderEvent = makeEvent(
            eventID: "evt_\(suffix)_3",
            payload: "1\(digestTail)",
            delivery: "2\(digestTail)",
            createdAt: 1_750_000_001,
            record: record,
            session: session
        )
        await assertThrows(.outOfOrderEvent) {
            _ = try await store.admitVerifiedEvent(outOfOrderEvent)
        }

        let eventCount = try await client.query(
            sql: "select count(*)::bigint as count from stripe_entitlement_provider_events where order_id = $1",
            binds: [.string(orderID)]
        )
        XCTAssertEqual(eventCount.first?.int64("count"), 2)
        let deliveryCount = try await client.query(
            sql: "select count(*)::bigint as count from stripe_entitlement_event_deliveries where provider_event_id like $1",
            binds: [.string("evt_\(suffix)%")]
        )
        XCTAssertEqual(deliveryCount.first?.int64("count"), 2)
    }

    private func makeEvent(
        eventID: String,
        payload: String,
        delivery: String,
        createdAt: TimeInterval,
        record: StripeEntitlementOrderRecord,
        session: StripeEntitlementCheckoutSession
    ) -> VerifiedStripeEntitlementEvent {
        VerifiedStripeEntitlementEvent(
            providerEventID: eventID,
            providerEventType: "checkout.session.completed",
            providerCreatedAt: Date(timeIntervalSince1970: createdAt),
            signatureTimestamp: Int64(createdAt + 1),
            payloadSHA256: payload,
            deliverySHA256: delivery,
            orderID: record.order.orderID,
            providerSessionID: session.providerSessionID,
            providerAccountID: record.providerAccountID,
            bindingSHA256: record.bindingSHA256,
            subjectID: record.order.subjectID,
            agreementID: record.order.agreementID,
            productKind: record.order.productKind,
            amountMinor: record.order.amountMinor,
            currency: record.order.currency,
            requestedState: .paymentConfirmed
        )
    }

    private func assertThrows(
        _ expected: StripeEntitlementProviderError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch {
            XCTAssertEqual(error as? StripeEntitlementProviderError, expected)
        }
    }
}
