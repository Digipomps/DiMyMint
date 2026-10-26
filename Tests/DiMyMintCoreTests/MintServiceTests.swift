import XCTest
import DiMyMintCore
import DiMyPaymentTypes

final class MintServiceTests: XCTestCase {
    func testIssueProducesSignaturesAndUpdatesMetrics() async throws {
        let service = MintService()

        let request = IssueRequest(
            requests: [
                BlindedCoinRequest(denomMinorUnits: 5, blindedMessage: "blind:a", mintKeyID: "dev-mint-key-1"),
                BlindedCoinRequest(denomMinorUnits: 10, blindedMessage: "blind:b", mintKeyID: "dev-mint-key-1")
            ],
            walletInstanceID: "wallet-1"
        )

        let response = try await service.issue(request)
        XCTAssertEqual(response.signatures.count, 2)
        XCTAssertEqual(response.debitedMinorUnits, 15)

        let metrics = await service.metrics()
        XCTAssertEqual(metrics.issuedLiabilitiesMinorUnits, 15)
        XCTAssertEqual(metrics.redeemedMinorUnits, 0)
    }

    func testRedeemRejectsDoubleSpend() async throws {
        let service = MintService()
        let bundle = SpendBundle(
            coins: [Coin(denomMinorUnits: 10, serial: "serial-1", mintKeyID: "dev-mint-key-1", signature: "sig")],
            requestID: UUID(),
            resourceID: "cell://demo/resource",
            createdAt: Date()
        )
        let bundleHash = try BundleHasher.hash(bundle: bundle)
        let request = RedeemRequest(bundle: bundle, bundleHash: bundleHash, merchantID: "merchant-a")

        let first = try await service.redeem(request)
        XCTAssertTrue(first.accepted)

        let second = try await service.redeem(request)
        XCTAssertFalse(second.accepted)
        XCTAssertEqual(second.rejectionReason, .doubleSpend)
    }
}
