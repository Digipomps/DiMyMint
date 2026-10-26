import Foundation

public protocol ProductCatalogStore: Sendable {
    func product(productID: String) async throws -> ProductCatalogItem?
    func upsertProduct(_ product: ProductCatalogItem) async throws
}

public protocol WalletStore: Sendable {
    func wallet(walletID: UUID) async throws -> StoredWallet?
    func wallet(customerID: String, currency: String) async throws -> StoredWallet?
    func upsertWallet(_ wallet: StoredWallet) async throws
    func balance(walletID: UUID) async throws -> WalletBalanceProjection?
    func upsertBalance(_ balance: WalletBalanceProjection) async throws
}

public protocol WalletReservationStore: Sendable {
    func reservation(reservationID: UUID) async throws -> WalletReservationRecord?
    func upsertReservation(_ reservation: WalletReservationRecord) async throws
}

public protocol QuoteStore: Sendable {
    func quote(quoteID: UUID) async throws -> PriceQuoteRecord?
    func upsertQuote(_ quote: PriceQuoteRecord) async throws
}

public protocol ProviderPaymentStore: Sendable {
    func payment(providerPaymentID: UUID) async throws -> ProviderPaymentRecord?
    func payment(provider: PaymentProvider, providerPaymentRef: String) async throws -> ProviderPaymentRecord?
    func upsertPayment(_ payment: ProviderPaymentRecord) async throws
}

public protocol ProviderEventStore: Sendable {
    func providerEvent(provider: PaymentProvider, providerEventRef: String) async throws -> ProviderEventRecord?
    func insertProviderEvent(_ event: ProviderEventRecord) async throws
}

public protocol CashEventStore: Sendable {
    func insertCashEvent(_ event: CashEventRecord) async throws
    func cashEvents(providerPaymentID: UUID) async throws -> [CashEventRecord]
}

public protocol WalletEventStore: Sendable {
    func insertWalletEvent(_ event: WalletEventRecord) async throws
    func walletEvents(walletID: UUID) async throws -> [WalletEventRecord]
}

public actor InMemoryFundingStore: ProductCatalogStore, WalletStore, WalletReservationStore, QuoteStore, ProviderPaymentStore, ProviderEventStore, CashEventStore, WalletEventStore {
    private var products: [String: ProductCatalogItem] = [:]
    private var walletsByID: [UUID: StoredWallet] = [:]
    private var walletIDsByCustomerCurrency: [String: UUID] = [:]
    private var balancesByWalletID: [UUID: WalletBalanceProjection] = [:]
    private var reservationsByID: [UUID: WalletReservationRecord] = [:]
    private var quotesByID: [UUID: PriceQuoteRecord] = [:]
    private var paymentsByID: [UUID: ProviderPaymentRecord] = [:]
    private var paymentIDsByProviderRef: [String: UUID] = [:]
    private var providerEventsByRef: [String: ProviderEventRecord] = [:]
    private var cashEventsByPaymentID: [UUID: [CashEventRecord]] = [:]
    private var walletEventsByWalletID: [UUID: [WalletEventRecord]] = [:]

    public init() {}

    private func paymentKey(provider: PaymentProvider, providerPaymentRef: String) -> String {
        "\(provider.rawValue)|\(providerPaymentRef)"
    }

    private func providerEventKey(provider: PaymentProvider, providerEventRef: String) -> String {
        "\(provider.rawValue)|\(providerEventRef)"
    }

    private func walletCustomerCurrencyKey(customerID: String, currency: String) -> String {
        "\(customerID)|\(currency.uppercased())"
    }

    public func product(productID: String) async throws -> ProductCatalogItem? {
        products[productID]
    }

    public func upsertProduct(_ product: ProductCatalogItem) async throws {
        products[product.productID] = product
    }

    public func wallet(walletID: UUID) async throws -> StoredWallet? {
        walletsByID[walletID]
    }

    public func wallet(customerID: String, currency: String) async throws -> StoredWallet? {
        let key = walletCustomerCurrencyKey(customerID: customerID, currency: currency)
        guard let walletID = walletIDsByCustomerCurrency[key] else {
            return nil
        }
        return walletsByID[walletID]
    }

    public func upsertWallet(_ wallet: StoredWallet) async throws {
        walletsByID[wallet.walletID] = wallet
        walletIDsByCustomerCurrency[walletCustomerCurrencyKey(customerID: wallet.customerID, currency: wallet.currency)] = wallet.walletID
        if balancesByWalletID[wallet.walletID] == nil {
            balancesByWalletID[wallet.walletID] = WalletBalanceProjection(walletID: wallet.walletID)
        }
    }

    public func balance(walletID: UUID) async throws -> WalletBalanceProjection? {
        balancesByWalletID[walletID]
    }

    public func upsertBalance(_ balance: WalletBalanceProjection) async throws {
        balancesByWalletID[balance.walletID] = balance
    }

    public func reservation(reservationID: UUID) async throws -> WalletReservationRecord? {
        reservationsByID[reservationID]
    }

    public func upsertReservation(_ reservation: WalletReservationRecord) async throws {
        reservationsByID[reservation.reservationID] = reservation
    }

    public func quote(quoteID: UUID) async throws -> PriceQuoteRecord? {
        quotesByID[quoteID]
    }

    public func upsertQuote(_ quote: PriceQuoteRecord) async throws {
        quotesByID[quote.quoteID] = quote
    }

    public func payment(providerPaymentID: UUID) async throws -> ProviderPaymentRecord? {
        paymentsByID[providerPaymentID]
    }

    public func payment(provider: PaymentProvider, providerPaymentRef: String) async throws -> ProviderPaymentRecord? {
        guard let paymentID = paymentIDsByProviderRef[paymentKey(provider: provider, providerPaymentRef: providerPaymentRef)] else {
            return nil
        }
        return paymentsByID[paymentID]
    }

    public func upsertPayment(_ payment: ProviderPaymentRecord) async throws {
        paymentsByID[payment.providerPaymentID] = payment
        paymentIDsByProviderRef[paymentKey(provider: payment.provider, providerPaymentRef: payment.providerPaymentRef)] = payment.providerPaymentID
    }

    public func providerEvent(provider: PaymentProvider, providerEventRef: String) async throws -> ProviderEventRecord? {
        providerEventsByRef[providerEventKey(provider: provider, providerEventRef: providerEventRef)]
    }

    public func insertProviderEvent(_ event: ProviderEventRecord) async throws {
        providerEventsByRef[providerEventKey(provider: event.provider, providerEventRef: event.providerEventRef)] = event
    }

    public func insertCashEvent(_ event: CashEventRecord) async throws {
        cashEventsByPaymentID[event.providerPaymentID, default: []].append(event)
    }

    public func cashEvents(providerPaymentID: UUID) async throws -> [CashEventRecord] {
        cashEventsByPaymentID[providerPaymentID, default: []]
    }

    public func insertWalletEvent(_ event: WalletEventRecord) async throws {
        walletEventsByWalletID[event.walletID, default: []].append(event)
    }

    public func walletEvents(walletID: UUID) async throws -> [WalletEventRecord] {
        walletEventsByWalletID[walletID, default: []]
    }
}
