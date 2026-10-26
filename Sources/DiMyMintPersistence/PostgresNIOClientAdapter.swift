import Foundation
import NIOSSL
import PostgresNIO

public enum PostgresDatabaseConfigurationError: Error, Equatable {
    case invalidURL(String)
    case unsupportedScheme(String)
    case missingHost
    case missingUsername
    case unsupportedSSLMode(String)
    case invalidIntegerParameter(name: String, value: String)
    case invalidConnectionPoolRange(minimum: Int, maximum: Int)
}

public enum PostgresDriverRuntimeError: Error, Equatable {
    case missingTables([String])
    case unsupportedColumnType(String)
}

public struct PostgresDatabaseConfiguration: Sendable, Equatable {
    public enum TLSMode: String, Sendable, Equatable {
        case disable
        case prefer
        case require

        fileprivate func makeTLSConfiguration() -> PostgresNIO.PostgresClient.Configuration.TLS {
            switch self {
            case .disable:
                return .disable
            case .prefer:
                return .prefer(.makeClientConfiguration())
            case .require:
                return .require(.makeClientConfiguration())
            }
        }
    }

    public let host: String
    public let port: Int
    public let username: String
    public let password: String?
    public let database: String?
    public let tlsMode: TLSMode
    public let connectTimeoutSeconds: Int?
    public let minimumConnections: Int?
    public let maximumConnections: Int?

    public init(
        host: String,
        port: Int = 5432,
        username: String,
        password: String? = nil,
        database: String? = nil,
        tlsMode: TLSMode = .prefer,
        connectTimeoutSeconds: Int? = nil,
        minimumConnections: Int? = nil,
        maximumConnections: Int? = nil
    ) throws {
        if let minimumConnections, minimumConnections < 0 {
            throw PostgresDatabaseConfigurationError.invalidIntegerParameter(name: "minimum_connections", value: String(minimumConnections))
        }
        if let maximumConnections, maximumConnections <= 0 {
            throw PostgresDatabaseConfigurationError.invalidIntegerParameter(name: "maximum_connections", value: String(maximumConnections))
        }
        if let minimumConnections, let maximumConnections, minimumConnections >= maximumConnections {
            throw PostgresDatabaseConfigurationError.invalidConnectionPoolRange(minimum: minimumConnections, maximum: maximumConnections)
        }

        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.tlsMode = tlsMode
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.minimumConnections = minimumConnections
        self.maximumConnections = maximumConnections
    }

    public static func parse(url: String) throws -> Self {
        guard let components = URLComponents(string: url) else {
            throw PostgresDatabaseConfigurationError.invalidURL(url)
        }

        guard let scheme = components.scheme?.lowercased(),
              scheme == "postgres" || scheme == "postgresql" else {
            throw PostgresDatabaseConfigurationError.unsupportedScheme(components.scheme ?? "")
        }

        guard let host = components.host, !host.isEmpty else {
            throw PostgresDatabaseConfigurationError.missingHost
        }

        guard let username = components.user, !username.isEmpty else {
            throw PostgresDatabaseConfigurationError.missingUsername
        }

        let queryItems = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }
        )
        let tlsMode = try parseTLSMode(queryItems["sslmode"])
        let connectTimeoutSeconds = try parseIntegerParameter(named: "connect_timeout", from: queryItems)
        let minimumConnections = try parseIntegerParameter(named: "minimum_connections", from: queryItems)
        let maximumConnections = try parseIntegerParameter(named: "maximum_connections", from: queryItems)
        let database = parseDatabaseName(path: components.percentEncodedPath)

        return try Self(
            host: host,
            port: components.port ?? 5432,
            username: username,
            password: components.password,
            database: database,
            tlsMode: tlsMode,
            connectTimeoutSeconds: connectTimeoutSeconds,
            minimumConnections: minimumConnections,
            maximumConnections: maximumConnections
        )
    }

    fileprivate func makeClientConfiguration() -> PostgresNIO.PostgresClient.Configuration {
        var configuration = PostgresNIO.PostgresClient.Configuration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: tlsMode.makeTLSConfiguration()
        )
        if let connectTimeoutSeconds {
            configuration.options.connectTimeout = .seconds(connectTimeoutSeconds)
        }
        if let minimumConnections {
            configuration.options.minimumConnections = minimumConnections
        }
        if let maximumConnections {
            configuration.options.maximumConnections = maximumConnections
        }
        return configuration
    }

    private static func parseTLSMode(_ rawValue: String?) throws -> TLSMode {
        guard let rawValue, !rawValue.isEmpty else {
            return .prefer
        }
        guard let mode = TLSMode(rawValue: rawValue.lowercased()) else {
            throw PostgresDatabaseConfigurationError.unsupportedSSLMode(rawValue)
        }
        return mode
    }

    private static func parseIntegerParameter(named name: String, from queryItems: [String: String]) throws -> Int? {
        guard let rawValue = queryItems[name], !rawValue.isEmpty else {
            return nil
        }
        guard let value = Int(rawValue) else {
            throw PostgresDatabaseConfigurationError.invalidIntegerParameter(name: name, value: rawValue)
        }
        return value
    }

    private static func parseDatabaseName(path: String) -> String? {
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty else {
            return nil
        }
        return trimmedPath.removingPercentEncoding ?? trimmedPath
    }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
public final class PostgresNIOClientAdapter: PostgresClient {
    public static let requiredTableNames: [String] = [
        "product_catalog_items",
        "wallets",
        "wallet_balance_projections",
        "price_quotes",
        "provider_payments",
        "provider_events_raw",
        "cash_events",
        "wallet_events"
    ]

    private let client: PostgresNIO.PostgresClient
    private let runTask: Task<Void, Never>

    private init(client: PostgresNIO.PostgresClient, runTask: Task<Void, Never>) {
        self.client = client
        self.runTask = runTask
    }

    deinit {
        runTask.cancel()
    }

    public static func connect(databaseURL: String) async throws -> PostgresNIOClientAdapter {
        try await connect(configuration: PostgresDatabaseConfiguration.parse(url: databaseURL))
    }

    public static func connect(configuration: PostgresDatabaseConfiguration) async throws -> PostgresNIOClientAdapter {
        let client = PostgresNIO.PostgresClient(configuration: configuration.makeClientConfiguration())
        let runTask = Task {
            await client.run()
        }
        let adapter = PostgresNIOClientAdapter(client: client, runTask: runTask)
        await Task.yield()
        do {
            _ = try await adapter.query(sql: "select 1 as ready", binds: [])
            return adapter
        } catch {
            runTask.cancel()
            throw error
        }
    }

    public func ensureRequiredTablesExist(_ tableNames: [String] = requiredTableNames) async throws {
        let sql = """
        select exists (
            select 1
            from information_schema.tables
            where table_schema = current_schema()
              and table_name = $1
        ) as exists
        """

        var missingTables: [String] = []
        for tableName in tableNames {
            let rows = try await query(sql: sql, binds: [.string(tableName)])
            let exists = rows.first?.bool("exists") ?? false
            if !exists {
                missingTables.append(tableName)
            }
        }

        if !missingTables.isEmpty {
            throw PostgresDriverRuntimeError.missingTables(missingTables)
        }
    }

    public func execute(sql: String, binds: [PostgresBind]) async throws {
        let query = try makeQuery(sql: sql, binds: binds)
        let rows = try await client.query(query)
        _ = try await rows.collect()
    }

    public func query(sql: String, binds: [PostgresBind]) async throws -> [PostgresRow] {
        let query = try makeQuery(sql: sql, binds: binds)
        let rows = try await client.query(query)
        return try await rows.collect().map(decodeRow)
    }

    private func makeQuery(sql: String, binds: [PostgresBind]) throws -> PostgresNIO.PostgresQuery {
        var postgresBinds = PostgresBindings(capacity: binds.count)
        for bind in binds {
            switch bind {
            case let .string(value):
                postgresBinds.append(value)
            case let .int64(value):
                postgresBinds.append(value)
            case let .int(value):
                postgresBinds.append(value)
            case let .uuid(value):
                postgresBinds.append(value)
            case let .timestamp(value):
                postgresBinds.append(value)
            case let .bool(value):
                postgresBinds.append(value)
            case let .data(value):
                try postgresBinds.append(value)
            case .null:
                postgresBinds.appendNull()
            }
        }
        return PostgresNIO.PostgresQuery(unsafeSQL: sql, binds: postgresBinds)
    }

    private func decodeRow(_ row: PostgresNIO.PostgresRow) throws -> PostgresRow {
        var storage: [String: PostgresValue] = [:]
        for cell in row.makeRandomAccess() {
            guard cell.bytes != nil else {
                continue
            }
            storage[cell.columnName] = try decodeValue(cell)
        }
        return PostgresRow(storage)
    }

    private func decodeValue(_ cell: PostgresCell) throws -> PostgresValue {
        switch cell.dataType {
        case .bool:
            return .bool(try cell.decode(Bool.self))
        case .int2, .int4:
            return .int(try cell.decode(Int.self))
        case .int8:
            return .int64(try cell.decode(Int64.self))
        case .uuid:
            return .uuid(try cell.decode(UUID.self))
        case .bytea:
            return .data(try cell.decode(Data.self))
        case .date, .timestamp, .timestamptz:
            return .timestamp(try cell.decode(Date.self))
        case .bpchar, .name, .text, .varchar:
            return .string(try cell.decode(String.self))
        default:
            throw PostgresDriverRuntimeError.unsupportedColumnType("\(cell.columnName): \(cell.dataType)")
        }
    }
}
