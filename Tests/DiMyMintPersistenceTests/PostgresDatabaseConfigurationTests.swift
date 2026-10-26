import XCTest
@testable import DiMyMintPersistence

final class PostgresDatabaseConfigurationTests: XCTestCase {
    func testParseDatabaseURLExtractsDriverSettings() throws {
        let configuration = try PostgresDatabaseConfiguration.parse(
            url: "postgresql://dimy:secret@db.internal:6543/dimymint?sslmode=disable&connect_timeout=5&minimum_connections=1&maximum_connections=6"
        )

        XCTAssertEqual(configuration.host, "db.internal")
        XCTAssertEqual(configuration.port, 6543)
        XCTAssertEqual(configuration.username, "dimy")
        XCTAssertEqual(configuration.password, "secret")
        XCTAssertEqual(configuration.database, "dimymint")
        XCTAssertEqual(configuration.tlsMode, .disable)
        XCTAssertEqual(configuration.connectTimeoutSeconds, 5)
        XCTAssertEqual(configuration.minimumConnections, 1)
        XCTAssertEqual(configuration.maximumConnections, 6)
    }

    func testParseDatabaseURLDefaultsToPreferTLSAndPort5432() throws {
        let configuration = try PostgresDatabaseConfiguration.parse(
            url: "postgres://mint@localhost/dimymint"
        )

        XCTAssertEqual(configuration.host, "localhost")
        XCTAssertEqual(configuration.port, 5432)
        XCTAssertEqual(configuration.username, "mint")
        XCTAssertNil(configuration.password)
        XCTAssertEqual(configuration.database, "dimymint")
        XCTAssertEqual(configuration.tlsMode, .prefer)
        XCTAssertNil(configuration.connectTimeoutSeconds)
    }

    func testParseDatabaseURLRejectsUnsupportedSSLMode() {
        XCTAssertThrowsError(
            try PostgresDatabaseConfiguration.parse(
                url: "postgres://mint@localhost/dimymint?sslmode=verify-full"
            )
        ) { error in
            XCTAssertEqual(
                error as? PostgresDatabaseConfigurationError,
                .unsupportedSSLMode("verify-full")
            )
        }
    }
}
