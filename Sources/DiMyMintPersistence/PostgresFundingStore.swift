import Foundation
import DiMyMintCore

public actor PostgresFundingStore: ProductCatalogStore, WalletStore, WalletReservationStore, QuoteStore, ProviderPaymentStore, ProviderEventStore, CashEventStore, WalletEventStore {
    private let client: any PostgresClient

    public init(client: any PostgresClient) {
        self.client = client
    }

    public func product(productID: String) async throws -> ProductCatalogItem? {
        let sql = """
        select product_id, product_type, title, unit_price_nok_ore, tax_code, tax_behavior, is_active
        from product_catalog_items
        where product_id = $1
        """
        let rows = try await client.query(sql: sql, binds: [.string(productID)])
        guard let row = rows.first else {
            return nil
        }
        return try decodeProduct(row)
    }

    public func upsertProduct(_ product: ProductCatalogItem) async throws {
        let sql = """
        insert into product_catalog_items (
            product_id, product_type, title, currency, tax_code, tax_behavior, is_active, metadata, created_at, updated_at, description, unit_price_nok_ore
        ) values (
            $1, $2, $3, 'NOK', $4, $5, $6, '{}'::jsonb, now(), now(), null, $7
        )
        on conflict (product_id) do update set
            product_type = excluded.product_type,
            title = excluded.title,
            tax_code = excluded.tax_code,
            tax_behavior = excluded.tax_behavior,
            is_active = excluded.is_active,
            unit_price_nok_ore = excluded.unit_price_nok_ore
        """
        try await client.execute(
            sql: sql,
            binds: [
                .string(product.productID),
                .string(product.productType),
                .string(product.title),
                .string(product.taxCode),
                .string(product.taxBehavior.rawValue),
                .bool(product.isActive),
                .int64(product.unitPriceNOKOre)
            ]
        )
    }

    public func wallet(walletID: UUID) async throws -> StoredWallet? {
        let sql = """
        select wallet_id, customer_id, currency, status, created_at
        from wallets
        where wallet_id = $1
        """
        let rows = try await client.query(sql: sql, binds: [.uuid(walletID)])
        guard let row = rows.first else {
            return nil
        }
        return try decodeWallet(row)
    }

    public func wallet(customerID: String, currency: String) async throws -> StoredWallet? {
        let sql = """
        select wallet_id, customer_id, currency, status, created_at
        from wallets
        where customer_id = $1 and currency = $2
        """
        let rows = try await client.query(sql: sql, binds: [.string(customerID), .string(currency.uppercased())])
        guard let row = rows.first else {
            return nil
        }
        return try decodeWallet(row)
    }

    public func upsertWallet(_ wallet: StoredWallet) async throws {
        let walletSQL = """
        insert into wallets (wallet_id, customer_id, currency, status, created_at, updated_at, metadata)
        values ($1, $2, $3, $4, $5, now(), '{}'::jsonb)
        on conflict (wallet_id) do update set
            customer_id = excluded.customer_id,
            currency = excluded.currency,
            status = excluded.status
        """
        try await client.execute(
            sql: walletSQL,
            binds: [
                .uuid(wallet.walletID),
                .string(wallet.customerID),
                .string(wallet.currency),
                .string(wallet.status),
                .timestamp(wallet.createdAt)
            ]
        )

        let balanceSQL = """
        insert into wallet_balance_projections (
            wallet_id, unit_name, available_units, reserved_units, consumed_units,
            reversed_units, expired_units, available_nok_ore, reserved_nok_ore,
            consumed_nok_ore, reversed_nok_ore, expired_nok_ore, updated_at
        ) values (
            $1, 'NOK_ORE', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, now()
        )
        on conflict (wallet_id) do nothing
        """
        try await client.execute(sql: balanceSQL, binds: [.uuid(wallet.walletID)])
    }

    public func balance(walletID: UUID) async throws -> WalletBalanceProjection? {
        let sql = """
        select wallet_id, unit_name, available_units, reserved_units, consumed_units,
               available_nok_ore, reserved_nok_ore, consumed_nok_ore, updated_at
        from wallet_balance_projections
        where wallet_id = $1
        """
        let rows = try await client.query(sql: sql, binds: [.uuid(walletID)])
        guard let row = rows.first else {
            return nil
        }
        return try decodeBalance(row)
    }

    public func upsertBalance(_ balance: WalletBalanceProjection) async throws {
        let sql = """
        insert into wallet_balance_projections (
            wallet_id, unit_name, available_units, reserved_units, consumed_units,
            reversed_units, expired_units, available_nok_ore, reserved_nok_ore,
            consumed_nok_ore, reversed_nok_ore, expired_nok_ore, updated_at
        ) values (
            $1, $2, $3, $4, $5, 0, 0, $6, $7, $8, 0, 0, $9
        )
        on conflict (wallet_id) do update set
            unit_name = excluded.unit_name,
            available_units = excluded.available_units,
            reserved_units = excluded.reserved_units,
            consumed_units = excluded.consumed_units,
            available_nok_ore = excluded.available_nok_ore,
            reserved_nok_ore = excluded.reserved_nok_ore,
            consumed_nok_ore = excluded.consumed_nok_ore,
            updated_at = excluded.updated_at
        """
        try await client.execute(
            sql: sql,
            binds: [
                .uuid(balance.walletID),
                .string(balance.unitName),
                .int64(balance.availableUnits),
                .int64(balance.reservedUnits),
                .int64(balance.consumedUnits),
                .int64(balance.availableNOKOre),
                .int64(balance.reservedNOKOre),
                .int64(balance.consumedNOKOre),
                .timestamp(balance.updatedAt)
            ]
        )
    }

    public func reservation(reservationID: UUID) async throws -> WalletReservationRecord? {
        let sql = """
        select reservation_id, wallet_id, customer_id, quote_id, resource_id, status,
               reserved_unit_name, reserved_unit_amount, reserved_nok_ore,
               created_at, updated_at, expires_at, released_at
        from wallet_reservations
        where reservation_id = $1
        """
        let rows = try await client.query(sql: sql, binds: [.uuid(reservationID)])
        guard let row = rows.first else {
            return nil
        }
        return try decodeReservation(row)
    }

    public func upsertReservation(_ reservation: WalletReservationRecord) async throws {
        let sql = """
        insert into wallet_reservations (
            reservation_id, wallet_id, customer_id, quote_id, resource_id, status,
            reserved_unit_name, reserved_unit_amount, reserved_nok_ore,
            created_at, updated_at, expires_at, released_at, metadata
        ) values (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, '{}'::jsonb
        )
        on conflict (reservation_id) do update set
            status = excluded.status,
            updated_at = excluded.updated_at,
            released_at = excluded.released_at
        """
        try await client.execute(
            sql: sql,
            binds: [
                .uuid(reservation.reservationID),
                .uuid(reservation.walletID),
                .string(reservation.customerID),
                reservation.quoteID.map(PostgresBind.uuid) ?? .null,
                reservation.resourceID.map(PostgresBind.string) ?? .null,
                .string(reservation.status.rawValue),
                .string(reservation.reservedUnitName),
                .int64(reservation.reservedUnitAmount),
                .int64(reservation.reservedNOKOre),
                .timestamp(reservation.createdAt),
                .timestamp(reservation.updatedAt),
                reservation.expiresAt.map(PostgresBind.timestamp) ?? .null,
                reservation.releasedAt.map(PostgresBind.timestamp) ?? .null
            ]
        )
    }

    public func quote(quoteID: UUID) async throws -> PriceQuoteRecord? {
        let sql = """
        select quote_id, wallet_id, customer_id, product_id, resource_id, quantity,
               amount_nok_ore, unit_name, unit_amount, tax_code, tax_behavior,
               expires_at, created_at
        from price_quotes
        where quote_id = $1
        """
        let rows = try await client.query(sql: sql, binds: [.uuid(quoteID)])
        guard let row = rows.first else {
            return nil
        }
        return try decodeQuote(row)
    }

    public func upsertQuote(_ quote: PriceQuoteRecord) async throws {
        let sql = """
        insert into price_quotes (
            quote_id, wallet_id, customer_id, product_id, resource_id, quantity,
            amount_nok_ore, unit_name, unit_amount, tax_code, tax_behavior, expires_at, created_at, metadata
        ) values (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, '{}'::jsonb
        )
        on conflict (quote_id) do update set
            amount_nok_ore = excluded.amount_nok_ore,
            unit_amount = excluded.unit_amount,
            tax_code = excluded.tax_code,
            tax_behavior = excluded.tax_behavior,
            expires_at = excluded.expires_at
        """
        try await client.execute(
            sql: sql,
            binds: [
                .uuid(quote.quoteID),
                .uuid(quote.walletID),
                .string(quote.customerID),
                .string(quote.productID),
                quote.resourceID.map(PostgresBind.string) ?? .null,
                .int(quote.quantity),
                .int64(quote.amountNOKOre),
                .string(quote.unitName),
                .int64(quote.unitAmount),
                .string(quote.taxCode),
                .string(quote.taxBehavior.rawValue),
                .timestamp(quote.expiresAt),
                .timestamp(quote.createdAt)
            ]
        )
    }

    public func payment(providerPaymentID: UUID) async throws -> ProviderPaymentRecord? {
        let sql = """
        select provider_payment_id, provider, provider_payment_ref, wallet_id, customer_id,
               quote_id, requested_amount_nok_ore, status, provider_session_url, created_at
        from provider_payments
        where provider_payment_id = $1
        """
        let rows = try await client.query(sql: sql, binds: [.uuid(providerPaymentID)])
        guard let row = rows.first else {
            return nil
        }
        return try decodePayment(row)
    }

    public func payment(provider: PaymentProvider, providerPaymentRef: String) async throws -> ProviderPaymentRecord? {
        let sql = """
        select provider_payment_id, provider, provider_payment_ref, wallet_id, customer_id,
               quote_id, requested_amount_nok_ore, status, provider_session_url, created_at
        from provider_payments
        where provider = $1 and provider_payment_ref = $2
        """
        let rows = try await client.query(sql: sql, binds: [.string(provider.rawValue), .string(providerPaymentRef)])
        guard let row = rows.first else {
            return nil
        }
        return try decodePayment(row)
    }

    public func upsertPayment(_ payment: ProviderPaymentRecord) async throws {
        let sql = """
        insert into provider_payments (
            provider_payment_id, provider, provider_payment_ref, wallet_id, customer_id,
            quote_id, currency, requested_amount_nok_ore, captured_amount_nok_ore,
            refunded_amount_nok_ore, disputed_amount_nok_ore, fee_amount_nok_ore,
            net_settlement_amount_nok_ore, status, provider_session_url, created_at, updated_at, metadata
        ) values (
            $1, $2, $3, $4, $5, $6, 'NOK', $7, 0, 0, 0, 0, 0, $8, $9, $10, now(), '{}'::jsonb
        )
        on conflict (provider_payment_id) do update set
            requested_amount_nok_ore = excluded.requested_amount_nok_ore,
            status = excluded.status,
            provider_session_url = excluded.provider_session_url
        """
        try await client.execute(
            sql: sql,
            binds: [
                .uuid(payment.providerPaymentID),
                .string(payment.provider.rawValue),
                .string(payment.providerPaymentRef),
                .uuid(payment.walletID),
                .string(payment.customerID),
                .uuid(payment.quoteID),
                .int64(payment.requestedAmountNOKOre),
                .string(encodeStatus(payment.status)),
                payment.checkoutURL.map(PostgresBind.string) ?? .null,
                .timestamp(payment.createdAt)
            ]
        )
    }

    public func providerEvent(provider: PaymentProvider, providerEventRef: String) async throws -> ProviderEventRecord? {
        let sql = """
        select provider_event_id, provider, provider_event_ref, provider_payment_ref, event_type,
               event_created_at, signature_verified, payload_sha256, raw_body
        from provider_events_raw
        where provider = $1 and provider_event_ref = $2
        """
        let rows = try await client.query(sql: sql, binds: [.string(provider.rawValue), .string(providerEventRef)])
        guard let row = rows.first else {
            return nil
        }
        return try decodeProviderEvent(row)
    }

    public func insertProviderEvent(_ event: ProviderEventRecord) async throws {
        let sql = """
        insert into provider_events_raw (
            provider_event_id, provider, provider_event_ref, provider_payment_ref, event_type,
            event_created_at, received_at, signature_verified, request_headers, payload, raw_body, payload_sha256,
            processing_status, processed_at, metadata
        ) values (
            $1, $2, $3, $4, $5, $6, now(), $7, '{}'::jsonb, '{}'::jsonb, $8, $9, 'pending', null, '{}'::jsonb
        )
        on conflict (provider, provider_event_ref) do nothing
        """
        try await client.execute(
            sql: sql,
            binds: [
                .uuid(event.providerEventID),
                .string(event.provider.rawValue),
                .string(event.providerEventRef),
                event.providerPaymentRef.map(PostgresBind.string) ?? .null,
                .string(event.eventType),
                .timestamp(event.occurredAt),
                .bool(event.signatureVerified),
                .data(event.rawBody),
                .string(event.payloadSHA256)
            ]
        )
    }

    public func insertCashEvent(_ event: CashEventRecord) async throws {
        let sql = """
        insert into cash_events (
            cash_event_id, provider_payment_id, provider_event_id, wallet_id, customer_id,
            provider, event_type, currency, gross_amount_nok_ore, fee_amount_nok_ore,
            net_amount_nok_ore, idempotency_key, occurred_at, metadata
        ) values (
            $1, $2, $3, $4, $5, $6, $7, 'NOK', $8, $9, $10, null, $11, '{}'::jsonb
        )
        """
        try await client.execute(
            sql: sql,
            binds: [
                .uuid(event.cashEventID),
                .uuid(event.providerPaymentID),
                .uuid(event.providerEventID),
                .uuid(event.walletID),
                .string(event.customerID),
                .string(event.provider.rawValue),
                .string(event.eventType.rawValue),
                .int64(event.grossAmountNOKOre),
                .int64(event.feeAmountNOKOre),
                .int64(event.netAmountNOKOre),
                .timestamp(event.occurredAt)
            ]
        )
    }

    public func cashEvents(providerPaymentID: UUID) async throws -> [CashEventRecord] {
        let sql = """
        select cash_event_id, provider_payment_id, provider_event_id, wallet_id, customer_id,
               provider, event_type, gross_amount_nok_ore, fee_amount_nok_ore,
               net_amount_nok_ore, occurred_at
        from cash_events
        where provider_payment_id = $1
        order by occurred_at asc
        """
        let rows = try await client.query(sql: sql, binds: [.uuid(providerPaymentID)])
        return try rows.map(decodeCashEvent)
    }

    public func insertWalletEvent(_ event: WalletEventRecord) async throws {
        let sql = """
        insert into wallet_events (
            value_event_id, wallet_id, customer_id, quote_id, cash_event_id, provider_payment_id,
            reservation_id, unit_name, unit_amount, nok_reference_amount_ore, event_type,
            occurred_at, reversal_of_event_id, idempotency_key, metadata
        ) values (
            $1, $2, $3, $4, $5, null, $6, $7, $8, $9, $10, $11, null, null, '{}'::jsonb
        )
        """
        try await client.execute(
            sql: sql,
            binds: [
                .uuid(event.valueEventID),
                .uuid(event.walletID),
                .string(event.customerID),
                event.quoteID.map(PostgresBind.uuid) ?? .null,
                event.cashEventID.map(PostgresBind.uuid) ?? .null,
                event.reservationID.map(PostgresBind.uuid) ?? .null,
                .string(event.unitName),
                .int64(event.unitAmount),
                .int64(event.nokReferenceAmountOre),
                .string(event.eventType.rawValue),
                .timestamp(event.occurredAt)
            ]
        )
    }

    public func walletEvents(walletID: UUID) async throws -> [WalletEventRecord] {
        let sql = """
        select value_event_id, wallet_id, customer_id, quote_id, cash_event_id, reservation_id, unit_name,
               unit_amount, nok_reference_amount_ore, event_type, occurred_at
        from wallet_events
        where wallet_id = $1
        order by occurred_at asc
        """
        let rows = try await client.query(sql: sql, binds: [.uuid(walletID)])
        return try rows.map(decodeWalletEvent)
    }

    private func decodeProduct(_ row: PostgresRow) throws -> ProductCatalogItem {
        ProductCatalogItem(
            productID: try requireString("product_id", row),
            productType: try requireString("product_type", row),
            title: try requireString("title", row),
            unitPriceNOKOre: try requireInt64("unit_price_nok_ore", row),
            taxCode: try requireString("tax_code", row),
            taxBehavior: try ProductTaxBehavior(rawValue: requireString("tax_behavior", row)) ?? {
                throw PostgresFundingStoreError.unsupportedValue("tax_behavior")
            }(),
            isActive: try requireBool("is_active", row)
        )
    }

    private func decodeWallet(_ row: PostgresRow) throws -> StoredWallet {
        StoredWallet(
            walletID: try requireUUID("wallet_id", row),
            customerID: try requireString("customer_id", row),
            currency: try requireString("currency", row),
            status: try requireString("status", row),
            createdAt: try requireTimestamp("created_at", row)
        )
    }

    private func decodeBalance(_ row: PostgresRow) throws -> WalletBalanceProjection {
        WalletBalanceProjection(
            walletID: try requireUUID("wallet_id", row),
            unitName: try requireString("unit_name", row),
            availableUnits: try requireInt64("available_units", row),
            reservedUnits: try requireInt64("reserved_units", row),
            consumedUnits: try requireInt64("consumed_units", row),
            availableNOKOre: try requireInt64("available_nok_ore", row),
            reservedNOKOre: try requireInt64("reserved_nok_ore", row),
            consumedNOKOre: try requireInt64("consumed_nok_ore", row),
            updatedAt: try requireTimestamp("updated_at", row)
        )
    }

    private func decodeReservation(_ row: PostgresRow) throws -> WalletReservationRecord {
        WalletReservationRecord(
            reservationID: try requireUUID("reservation_id", row),
            walletID: try requireUUID("wallet_id", row),
            customerID: try requireString("customer_id", row),
            quoteID: row.uuid("quote_id"),
            resourceID: row.string("resource_id"),
            status: try WalletReservationStatus(rawValue: requireString("status", row)) ?? {
                throw PostgresFundingStoreError.unsupportedValue("reservation_status")
            }(),
            reservedUnitName: try requireString("reserved_unit_name", row),
            reservedUnitAmount: try requireInt64("reserved_unit_amount", row),
            reservedNOKOre: try requireInt64("reserved_nok_ore", row),
            createdAt: try requireTimestamp("created_at", row),
            updatedAt: try requireTimestamp("updated_at", row),
            expiresAt: row.timestamp("expires_at"),
            releasedAt: row.timestamp("released_at")
        )
    }

    private func decodeQuote(_ row: PostgresRow) throws -> PriceQuoteRecord {
        PriceQuoteRecord(
            quoteID: try requireUUID("quote_id", row),
            walletID: try requireUUID("wallet_id", row),
            customerID: try requireString("customer_id", row),
            productID: try requireString("product_id", row),
            resourceID: row.string("resource_id"),
            quantity: try requireInt("quantity", row),
            amountNOKOre: try requireInt64("amount_nok_ore", row),
            unitName: try requireString("unit_name", row),
            unitAmount: try requireInt64("unit_amount", row),
            taxCode: try requireString("tax_code", row),
            taxBehavior: try ProductTaxBehavior(rawValue: requireString("tax_behavior", row)) ?? {
                throw PostgresFundingStoreError.unsupportedValue("tax_behavior")
            }(),
            expiresAt: try requireTimestamp("expires_at", row),
            createdAt: try requireTimestamp("created_at", row)
        )
    }

    private func decodePayment(_ row: PostgresRow) throws -> ProviderPaymentRecord {
        let status = try decodePaymentStatus(try requireString("status", row))
        return ProviderPaymentRecord(
            providerPaymentID: try requireUUID("provider_payment_id", row),
            provider: try PaymentProvider(rawValue: requireString("provider", row)) ?? {
                throw PostgresFundingStoreError.unsupportedValue("provider")
            }(),
            providerPaymentRef: try requireString("provider_payment_ref", row),
            walletID: try requireUUID("wallet_id", row),
            customerID: try requireString("customer_id", row),
            quoteID: try requireUUID("quote_id", row),
            requestedAmountNOKOre: try requireInt64("requested_amount_nok_ore", row),
            status: status,
            checkoutURL: row.string("provider_session_url"),
            createdAt: try requireTimestamp("created_at", row)
        )
    }

    private func decodeProviderEvent(_ row: PostgresRow) throws -> ProviderEventRecord {
        ProviderEventRecord(
            providerEventID: try requireUUID("provider_event_id", row),
            provider: try PaymentProvider(rawValue: requireString("provider", row)) ?? {
                throw PostgresFundingStoreError.unsupportedValue("provider")
            }(),
            providerEventRef: try requireString("provider_event_ref", row),
            providerPaymentRef: row.string("provider_payment_ref"),
            eventType: try requireString("event_type", row),
            signatureVerified: try requireBool("signature_verified", row),
            occurredAt: try requireTimestamp("event_created_at", row),
            payloadSHA256: try requireString("payload_sha256", row),
            rawBody: try requireData("raw_body", row),
            headers: [:]
        )
    }

    private func decodeCashEvent(_ row: PostgresRow) throws -> CashEventRecord {
        CashEventRecord(
            cashEventID: try requireUUID("cash_event_id", row),
            providerPaymentID: try requireUUID("provider_payment_id", row),
            providerEventID: try requireUUID("provider_event_id", row),
            walletID: try requireUUID("wallet_id", row),
            customerID: try requireString("customer_id", row),
            provider: try PaymentProvider(rawValue: requireString("provider", row)) ?? {
                throw PostgresFundingStoreError.unsupportedValue("provider")
            }(),
            eventType: try CashEventType(rawValue: requireString("event_type", row)) ?? {
                throw PostgresFundingStoreError.unsupportedValue("cash_event_type")
            }(),
            grossAmountNOKOre: try requireInt64("gross_amount_nok_ore", row),
            feeAmountNOKOre: try requireInt64("fee_amount_nok_ore", row),
            netAmountNOKOre: try requireInt64("net_amount_nok_ore", row),
            occurredAt: try requireTimestamp("occurred_at", row)
        )
    }

    private func decodeWalletEvent(_ row: PostgresRow) throws -> WalletEventRecord {
        WalletEventRecord(
            valueEventID: try requireUUID("value_event_id", row),
            walletID: try requireUUID("wallet_id", row),
            customerID: try requireString("customer_id", row),
            quoteID: row.uuid("quote_id"),
            cashEventID: row.uuid("cash_event_id"),
            reservationID: row.uuid("reservation_id"),
            eventType: try WalletEventType(rawValue: requireString("event_type", row)) ?? {
                throw PostgresFundingStoreError.unsupportedValue("wallet_event_type")
            }(),
            unitName: try requireString("unit_name", row),
            unitAmount: try requireInt64("unit_amount", row),
            nokReferenceAmountOre: try requireInt64("nok_reference_amount_ore", row),
            occurredAt: try requireTimestamp("occurred_at", row)
        )
    }

    private func decodePaymentStatus(_ value: String) throws -> ProviderPaymentStatus {
        switch value {
        case "initiated":
            return .initiated
        case "authorized":
            return .authorized
        case "captured":
            return .captured
        case "failed":
            return .failed
        case "partially_refunded":
            return .partiallyRefunded
        case "refunded":
            return .refunded
        case "disputed":
            return .disputed
        case "reversed":
            return .reversed
        case "settled":
            return .settled
        default:
            throw PostgresFundingStoreError.unsupportedValue("status")
        }
    }

    private func encodeStatus(_ status: ProviderPaymentStatus) -> String {
        switch status {
        case .initiated:
            return "initiated"
        case .authorized:
            return "authorized"
        case .captured:
            return "captured"
        case .failed:
            return "failed"
        case .partiallyRefunded:
            return "partially_refunded"
        case .refunded:
            return "refunded"
        case .disputed:
            return "disputed"
        case .reversed:
            return "reversed"
        case .settled:
            return "settled"
        }
    }

    private func requireString(_ key: String, _ row: PostgresRow) throws -> String {
        guard let value = row.string(key) else {
            throw PostgresFundingStoreError.missingColumn(key)
        }
        return value
    }

    private func requireInt64(_ key: String, _ row: PostgresRow) throws -> Int64 {
        guard let value = row.int64(key) else {
            throw PostgresFundingStoreError.missingColumn(key)
        }
        return value
    }

    private func requireInt(_ key: String, _ row: PostgresRow) throws -> Int {
        guard let value = row.int(key) else {
            throw PostgresFundingStoreError.missingColumn(key)
        }
        return value
    }

    private func requireUUID(_ key: String, _ row: PostgresRow) throws -> UUID {
        guard let value = row.uuid(key) else {
            throw PostgresFundingStoreError.missingColumn(key)
        }
        return value
    }

    private func requireTimestamp(_ key: String, _ row: PostgresRow) throws -> Date {
        guard let value = row.timestamp(key) else {
            throw PostgresFundingStoreError.missingColumn(key)
        }
        return value
    }

    private func requireBool(_ key: String, _ row: PostgresRow) throws -> Bool {
        guard let value = row.bool(key) else {
            throw PostgresFundingStoreError.missingColumn(key)
        }
        return value
    }

    private func requireData(_ key: String, _ row: PostgresRow) throws -> Data {
        guard let value = row.data(key) else {
            throw PostgresFundingStoreError.missingColumn(key)
        }
        return value
    }
}
