import Foundation

struct DiMyMintServerConfiguration: Sendable {
    enum StorageMode: String, Sendable {
        case inMemory = "in-memory"
        case postgres = "postgres"
    }

    let host: String
    let port: UInt16
    let storageMode: StorageMode
    let postgresURL: String?

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let host = environment["DIMY_MINT_HOST"] ?? "127.0.0.1"
        let port = UInt16(environment["DIMY_MINT_PORT"] ?? "") ?? 8080
        let storageMode = StorageMode(rawValue: environment["DIMY_MINT_STORAGE"] ?? "") ?? .inMemory
        let postgresURL = environment["DIMY_MINT_POSTGRES_URL"]
        return Self(host: host, port: port, storageMode: storageMode, postgresURL: postgresURL)
    }
}
