import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct StripeEntitlementProviderConfiguration: Sendable {
    public let accountID: String
    public let secretKey: String
    public let webhookSecret: String
    public let expectedCurrency: String
    public let webhookToleranceSeconds: TimeInterval

    public init(
        accountID: String,
        secretKey: String,
        webhookSecret: String,
        expectedCurrency: String = "NOK",
        webhookToleranceSeconds: TimeInterval = 300
    ) throws {
        let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let webhookSecret = webhookSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let currency = expectedCurrency.uppercased()
        guard accountID.hasPrefix("acct_"), accountID.count > 5 else {
            throw StripeEntitlementProviderError.invalidConfiguration("account_id")
        }
        guard secretKey.hasPrefix("sk_test_"), !secretKey.hasPrefix("sk_live_") else {
            throw StripeEntitlementProviderError.liveModeForbidden
        }
        guard webhookSecret.hasPrefix("whsec_"), webhookSecret.count > 7 else {
            throw StripeEntitlementProviderError.invalidConfiguration("webhook_secret")
        }
        guard currency.count == 3,
              currency.unicodeScalars.allSatisfy(Self.isUppercaseASCII) else {
            throw StripeEntitlementProviderError.invalidConfiguration("currency")
        }
        guard webhookToleranceSeconds > 0, webhookToleranceSeconds <= 300 else {
            throw StripeEntitlementProviderError.invalidConfiguration("webhook_tolerance")
        }
        self.accountID = accountID
        self.secretKey = secretKey
        self.webhookSecret = webhookSecret
        self.expectedCurrency = currency
        self.webhookToleranceSeconds = webhookToleranceSeconds
    }

    private static func isUppercaseASCII(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 65 && scalar.value <= 90
    }
}

public struct StripeEntitlementHTTPRequest: Sendable {
    public let url: URL
    public let headers: [String: String]
    public let body: Data

    public init(url: URL, headers: [String: String], body: Data) {
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct StripeEntitlementHTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol StripeEntitlementHTTPTransport: Sendable {
    func send(_ request: StripeEntitlementHTTPRequest) async throws -> StripeEntitlementHTTPResponse
}

public struct URLSessionStripeEntitlementHTTPTransport: StripeEntitlementHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: StripeEntitlementHTTPRequest) async throws -> StripeEntitlementHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body
        do {
            let (body, response) = try await session.data(for: urlRequest)
            guard let response = response as? HTTPURLResponse else {
                throw StripeEntitlementProviderError.providerNetworkFailure
            }
            return StripeEntitlementHTTPResponse(statusCode: response.statusCode, body: body)
        } catch let error as StripeEntitlementProviderError {
            throw error
        } catch {
            throw StripeEntitlementProviderError.providerNetworkFailure
        }
    }
}

public actor StripeEntitlementProviderService {
    private let configuration: StripeEntitlementProviderConfiguration
    private let store: any StripeEntitlementProviderStore
    private let transport: any StripeEntitlementHTTPTransport
    private let now: @Sendable () -> Date

    public init(
        configuration: StripeEntitlementProviderConfiguration,
        store: any StripeEntitlementProviderStore,
        transport: any StripeEntitlementHTTPTransport = URLSessionStripeEntitlementHTTPTransport(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.store = store
        self.transport = transport
        self.now = now
    }

    public func createCheckoutSession(
        for order: EntitlementCheckoutOrder
    ) async throws -> StripeEntitlementCheckoutSession {
        try Self.validate(order: order, expectedCurrency: configuration.expectedCurrency)
        let binding = Self.bindingSHA256(order: order, accountID: configuration.accountID)
        let idempotencyKey = "haven-entitlement-\(binding)"
        let reserved = try await store.reserveOrder(
            StripeEntitlementOrderRecord(
                order: order,
                providerAccountID: configuration.accountID,
                bindingSHA256: binding,
                idempotencyKey: idempotencyKey,
                createdAt: now()
            )
        )
        if let sessionID = reserved.providerSessionID,
           let checkoutURL = reserved.checkoutURL {
            return StripeEntitlementCheckoutSession(
                providerSessionID: sessionID,
                checkoutURL: checkoutURL,
                orderID: order.orderID,
                bindingSHA256: binding,
                idempotencyKey: idempotencyKey
            )
        }

        let metadata = Self.metadata(order: order, accountID: configuration.accountID, bindingSHA256: binding)
        let request = StripeEntitlementHTTPRequest(
            url: URL(string: "https://api.stripe.com/v1/checkout/sessions")!,
            headers: [
                "Authorization": "Bearer \(configuration.secretKey)",
                "Content-Type": "application/x-www-form-urlencoded",
                "Idempotency-Key": idempotencyKey
            ],
            body: Self.formBody(order: order, metadata: metadata)
        )
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw StripeEntitlementProviderError.providerRejected(response.statusCode)
        }
        guard response.body.count <= 65_536 else {
            throw StripeEntitlementProviderError.invalidProviderResponse
        }
        let decoded: StripeCheckoutSessionResponse
        do {
            decoded = try JSONDecoder().decode(StripeCheckoutSessionResponse.self, from: response.body)
        } catch {
            throw StripeEntitlementProviderError.invalidProviderResponse
        }
        try Self.validate(response: decoded, order: order, expectedMetadata: metadata)
        let session = StripeEntitlementCheckoutSession(
            providerSessionID: decoded.id,
            checkoutURL: decoded.url,
            orderID: order.orderID,
            bindingSHA256: binding,
            idempotencyKey: idempotencyKey
        )
        _ = try await store.attachSession(session, toOrderID: order.orderID)
        return session
    }

    public func ingestWebhook(
        rawBody: Data,
        stripeSignature: String?
    ) async throws -> StripeEntitlementWebhookResult {
        guard rawBody.count <= 1_048_576 else {
            throw StripeEntitlementProviderError.invalidWebhookPayload
        }
        guard let stripeSignature, !stripeSignature.isEmpty else {
            throw StripeEntitlementProviderError.missingWebhookSignature
        }
        let verification = try StripeWebhookVerifier.verify(
            rawBody: rawBody,
            signatureHeader: stripeSignature,
            secret: configuration.webhookSecret,
            toleranceSeconds: configuration.webhookToleranceSeconds,
            now: now()
        )
        let envelope: StripeEventEnvelope
        do {
            envelope = try JSONDecoder().decode(StripeEventEnvelope.self, from: rawBody)
        } catch {
            throw StripeEntitlementProviderError.invalidWebhookPayload
        }
        let orderID = envelope.data.object.metadata?["order_id"] ?? ""
        guard let order = try await store.order(orderID: orderID) else {
            throw StripeEntitlementProviderError.unknownOrder
        }
        let event = try Self.validate(
            envelope: envelope,
            verification: verification,
            order: order,
            expectedAccountID: configuration.accountID,
            expectedCurrency: configuration.expectedCurrency
        )
        let result = try await store.admitVerifiedEvent(event)
        return StripeEntitlementWebhookResult(
            providerEventID: event.providerEventID,
            orderID: event.orderID,
            providerSessionID: event.providerSessionID,
            state: result.order.state,
            admission: result.admission,
            mayRequestEntitlementIssuance:
                result.admission == .accepted && result.order.state == .paymentConfirmed
        )
    }
}

extension StripeEntitlementProviderService {
    static let contractSchema = "haven.provider.entitlement-checkout.v0"

    static func validate(order: EntitlementCheckoutOrder, expectedCurrency: String) throws {
        guard isIdentifier(order.orderID),
              isIdentifier(order.subjectID),
              isIdentifier(order.agreementID),
              order.amountMinor > 0,
              order.currency.uppercased() == expectedCurrency else {
            throw StripeEntitlementProviderError.invalidOrder
        }
        for rawURL in [order.successURL, order.cancelURL] {
            guard let url = URL(string: rawURL),
                  url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil else {
                throw StripeEntitlementProviderError.invalidOrder
            }
        }
    }

    static func isIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 200 &&
            !trimmed.contains("\n") && !trimmed.contains("\r")
    }

    static func bindingSHA256(order: EntitlementCheckoutOrder, accountID: String) -> String {
        let fields = [
            contractSchema,
            "stripe",
            "test",
            accountID,
            order.orderID,
            order.subjectID,
            order.agreementID,
            order.productKind.rawValue,
            String(order.amountMinor),
            order.currency.uppercased(),
            order.successURL,
            order.cancelURL,
            "non_transferable=true",
            "cash_out=false",
            "external_acceptance=false"
        ]
        return StripeEntitlementHashing.sha256Hex(Data(fields.joined(separator: "\n").utf8))
    }

    static func metadata(
        order: EntitlementCheckoutOrder,
        accountID: String,
        bindingSHA256: String
    ) -> [String: String] {
        [
            "contract_schema": contractSchema,
            "provider": "stripe",
            "provider_mode": "test",
            "provider_account_id": accountID,
            "order_id": order.orderID,
            "subject_id": order.subjectID,
            "agreement_id": order.agreementID,
            "product_kind": order.productKind.rawValue,
            "amount_minor": String(order.amountMinor),
            "currency": order.currency.uppercased(),
            "binding_sha256": bindingSHA256,
            "non_transferable": "true",
            "cash_out": "false",
            "external_acceptance": "false"
        ]
    }

    static func formBody(order: EntitlementCheckoutOrder, metadata: [String: String]) -> Data {
        var fields: [String: String] = [
            "mode": "payment",
            "success_url": order.successURL,
            "cancel_url": order.cancelURL,
            "client_reference_id": order.orderID,
            "line_items[0][quantity]": "1",
            "line_items[0][price_data][currency]": order.currency.lowercased(),
            "line_items[0][price_data][unit_amount]": String(order.amountMinor),
            "line_items[0][price_data][product_data][name]": order.productKind.rawValue
        ]
        for (key, value) in metadata {
            fields["metadata[\(key)]"] = value
        }
        return Data(
            fields.sorted { $0.key < $1.key }
                .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
                .joined(separator: "&").utf8
        )
    }

    static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    static func validate(
        response: StripeCheckoutSessionResponse,
        order: EntitlementCheckoutOrder,
        expectedMetadata: [String: String]
    ) throws {
        guard response.id.hasPrefix("cs_test_"),
              response.livemode == false,
              response.mode == "payment",
              response.status == "open",
              response.paymentStatus == "unpaid",
              response.clientReferenceID == order.orderID,
              response.amountTotal == order.amountMinor,
              response.currency?.uppercased() == order.currency.uppercased(),
              response.metadata == expectedMetadata,
              let url = URL(string: response.url),
              url.scheme == "https", url.host == "checkout.stripe.com",
              url.user == nil, url.password == nil else {
            throw StripeEntitlementProviderError.invalidProviderResponse
        }
    }

    static func validate(
        envelope: StripeEventEnvelope,
        verification: StripeWebhookVerification,
        order: StripeEntitlementOrderRecord,
        expectedAccountID: String,
        expectedCurrency: String
    ) throws -> VerifiedStripeEntitlementEvent {
        let object = envelope.data.object
        let expectedMetadata = metadata(
            order: order.order,
            accountID: expectedAccountID,
            bindingSHA256: order.bindingSHA256
        )
        guard envelope.object == "event",
              envelope.id.hasPrefix("evt_"),
              envelope.account.map({ $0 == expectedAccountID }) ?? true,
              envelope.livemode == false,
              object.id == order.providerSessionID,
              object.id.hasPrefix("cs_test_"),
              object.livemode == false,
              object.mode == "payment",
              object.clientReferenceID == order.order.orderID,
              object.amountTotal == order.order.amountMinor,
              object.currency?.uppercased() == expectedCurrency,
              object.currency?.uppercased() == order.order.currency.uppercased(),
              object.metadata == expectedMetadata else {
            throw StripeEntitlementProviderError.webhookBindingMismatch
        }

        let requestedState: StripeEntitlementPaymentState
        switch envelope.type {
        case "checkout.session.completed":
            switch object.paymentStatus {
            case "paid": requestedState = .paymentConfirmed
            case "unpaid": requestedState = .paymentPending
            default: throw StripeEntitlementProviderError.paymentIncomplete
            }
        case "checkout.session.async_payment_succeeded":
            guard object.paymentStatus == "paid" else {
                throw StripeEntitlementProviderError.paymentIncomplete
            }
            requestedState = .paymentConfirmed
        case "checkout.session.async_payment_failed":
            guard object.paymentStatus == "unpaid" else {
                throw StripeEntitlementProviderError.webhookBindingMismatch
            }
            requestedState = .paymentFailed
        default:
            throw StripeEntitlementProviderError.unsupportedProviderEvent
        }

        return VerifiedStripeEntitlementEvent(
            providerEventID: envelope.id,
            providerEventType: envelope.type,
            providerCreatedAt: Date(timeIntervalSince1970: TimeInterval(envelope.created)),
            signatureTimestamp: verification.timestamp,
            payloadSHA256: verification.payloadSHA256,
            deliverySHA256: verification.deliverySHA256,
            orderID: order.order.orderID,
            providerSessionID: object.id,
            providerAccountID: expectedAccountID,
            bindingSHA256: order.bindingSHA256,
            subjectID: order.order.subjectID,
            agreementID: order.order.agreementID,
            productKind: order.order.productKind,
            amountMinor: order.order.amountMinor,
            currency: order.order.currency.uppercased(),
            requestedState: requestedState
        )
    }
}

struct StripeCheckoutSessionResponse: Decodable {
    let id: String
    let url: String
    let livemode: Bool
    let mode: String
    let status: String
    let paymentStatus: String
    let clientReferenceID: String?
    let amountTotal: Int64?
    let currency: String?
    let metadata: [String: String]

    private enum CodingKeys: String, CodingKey {
        case id, url, livemode, mode, status, currency, metadata
        case paymentStatus = "payment_status"
        case clientReferenceID = "client_reference_id"
        case amountTotal = "amount_total"
    }
}

struct StripeEventEnvelope: Decodable {
    struct DataContainer: Decodable {
        let object: StripeCheckoutEventObject
    }

    let id: String
    let object: String
    let account: String?
    let livemode: Bool
    let type: String
    let created: Int64
    let data: DataContainer
}

struct StripeCheckoutEventObject: Decodable {
    let id: String
    let livemode: Bool
    let mode: String
    let paymentStatus: String?
    let clientReferenceID: String?
    let amountTotal: Int64?
    let currency: String?
    let metadata: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case id, livemode, mode, currency, metadata
        case paymentStatus = "payment_status"
        case clientReferenceID = "client_reference_id"
        case amountTotal = "amount_total"
    }
}
