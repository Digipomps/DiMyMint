import Foundation
import DiMyMintCore
import DiMyMintHTTP
import DiMyMintPersistence

private enum DiMyMintServerBootstrapError: Error {
    case missingPostgresURL
    case publicHTTPExposureDisabled
}

@main
struct DiMyMintServerMain {
    static func main() async throws {
        let configuration = DiMyMintServerConfiguration.fromEnvironment()
        let exposureProbe = MintHTTPRouter(
            handlers: MintHTTPHandlers(mintService: MintService())
        )
        let publiclyExposedRoutes = await exposureProbe.routes
        guard !publiclyExposedRoutes.isEmpty else {
            throw DiMyMintServerBootstrapError.publicHTTPExposureDisabled
        }
        let fundingService = try await makeFundingService(configuration: configuration)
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

        let service = MintService()
        let handlers = MintHTTPHandlers(mintService: service, fundingService: fundingService)
        let router = MintHTTPRouter(handlers: handlers)
        let server = LocalHTTPServer(configuration: configuration, router: router)

        let metrics = await service.metrics()
        print("DiMyMintServer bootstrap ready")
        print("Issued liabilities: \(metrics.issuedLiabilitiesMinorUnits) minor units")
        print("Storage mode: \(configuration.storageMode.rawValue)")
        print("Configured routes:")
        for route in await router.routes {
            print("- \(route.method.rawValue) \(route.path) - \(route.summary)")
        }
        print("Persistence modules available: InMemoryFundingStore and PostgresFundingStore")
        try await server.start()
    }

    private static func makeFundingService(configuration: DiMyMintServerConfiguration) async throws -> FundingService {
        switch configuration.storageMode {
        case .inMemory:
            let store = InMemoryFundingStore()
            return FundingService(store: store)
        case .postgres:
            guard let postgresURL = configuration.postgresURL, !postgresURL.isEmpty else {
                throw DiMyMintServerBootstrapError.missingPostgresURL
            }
            let client = try await PostgresNIOClientAdapter.connect(databaseURL: postgresURL)
            try await client.ensureRequiredTablesExist()
            let store = PostgresFundingStore(client: client)
            return FundingService(
                productCatalogStore: store,
                walletStore: store,
                walletReservationStore: store,
                quoteStore: store,
                providerPaymentStore: store,
                providerEventStore: store,
                cashEventStore: store,
                walletEventStore: store
            )
        }
    }
}
