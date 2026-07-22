import Foundation

/// Minimal Bech32 implementation (BIP-173) used by the `age` key format.
///
/// `age` encodes X25519 public keys as `age1…` and secret keys as the
/// uppercase `AGE-SECRET-KEY-1…`, both plain Bech32 over the raw 32-byte key.
enum Bech32 {
    enum Error: Swift.Error, LocalizedError {
        case invalidCharacter
        case invalidChecksum
        case invalidHRP
        case tooShort
        case mixedCase

        var errorDescription: String? {
            switch self {
            case .invalidCharacter: return "The key contains characters that aren't valid Bech32."
            case .invalidChecksum: return "The key's checksum doesn't match — it may be corrupted or mistyped."
            case .invalidHRP: return "The key prefix isn't what SnapSiphon expected."
            case .tooShort: return "The key is too short to be valid."
            case .mixedCase: return "The key mixes upper and lower case, which Bech32 forbids."
            }
        }
    }

    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let generator: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ UInt32(v)
            for i in 0..<5 where (top >> i) & 1 == 1 {
                chk ^= generator[i]
            }
        }
        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        let s = Array(hrp.utf8)
        return s.map { $0 >> 5 } + [0] + s.map { $0 & 31 }
    }

    private static func createChecksum(hrp: String, data: [UInt8]) -> [UInt8] {
        let values = hrpExpand(hrp) + data
        let mod = polymod(values + [0, 0, 0, 0, 0, 0]) ^ 1
        return (0..<6).map { UInt8((mod >> (5 * (5 - $0))) & 31) }
    }

    private static func verifyChecksum(hrp: String, data: [UInt8]) -> Bool {
        polymod(hrpExpand(hrp) + data) == 1
    }

    // MARK: 5-bit <-> 8-bit conversion

    private static func convertBits(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc = 0
        var bits = 0
        var result: [UInt8] = []
        let maxv = (1 << to) - 1
        for value in data {
            let v = Int(value)
            if v < 0 || (v >> from) != 0 { return nil }
            acc = (acc << from) | v
            bits += from
            while bits >= to {
                bits -= to
                result.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits > 0 { result.append(UInt8((acc << (to - bits)) & maxv)) }
        } else if bits >= from || ((acc << (to - bits)) & maxv) != 0 {
            return nil
        }
        return result
    }

    // MARK: Public API

    static func encode(hrp: String, data: [UInt8]) -> String {
        guard let converted = convertBits(data, from: 8, to: 5, pad: true) else { return "" }
        let checksum = createChecksum(hrp: hrp, data: converted)
        let combined = converted + checksum
        return hrp + "1" + String(combined.map { charset[Int($0)] })
    }

    static func decode(_ string: String, expectedHRP: String) throws -> [UInt8] {
        let (hrp, bytes) = try decode(string)
        guard hrp == expectedHRP.lowercased() else { throw Error.invalidHRP }
        return bytes
    }

    /// Decode returning the human-readable prefix too, so callers can dispatch on
    /// it (e.g. `age` vs `age1se` vs `age1yubikey`). The separator is the *last*
    /// "1", so multi-token HRPs like `age1se` decode correctly.
    static func decode(_ string: String) throws -> (hrp: String, data: [UInt8]) {
        let lower = string.lowercased()
        let upper = string.uppercased()
        guard string == lower || string == upper else { throw Error.mixedCase }
        let normalized = lower
        guard let sep = normalized.lastIndex(of: "1") else { throw Error.invalidHRP }
        let hrp = String(normalized[normalized.startIndex..<sep])
        let dataPart = normalized[normalized.index(after: sep)...]
        guard dataPart.count >= 6 else { throw Error.tooShort }

        var values: [UInt8] = []
        for ch in dataPart {
            guard let idx = charset.firstIndex(of: ch) else { throw Error.invalidCharacter }
            values.append(UInt8(idx))
        }
        guard verifyChecksum(hrp: hrp, data: values) else { throw Error.invalidChecksum }
        let payload = Array(values.dropLast(6))
        guard let bytes = convertBits(payload, from: 5, to: 8, pad: false) else {
            throw Error.invalidChecksum
        }
        return (hrp, bytes)
    }
}
