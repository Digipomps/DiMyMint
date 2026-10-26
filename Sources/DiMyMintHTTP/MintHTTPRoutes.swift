import Foundation

public enum MintHTTPMethod: String, Codable, Hashable, Sendable {
    case get = "GET"
    case post = "POST"
}

public struct MintHTTPRouteDefinition: Codable, Hashable, Sendable {
    public let method: MintHTTPMethod
    public let path: String
    public let summary: String

    public init(method: MintHTTPMethod, path: String, summary: String) {
        self.method = method
        self.path = path
        self.summary = summary
    }
}

public struct MintHTTPRequestContext: Sendable {
    public let body: Data
    public let headers: [String: String]
    public let pathParameters: [String: String]

    public init(
        body: Data = Data(),
        headers: [String: String] = [:],
        pathParameters: [String: String] = [:]
    ) {
        self.body = body
        self.headers = headers
        self.pathParameters = pathParameters
    }
}

public enum MintHTTPRoute: String, CaseIterable, Sendable {
    case issue
    case redeem
    case metrics
    case createQuote
    case createPaymentSession
    case stripeWebhook
    case wallet
    case walletBalance
    case createWalletReservation
    case releaseWalletReservation

    public var definition: MintHTTPRouteDefinition {
        switch self {
        case .issue:
            return MintHTTPRouteDefinition(method: .post, path: "/issue", summary: "Issue mint signatures")
        case .redeem:
            return MintHTTPRouteDefinition(method: .post, path: "/redeem", summary: "Redeem a spend bundle")
        case .metrics:
            return MintHTTPRouteDefinition(method: .get, path: "/metrics", summary: "Read mint metrics")
        case .createQuote:
            return MintHTTPRouteDefinition(method: .post, path: "/v1/payments/quotes", summary: "Create a product quote")
        case .createPaymentSession:
            return MintHTTPRouteDefinition(method: .post, path: "/v1/payments/sessions", summary: "Create a PSP payment session")
        case .stripeWebhook:
            return MintHTTPRouteDefinition(method: .post, path: "/v1/payments/stripe/webhook", summary: "Ingest Stripe webhook")
        case .wallet:
            return MintHTTPRouteDefinition(method: .get, path: "/v1/wallets/:walletID", summary: "Read wallet metadata")
        case .walletBalance:
            return MintHTTPRouteDefinition(method: .get, path: "/v1/wallets/:walletID/balance", summary: "Read wallet balance projection")
        case .createWalletReservation:
            return MintHTTPRouteDefinition(method: .post, path: "/v1/wallets/:walletID/reservations", summary: "Reserve wallet value for a quote/resource")
        case .releaseWalletReservation:
            return MintHTTPRouteDefinition(method: .post, path: "/v1/wallets/:walletID/reservations/:reservationID/release", summary: "Release an active wallet reservation")
        }
    }
}

public enum MintHTTPRouterError: Error, Equatable {
    case exposureDisabled
}

public actor MintHTTPRouter {
    private let handlers: MintHTTPHandlers
    private let exposedRoutes: [MintHTTPRoute]

    /// Public construction is deliberately fail-closed. The existing routes
    /// model legacy monetary effects and are not an entitlement-provider API.
    public init(handlers: MintHTTPHandlers) {
        self.handlers = handlers
        self.exposedRoutes = []
    }

    /// Test-only compatibility path for exercising the legacy router without
    /// making it possible for the server executable to opt in through config.
    init(handlers: MintHTTPHandlers, localTestExposure: Bool) {
        self.handlers = handlers
        self.exposedRoutes = localTestExposure ? MintHTTPRoute.allCases : []
    }

    public var routes: [MintHTTPRouteDefinition] {
        exposedRoutes.map(\.definition)
    }

    public func resolve(method: MintHTTPMethod, path: String) -> (route: MintHTTPRoute, pathParameters: [String: String])? {
        let normalizedPath = normalize(path)
        for route in exposedRoutes {
            let definition = route.definition
            guard definition.method == method else {
                continue
            }
            if let parameters = match(pattern: definition.path, actual: normalizedPath) {
                return (route, parameters)
            }
        }
        return nil
    }

    public func handle(route: MintHTTPRoute, context: MintHTTPRequestContext) async throws -> Data {
        guard exposedRoutes.contains(route) else {
            throw MintHTTPRouterError.exposureDisabled
        }
        switch route {
        case .issue:
            return try await handlers.handleIssue(body: context.body)
        case .redeem:
            return try await handlers.handleRedeem(body: context.body)
        case .metrics:
            return try await handlers.handleMetrics()
        case .createQuote:
            return try await handlers.handleCreateQuote(body: context.body)
        case .createPaymentSession:
            return try await handlers.handleCreatePaymentSession(body: context.body)
        case .stripeWebhook:
            return try await handlers.handleStripeWebhook(body: context.body, headers: context.headers)
        case .wallet:
            guard let rawWalletID = context.pathParameters["walletID"],
                  let walletID = UUID(uuidString: rawWalletID) else {
                throw MintHTTPHandlerError.decodingFailed
            }
            return try await handlers.handleWallet(walletID: walletID)
        case .walletBalance:
            guard let rawWalletID = context.pathParameters["walletID"],
                  let walletID = UUID(uuidString: rawWalletID) else {
                throw MintHTTPHandlerError.decodingFailed
            }
            return try await handlers.handleWalletBalance(walletID: walletID)
        case .createWalletReservation:
            guard let rawWalletID = context.pathParameters["walletID"],
                  let walletID = UUID(uuidString: rawWalletID) else {
                throw MintHTTPHandlerError.decodingFailed
            }
            return try await handlers.handleCreateWalletReservation(walletID: walletID, body: context.body)
        case .releaseWalletReservation:
            guard let rawWalletID = context.pathParameters["walletID"],
                  let walletID = UUID(uuidString: rawWalletID),
                  let rawReservationID = context.pathParameters["reservationID"],
                  let reservationID = UUID(uuidString: rawReservationID) else {
                throw MintHTTPHandlerError.decodingFailed
            }
            return try await handlers.handleReleaseWalletReservation(walletID: walletID, reservationID: reservationID, body: context.body)
        }
    }

    private func normalize(_ path: String) -> String {
        if path.isEmpty {
            return "/"
        }
        if path == "/" {
            return path
        }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func match(pattern: String, actual: String) -> [String: String]? {
        let patternComponents = normalize(pattern).split(separator: "/").map(String.init)
        let actualComponents = normalize(actual).split(separator: "/").map(String.init)
        guard patternComponents.count == actualComponents.count else {
            return nil
        }

        var parameters: [String: String] = [:]
        for (patternComponent, actualComponent) in zip(patternComponents, actualComponents) {
            if patternComponent.hasPrefix(":") {
                parameters[String(patternComponent.dropFirst())] = actualComponent
                continue
            }
            guard patternComponent == actualComponent else {
                return nil
            }
        }
        return parameters
    }
}
