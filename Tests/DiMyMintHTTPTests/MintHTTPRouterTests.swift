import XCTest
@testable import DiMyMintCore
@testable import DiMyMintHTTP

final class MintHTTPRouterTests: XCTestCase {
    func testPublicRouterIsFailClosedByDefault() async throws {
        let handlers = MintHTTPHandlers(mintService: MintService())
        let router = MintHTTPRouter(handlers: handlers)

        let routes = await router.routes
        XCTAssertTrue(routes.isEmpty)
        let resolved = await router.resolve(method: .post, path: "/issue")
        XCTAssertNil(resolved)
        do {
            _ = try await router.handle(route: .issue, context: MintHTTPRequestContext())
            XCTFail("Expected disabled exposure")
        } catch {
            XCTAssertEqual(error as? MintHTTPRouterError, .exposureDisabled)
        }
    }

    func testRouterResolvesParameterizedWalletRoute() async throws {
        let handlers = MintHTTPHandlers(mintService: MintService())
        let router = MintHTTPRouter(handlers: handlers, localTestExposure: true)

        let resolved = await router.resolve(method: .get, path: "/v1/wallets/11111111-1111-1111-1111-111111111111/balance")

        XCTAssertEqual(resolved?.route, .walletBalance)
        XCTAssertEqual(resolved?.pathParameters["walletID"], "11111111-1111-1111-1111-111111111111")
    }

    func testRouterResolvesWalletReservationRoutes() async throws {
        let handlers = MintHTTPHandlers(mintService: MintService())
        let router = MintHTTPRouter(handlers: handlers, localTestExposure: true)

        let create = await router.resolve(
            method: .post,
            path: "/v1/wallets/11111111-1111-1111-1111-111111111111/reservations"
        )
        XCTAssertEqual(create?.route, .createWalletReservation)
        XCTAssertEqual(create?.pathParameters["walletID"], "11111111-1111-1111-1111-111111111111")

        let release = await router.resolve(
            method: .post,
            path: "/v1/wallets/11111111-1111-1111-1111-111111111111/reservations/22222222-2222-2222-2222-222222222222/release"
        )
        XCTAssertEqual(release?.route, .releaseWalletReservation)
        XCTAssertEqual(release?.pathParameters["walletID"], "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(release?.pathParameters["reservationID"], "22222222-2222-2222-2222-222222222222")
    }

    func testRouterExposesFundingRoutesAndDispatchesWalletBalance() async throws {
        let fundingStore = InMemoryFundingStore()
        let fundingService = FundingService(store: fundingStore)
        try await fundingService.registerProduct(
            ProductCatalogItem(
                productID: "generalcell.starter",
                productType: "hosting_plan",
                title: "GeneralCell Starter",
                unitPriceNOKOre: 149_000,
                taxCode: "standard_25",
                taxBehavior: .inclusive
            )
        )

        let quote = try await fundingService.createQuote(
            CreateQuoteRequest(
                customerID: "customer_router",
                productID: "generalcell.starter",
                quantity: 1
            )
        )

        let handlers = MintHTTPHandlers(
            mintService: MintService(),
            fundingService: fundingService
        )
        let router = MintHTTPRouter(handlers: handlers, localTestExposure: true)

        let routes = await router.routes
        XCTAssertTrue(routes.contains(MintHTTPRoute.createQuote.definition))
        XCTAssertTrue(routes.contains(MintHTTPRoute.walletBalance.definition))
        XCTAssertTrue(routes.contains(MintHTTPRoute.createWalletReservation.definition))
        XCTAssertTrue(routes.contains(MintHTTPRoute.releaseWalletReservation.definition))

        let responseData = try await router.handle(
            route: .walletBalance,
            context: MintHTTPRequestContext(
                pathParameters: ["walletID": quote.walletID.uuidString]
            )
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let balance = try decoder.decode(WalletBalanceResponse.self, from: responseData)
        XCTAssertEqual(balance.walletID, quote.walletID)
        XCTAssertEqual(balance.availableNOKOre, 0)
    }
}
