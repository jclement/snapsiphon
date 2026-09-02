import XCTest
@testable import SnapSiphon

private final class S3StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let result = try Self.handler?(request)
            guard let result else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: result.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class S3AndRestoreTests: XCTestCase {
    func testAWSOfficialSigV4Vector() throws {
        let signer = SigV4(
            accessKeyID: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            region: "us-east-1")
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z"))
        let request = signer.sign(
            method: "GET",
            url: try XCTUnwrap(URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")),
            headers: ["range": "bytes=0-9"],
            contentSHA256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            now: date)
        XCTAssertTrue(request.headers["Authorization"]?.hasSuffix(
            "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
        ) == true)
    }

    func testSessionTokenIsSigned() throws {
        let signer = SigV4(accessKeyID: "id", secretAccessKey: "secret",
                           region: "us-east-1", sessionToken: "token")
        let request = signer.sign(method: "GET",
                                  url: try XCTUnwrap(URL(string: "https://bucket.example.com/")),
                                  now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(request.headers["x-amz-security-token"], "token")
        XCTAssertTrue(request.headers["Authorization"]?.contains("x-amz-security-token") == true)
    }

    func testRestoreScriptVerifiesExistingOutputsAndSupportsNamespaceFreeXML() {
        var config = S3Config()
        config.endpoint = "s3.example.com"
        config.region = "us-east-1"
        config.bucket = "photos"
        let script = RestoreScript.build(
            config: config,
            credentials: S3Credentials(accessKeyID: "id", secretAccessKey: "secret",
                                       sessionToken: "session"),
            ageSecret: Age.Identity().bech32)
        XCTAssertTrue(script.contains("expected and sha256_file(target) == expected"))
        XCTAssertTrue(script.contains("e.tag.rsplit(\"}\", 1)[-1]"))
        XCTAssertTrue(script.contains("x-amz-security-token"))
        XCTAssertTrue(script.contains("ck_db.unlink(missing_ok=True)"))
    }

    func testVersionListingPaginatesAndMalformedXMLFails() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [S3StubURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        var config = S3Config()
        config.endpoint = "s3.example.com"
        config.region = "us-east-1"
        config.bucket = "photos"
        config.pathStyle = true
        let client = S3Client(config: config,
                              credentials: S3Credentials(accessKeyID: "id",
                                                        secretAccessKey: "secret"),
                              session: session)
        let key = client.fullKey(for: "objects/aa/blob")
        S3StubURLProtocol.handler = { request in
            let query = URLComponents(url: try XCTUnwrap(request.url),
                                      resolvingAgainstBaseURL: false)?.queryItems ?? []
            let isSecond = query.contains { $0.name == "key-marker" }
            let body = isSecond
                ? """
                  <ListVersionsResult>
                    <IsTruncated>false</IsTruncated>
                    <Version><Key>\(key)</Key><VersionId>v3</VersionId></Version>
                  </ListVersionsResult>
                  """
                : """
                  <ListVersionsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                    <IsTruncated>true</IsTruncated>
                    <NextKeyMarker>\(key)</NextKeyMarker>
                    <NextVersionIdMarker>v2</NextVersionIdMarker>
                    <Version><Key>\(key)</Key><VersionId>v1</VersionId></Version>
                    <DeleteMarker><Key>\(key)</Key><VersionId>v2</VersionId></DeleteMarker>
                  </ListVersionsResult>
                  """
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let versions = try await client.listVersions(forKey: key)
        XCTAssertEqual(versions.map(\.versionId), ["v1", "v2", "v3"])

        S3StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                             httpVersion: nil, headerFields: nil)!,
             Data("<broken".utf8))
        }
        do {
            _ = try await client.listObjects()
            XCTFail("Malformed XML must not be accepted as an empty bucket")
        } catch let error as S3Error {
            guard case .malformedResponse = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func stubbedClient(prefix: String = "SnapSiphon") -> S3Client {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [S3StubURLProtocol.self]
        var config = S3Config()
        config.endpoint = "s3.example.com"
        config.region = "us-east-1"
        config.bucket = "photos"
        config.prefix = prefix
        config.pathStyle = true
        return S3Client(config: config,
                        credentials: S3Credentials(accessKeyID: "id", secretAccessKey: "secret"),
                        session: URLSession(configuration: sessionConfig))
    }

    /// The preflight LIST must use the same slash-terminated prefix as every
    /// other request: a B2 key restricted to `SnapSiphon/` rejects a bare
    /// `prefix=SnapSiphon` with 403, failing Save & Test for a working setup.
    func testPreflightListsUnderSlashTerminatedPrefix() async throws {
        var seenPrefixes: [String?] = []
        S3StubURLProtocol.handler = { request in
            let query = URLComponents(url: try XCTUnwrap(request.url),
                                      resolvingAgainstBaseURL: false)?.queryItems ?? []
            seenPrefixes.append(query.first { $0.name == "prefix" }?.value)
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                                    httpVersion: nil, headerFields: nil)!,
                    Data("<ListBucketResult></ListBucketResult>".utf8))
        }
        try await stubbedClient().testConnection()
        XCTAssertEqual(seenPrefixes, ["SnapSiphon/"])

        // An empty user prefix lists the whole bucket rather than sending a
        // dangling "/" that would match nothing.
        seenPrefixes = []
        try await stubbedClient(prefix: "").testConnection()
        XCTAssertEqual(seenPrefixes, [nil])
    }

    /// A provider that omits Content-Length on HEAD must report the object as
    /// present with an unknown size — never `-1` for the index to record.
    func testHeadWithoutContentLengthReportsUnknownSize() async throws {
        S3StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                             httpVersion: nil, headerFields: nil)!, Data())
        }
        let head = try await stubbedClient().headObject(key: "SnapSiphon/objects/aa/blob")
        XCTAssertNotNil(head)
        XCTAssertNil(head?.size)
    }

    /// Users paste the dashboard's URL form of the endpoint; the client (and
    /// the restore script, which bakes the value in) want the bare host.
    func testEndpointNormalizer() {
        XCTAssertEqual(S3Config.normalizedEndpoint("  https://abc123.r2.cloudflarestorage.com/\n"),
                       "abc123.r2.cloudflarestorage.com")
        XCTAssertEqual(S3Config.normalizedEndpoint("HTTP://minio.example.com//"), "minio.example.com")
        XCTAssertEqual(S3Config.normalizedEndpoint("s3.us-west-004.backblazeb2.com"),
                       "s3.us-west-004.backblazeb2.com")
        // A port is part of the host and must survive.
        XCTAssertEqual(S3Config.normalizedEndpoint("https://picos3.tailnet.ts.net:9000/"),
                       "picos3.tailnet.ts.net:9000")
        XCTAssertEqual(S3Config.normalizedEndpoint(""), "")
    }

    /// Only throttling (408/429), server incidents (5xx) and transport faults
    /// retry. 501 is a provider saying "never" (B2 to a conditional PUT), and
    /// retrying it three times with backoff costs seconds per call.
    func testTransientClassification() {
        XCTAssertTrue(S3Client.isTransient(S3Error.http(429, "")))
        XCTAssertTrue(S3Client.isTransient(S3Error.http(408, "")))
        XCTAssertTrue(S3Client.isTransient(S3Error.http(503, "")))
        XCTAssertTrue(S3Client.isTransient(S3Error.http(500, "")))
        XCTAssertFalse(S3Client.isTransient(S3Error.http(501, "")))
        XCTAssertFalse(S3Client.isTransient(S3Error.http(412, "")))
        XCTAssertFalse(S3Client.isTransient(S3Error.http(403, "")))
        XCTAssertFalse(S3Client.isTransient(S3Error.http(404, "")))
        XCTAssertFalse(S3Client.isTransient(S3Error.http(405, "")))
        XCTAssertFalse(S3Client.isTransient(S3Error.http(400, "")))
        // A body stream that CFNetwork could not re-send is worth one more
        // attempt: the retry builds a fresh producer from the file on disk.
        XCTAssertTrue(S3Client.isTransient(URLError(.requestBodyStreamExhausted)))
        XCTAssertTrue(S3Client.isTransient(URLError(.timedOut)))
        XCTAssertFalse(S3Client.isTransient(URLError(.cancelled)))
        XCTAssertFalse(S3Client.isTransient(CancellationError()))
    }
}
