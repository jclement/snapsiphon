import Foundation
import CryptoKit

/// A classic Bloom filter over asset identifiers. SnapSiphon keeps a full
/// SQLite index as the source of truth, but the Bloom filter is the fast,
/// cache-friendly front line: when scanning tens of thousands of photos we ask
/// "have I definitely NOT seen this one?" without a DB round-trip per asset.
///
/// - A negative answer is authoritative → the asset is new, enqueue it.
/// - A positive answer is probabilistic → confirm against the real index.
///
/// The bit array is `Codable`, so it round-trips to disk as a compact blob.
struct BloomFilter: Codable {
    private(set) var bits: [UInt64]
    let bitCount: Int
    let hashCount: Int
    private(set) var insertedCount: Int

    /// Size the filter for an expected item count and target false-positive rate.
    init(expectedItems: Int, falsePositiveRate: Double = 0.001) {
        let n = max(1, Double(expectedItems))
        let p = min(max(falsePositiveRate, 1e-6), 0.5)
        // Optimal bit count m = -n·ln(p) / (ln2)²
        let m = Int(ceil(-n * log(p) / (log(2) * log(2))))
        let k = max(1, Int(round(Double(m) / n * log(2))))
        self.bitCount = max(64, m)
        self.hashCount = min(k, 16)
        self.bits = Array(repeating: 0, count: (bitCount + 63) / 64)
        self.insertedCount = 0
    }

    /// Derive `hashCount` indices from one SHA-256 using double hashing.
    private func indices(for key: String) -> [Int] {
        let digest = SHA256.hash(data: Data(key.utf8))
        let bytes = Array(digest)
        func u64(_ range: Range<Int>) -> UInt64 {
            var v: UInt64 = 0
            for i in range { v = (v << 8) | UInt64(bytes[i]) }
            return v
        }
        let h1 = u64(0..<8)
        let h2 = u64(8..<16) | 1  // ensure odd so it strides the whole space
        var result: [Int] = []
        result.reserveCapacity(hashCount)
        for i in 0..<hashCount {
            let combined = h1 &+ UInt64(i) &* h2
            result.append(Int(combined % UInt64(bitCount)))
        }
        return result
    }

    mutating func insert(_ key: String) {
        for idx in indices(for: key) {
            bits[idx >> 6] |= (1 << UInt64(idx & 63))
        }
        insertedCount += 1
    }

    /// `false` → definitely absent. `true` → probably present (verify).
    func mightContain(_ key: String) -> Bool {
        for idx in indices(for: key) {
            if bits[idx >> 6] & (1 << UInt64(idx & 63)) == 0 { return false }
        }
        return true
    }

    /// Current estimated false-positive probability given how full it is.
    var estimatedFalsePositiveRate: Double {
        let k = Double(hashCount)
        let m = Double(bitCount)
        let n = Double(insertedCount)
        return pow(1 - exp(-k * n / m), k)
    }

    var fillRatio: Double {
        let setBits = bits.reduce(0) { $0 + $1.nonzeroBitCount }
        return Double(setBits) / Double(bitCount)
    }
}
