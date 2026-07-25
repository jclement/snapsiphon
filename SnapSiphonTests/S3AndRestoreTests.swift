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
}
