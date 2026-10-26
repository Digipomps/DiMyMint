import XCTest
@testable import DiMyMintCore

final class FundingServiceTests: XCTestCase {
    func testCreateQuoteAndPaymentSessionUseCatalogPrice() async throws {
        let store = InMemoryFundingStore()
        let service = FundingService(store: store)

        try await service.registerProduct(
            ProductCatalogItem(
                productID: "generalcell.production",
                productType: "hosting_plan",
                title: "GeneralCell Production",
                unitPriceNOKOre: 499_000,
                taxCode: "standard_25",
                taxBehavior: .inclusive
            )
        )

        let quote = try await service.createQuote(
            CreateQuoteRequest(
                customerID: "customer_123",
                productID: "generalcell.production",
                resourceID: "cell:general:alpha",
                quantity: 1,
                providerPreference: .stripe
            )
        )

        XCTAssertEqual(quote.customerID, "customer_123")
        XCTAssertEqual(quote.amountNOKOre, 499_000)
        XCTAssertEqual(quote.taxCode, "standard_25")

        let paymentSession = try await service.createPaymentSession(
            CreatePaymentSessionRequest(
                quoteID: quote.quoteID,
                provider: .stripe,
                returnURL: "https://example.com/success",
                cancelURL: "https://example.com/cancel"
            )
        )

        XCTAssertEqual(paymentSession.provider, .stripe)
        XCTAssertEqual(paymentSession.status, .initiated)
        XCTAssertTrue(paymentSession.checkoutURL.contains(paymentSession.providerPaymentRef))

        let storedPayment = try await store.payment(provider: .stripe, providerPaymentRef: paymentSession.providerPaymentRef)
        XCTAssertEqual(storedPayment?.requestedAmountNOKOre, 499_000)
        XCTAssertEqual(storedPayment?.quoteID, quote.quoteID)
        XCTAssertEqual(storedPayment?.walletID, quote.walletID)
    }

    func testStripeWebhookCreditsWalletExactlyOnce() async throws {
        let store = InMemoryFundingStore()
        let service = FundingService(store: store)

        try await service.registerProduct(
            ProductCatalogItem(
                productID: "generalcell.starter",
                productType: "hosting_plan",
                title: "GeneralCell Starter",
                unitPriceNOKOre: 120_00,
                taxCode: "standard_25",
                taxBehavior: .inclusive
            )
        )

        let quote = try await service.createQuote(
            CreateQuoteRequest(
                customerID: "customer_456",
                productID: "generalcell.starter",
                resourceID: "cell:general:beta",
                quantity: 1,
                providerPreference: .stripe
            )
        )

        let paymentSession = try await service.createPaymentSession(
            CreatePaymentSessionRequest(
                quoteID: quote.quoteID,
                provider: .stripe,
                returnURL: "https://example.com/success",
                cancelURL: "https://example.com/cancel"
            )
        )

        let payload = """
        {
          "id": "evt_test_123",
          "type": "payment_intent.succeeded",
          "created": 1741867200,
          "data": {
            "object": {
              "id": "\(paymentSession.providerPaymentRef)",
              "amount": 12000,
              "currency": "nok",
              "metadata": {
                "wallet_id": "\(quote.walletID.uuidString)",
                "customer_id": "customer_456",
                "quote_id": "\(quote.quoteID.uuidString)"
              }
            }
          }
        }
        """.data(using: .utf8)!

        let headers = ["Stripe-Signature": "t=1,v1=testsig"]

        let firstAck = try await service.ingestStripeWebhook(body: payload, headers: headers)
        XCTAssertTrue(firstAck.accepted)
        XCTAssertFalse(firstAck.alreadyProcessed)
        XCTAssertEqual(firstAck.effect, "wallet_credited")

        let rawEvent = try await store.providerEvent(provider: .stripe, providerEventRef: "evt_test_123")
        XCTAssertNotNil(rawEvent)
        XCTAssertEqual(rawEvent?.providerPaymentRef, paymentSession.providerPaymentRef)

        let payment = try await store.payment(provider: .stripe, providerPaymentRef: paymentSession.providerPaymentRef)
        XCTAssertEqual(payment?.status, .captured)

        let cashEvents = try await store.cashEvents(providerPaymentID: payment!.providerPaymentID)
        XCTAssertEqual(cashEvents.count, 1)
        XCTAssertEqual(cashEvents.first?.eventType, .paymentCaptured)
        XCTAssertEqual(cashEvents.first?.grossAmountNOKOre, 12_000)

        let balance = try await service.walletBalance(walletID: quote.walletID)
        XCTAssertEqual(balance.availableNOKOre, 12_000)
        XCTAssertEqual(balance.availableUnits, 12_000)

        let secondAck = try await service.ingestStripeWebhook(body: payload, headers: headers)
        XCTAssertTrue(secondAck.accepted)
        XCTAssertTrue(secondAck.alreadyProcessed)
        XCTAssertEqual(secondAck.effect, "duplicate_ignored")

        let duplicateBalance = try await service.walletBalance(walletID: quote.walletID)
        XCTAssertEqual(duplicateBalance.availableNOKOre, 12_000)

        let walletEvents = try await store.walletEvents(walletID: quote.walletID)
        XCTAssertEqual(walletEvents.count, 1)
        XCTAssertEqual(walletEvents.first?.eventType, .walletCreditGranted)
    }

    func testWalletReservationMovesAvailableToReservedAndReleaseRestoresBalance() async throws {
        let store = InMemoryFundingStore()
        let service = FundingService(store: store)

        try await service.registerProduct(
            ProductCatalogItem(
                productID: "proofdoor.ai.entry",
                productType: "access_entitlement",
                title: "ProofDoor AI Entry",
                unitPriceNOKOre: 250,
                taxCode: "standard_25",
                taxBehavior: .inclusive
            )
        )

        let quote = try await service.createQuote(
            CreateQuoteRequest(
                customerID: "customer_reserve",
                productID: "proofdoor.ai.entry",
                resourceID: "cell:///PaymentProofDoor#ai",
                quantity: 1,
                providerPreference: .stripe
            )
        )

        let paymentSession = try await service.createPaymentSession(
            CreatePaymentSessionRequest(
                quoteID: quote.quoteID,
                provider: .stripe,
                returnURL: "https://example.com/success",
                cancelURL: "https://example.com/cancel"
            )
        )

        let payload = """
        {
          "id": "evt_reserve_123",
          "type": "payment_intent.succeeded",
          "created": 1741867200,
          "data": {
            "object": {
              "id": "\(paymentSession.providerPaymentRef)",
              "amount": 250,
              "currency": "nok",
              "metadata": {
                "wallet_id": "\(quote.walletID.uuidString)",
                "customer_id": "customer_reserve",
                "quote_id": "\(quote.quoteID.uuidString)"
              }
            }
          }
        }
        """.data(using: .utf8)!

        _ = try await service.ingestStripeWebhook(body: payload, headers: ["Stripe-Signature": "t=1,v1=testsig"])

        let reservation = try await service.createWalletReservation(
            walletID: quote.walletID,
            request: CreateWalletReservationRequest(quoteID: quote.quoteID)
        )

        XCTAssertEqual(reservation.status, .active)
        XCTAssertEqual(reservation.reservedNOKOre, 250)
        XCTAssertEqual(reservation.resourceID, "cell:///PaymentProofDoor#ai")

        let reservedBalance = try await service.walletBalance(walletID: quote.walletID)
        XCTAssertEqual(reservedBalance.availableNOKOre, 0)
        XCTAssertEqual(reservedBalance.reservedNOKOre, 250)

        let walletEvents = try await store.walletEvents(walletID: quote.walletID)
        XCTAssertEqual(walletEvents.map(\.eventType), [.walletCreditGranted, .walletReserved])
        XCTAssertEqual(walletEvents.last?.reservationID, reservation.reservationID)

        let released = try await service.releaseWalletReservation(
            walletID: quote.walletID,
            reservationID: reservation.reservationID,
            request: ReleaseWalletReservationRequest(reason: "test_release")
        )

        XCTAssertEqual(released.status, .released)
        XCTAssertNotNil(released.releasedAt)

        let releasedBalance = try await service.walletBalance(walletID: quote.walletID)
        XCTAssertEqual(releasedBalance.availableNOKOre, 250)
        XCTAssertEqual(releasedBalance.reservedNOKOre, 0)

        let finalEvents = try await store.walletEvents(walletID: quote.walletID)
        XCTAssertEqual(finalEvents.map(\.eventType), [.walletCreditGranted, .walletReserved, .walletReservationReleased])

        let duplicateRelease = try await service.releaseWalletReservation(
            walletID: quote.walletID,
            reservationID: reservation.reservationID,
            request: ReleaseWalletReservationRequest(reason: "duplicate")
        )
        XCTAssertEqual(duplicateRelease.status, .released)

        let duplicateReleaseBalance = try await service.walletBalance(walletID: quote.walletID)
        XCTAssertEqual(duplicateReleaseBalance.availableNOKOre, 250)
        XCTAssertEqual(duplicateReleaseBalance.reservedNOKOre, 0)
    }
}
