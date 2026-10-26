import Foundation
import XCTest
@testable import DiMyMintCore
@testable import DiMyMintPersistence

final class PostgresStripeEntitlementProviderStoreTests: XCTestCase {
    func testReserveOrderUsesImmutableInsertAndReturnsExactStoredBinding() async throws {
        let client = RecordingEntitlementPostgresClient()
        let record = makeRecord()
        await client.enqueue([orderRow(record)])
        let store = PostgresStripeEntitlementProviderStore(client: client)

        let stored = try await store.reserveOrder(record)

        XCTAssertEqual(stored, record)
        let statements = await client.statements()
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].sql.contains("insert into stripe_entitlement_checkout_orders"))
        XCTAssertTrue(statements[0].sql.contains("on conflict (order_id) do nothing"))
        XCTAssertTrue(statements[0].sql.contains("true, false, false"))
        XCTAssertFalse(statements[0].sql.lowercased().contains("wallet"))
        XCTAssertEqual(statements[0].binds[0], .string(record.order.orderID))
        XCTAssertEqual(statements[0].binds[1], .string(record.order.subjectID))
        XCTAssertEqual(statements[0].binds[2], .string(record.order.agreementID))
        XCTAssertEqual(statements[0].binds[3], .string("access_entitlement"))
        XCTAssertEqual(statements[0].binds[4], .string(record.providerAccountID))
        XCTAssertEqual(statements[0].binds[5], .string(record.bindingSHA256))
        XCTAssertEqual(statements[0].binds[6], .string(record.idempotencyKey))
    }

    func testAttachSessionUsesConditionalTransitionAndCanResumeCommittedResult() async throws {
        let client = RecordingEntitlementPostgresClient()
        let record = makeRecord().attaching(makeSession())
        await client.enqueue([orderRow(record)])
        let store = PostgresStripeEntitlementProviderStore(client: client)

        let stored = try await store.attachSession(makeSession(), toOrderID: record.order.orderID)

        XCTAssertEqual(stored, record)
        let statements = await client.statements()
        let statement = try XCTUnwrap(statements.first)
        XCTAssertTrue(statement.sql.contains("provider_session_id is null"))
        XCTAssertTrue(statement.sql.contains("state = 'creating'"))
        XCTAssertTrue(statement.sql.contains("returning"))
    }

    func testAdmissionCallsSingleAtomicDatabaseFunctionAndReadsCommittedOrder() async throws {
        let client = RecordingEntitlementPostgresClient()
        let event = makeEvent()
        let confirmed = makeRecord().attaching(makeSession()).applying(event)
        await client.enqueue([PostgresRow(["admission": .string("accepted")])])
        await client.enqueue([orderRow(confirmed)])
        let store = PostgresStripeEntitlementProviderStore(client: client)

        let result = try await store.admitVerifiedEvent(event)

        XCTAssertEqual(result.admission, .accepted)
        XCTAssertEqual(result.order.state, .paymentConfirmed)
        let statements = await client.statements()
        XCTAssertEqual(statements.count, 2)
        XCTAssertTrue(statements[0].sql.contains("admit_stripe_entitlement_provider_event"))
        XCTAssertEqual(statements[0].binds.count, 16)
        XCTAssertFalse(statements[0].binds.contains(where: { bind in
            if case .data = bind { return true }
            return false
        }))
        XCTAssertFalse(String(describing: statements[0].binds).contains("whsec_"))
    }

    func testAdmissionMapsDatabaseRejectionsWithoutReadingOrder() async throws {
        let expectations: [(String, StripeEntitlementProviderError)] = [
            ("provider_event_conflict", .providerEventConflict),
            ("replayed_delivery", .replayedDelivery),
            ("out_of_order", .outOfOrderEvent),
            ("binding_mismatch", .webhookBindingMismatch),
            ("unknown_order", .unknownOrder)
        ]
        for (outcome, expected) in expectations {
            let client = RecordingEntitlementPostgresClient()
            await client.enqueue([PostgresRow(["admission": .string(outcome)])])
            let store = PostgresStripeEntitlementProviderStore(client: client)
            do {
                _ = try await store.admitVerifiedEvent(makeEvent())
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? StripeEntitlementProviderError, expected)
            }
            let statementCount = await client.statements().count
            XCTAssertEqual(statementCount, 1)
        }
    }

    func testMigrationProvidesNarrowAtomicAndPrivacyPreservingContract() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let migrationURL = repositoryRoot
            .appendingPathComponent("db/migrations/0002_stripe_entitlement_provider_v0.sql")
        let sql = try String(contentsOf: migrationURL, encoding: .utf8).lowercased()

        XCTAssertTrue(sql.contains("create table if not exists stripe_entitlement_checkout_orders"))
        XCTAssertTrue(sql.contains("create table if not exists stripe_entitlement_provider_events"))
        XCTAssertTrue(sql.contains("create table if not exists stripe_entitlement_event_deliveries"))
        XCTAssertTrue(sql.contains("for update"))
        XCTAssertTrue(sql.contains("security invoker"))
        XCTAssertTrue(sql.contains("revoke all on function"))
        XCTAssertTrue(sql.contains("non_transferable boolean not null default true"))
        XCTAssertTrue(sql.contains("cash_out boolean not null default false"))
        XCTAssertTrue(sql.contains("external_acceptance boolean not null default false"))
        XCTAssertTrue(sql.contains("product_kind in ('access_entitlement', 'usage_quota')"))
        XCTAssertFalse(sql.contains("raw_body"))
        XCTAssertFalse(sql.contains("request_headers"))
        for forbidden in ["wallet", "cash_events", "mint_issued", "coin", "redeem", "payout", "transfer_data"] {
            XCTAssertFalse(sql.contains(forbidden), forbidden)
        }
    }

    private func makeRecord() -> StripeEntitlementOrderRecord {
        StripeEntitlementOrderRecord(
            order: EntitlementCheckoutOrder(
                orderID: "order-db-1",
                subjectID: "subject-db-1",
                agreementID: "agreement-db-1",
                productKind: .accessEntitlement,
                amountMinor: 1_250,
                currency: "NOK",
                successURL: "https://haven.example/success",
                cancelURL: "https://haven.example/cancel"
            ),
            providerAccountID: "acct_haven_test",
            bindingSHA256: String(repeating: "a", count: 64),
            idempotencyKey: "haven-entitlement-\(String(repeating: "a", count: 64))",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }

    private func makeSession() -> StripeEntitlementCheckoutSession {
        StripeEntitlementCheckoutSession(
            providerSessionID: "cs_test_db_1",
            checkoutURL: "https://checkout.stripe.com/c/pay/cs_test_db_1",
            orderID: "order-db-1",
            bindingSHA256: String(repeating: "a", count: 64),
            idempotencyKey: "haven-entitlement-\(String(repeating: "a", count: 64))"
        )
    }

    private func makeEvent() -> VerifiedStripeEntitlementEvent {
        VerifiedStripeEntitlementEvent(
            providerEventID: "evt_db_1",
            providerEventType: "checkout.session.completed",
            providerCreatedAt: Date(timeIntervalSince1970: 1_750_000_001),
            signatureTimestamp: 1_750_000_002,
            payloadSHA256: String(repeating: "b", count: 64),
            deliverySHA256: String(repeating: "c", count: 64),
            orderID: "order-db-1",
            providerSessionID: "cs_test_db_1",
            providerAccountID: "acct_haven_test",
            bindingSHA256: String(repeating: "a", count: 64),
            subjectID: "subject-db-1",
            agreementID: "agreement-db-1",
            productKind: .accessEntitlement,
            amountMinor: 1_250,
            currency: "NOK",
            requestedState: .paymentConfirmed
        )
    }

    private func orderRow(_ record: StripeEntitlementOrderRecord) -> PostgresRow {
        var values: [String: PostgresValue] = [
            "order_id": .string(record.order.orderID),
            "subject_id": .string(record.order.subjectID),
            "agreement_id": .string(record.order.agreementID),
            "product_kind": .string(record.order.productKind.rawValue),
            "provider_account_id": .string(record.providerAccountID),
            "binding_sha256": .string(record.bindingSHA256),
            "idempotency_key": .string(record.idempotencyKey),
            "amount_minor": .int64(record.order.amountMinor),
            "currency": .string(record.order.currency),
            "success_url": .string(record.order.successURL),
            "cancel_url": .string(record.order.cancelURL),
            "state": .string(record.state.rawValue),
            "created_at": .timestamp(record.createdAt)
        ]
        if let value = record.providerSessionID { values["provider_session_id"] = .string(value) }
        if let value = record.checkoutURL { values["checkout_url"] = .string(value) }
        if let value = record.lastProviderEventCreatedAt {
            values["last_provider_event_created_at"] = .timestamp(value)
        }
        return PostgresRow(values)
    }
}

private actor RecordingEntitlementPostgresClient: PostgresClient {
    private var recorded: [PostgresExecutedStatement] = []
    private var results: [[PostgresRow]] = []

    func enqueue(_ rows: [PostgresRow]) {
        results.append(rows)
    }

    func statements() -> [PostgresExecutedStatement] {
        recorded
    }

    func execute(sql: String, binds: [PostgresBind]) {
        recorded.append(.init(sql: sql, binds: binds))
    }

    func query(sql: String, binds: [PostgresBind]) throws -> [PostgresRow] {
        recorded.append(.init(sql: sql, binds: binds))
        guard !results.isEmpty else { return [] }
        return results.removeFirst()
    }
}
