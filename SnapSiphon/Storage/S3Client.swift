import Foundation
import CryptoKit

/// Connection settings for an S3-compatible bucket. Secrets live in the
/// Keychain (see `S3CredentialStore`); this struct carries the non-secret parts
/// plus, transiently, the loaded credentials while a client is alive.
struct S3Config: Codable, Equatable {
    enum Provider: String, Codable, CaseIterable, Identifiable {
        case backblazeB2
        case cloudflareR2
        case custom

        var id: String { rawValue }
        var title: String {
            switch self {
            case .backblazeB2: return "Backblaze B2"
            case .cloudflareR2: return "Cloudflare R2"
            case .custom: return "Custom S3"
            }
        }
        var usesPathStyle: Bool { self == .cloudflareR2 || self == .custom }
        var defaultRegion: String {
            switch self {
            case .cloudflareR2: return "auto"
            case .backblazeB2: return "us-west-004"
            case .custom: return "us-east-1"
            }
        }
    }

    var provider: Provider = .backblazeB2
    /// Host only, e.g. `s3.us-west-004.backblazeb2.com` or
    /// `<accountid>.r2.cloudflarestorage.com`.
    var endpoint: String = ""
    var region: String = ""
    var bucket: String = ""
    var prefix: String = "SnapSiphon"

    var isComplete: Bool {
        !endpoint.isEmpty && !bucket.isEmpty && !region.isEmpty
    }
}

/// Loaded credentials paired with config, ready to sign requests.
struct S3Credentials {
    var accessKeyID: String
    var secretAccessKey: String
}

enum S3Error: Error, LocalizedError {
    case badConfig
    case http(Int, String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .badConfig: return "The storage configuration is incomplete."
        case .http(let code, let body):
            return "Storage returned HTTP \(code).\(body.isEmpty ? "" : " \(body.prefix(300))")"
        case .network(let m): return "Network error: \(m)"
        }
    }
}

/// A thin async S3 client: signs with SigV4 and uploads via `URLSession`.
/// Kept deliberately small — just the verbs SnapSiphon needs (PUT, HEAD, GET
/// list) so there is no opaque SDK between the user's photos and their bucket.
final class S3Client {
    let config: S3Config
    private let signer: SigV4
    private let session: URLSession

    init(config: S3Config, credentials: S3Credentials, session: URLSession = .shared) {
        self.config = config
        self.signer = SigV4(accessKeyID: credentials.accessKeyID,
                            secretAccessKey: credentials.secretAccessKey,
                            region: config.region)
        self.session = session
    }

    /// Full object key including the configured prefix.
    func fullKey(for name: String) -> String {
        let p = config.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return p.isEmpty ? name : "\(p)/\(name)"
    }

    private func objectURL(key: String) throws -> URL {
        let encodedKey = key.split(separator: "/", omittingEmptySubsequences: false)
            .map { SigV4.uriEncode(String($0), encodeSlash: true) }
            .joined(separator: "/")
        let urlString: String
        if config.provider.usesPathStyle {
            urlString = "https://\(config.endpoint)/\(config.bucket)/\(encodedKey)"
        } else {
            urlString = "https://\(config.bucket).\(config.endpoint)/\(encodedKey)"
        }
        guard let url = URL(string: urlString) else { throw S3Error.badConfig }
        return url
    }

    // MARK: PUT (upload from a file on disk)

    /// Upload the file at `fileURL` to `key`. Progress is reported 0…1.
    /// When `bytesPerSecond > 0` the body is fed through a throttled bound stream
    /// so real on-the-wire throughput is capped; otherwise the fast file path is
    /// used and `URLSession` sends as fast as the link allows.
    func putObject(fileURL: URL, key: String, contentType: String,
                   contentMD5: String? = nil,
                   bytesPerSecond: Double = 0,
                   now: Date = Date(),
                   progress: ((Double) -> Void)? = nil) async throws {
        let url = try objectURL(key: key)
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil

        var headers: [String: String] = ["content-type": contentType]
        if let size { headers["content-length"] = String(size) }
        // Object-Lock buckets (and integrity-checking in general) require Content-MD5.
        if let contentMD5 { headers["content-md5"] = contentMD5 }
        let signed = signer.sign(method: "PUT", url: url, headers: headers, now: now)

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (k, v) in signed.headers { request.setValue(v, forHTTPHeaderField: k) }
        let delegate = UploadProgressDelegate(progress: progress)

        if bytesPerSecond > 0 {
            // Throttled path: stream the body ourselves at a limited rate.
            let producer = try ThrottledBodyStream(fileURL: fileURL, bytesPerSecond: bytesPerSecond)
            request.httpBodyStream = producer.bodyStream
            producer.start()
            defer { producer.cancel() }   // reap the producer thread win or lose
            let (data, response) = try await session.data(for: request, delegate: delegate)
            try Self.validate(response: response, data: data)
        } else {
            let (data, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
            try Self.validate(response: response, data: data)
        }
    }

    // MARK: DELETE (version-aware, for freeing bytes on versioned/locked buckets)

    struct ObjectVersion { let versionId: String; let isDeleteMarker: Bool }

    /// List all versions and delete-markers for a specific object key. On a
    /// versioned bucket (which Object Lock requires) freeing bytes means deleting
    /// each version, not just adding a hide-marker.
    func listVersions(forKey key: String, now: Date = Date()) async throws -> [ObjectVersion] {
        var components: URLComponents
        if config.provider.usesPathStyle {
            components = URLComponents(string: "https://\(config.endpoint)/\(config.bucket)")!
        } else {
            components = URLComponents(string: "https://\(config.bucket).\(config.endpoint)")!
        }
        components.queryItems = [URLQueryItem(name: "versions", value: ""),
                                 URLQueryItem(name: "prefix", value: key)]
        guard let url = components.url else { throw S3Error.badConfig }
        let signed = signer.sign(method: "GET", url: url, now: now)
        var request = URLRequest(url: url)
        for (k, v) in signed.headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return ListVersionsParser(matchKey: key).parse(data)
    }

    /// Delete one specific version. On an Object-Lock bucket this **fails** until
    /// the version's retention expires — that's the safety window; callers keep
    /// the tombstone and retry later. A 404 counts as already gone.
    func deleteObjectVersion(key: String, versionId: String, now: Date = Date()) async throws {
        guard var comps = URLComponents(url: try objectURL(key: key), resolvingAgainstBaseURL: false) else {
            throw S3Error.badConfig
        }
        comps.queryItems = [URLQueryItem(name: "versionId", value: versionId)]
        guard let url = comps.url else { throw S3Error.badConfig }
        let signed = signer.sign(method: "DELETE", url: url, now: now)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        for (k, v) in signed.headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw S3Error.network("No response") }
        if http.statusCode == 404 { return }
        guard (200..<300).contains(http.statusCode) else {
            throw S3Error.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: HEAD (existence check)

    /// Returns true if the object exists remotely.
    func headObject(key: String, now: Date = Date()) async throws -> Bool {
        let url = try objectURL(key: key)
        let signed = signer.sign(method: "HEAD", url: url, now: now)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        for (k, v) in signed.headers { request.setValue(v, forHTTPHeaderField: k) }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw S3Error.network("No response") }
        if http.statusCode == 404 { return false }
        if (200..<300).contains(http.statusCode) { return true }
        throw S3Error.http(http.statusCode, "")
    }

    // MARK: GET (verification downloads)

    /// Download an object to a local file (streamed by URLSession).
    func getObject(key: String, to destination: URL, now: Date = Date()) async throws {
        let url = try objectURL(key: key)
        let signed = signer.sign(method: "GET", url: url, now: now)
        var request = URLRequest(url: url)
        for (k, v) in signed.headers { request.setValue(v, forHTTPHeaderField: k) }
        let (tmp, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = (try? String(contentsOf: tmp, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: tmp)
            throw S3Error.http((response as? HTTPURLResponse)?.statusCode ?? -1, body)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
    }

    // MARK: List (verify / reconcile remote → local index)

    struct RemoteObject {
        let key: String
        let size: Int64
        let etag: String   // MD5 hex for single-part uploads (quotes stripped)
    }

    /// List objects under the configured prefix with size + ETag (one page,
    /// up to 1000). This is verification's workhorse: ~10 requests cover a
    /// 10k-object archive, no per-object HEADs needed.
    func listObjects(continuationToken: String? = nil, now: Date = Date()) async throws -> (objects: [RemoteObject], next: String?) {
        var components: URLComponents
        if config.provider.usesPathStyle {
            components = URLComponents(string: "https://\(config.endpoint)/\(config.bucket)")!
        } else {
            components = URLComponents(string: "https://\(config.bucket).\(config.endpoint)")!
        }
        var items = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "prefix", value: config.prefix),
        ]
        if let token = continuationToken {
            items.append(URLQueryItem(name: "continuation-token", value: token))
        }
        components.queryItems = items
        guard let url = components.url else { throw S3Error.badConfig }

        let signed = signer.sign(method: "GET", url: url, now: now)
        var request = URLRequest(url: url)
        for (k, v) in signed.headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)

        let parser = ListBucketParser()
        return parser.parse(data)
    }

    /// Best-effort connectivity check: list a single page.
    func testConnection() async throws {
        _ = try await listObjects()
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw S3Error.network("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw S3Error.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: Transient-error retries

    /// B2 (and S3 generally) documents 5xx/429 as transient — "InternalError"
    /// incidents are expected to resolve on retry with backoff. Auth/config
    /// errors (4xx) and cancellation are NOT retryable.
    static func isTransient(_ error: Error) -> Bool {
        if case S3Error.http(let code, _) = error {
            return code == 429 || (500...599).contains(code)
        }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                 .notConnectedToInternet, .dnsLookupFailed, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Run an operation up to `attempts` times, with exponential backoff and
    /// jitter between transient failures (~1s, ~3s). Cancellation propagates
    /// immediately — the backoff sleep throws on cancel, so pause stays snappy.
    static func withRetries<T>(attempts: Int = 3,
                               onRetry: ((Int, Error) -> Void)? = nil,
                               _ operation: () async throws -> T) async throws -> T {
        for attempt in 1...attempts {
            do {
                return try await operation()
            } catch {
                guard attempt < attempts, isTransient(error) else { throw error }
                onRetry?(attempt, error)
                let backoff = pow(3.0, Double(attempt - 1)) * Double.random(in: 0.8...1.4)
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
        fatalError("unreachable")
    }
}

/// Reports byte-level upload progress from `URLSession`, coalesced to ≥1%
/// steps. Uncoalesced, this fires hundreds of times/sec per stream and each
/// call hops to the main actor to mutate published state — enough sustained
/// main-thread churn to starve the UI (and trip the watchdog) on long runs.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let progress: ((Double) -> Void)?
    private var lastReported: Double = -1
    init(progress: ((Double) -> Void)?) { self.progress = progress }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let p = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        if p - lastReported >= 0.01 || p >= 1 {
            lastReported = p
            progress?(p)
        }
    }
}

/// Streaming XML parser for the subset of ListBucketResult we care about.
private final class ListBucketParser: NSObject, XMLParserDelegate {
    private var objects: [S3Client.RemoteObject] = []
    private var next: String?
    private var current = ""
    private var currentKey = ""
    private var currentSize: Int64 = 0
    private var currentETag = ""
    private var inContents = false

    func parse(_ data: Data) -> (objects: [S3Client.RemoteObject], next: String?) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return (objects, next)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        current = ""
        if elementName == "Contents" { inContents = true; currentKey = ""; currentSize = 0; currentETag = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { current += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "Key" where inContents: currentKey = trimmed
        case "Size" where inContents: currentSize = Int64(trimmed) ?? 0
        case "ETag" where inContents:
            currentETag = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased()
        case "Contents":
            if !currentKey.isEmpty {
                objects.append(.init(key: currentKey, size: currentSize, etag: currentETag))
            }
            inContents = false
        case "NextContinuationToken":
            next = trimmed
        default:
            break
        }
    }
}

/// Parses ListVersionsResult for the versions + delete-markers of one exact key.
private final class ListVersionsParser: NSObject, XMLParserDelegate {
    private let matchKey: String
    private var results: [S3Client.ObjectVersion] = []
    private var current = ""
    private var key = ""
    private var versionId = ""
    private var isMarker = false
    private var inEntry = false

    init(matchKey: String) { self.matchKey = matchKey }

    func parse(_ data: Data) -> [S3Client.ObjectVersion] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return results
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        current = ""
        if elementName == "Version" || elementName == "DeleteMarker" {
            inEntry = true; key = ""; versionId = ""
            isMarker = elementName == "DeleteMarker"
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { current += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "Key" where inEntry: key = current.trimmingCharacters(in: .whitespacesAndNewlines)
        case "VersionId" where inEntry: versionId = current.trimmingCharacters(in: .whitespacesAndNewlines)
        case "Version", "DeleteMarker":
            if key == matchKey && !versionId.isEmpty {
                results.append(.init(versionId: versionId, isDeleteMarker: isMarker))
            }
            inEntry = false
        default: break
        }
    }
}
