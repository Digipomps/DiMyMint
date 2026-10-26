import Foundation
import XCTest
@testable import DiMyMintCore

final class StripeEntitlementProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let accountID = "acct_haven_test"
    private let secretKey = "sk_test_provider_secret"
    private let webhookSecret = "whsec_provider_secret"

    func testConfigurationRejectsLiveModeAndInvalidScope() throws {
        XCTAssertThrowsError(
            try StripeEntitlementProviderConfiguration(
                accountID: accountID,
                secretKey: "sk_live_forbidden",
                webhookSecret: webhookSecret
            )
        ) { error in
            XCTAssertEqual(error as? StripeEntitlementProviderError, .liveModeForbidden)
        }
        XCTAssertThrowsError(
            try StripeEntitlementProviderConfiguration(
                accountID: "merchant",
                secretKey: secretKey,
                webhookSecret: webhookSecret
            )
        )
        XCTAssertThrowsError(
            try StripeEntitlementProviderConfiguration(
                accountID: accountID,
                secretKey: secretKey,
                webhookSecret: webhookSecret,
                webhookToleranceSeconds: 0
            )
        )
    }

    func testCheckoutRequestIsExactlyBoundAndIdempotent() async throws {
        let order = makeOrder()
        let transport = RecordingStripeTransport()
        let binding = StripeEntitlementProviderService.bindingSHA256(order: order, accountID: accountID)
        await transport.enqueue(
            StripeEntitlementHTTPResponse(
                statusCode: 200,
                body: try checkoutResponse(order: order, binding: binding)
            )
        )
        let store = InMemoryStripeEntitlementProviderStore()
        let service = try makeService(store: store, transport: transport)

        let session = try await service.createCheckoutSession(for: order)
        let replay = try await service.createCheckoutSession(for: order)

        XCTAssertEqual(session, replay)
        XCTAssertEqual(session.providerSessionID, "cs_test_haven_1")
        XCTAssertEqual(session.bindingSHA256, binding)
        XCTAssertEqual(session.idempotencyKey, "haven-entitlement-\(binding)")
        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://api.stripe.com/v1/checkout/sessions")
        XCTAssertEqual(request.headers["Authorization"], "Bearer \(secretKey)")
        XCTAssertEqual(request.headers["Idempotency-Key"], session.idempotencyKey)
        XCTAssertNil(request.headers["Stripe-Account"], "Stripe Connect must not be enabled")
        let form = formValues(request.body)
        XCTAssertEqual(form["mode"], "payment")
        XCTAssertEqual(form["client_reference_id"], order.orderID)
        XCTAssertEqual(form["line_items[0][price_data][unit_amount]"], "1250")
        XCTAssertEqual(form["metadata[subject_id]"], order.subjectID)
        XCTAssertEqual(form["metadata[agreement_id]"], order.agreementID)
        XCTAssertEqual(form["metadata[product_kind]"], "access_entitlement")
        XCTAssertEqual(form["metadata[provider_account_id]"], accountID)
        XCTAssertEqual(form["metadata[binding_sha256]"], binding)
        XCTAssertEqual(form["metadata[non_transferable]"], "true")
        XCTAssertEqual(form["metadata[cash_out]"], "false")
        XCTAssertEqual(form["metadata[external_acceptance]"], "false")
        let bodyText = String(decoding: request.body, as: UTF8.self)
        for forbidden in ["wallet", "coin", "token", "redeem", "payout", "transfer_data"] {
            XCTAssertFalse(bodyText.lowercased().contains(forbidden), forbidden)
        }
    }

    func testChangedOrderCannotReuseOrderID() async throws {
        let order = makeOrder()
        let transport = RecordingStripeTransport()
        let binding = StripeEntitlementProviderService.bindingSHA256(order: order, accountID: accountID)
        await transport.enqueue(.init(statusCode: 200, body: try checkoutResponse(order: order, binding: binding)))
        let store = InMemoryStripeEntitlementProviderStore()
        let service = try makeService(store: store, transport: transport)
        _ = try await service.createCheckoutSession(for: order)

        let changed = EntitlementCheckoutOrder(
            orderID: order.orderID,
            subjectID: order.subjectID,
            agreementID: order.agreementID,
            productKind: order.productKind,
            amountMinor: order.amountMinor + 1,
            currency: order.currency,
            successURL: order.successURL,
            cancelURL: order.cancelURL
        )
        await XCTAssertThrowsErrorAsync(
            try await service.createCheckoutSession(for: changed),
            equals: .orderConflict
        )
    }

    func testCheckoutFailsClosedOnProviderAndResponseFailures() async throws {
        let order = makeOrder()
        let invalidBodies: [Data] = [
            Data("not-json".utf8),
            try checkoutResponse(order: order, binding: "wrong"),
            try checkoutResponse(order: order, binding: StripeEntitlementProviderService.bindingSHA256(order: order, accountID: accountID), overrides: ["livemode": true]),
            try checkoutResponse(order: order, binding: StripeEntitlementProviderService.bindingSHA256(order: order, accountID: accountID), overrides: ["id": "cs_live_forbidden"]),
            try checkoutResponse(order: order, binding: StripeEntitlementProviderService.bindingSHA256(order: order, accountID: accountID), overrides: ["url": "https://evil.example/session"]),
            try checkoutResponse(order: order, binding: StripeEntitlementProviderService.bindingSHA256(order: order, accountID: accountID), overrides: ["amount_total": 999])
        ]
        for (index, body) in invalidBodies.enumerated() {
            let transport = RecordingStripeTransport()
            await transport.enqueue(.init(statusCode: 200, body: body))
            let service = try makeService(store: InMemoryStripeEntitlementProviderStore(), transport: transport)
            await XCTAssertThrowsErrorAsync(
                try await service.createCheckoutSession(for: makeOrder(orderID: "order-invalid-\(index)")),
                equals: .invalidProviderResponse
            )
        }

        let rejectedTransport = RecordingStripeTransport()
        await rejectedTransport.enqueue(.init(statusCode: 503, body: Data()))
        let rejectedService = try makeService(store: InMemoryStripeEntitlementProviderStore(), transport: rejectedTransport)
        await XCTAssertThrowsErrorAsync(
            try await rejectedService.createCheckoutSession(for: makeOrder(orderID: "order-rejected")),
            equals: .providerRejected(503)
        )

        let failedTransport = RecordingStripeTransport()
        await failedTransport.enqueue(error: TestTransportError.failed)
        let failedService = try makeService(store: InMemoryStripeEntitlementProviderStore(), transport: failedTransport)
        do {
            _ = try await failedService.createCheckoutSession(for: makeOrder(orderID: "order-network"))
            XCTFail("Expected network failure")
        } catch TestTransportError.failed {
        }
    }

    func testProviderFailureCanResumeWithExactSameIdempotencyBinding() async throws {
        let order = makeOrder(orderID: "order-resume")
        let transport = RecordingStripeTransport()
        let binding = StripeEntitlementProviderService.bindingSHA256(order: order, accountID: accountID)
        await transport.enqueue(error: TestTransportError.failed)
        await transport.enqueue(.init(statusCode: 200, body: try checkoutResponse(order: order, binding: binding)))
        let service = try makeService(store: InMemoryStripeEntitlementProviderStore(), transport: transport)

        do {
            _ = try await service.createCheckoutSession(for: order)
            XCTFail("Expected the first provider call to fail")
        } catch TestTransportError.failed {
        }
        let session = try await service.createCheckoutSession(for: order)

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].headers["Idempotency-Key"], requests[1].headers["Idempotency-Key"])
        XCTAssertEqual(requests[0].body, requests[1].body)
        XCTAssertEqual(session.bindingSHA256, binding)
    }

    func testWebhookRejectsMissingInvalidStaleFutureDuplicateTimestampAndMutation() async throws {
        let (service, order, _) = try await preparedService()
        let body = try eventBody(order: order)

        await XCTAssertThrowsErrorAsync(
            try await service.ingestWebhook(rawBody: body, stripeSignature: nil),
            equals: .missingWebhookSignature
        )
        for header in [
            "garbage",
            "t=1750000000",
            "v1=\(String(repeating: "a", count: 64))",
            "t=1750000000,t=1750000000,v1=\(String(repeating: "a", count: 64))",
            "t=1750000000,v1=short"
        ] {
            await XCTAssertThrowsErrorAsync(
                try await service.ingestWebhook(rawBody: body, stripeSignature: header),
                equals: .invalidWebhookSignature
            )
        }
        await XCTAssertThrowsErrorAsync(
            try await service.ingestWebhook(rawBody: body, stripeSignature: signature(for: body, timestamp: 1_749_999_699)),
            equals: .webhookTimestampOutsideTolerance
        )
        await XCTAssertThrowsErrorAsync(
            try await service.ingestWebhook(rawBody: body, stripeSignature: signature(for: body, timestamp: 1_750_000_301)),
            equals: .webhookTimestampOutsideTolerance
        )
        var mutated = body
        mutated.append(0x20)
        await XCTAssertThrowsErrorAsync(
            try await service.ingestWebhook(rawBody: mutated, stripeSignature: signature(for: body)),
            equals: .invalidWebhookSignature
        )
    }

    func testWebhookRejectsEveryBindingMismatchAfterValidSignature() async throws {
        let cases: [[String: Any]] = [
            ["account": "acct_wrong"],
            ["livemode": true],
            ["session_id": "cs_test_wrong"],
            ["session_livemode": true],
            ["mode": "subscription"],
            ["amount_total": 1251],
            ["currency": "usd"],
            ["client_reference_id": "other-order"],
            ["subject_id": "other-subject"],
            ["agreement_id": "other-agreement"],
            ["provider_account_id": "acct_wrong"],
            ["product_kind": "wallet"],
            ["binding_sha256": "wrong"],
            ["external_acceptance": "true"]
        ]
        for (index, override) in cases.enumerated() {
            let (service, order, _) = try await preparedService(orderID: "order-mismatch-\(index)")
            let body = try eventBody(order: order, overrides: override)
            await XCTAssertThrowsErrorAsync(
                try await service.ingestWebhook(rawBody: body, stripeSignature: signature(for: body)),
                equals: .webhookBindingMismatch
            )
        }
    }

    func testPaidWebhookIsIdempotentAndConcurrentSafe() async throws {
        let (service, order, _) = try await preparedService()
        let body = try eventBody(order: order)
        let header = signature(for: body)

        let results = try await withThrowingTaskGroup(of: StripeEntitlementWebhookResult.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await service.ingestWebhook(rawBody: body, stripeSignature: header)
                }
            }
            var values: [StripeEntitlementWebhookResult] = []
            for try await result in group { values.append(result) }
            return values
        }

        XCTAssertEqual(results.filter { $0.admission == .accepted }.count, 1)
        XCTAssertEqual(results.filter { $0.admission == .duplicate }.count, 15)
        XCTAssertEqual(results.filter(\.mayRequestEntitlementIssuance).count, 1)
        XCTAssertTrue(results.allSatisfy { $0.state == .paymentConfirmed })

        let providerRetry = try await service.ingestWebhook(
            rawBody: body,
            stripeSignature: signature(for: body, timestamp: 1_750_000_001)
        )
        XCTAssertEqual(providerRetry.admission, .duplicate)
        XCTAssertFalse(providerRetry.mayRequestEntitlementIssuance)
    }

    func testUnpaidCompletionNeverAuthorizesAndAsyncSuccessDoes() async throws {
        let (service, order, _) = try await preparedService()
        let pendingBody = try eventBody(
            order: order,
            eventID: "evt_pending",
            eventType: "checkout.session.completed",
            providerCreated: 1_750_000_001,
            paymentStatus: "unpaid"
        )
        let pending = try await service.ingestWebhook(rawBody: pendingBody, stripeSignature: signature(for: pendingBody))
        XCTAssertEqual(pending.state, .paymentPending)
        XCTAssertEqual(pending.admission, .pending)
        XCTAssertFalse(pending.mayRequestEntitlementIssuance)

        let successBody = try eventBody(
            order: order,
            eventID: "evt_async_success",
            eventType: "checkout.session.async_payment_succeeded",
            providerCreated: 1_750_000_002,
            paymentStatus: "paid"
        )
        let success = try await service.ingestWebhook(rawBody: successBody, stripeSignature: signature(for: successBody))
        XCTAssertEqual(success.state, .paymentConfirmed)
        XCTAssertTrue(success.mayRequestEntitlementIssuance)
    }

    func testAsyncIncompleteDuplicateConflictAndOutOfOrderAreRejected() async throws {
        let (incompleteService, incompleteOrder, _) = try await preparedService(orderID: "order-incomplete")
        let incomplete = try eventBody(
            order: incompleteOrder,
            eventID: "evt_incomplete",
            eventType: "checkout.session.async_payment_succeeded",
            paymentStatus: "unpaid"
        )
        await XCTAssertThrowsErrorAsync(
            try await incompleteService.ingestWebhook(rawBody: incomplete, stripeSignature: signature(for: incomplete)),
            equals: .paymentIncomplete
        )

        let (service, order, _) = try await preparedService(orderID: "order-ordering")
        let pending = try eventBody(
            order: order,
            eventID: "evt_same",
            providerCreated: 1_750_000_010,
            paymentStatus: "unpaid"
        )
        _ = try await service.ingestWebhook(rawBody: pending, stripeSignature: signature(for: pending))

        let changedSameID = try eventBody(
            order: order,
            eventID: "evt_same",
            eventType: "checkout.session.async_payment_succeeded",
            providerCreated: 1_750_000_011,
            paymentStatus: "paid"
        )
        await XCTAssertThrowsErrorAsync(
            try await service.ingestWebhook(rawBody: changedSameID, stripeSignature: signature(for: changedSameID)),
            equals: .providerEventConflict
        )

        let outOfOrder = try eventBody(
            order: order,
            eventID: "evt_old",
            eventType: "checkout.session.async_payment_succeeded",
            providerCreated: 1_750_000_009,
            paymentStatus: "paid"
        )
        await XCTAssertThrowsErrorAsync(
            try await service.ingestWebhook(rawBody: outOfOrder, stripeSignature: signature(for: outOfOrder)),
            equals: .outOfOrderEvent
        )
    }

    func testDistinctPaidEventsHaveSingleEconomicEffect() async throws {
        let (service, order, _) = try await preparedService(orderID: "order-economic")
        let first = try eventBody(order: order, eventID: "evt_paid_1", providerCreated: 1_750_000_001)
        let second = try eventBody(
            order: order,
            eventID: "evt_paid_2",
            eventType: "checkout.session.async_payment_succeeded",
            providerCreated: 1_750_000_002
        )
        let firstResult = try await service.ingestWebhook(rawBody: first, stripeSignature: signature(for: first))
        let secondResult = try await service.ingestWebhook(rawBody: second, stripeSignature: signature(for: second))
        XCTAssertEqual(firstResult.admission, .accepted)
        XCTAssertEqual(secondResult.admission, .economicDuplicate)
        XCTAssertTrue(firstResult.mayRequestEntitlementIssuance)
        XCTAssertFalse(secondResult.mayRequestEntitlementIssuance)
    }

    private func makeService(
        store: InMemoryStripeEntitlementProviderStore,
        transport: RecordingStripeTransport
    ) throws -> StripeEntitlementProviderService {
        StripeEntitlementProviderService(
            configuration: try .init(
                accountID: accountID,
                secretKey: secretKey,
                webhookSecret: webhookSecret
            ),
            store: store,
            transport: transport,
            now: { self.now }
        )
    }

    private func preparedService(
        orderID: String = "order-1"
    ) async throws -> (StripeEntitlementProviderService, EntitlementCheckoutOrder, RecordingStripeTransport) {
        let order = makeOrder(orderID: orderID)
        let transport = RecordingStripeTransport()
        let binding = StripeEntitlementProviderService.bindingSHA256(order: order, accountID: accountID)
        await transport.enqueue(.init(statusCode: 200, body: try checkoutResponse(order: order, binding: binding)))
        let service = try makeService(store: InMemoryStripeEntitlementProviderStore(), transport: transport)
        _ = try await service.createCheckoutSession(for: order)
        return (service, order, transport)
    }

    private func makeOrder(orderID: String = "order-1") -> EntitlementCheckoutOrder {
        EntitlementCheckoutOrder(
            orderID: orderID,
            subjectID: "subject-kjetil2",
            agreementID: "agreement-access-1",
            productKind: .accessEntitlement,
            amountMinor: 1_250,
            currency: "NOK",
            successURL: "https://haven.example/success",
            cancelURL: "https://haven.example/cancel"
        )
    }

    private func checkoutResponse(
        order: EntitlementCheckoutOrder,
        binding: String,
        overrides: [String: Any] = [:]
    ) throws -> Data {
        var object: [String: Any] = [
            "id": "cs_test_haven_1",
            "url": "https://checkout.stripe.com/c/pay/cs_test_haven_1",
            "livemode": false,
            "mode": "payment",
            "status": "open",
            "payment_status": "unpaid",
            "client_reference_id": order.orderID,
            "amount_total": order.amountMinor,
            "currency": order.currency.lowercased(),
            "metadata": StripeEntitlementProviderService.metadata(
                order: order,
                accountID: accountID,
                bindingSHA256: binding
            )
        ]
        for (key, value) in overrides { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func eventBody(
        order: EntitlementCheckoutOrder,
        eventID: String = "evt_haven_1",
        eventType: String = "checkout.session.completed",
        providerCreated: Int64 = 1_750_000_001,
        paymentStatus: String = "paid",
        overrides: [String: Any] = [:]
    ) throws -> Data {
        let binding = StripeEntitlementProviderService.bindingSHA256(order: order, accountID: accountID)
        var metadata = StripeEntitlementProviderService.metadata(
            order: order,
            accountID: accountID,
            bindingSHA256: binding
        )
        for key in ["subject_id", "agreement_id", "provider_account_id", "product_kind", "binding_sha256", "external_acceptance"] {
            if let value = overrides[key] as? String { metadata[key] = value }
        }
        var session: [String: Any] = [
            "id": overrides["session_id"] ?? "cs_test_haven_1",
            "livemode": overrides["session_livemode"] ?? false,
            "mode": overrides["mode"] ?? "payment",
            "payment_status": paymentStatus,
            "client_reference_id": overrides["client_reference_id"] ?? order.orderID,
            "amount_total": overrides["amount_total"] ?? order.amountMinor,
            "currency": overrides["currency"] ?? order.currency.lowercased(),
            "metadata": metadata
        ]
        if let status = overrides["payment_status"] { session["payment_status"] = status }
        let envelope: [String: Any] = [
            "id": eventID,
            "object": "event",
            "account": overrides["account"] ?? accountID,
            "livemode": overrides["livemode"] ?? false,
            "type": eventType,
            "created": providerCreated,
            "data": ["object": session]
        ]
        return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
    }

    private func signature(for body: Data, timestamp: Int64 = 1_750_000_000) -> String {
        var signed = Data("\(timestamp).".utf8)
        signed.append(body)
        let signature = StripeWebhookVerifier.hmacSHA256Hex(data: signed, secret: webhookSecret)
        return "t=\(timestamp),v1=\(signature)"
    }

    private func formValues(_ data: Data) -> [String: String] {
        let raw = String(decoding: data, as: UTF8.self)
        var components = URLComponents()
        components.percentEncodedQuery = raw
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
}

private actor RecordingStripeTransport: StripeEntitlementHTTPTransport {
    private var recorded: [StripeEntitlementHTTPRequest] = []
    private var results: [Result<StripeEntitlementHTTPResponse, Error>] = []

    func enqueue(_ response: StripeEntitlementHTTPResponse) {
        results.append(.success(response))
    }

    func enqueue(error: Error) {
        results.append(.failure(error))
    }

    func requests() -> [StripeEntitlementHTTPRequest] {
        recorded
    }

    func send(_ request: StripeEntitlementHTTPRequest) throws -> StripeEntitlementHTTPResponse {
        recorded.append(request)
        guard !results.isEmpty else { throw TestTransportError.failed }
        return try results.removeFirst().get()
    }
}

private enum TestTransportError: Error {
    case failed
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: @autoclosure () async throws -> T,
        equals expected: StripeEntitlementProviderError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected error \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? StripeEntitlementProviderError, expected, file: file, line: line)
        }
    }
}
