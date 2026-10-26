// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DiMyMint",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "DiMyMintCore", targets: ["DiMyMintCore"]),
        .library(name: "DiMyMintPersistence", targets: ["DiMyMintPersistence"]),
        .library(name: "DiMyMintHTTP", targets: ["DiMyMintHTTP"]),
        .executable(name: "DiMyMintServer", targets: ["DiMyMintServer"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/Digipomps/DiMyMicropayments.git",
            .upToNextMinor(from: "2026.10.1")
        ),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0"),
        // Keep the standalone Postgres host on security-patched NIO versions.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.2"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.45.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0")
    ],
    targets: [
        .target(
            name: "DiMyMintCore",
            dependencies: [
                .product(name: "DiMyPaymentTypes", package: "DiMyMicropayments"),
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .target(
            name: "DiMyMintHTTP",
            dependencies: [
                "DiMyMintCore",
                .product(name: "DiMyPaymentTypes", package: "DiMyMicropayments")
            ]
        ),
        .target(
            name: "DiMyMintPersistence",
            dependencies: [
                "DiMyMintCore",
                .product(name: "PostgresNIO", package: "postgres-nio")
            ]
        ),
        .executableTarget(
            name: "DiMyMintServer",
            dependencies: ["DiMyMintHTTP", "DiMyMintCore", "DiMyMintPersistence"]
        ),
        .testTarget(
            name: "DiMyMintCoreTests",
            dependencies: [
                "DiMyMintCore",
                .product(name: "DiMyPaymentTypes", package: "DiMyMicropayments")
            ]
        ),
        .testTarget(
            name: "DiMyMintHTTPTests",
            dependencies: ["DiMyMintHTTP", "DiMyMintCore"]
        ),
        .testTarget(
            name: "DiMyMintPersistenceTests",
            dependencies: ["DiMyMintPersistence", "DiMyMintCore"]
        )
    ]
)
