import Foundation

private struct StripeWebhookEnvelope: Decodable {
    struct DataContainer: Decodable {
        let object: StripeEventObject
    }

    let id: String
    let type: String
    let created: TimeInterval?
    let data: DataContainer
}

private struct StripeEventObject: Decodable {
    let id: String
    let amount: Int64?
    let amountTotal: Int64?
    let currency: String?
    let paymentIntent: String?
    let metadata: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case id
        case amount
        case amountTotal = "amount_total"
        case currency
        case paymentIntent = "payment_intent"
        case metadata
    }
}

public actor FundingService {
    private let productCatalogStore: any ProductCatalogStore
    private let walletStore: any WalletStore
    private let walletReservationStore: any WalletReservationStore
    private let quoteStore: any QuoteStore
    private let providerPaymentStore: any ProviderPaymentStore
    private let providerEventStore: any ProviderEventStore
    private let cashEventStore: any CashEventStore
    private let walletEventStore: any WalletEventStore

    public init(store: InMemoryFundingStore = InMemoryFundingStore()) {
        self.productCatalogStore = store
        self.walletStore = store
        self.walletReservationStore = store
        self.quoteStore = store
        self.providerPaymentStore = store
        self.providerEventStore = store
        self.cashEventStore = store
        self.walletEventStore = store
    }

    public init(
        productCatalogStore: any ProductCatalogStore,
        walletStore: any WalletStore,
        walletReservationStore: any WalletReservationStore,
        quoteStore: any QuoteStore,
        providerPaymentStore: any ProviderPaymentStore,
        providerEventStore: any ProviderEventStore,
        cashEventStore: any CashEventStore,
        walletEventStore: any WalletEventStore
    ) {
        self.productCatalogStore = productCatalogStore
        self.walletStore = walletStore
        self.walletReservationStore = walletReservationStore
        self.quoteStore = quoteStore
        self.providerPaymentStore = providerPaymentStore
        self.providerEventStore = providerEventStore
        self.cashEventStore = cashEventStore
        self.walletEventStore = walletEventStore
    }

    public func registerProduct(_ product: ProductCatalogItem) async throws {
        try await productCatalogStore.upsertProduct(product)
    }

    public func walletSummary(walletID: UUID) async throws -> WalletSummaryResponse {
        guard let wallet = try await walletStore.wallet(walletID: walletID) else {
            throw FundingServiceError.unknownWallet(walletID)
        }
        return WalletSummaryResponse(wallet: wallet)
    }

    public func walletBalance(walletID: UUID) async throws -> WalletBalanceResponse {
        guard let wallet = try await walletStore.wallet(walletID: walletID),
              let balance = try await walletStore.balance(walletID: wallet.walletID) else {
            throw FundingServiceError.unknownWallet(walletID)
        }
        return WalletBalanceResponse(projection: balance)
    }

    public func createWalletReservation(
        walletID: UUID,
        request: CreateWalletReservationRequest
    ) async throws -> WalletReservationResponse {
        guard let wallet = try await walletStore.wallet(walletID: walletID),
              let balance = try await walletStore.balance(walletID: wallet.walletID) else {
            throw FundingServiceError.unknownWallet(walletID)
        }

        guard let quote = try await quoteStore.quote(quoteID: request.quoteID) else {
            throw FundingServiceError.unknownQuote(request.quoteID)
        }

        guard quote.walletID == wallet.walletID else {
            throw FundingServiceError.quoteWalletMismatch(quoteID: quote.quoteID, walletID: wallet.walletID)
        }

        guard quote.expiresAt > Date() else {
            throw FundingServiceError.quoteExpired(quote.quoteID)
        }

        guard quote.amountNOKOre > 0 else {
            throw FundingServiceError.invalidAmount(quote.amountNOKOre)
        }

        guard balance.availableNOKOre >= quote.amountNOKOre else {
            throw FundingServiceError.insufficientWalletBalance(
                walletID: wallet.walletID,
                availableNOKOre: balance.availableNOKOre,
                requiredNOKOre: quote.amountNOKOre
            )
        }

        let reservation = WalletReservationRecord(
            walletID: wallet.walletID,
            customerID: wallet.customerID,
            quoteID: quote.quoteID,
            resourceID: normalizedResourceID(request.resourceID ?? quote.resourceID),
            reservedUnitName: quote.unitName,
            reservedUnitAmount: quote.unitAmount,
            reservedNOKOre: quote.amountNOKOre,
            expiresAt: quote.expiresAt
        )

        try await walletReservationStore.upsertReservation(reservation)
        try await walletEventStore.insertWalletEvent(
            WalletEventRecord(
                walletID: wallet.walletID,
                customerID: wallet.customerID,
                quoteID: quote.quoteID,
                cashEventID: nil,
                reservationID: reservation.reservationID,
                eventType: .walletReserved,
                unitName: quote.unitName,
                unitAmount: quote.unitAmount,
                nokReferenceAmountOre: quote.amountNOKOre
            )
        )
        try await walletStore.upsertBalance(
            WalletBalanceProjection(
                walletID: balance.walletID,
                unitName: balance.unitName,
                availableUnits: balance.availableUnits - quote.unitAmount,
                reservedUnits: balance.reservedUnits + quote.unitAmount,
                consumedUnits: balance.consumedUnits,
                availableNOKOre: balance.availableNOKOre - quote.amountNOKOre,
                reservedNOKOre: balance.reservedNOKOre + quote.amountNOKOre,
                consumedNOKOre: balance.consumedNOKOre,
                updatedAt: Date()
            )
        )

        return WalletReservationResponse(record: reservation)
    }

    public func releaseWalletReservation(
        walletID: UUID,
        reservationID: UUID,
        request: ReleaseWalletReservationRequest
    ) async throws -> WalletReservationResponse {
        guard let wallet = try await walletStore.wallet(walletID: walletID),
              let balance = try await walletStore.balance(walletID: wallet.walletID) else {
            throw FundingServiceError.unknownWallet(walletID)
        }

        guard let reservation = try await walletReservationStore.reservation(reservationID: reservationID) else {
            throw FundingServiceError.unknownReservation(reservationID)
        }

        guard reservation.walletID == wallet.walletID else {
            throw FundingServiceError.unknownReservation(reservationID)
        }

        if reservation.status == .released {
            return WalletReservationResponse(record: reservation)
        }

        guard reservation.status == .active else {
            throw FundingServiceError.reservationNotActive(reservationID)
        }

        let released = reservation.with(status: .released, releasedAt: Date())
        try await walletReservationStore.upsertReservation(released)
        try await walletEventStore.insertWalletEvent(
            WalletEventRecord(
                walletID: wallet.walletID,
                customerID: wallet.customerID,
                quoteID: reservation.quoteID,
                cashEventID: nil,
                reservationID: reservation.reservationID,
                eventType: .walletReservationReleased,
                unitName: reservation.reservedUnitName,
                unitAmount: reservation.reservedUnitAmount,
                nokReferenceAmountOre: reservation.reservedNOKOre
            )
        )

        try await walletStore.upsertBalance(
            WalletBalanceProjection(
                walletID: balance.walletID,
                unitName: balance.unitName,
                availableUnits: balance.availableUnits + reservation.reservedUnitAmount,
                reservedUnits: balance.reservedUnits - reservation.reservedUnitAmount,
                consumedUnits: balance.consumedUnits,
                availableNOKOre: balance.availableNOKOre + reservation.reservedNOKOre,
                reservedNOKOre: balance.reservedNOKOre - reservation.reservedNOKOre,
                consumedNOKOre: balance.consumedNOKOre,
                updatedAt: Date()
            )
        )

        _ = request.reason
        return WalletReservationResponse(record: released)
    }

    public func createQuote(_ request: CreateQuoteRequest) async throws -> CreateQuoteResponse {
        guard request.quantity > 0 else {
            throw FundingServiceError.invalidQuantity(request.quantity)
        }

        guard let product = try await productCatalogStore.product(productID: request.productID) else {
            throw FundingServiceError.unknownProduct(request.productID)
        }

        guard product.isActive else {
            throw FundingServiceError.inactiveProduct(request.productID)
        }

        let wallet = try await resolveWallet(customerID: request.customerID, walletID: request.walletID)
        let amount = product.unitPriceNOKOre * Int64(request.quantity)
        guard amount >= 0 else {
            throw FundingServiceError.invalidAmount(amount)
        }

        let quote = PriceQuoteRecord(
            walletID: wallet.walletID,
            customerID: request.customerID,
            productID: request.productID,
            resourceID: request.resourceID,
            quantity: request.quantity,
            amountNOKOre: amount,
            unitAmount: amount,
            taxCode: product.taxCode,
            taxBehavior: product.taxBehavior,
            expiresAt: Date().addingTimeInterval(30 * 60)
        )

        try await quoteStore.upsertQuote(quote)
        return CreateQuoteResponse(record: quote)
    }

    public func createPaymentSession(_ request: CreatePaymentSessionRequest) async throws -> CreatePaymentSessionResponse {
        guard let quote = try await quoteStore.quote(quoteID: request.quoteID) else {
            throw FundingServiceError.unknownQuote(request.quoteID)
        }

        guard quote.expiresAt > Date() else {
            throw FundingServiceError.quoteExpired(quote.quoteID)
        }

        let providerPaymentRef = makeProviderPaymentRef(provider: request.provider)
        let checkoutURL = "https://checkout.example.invalid/\(request.provider.rawValue)/\(providerPaymentRef)"
        let payment = ProviderPaymentRecord(
            provider: request.provider,
            providerPaymentRef: providerPaymentRef,
            walletID: quote.walletID,
            customerID: quote.customerID,
            quoteID: quote.quoteID,
            requestedAmountNOKOre: quote.amountNOKOre,
            status: .initiated,
            checkoutURL: checkoutURL
        )

        try await providerPaymentStore.upsertPayment(payment)
        return CreatePaymentSessionResponse(record: payment, checkoutURL: checkoutURL)
    }

    public func ingestStripeWebhook(body: Data, headers: [String: String]) async throws -> StripeWebhookAcknowledgement {
        guard headers.keys.contains(where: { $0.caseInsensitiveCompare("Stripe-Signature") == .orderedSame }) else {
            throw FundingServiceError.missingWebhookSignature
        }

        let envelope = try JSONDecoder().decode(StripeWebhookEnvelope.self, from: body)
        if try await providerEventStore.providerEvent(provider: .stripe, providerEventRef: envelope.id) != nil {
            return StripeWebhookAcknowledgement(
                accepted: true,
                alreadyProcessed: true,
                providerEventRef: envelope.id,
                effect: "duplicate_ignored"
            )
        }

        let occurredAt = envelope.created.map(Date.init(timeIntervalSince1970:)) ?? Date()
        let providerEventRef = envelope.id
        let providerPaymentRef = envelope.data.object.paymentIntent ?? envelope.data.object.id
        let rawEvent = ProviderEventRecord(
            provider: .stripe,
            providerEventRef: providerEventRef,
            providerPaymentRef: providerPaymentRef,
            eventType: envelope.type,
            signatureVerified: true,
            occurredAt: occurredAt,
            payloadSHA256: FundingHashing.sha256Hex(body),
            rawBody: body,
            headers: headers
        )
        try await providerEventStore.insertProviderEvent(rawEvent)

        switch envelope.type {
        case "payment_intent.succeeded", "checkout.session.completed":
            let amount = envelope.data.object.amount ?? envelope.data.object.amountTotal
            guard let amount, amount >= 0 else {
                throw FundingServiceError.invalidStripeEventPayload
            }

            let payment = try await resolvePaymentForCapture(
                providerPaymentRef: providerPaymentRef,
                envelope: envelope,
                amount: amount
            )

            let updatedPayment = payment.with(status: .captured, requestedAmountNOKOre: max(payment.requestedAmountNOKOre, amount))
            try await providerPaymentStore.upsertPayment(updatedPayment)

            let cashEvent = CashEventRecord(
                providerPaymentID: updatedPayment.providerPaymentID,
                providerEventID: rawEvent.providerEventID,
                walletID: updatedPayment.walletID,
                customerID: updatedPayment.customerID,
                provider: .stripe,
                eventType: .paymentCaptured,
                grossAmountNOKOre: amount,
                netAmountNOKOre: amount,
                occurredAt: occurredAt
            )
            try await cashEventStore.insertCashEvent(cashEvent)

            let walletEvent = WalletEventRecord(
                walletID: updatedPayment.walletID,
                customerID: updatedPayment.customerID,
                quoteID: updatedPayment.quoteID,
                cashEventID: cashEvent.cashEventID,
                eventType: .walletCreditGranted,
                unitAmount: amount,
                nokReferenceAmountOre: amount,
                occurredAt: occurredAt
            )
            try await walletEventStore.insertWalletEvent(walletEvent)
            try await incrementWalletBalance(walletID: updatedPayment.walletID, amount: amount)

            return StripeWebhookAcknowledgement(
                accepted: true,
                alreadyProcessed: false,
                providerEventRef: providerEventRef,
                effect: "wallet_credited"
            )
        default:
            return StripeWebhookAcknowledgement(
                accepted: true,
                alreadyProcessed: false,
                providerEventRef: providerEventRef,
                effect: "stored_without_projection"
            )
        }
    }

    private func resolveWallet(customerID: String, walletID: UUID?) async throws -> StoredWallet {
        if let walletID {
            guard let wallet = try await walletStore.wallet(walletID: walletID) else {
                throw FundingServiceError.unknownWallet(walletID)
            }
            return wallet
        }

        if let existing = try await walletStore.wallet(customerID: customerID, currency: "NOK") {
            return existing
        }

        let wallet = StoredWallet(customerID: customerID)
        try await walletStore.upsertWallet(wallet)
        return wallet
    }

    private func resolvePaymentForCapture(
        providerPaymentRef: String,
        envelope: StripeWebhookEnvelope,
        amount: Int64
    ) async throws -> ProviderPaymentRecord {
        if let existing = try await providerPaymentStore.payment(provider: .stripe, providerPaymentRef: providerPaymentRef) {
            return existing
        }

        guard let metadata = envelope.data.object.metadata,
              let customerID = metadata["customer_id"] else {
            throw FundingServiceError.unknownProviderPaymentRef(providerPaymentRef)
        }

        let walletID: UUID
        if let rawWalletID = metadata["wallet_id"], let parsed = UUID(uuidString: rawWalletID) {
            walletID = parsed
            if try await walletStore.wallet(walletID: parsed) == nil {
                try await walletStore.upsertWallet(StoredWallet(walletID: parsed, customerID: customerID))
            }
        } else {
            let wallet = try await resolveWallet(customerID: customerID, walletID: nil)
            walletID = wallet.walletID
        }

        let quoteID = metadata["quote_id"].flatMap(UUID.init(uuidString:))
        guard let resolvedQuoteID = quoteID else {
            throw FundingServiceError.invalidStripeEventPayload
        }

        let checkoutURL = "https://checkout.example.invalid/stripe/\(providerPaymentRef)"
        let payment = ProviderPaymentRecord(
            provider: .stripe,
            providerPaymentRef: providerPaymentRef,
            walletID: walletID,
            customerID: customerID,
            quoteID: resolvedQuoteID,
            requestedAmountNOKOre: amount,
            status: .captured,
            checkoutURL: checkoutURL
        )
        try await providerPaymentStore.upsertPayment(payment)
        return payment
    }

    private func incrementWalletBalance(walletID: UUID, amount: Int64) async throws {
        guard let existing = try await walletStore.balance(walletID: walletID) else {
            throw FundingServiceError.unknownWallet(walletID)
        }

        let updated = WalletBalanceProjection(
            walletID: walletID,
            unitName: existing.unitName,
            availableUnits: existing.availableUnits + amount,
            reservedUnits: existing.reservedUnits,
            consumedUnits: existing.consumedUnits,
            availableNOKOre: existing.availableNOKOre + amount,
            reservedNOKOre: existing.reservedNOKOre,
            consumedNOKOre: existing.consumedNOKOre,
            updatedAt: Date()
        )
        try await walletStore.upsertBalance(updated)
    }

    private func normalizedResourceID(_ resourceID: String?) -> String? {
        let trimmed = resourceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func makeProviderPaymentRef(provider: PaymentProvider) -> String {
        "\(provider.rawValue)_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }
}
