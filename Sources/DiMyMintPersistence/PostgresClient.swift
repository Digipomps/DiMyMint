import Foundation

public enum PostgresBind: Equatable, Sendable {
    case string(String)
    case int64(Int64)
    case int(Int)
    case uuid(UUID)
    case timestamp(Date)
    case bool(Bool)
    case data(Data)
    case null
}

public enum PostgresValue: Equatable, Sendable {
    case string(String)
    case int64(Int64)
    case int(Int)
    case uuid(UUID)
    case timestamp(Date)
    case bool(Bool)
    case data(Data)
}

public struct PostgresRow: Equatable, Sendable {
    private let storage: [String: PostgresValue]

    public init(_ storage: [String: PostgresValue]) {
        self.storage = storage
    }

    public func string(_ key: String) -> String? {
        guard case let .string(value)? = storage[key] else {
            return nil
        }
        return value
    }

    public func int64(_ key: String) -> Int64? {
        switch storage[key] {
        case let .int64(value)?:
            return value
        case let .int(value)?:
            return Int64(value)
        default:
            return nil
        }
    }

    public func int(_ key: String) -> Int? {
        switch storage[key] {
        case let .int(value)?:
            return value
        case let .int64(value)?:
            return Int(exactly: value)
        default:
            return nil
        }
    }

    public func uuid(_ key: String) -> UUID? {
        guard case let .uuid(value)? = storage[key] else {
            return nil
        }
        return value
    }

    public func timestamp(_ key: String) -> Date? {
        guard case let .timestamp(value)? = storage[key] else {
            return nil
        }
        return value
    }

    public func bool(_ key: String) -> Bool? {
        guard case let .bool(value)? = storage[key] else {
            return nil
        }
        return value
    }

    public func data(_ key: String) -> Data? {
        guard case let .data(value)? = storage[key] else {
            return nil
        }
        return value
    }
}

public struct PostgresExecutedStatement: Equatable, Sendable {
    public let sql: String
    public let binds: [PostgresBind]

    public init(sql: String, binds: [PostgresBind]) {
        self.sql = sql
        self.binds = binds
    }
}

public protocol PostgresClient: Sendable {
    func execute(sql: String, binds: [PostgresBind]) async throws
    func query(sql: String, binds: [PostgresBind]) async throws -> [PostgresRow]
}

public enum PostgresFundingStoreError: Error, Equatable {
    case missingColumn(String)
    case unsupportedValue(String)
}
