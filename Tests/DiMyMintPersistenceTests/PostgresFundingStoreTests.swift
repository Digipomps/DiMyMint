import XCTest
@testable import DiMyMintCore
@testable import DiMyMintPersistence

final class PostgresFundingStoreTests: XCTestCase {
    func testUpsertQuoteEmitsExpectedSQLAndBinds() async throws {
        let client = RecordingPostgresClient()
        let store = PostgresFundingStore(client: client)
        let quote = PriceQuoteRecord(
            quoteID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            walletID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            customerID: "customer_1",
            productID: "generalcell.starter",
            resourceID: "cell:alpha",
            quantity: 2,
            amountNOKOre: 298_000,
            unitAmount: 298_000,
            taxCode: "standard_25",
            taxBehavior: .inclusive,
            expiresAt: Date(timeIntervalSince1970: 1_741_000_000),
            createdAt: Date(timeIntervalSince1970: 1_741_000_100)
        )

        try await store.upsertQuote(quote)

        let statements = await client.executedStatements()
        XCTAssertEqual(statements.count, 1)
        XCTAssertTrue(statements[0].sql.contains("insert into price_quotes"))
        XCTAssertEqual(
            statements[0].binds,
            [
                .uuid(quote.quoteID),
                .uuid(quote.walletID),
                .string("customer_1"),
                .string("generalcell.starter"),
                .string("cell:alpha"),
                .int(2),
                .int64(298_000),
                .string("NOK_ORE"),
                .int64(298_000),
                .string("standard_25"),
                .string("inclusive"),
                .timestamp(quote.expiresAt),
                .timestamp(quote.createdAt)
            ]
        )
    }

    func testPaymentLookupDecodesStoredRow() async throws {
        let client = RecordingPostgresClient()
        let store = PostgresFundingStore(client: client)
        let paymentID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let walletID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let quoteID = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        let createdAt = Date(timeIntervalSince1970: 1_742_000_000)

        await client.enqueueQueryResult(
            [
                PostgresRow(
                    [
                        "provider_payment_id": .uuid(paymentID),
                        "provider": .string("stripe"),
                        "provider_payment_ref": .string("pi_123"),
                        "wallet_id": .uuid(walletID),
                        "customer_id": .string("customer_2"),
                        "quote_id": .uuid(quoteID),
                        "requested_amount_nok_ore": .int64(499_000),
                        "status": .string("captured"),
                        "provider_session_url": .string("https://checkout.example.invalid/stripe/pi_123"),
                        "created_at": .timestamp(createdAt)
                    ]
                )
            ]
        )

        let payment = try await store.payment(provider: .stripe, providerPaymentRef: "pi_123")

        XCTAssertEqual(payment?.providerPaymentID, paymentID)
        XCTAssertEqual(payment?.walletID, walletID)
        XCTAssertEqual(payment?.quoteID, quoteID)
        XCTAssertEqual(payment?.requestedAmountNOKOre, 499_000)
        XCTAssertEqual(payment?.status, .captured)
    }

    func testUpsertQuotePropagatesClientFailure() async throws {
        let client = RecordingPostgresClient()
        let store = PostgresFundingStore(client: client)
        let quote = PriceQuoteRecord(
            walletID: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            customerID: "customer_3",
            productID: "generalcell.starter",
            resourceID: "cell:gamma",
            quantity: 1,
            amountNOKOre: 149_000,
            unitAmount: 149_000,
            taxCode: "standard_25",
            taxBehavior: .inclusive,
            expiresAt: Date(timeIntervalSince1970: 1_741_000_000)
        )
        await client.setExecuteError(.forcedFailure)

        do {
            try await store.upsertQuote(quote)
            XCTFail("Expected upsertQuote to throw")
        } catch {
            XCTAssertEqual(error as? RecordingPostgresClientError, .forcedFailure)
        }
    }
}

private actor RecordingPostgresClient: PostgresClient {
    private var statements: [PostgresExecutedStatement] = []
    private var queuedResults: [[PostgresRow]] = []
    private var executeError: RecordingPostgresClientError?

    func enqueueQueryResult(_ rows: [PostgresRow]) {
        queuedResults.append(rows)
    }

    func setExecuteError(_ error: RecordingPostgresClientError?) {
        executeError = error
    }

    func executedStatements() -> [PostgresExecutedStatement] {
        statements
    }

    func execute(sql: String, binds: [PostgresBind]) async throws {
        if let executeError {
            throw executeError
        }
        statements.append(PostgresExecutedStatement(sql: sql, binds: binds))
    }

    func query(sql: String, binds: [PostgresBind]) async throws -> [PostgresRow] {
        statements.append(PostgresExecutedStatement(sql: sql, binds: binds))
        if queuedResults.isEmpty {
            return []
        }
        return queuedResults.removeFirst()
    }
}

private enum RecordingPostgresClientError: Error, Equatable {
    case forcedFailure
}
