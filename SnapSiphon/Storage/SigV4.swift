import Foundation
import CryptoKit

/// AWS Signature Version 4 signing for S3-compatible services (Backblaze B2,
/// Cloudflare R2, and AWS itself). Uses the `UNSIGNED-PAYLOAD` content hash so
/// we never have to buffer or double-read a multi-gigabyte encrypted video just
/// to sign it — legal over HTTPS, which both B2 and R2 require.
struct SigV4 {
    let accessKeyID: String
    let secretAccessKey: String
    let region: String
    let service: String = "s3"

    struct SignedRequest {
        var url: URL
        var method: String
        var headers: [String: String]
    }

    /// Sign a request. `contentSHA256` defaults to UNSIGNED-PAYLOAD.
    func sign(
        method: String,
        url: URL,
        headers: [String: String] = [:],
        contentSHA256: String = "UNSIGNED-PAYLOAD",
        now: Date
    ) -> SignedRequest {
        let amzDate = Self.amzDateFormatter.string(from: now)
        let dateStamp = Self.dateStampFormatter.string(from: now)

        guard let host = url.host else {
            return SignedRequest(url: url, method: method, headers: headers)
        }

        var canonicalHeaders = headers
        canonicalHeaders["host"] = host
        canonicalHeaders["x-amz-content-sha256"] = contentSHA256
        canonicalHeaders["x-amz-date"] = amzDate

        // Canonical headers must be sorted by lowercased name.
        let sortedHeaderKeys = canonicalHeaders.keys
            .map { ($0.lowercased(), $0) }
            .sorted { $0.0 < $1.0 }

        let canonicalHeaderString = sortedHeaderKeys
            .map { "\($0.0):\(canonicalHeaders[$0.1]!.trimmingCharacters(in: .whitespaces))\n" }
            .joined()
        let signedHeaders = sortedHeaderKeys.map { $0.0 }.joined(separator: ";")

        let canonicalURI = Self.canonicalURIPath(url)
        let canonicalQuery = Self.canonicalQueryString(url)

        let canonicalRequest = [
            method,
            canonicalURI,
            canonicalQuery,
            canonicalHeaderString,
            signedHeaders,
            contentSHA256,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.hexSHA256(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = Self.signingKey(secret: secretAccessKey, dateStamp: dateStamp, region: region, service: service)
        let signature = Self.hmacHex(key: signingKey, data: Data(stringToSign.utf8))

        let authorization = "AWS4-HMAC-SHA256 " +
            "Credential=\(accessKeyID)/\(scope), " +
            "SignedHeaders=\(signedHeaders), " +
            "Signature=\(signature)"

        var finalHeaders = canonicalHeaders
        finalHeaders["Authorization"] = authorization
        return SignedRequest(url: url, method: method, headers: finalHeaders)
    }

    // MARK: Canonicalization

    private static func canonicalURIPath(_ url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        // Each segment must be RFC-3986 encoded; the key can contain "/".
        let segments: [Substring] = path.split(separator: "/", omittingEmptySubsequences: false)
        let encoded: [String] = segments.map { uriEncode(String($0), encodeSlash: true) }
        return encoded.joined(separator: "/")
    }

    private static func canonicalQueryString(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              !items.isEmpty else { return "" }
        let pairs: [(String, String)] = items.map { item in
            (uriEncode(item.name, encodeSlash: true), uriEncode(item.value ?? "", encodeSlash: true))
        }
        let sorted = pairs.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        let joined: [String] = sorted.map { "\($0.0)=\($0.1)" }
        return joined.joined(separator: "&")
    }

    /// RFC 3986 unreserved set; everything else percent-encoded uppercase.
    static func uriEncode(_ string: String, encodeSlash: Bool) -> String {
        let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        var allowed = Set(unreserved.unicodeScalars)
        if !encodeSlash { allowed.insert("/") }
        var out = ""
        for byte in string.utf8 {
            let scalar = UnicodeScalar(byte)
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    // MARK: Crypto primitives

    static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    private static func hmacHex(key: Data, data: Data) -> String {
        hmac(key: key, data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func signingKey(secret: String, dateStamp: String, region: String, service: String) -> Data {
        let kDate = hmac(key: Data("AWS4\(secret)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        return hmac(key: kService, data: Data("aws4_request".utf8))
    }

    // MARK: Date formatters

    static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    static let dateStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return f
    }()
}
