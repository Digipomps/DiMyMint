import Crypto
import Foundation

struct StripeWebhookVerification: Hashable, Sendable {
    let timestamp: Int64
    let payloadSHA256: String
    let deliverySHA256: String
}

enum StripeWebhookVerifier {
    static func verify(
        rawBody: Data,
        signatureHeader: String,
        secret: String,
        toleranceSeconds: TimeInterval,
        now: Date
    ) throws -> StripeWebhookVerification {
        var timestamps: [Int64] = []
        var signatures: [String] = []

        for component in signatureHeader.split(separator: ",", omittingEmptySubsequences: false) {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else {
                throw StripeEntitlementProviderError.invalidWebhookSignature
            }
            switch pair[0] {
            case "t":
                guard let value = Int64(pair[1]) else {
                    throw StripeEntitlementProviderError.invalidWebhookSignature
                }
                timestamps.append(value)
            case "v1":
                let value = String(pair[1]).lowercased()
                guard value.count == 64,
                      value.unicodeScalars.allSatisfy(Self.isLowercaseHex) else {
                    throw StripeEntitlementProviderError.invalidWebhookSignature
                }
                signatures.append(value)
            default:
                continue
            }
        }

        guard timestamps.count == 1, let timestamp = timestamps.first, !signatures.isEmpty else {
            throw StripeEntitlementProviderError.invalidWebhookSignature
        }
        guard abs(now.timeIntervalSince1970 - TimeInterval(timestamp)) <= toleranceSeconds else {
            throw StripeEntitlementProviderError.webhookTimestampOutsideTolerance
        }

        var signedPayload = Data("\(timestamp).".utf8)
        signedPayload.append(rawBody)
        let expected = hmacSHA256Hex(data: signedPayload, secret: secret)
        guard signatures.contains(where: { constantTimeEqual($0, expected) }) else {
            throw StripeEntitlementProviderError.invalidWebhookSignature
        }

        return StripeWebhookVerification(
            timestamp: timestamp,
            payloadSHA256: StripeEntitlementHashing.sha256Hex(rawBody),
            deliverySHA256: StripeEntitlementHashing.sha256Hex(signedPayload)
        )
    }

    static func hmacSHA256Hex(data: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(code).map { String(format: "%02x", $0) }.joined()
    }

    private static func isLowercaseHex(_ scalar: UnicodeScalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }
}

enum StripeEntitlementHashing {
    static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }
}
