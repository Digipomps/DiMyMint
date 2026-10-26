import Foundation
import DiMyMintCore
import DiMyPaymentTypes

public enum MintHTTPHandlerError: Error {
    case decodingFailed
}

public actor MintHTTPHandlers {
    private let mintService: MintService
    private let fundingService: FundingService
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(mintService: MintService, fundingService: FundingService = FundingService()) {
        self.mintService = mintService
        self.fundingService = fundingService

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    public func handleIssue(body: Data) async throws -> Data {
        let request = try decoder.decode(IssueRequest.self, from: body)
        let response = try await mintService.issue(request)
        return try encoder.encode(response)
    }

    public func handleRedeem(body: Data) async throws -> Data {
        let request = try decoder.decode(RedeemRequest.self, from: body)
        let response = try await mintService.redeem(request)
        return try encoder.encode(response)
    }

    public func handleMetrics() async throws -> Data {
        let response = await mintService.metrics()
        return try encoder.encode(response)
    }

    public func handleCreateQuote(body: Data) async throws -> Data {
        let request = try decoder.decode(CreateQuoteRequest.self, from: body)
        let response = try await fundingService.createQuote(request)
        return try encoder.encode(response)
    }

    public func handleCreatePaymentSession(body: Data) async throws -> Data {
        let request = try decoder.decode(CreatePaymentSessionRequest.self, from: body)
        let response = try await fundingService.createPaymentSession(request)
        return try encoder.encode(response)
    }

    public func handleWallet(walletID: UUID) async throws -> Data {
        let response = try await fundingService.walletSummary(walletID: walletID)
        return try encoder.encode(response)
    }

    public func handleWalletBalance(walletID: UUID) async throws -> Data {
        let response = try await fundingService.walletBalance(walletID: walletID)
        return try encoder.encode(response)
    }

    public func handleCreateWalletReservation(walletID: UUID, body: Data) async throws -> Data {
        let request = try decoder.decode(CreateWalletReservationRequest.self, from: body)
        let response = try await fundingService.createWalletReservation(walletID: walletID, request: request)
        return try encoder.encode(response)
    }

    public func handleReleaseWalletReservation(walletID: UUID, reservationID: UUID, body: Data) async throws -> Data {
        let request: ReleaseWalletReservationRequest
        if body.isEmpty {
            request = ReleaseWalletReservationRequest()
        } else {
            request = try decoder.decode(ReleaseWalletReservationRequest.self, from: body)
        }
        let response = try await fundingService.releaseWalletReservation(
            walletID: walletID,
            reservationID: reservationID,
            request: request
        )
        return try encoder.encode(response)
    }

    public func handleStripeWebhook(body: Data, headers: [String: String]) async throws -> Data {
        let response = try await fundingService.ingestStripeWebhook(body: body, headers: headers)
        return try encoder.encode(response)
    }
}
