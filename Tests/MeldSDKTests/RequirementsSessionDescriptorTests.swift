import CryptoKit
import XCTest
@testable import MeldSDK

final class RequirementsSessionDescriptorTests: XCTestCase {
    func testEveryFixtureMintDecodesAndBuildsOnlyItsOwnRequests() throws {
        let sessions = try RequirementsFixtures.sessionNames()
        XCTAssertGreaterThanOrEqual(sessions.count, 9)
        for name in sessions {
            let mint = try RequirementsFixtures.mint(name)
            let session = try MeldRequirementsSession.from(jsonData: JSONSerialization.data(withJSONObject: mint))
            XCTAssertEqual(session.id, mint["id"] as? String, name)
            XCTAssertEqual(session.serviceProviders, mint["serviceProviders"] as? [String], name)
            XCTAssertEqual(session.expiresAt, RequirementsFixtures.date(try XCTUnwrap(mint["expiresAt"] as? String)), name)
            let descriptor = try RequirementsSessionDescriptor(session: session.raw, environment: .sandbox)
            let read = try descriptor.request(operation: "READ", fields: [:], key: nil)
            XCTAssertEqual(read.url?.absoluteString, "https://api-sb.meld.io/crypto/onramp/requirements-sessions/\(session.id)/actions")
            XCTAssertEqual(read.httpMethod, "POST")
            XCTAssertEqual(read.value(forHTTPHeaderField: "Authorization"), "Bearer \(try XCTUnwrap(mint["token"] as? String))")
            XCTAssertEqual(read.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(read.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertNil(read.value(forHTTPHeaderField: "X-Idempotency-Key"))
            XCTAssertFalse(read.httpShouldHandleCookies)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(read.httpBody)) as? [String: Any])
            XCTAssertJSONEqual(body, try XCTUnwrap(try RequirementsFixtures.exchanges(name, "READ").first?["request"] as? [String: Any]))
            for run in try RequirementsFixtures.runs(name) {
                let key = try XCTUnwrap(UUID(uuidString: run.key))
                var fields = run.request
                fields["version"] = nil
                fields["operation"] = nil
                let request = try descriptor.request(operation: "RUN_STEP", fields: fields, key: key)
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Idempotency-Key"), run.key)
                XCTAssertJSONEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any], run.request)
            }
            XCTAssertThrowsError(try descriptor.request(operation: "READ", fields: [:], key: UUID()))
            XCTAssertThrowsError(try descriptor.request(operation: "RUN_STEP", fields: ["stepId": "x"], key: nil))
            XCTAssertThrowsError(try descriptor.request(operation: "READ_SUBMISSION", fields: [:], key: nil))
        }
    }

    func testTheTokenIsNeverPrinted() throws {
        let mint = try RequirementsFixtures.mint("banxa-fresh")
        let token = try XCTUnwrap(mint["token"] as? String)
        let session = try MeldRequirementsSession.from(jsonData: JSONSerialization.data(withJSONObject: mint))
        let descriptor = try RequirementsSessionDescriptor(session: session.raw, environment: .sandbox)
        let client = RequirementsActionClient(descriptor: descriptor, transport: FixtureTransport())
        var dumped = ""
        dump(session, to: &dumped)
        XCTAssertFalse(dumped.contains(token), dumped)
        for printed in [String(describing: session), String(reflecting: session), "\(session)",
                        String(describing: descriptor), String(describing: client)] {
            XCTAssertFalse(printed.contains(token), printed)
            XCTAssertTrue(printed.contains("REDACTED"), printed)
        }
        XCTAssertEqual(String(describing: session), "[MeldRequirementsSession REDACTED]")
    }

    func testRejectsEndpointsOutsideTheSessionPath() throws {
        let id = "Rs7dQhV3mKp2XaYc9TbN4e"
        for endpoint in ["https://other.example/crypto/onramp/requirements-sessions/\(id)/actions",
                         "http://api-sb.meld.io/crypto/onramp/requirements-sessions/\(id)/actions",
                         "https://api-sb.meld.io:8443/crypto/onramp/requirements-sessions/\(id)/actions",
                         "https://user:pass@api-sb.meld.io/crypto/onramp/requirements-sessions/\(id)/actions",
                         "//other.example/crypto/onramp/requirements-sessions/\(id)/actions",
                         "/crypto/onramp/requirements-sessions/OtherSession1/actions",
                         "/crypto/order/headless/onramp/BANXA/\(id)/actions",
                         "/crypto/onramp/requirements-sessions/\(id)/actions/",
                         "/crypto/onramp/requirements-sessions/\(id)/./actions",
                         "/crypto/onramp/requirements-sessions/../requirements-sessions/\(id)/actions",
                         "/crypto/onramp/requirements-sessions/\(id)/actions?token=synthetic",
                         "/crypto/onramp/requirements-sessions/\(id)/actions?",
                         "/crypto/onramp/requirements-sessions/\(id)/actions#fragment",
                         "/crypto/onramp/requirements%2Dsessions/\(id)/actions"] {
            XCTAssertThrowsError(try descriptor(actions: ["endpoint": endpoint]), endpoint)
        }
        XCTAssertNoThrow(try descriptor(actions: ["endpoint": "https://api-sb.meld.io:443/crypto/onramp/requirements-sessions/\(id)/actions"]))
        XCTAssertNoThrow(try descriptor(actions: ["endpoint": "https://api-sb.meld.io/crypto/onramp/requirements-sessions/\(id)/actions"]))
    }

    func testARelativeEndpointResolvesAgainstTheConfiguredEnvironmentAndAnAbsoluteOneMustBeOnIt() throws {
        var mint = try RequirementsFixtures.mint("banxa-fresh")
        var actions = try XCTUnwrap(mint["requirementsActions"] as? [String: Any])
        actions["endpoint"] = "https://api.meld.io" + (actions["endpoint"] as? String ?? "")
        mint["requirementsActions"] = actions
        XCTAssertNoThrow(try MeldRequirementsSession.from(jsonData: JSONSerialization.data(withJSONObject: mint)))
        XCTAssertNoThrow(try RequirementsSessionDescriptor(session: mint, environment: .production))
        XCTAssertThrowsError(try RequirementsSessionDescriptor(session: mint, environment: .sandbox))
        let relative = try RequirementsFixtures.mint("banxa-fresh")
        XCTAssertEqual(try RequirementsSessionDescriptor(session: relative, environment: .qa).endpoint.host, "api-qa.meld.io")
    }

    func testIdsAreBase58AndMatchThePath() throws {
        for id in ["", "has0zero", "hasOletter", "hasIletter", "haslletter", "has-dash", String(repeating: "a", count: 65)] {
            var mint = try RequirementsFixtures.mint("banxa-fresh")
            mint["id"] = id
            var actions = try XCTUnwrap(mint["requirementsActions"] as? [String: Any])
            actions["endpoint"] = "/crypto/onramp/requirements-sessions/\(id)/actions"
            mint["requirementsActions"] = actions
            XCTAssertThrowsError(try RequirementsSessionDescriptor(session: mint, environment: .sandbox), id)
            XCTAssertThrowsError(try MeldRequirementsSession.from(jsonData: JSONSerialization.data(withJSONObject: mint)), id)
        }
        let longest = String(repeating: "a", count: 64)
        var mint = try RequirementsFixtures.mint("banxa-fresh")
        mint["id"] = longest
        var actions = try XCTUnwrap(mint["requirementsActions"] as? [String: Any])
        actions["endpoint"] = "/crypto/onramp/requirements-sessions/\(longest)/actions"
        mint["requirementsActions"] = actions
        XCTAssertNoThrow(try RequirementsSessionDescriptor(session: mint, environment: .sandbox))
    }

    func testStrictVersionOperationsAndBearer() throws {
        for version: Any in [true, "1", 0, 1.5, 2] {
            XCTAssertThrowsError(try descriptor(actions: ["version": version]))
        }
        let read = ["operation": "READ", "idempotencyKeyRequired": false] as [String: Any]
        let run = ["operation": "RUN_STEP", "idempotencyKeyRequired": true] as [String: Any]
        for operations: Any in [[read], [run], [read, run, ["operation": "OTHER", "idempotencyKeyRequired": false]],
                                [read, ["operation": "RUN_STEP", "idempotencyKeyRequired": false]],
                                [["operation": "READ", "idempotencyKeyRequired": true], run],
                                [read, ["operation": "RUN_STEP", "idempotencyKeyRequired": 1]], [read, run, read], []] {
            XCTAssertThrowsError(try descriptor(actions: ["operations": operations]))
        }
        XCTAssertNoThrow(try descriptor(actions: ["operations": [run, read]]))
        for pointer in ["token", "/missing", "/requirementsActions", "/bad~2pointer"] {
            XCTAssertThrowsError(try descriptor(actions: ["bearerTokenPointer": pointer]), pointer)
        }
        for token in ["", "has space", "line\nbreak", "caf\u{e9}", String(repeating: "x", count: 16385)] {
            XCTAssertThrowsError(try descriptor(mint: ["token": token]))
        }
        XCTAssertNoThrow(try descriptor(mint: ["token": String(repeating: "x", count: 16384)]))
        XCTAssertThrowsError(try MeldRequirementsSession.from(jsonString: "[]"))
        XCTAssertThrowsError(try MeldRequirementsSession.from(jsonString: "{}"))
        XCTAssertThrowsError(try MeldRequirementsSession.from(jsonString: "not json"))
    }

    func testClientReadsUpToTheSessionCapAndKeepsOnlyKnownCodesAndFieldErrors() throws {
        let descriptor = try self.descriptor()
        let transport = FixtureTransport()
        let client = RequirementsActionClient(descriptor: descriptor, transport: transport)
        XCTAssertEqual(RequirementsActionClient.responseLimit, 262_144)

        let big = ["version": 1, "padding": String(repeating: "x", count: 200_000)] as [String: Any]
        transport.respond = { _ in FixtureTransport.json(200, big) }
        XCTAssertEqual(try reply(client, "READ").kind, "success")

        transport.respond = { _ in FixtureTransport.json(400, ["version": 1, "code": "INVALID_REQUEST",
            "fieldErrors": [["key": "email", "reason": "INVALID"], ["key": "name.firstName", "reason": "REQUIRED"]]]) }
        guard case let .failure(status, code, fieldErrors) = try reply(client, "RUN_STEP", key: UUID()).value else {
            return XCTFail("expected a failure")
        }
        XCTAssertEqual(status, 400)
        XCTAssertEqual(code, "INVALID_REQUEST")
        XCTAssertEqual(fieldErrors, [MeldFieldError(key: "email", reason: "INVALID"),
                                     MeldFieldError(key: "name.firstName", reason: "REQUIRED")])

        for (status, body) in [(409, ["version": 1, "code": "unknown-sensitive-value"]),
                               (409, ["version": 1, "code": "AUTHORIZATION_REQUIRED"]),
                               (400, ["version": 1, "code": "INVALID_REQUEST", "fieldErrors": [["key": "email"]]])] as [(Int, [String: Any])] {
            transport.respond = { _ in FixtureTransport.json(status, body) }
            guard case let .failure(_, code, fieldErrors) = try reply(client, "RUN_STEP", key: UUID()).value else {
                return XCTFail("expected a failure")
            }
            XCTAssertEqual(code, status == 400 ? "INVALID_REQUEST" : nil)
            XCTAssertTrue(fieldErrors.isEmpty)
        }

        transport.respond = { _ in .response(status: 200, body: nil) }
        XCTAssertEqual(try reply(client, "READ").kind, "invalid", "over the cap reads as no body")
        transport.respond = { _ in .notHTTP }
        XCTAssertEqual(try reply(client, "READ").kind, "invalid")
        transport.respond = { _ in .transportFailed }
        XCTAssertEqual(try reply(client, "READ").kind, "transport")
        XCTAssertEqual(try reply(client, "RUN_STEP", fields: ["value": String(repeating: "x", count: 65536)], key: UUID()).kind,
                       "invalid", "a request over 64 KiB is never sent")
        XCTAssertEqual(transport.calls.count, 8)
    }

    func testURLSessionTransportCapsTheBodyItHandsBack() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionURLProtocol.self]
        let transport = URLSessionActionTransport(configuration: configuration)
        defer { transport.finish() }
        let client = RequirementsActionClient(descriptor: try descriptor(), transport: transport)
        SessionURLProtocol.body = try JSONSerialization.data(withJSONObject: ["version": 1, "padding": String(repeating: "x", count: 250_000)])
        XCTAssertEqual(try reply(client, "READ").kind, "success")
        SessionURLProtocol.body = try JSONSerialization.data(withJSONObject: ["version": 1, "padding": String(repeating: "x", count: 270_000)])
        XCTAssertEqual(try reply(client, "READ").kind, "invalid")
        XCTAssertEqual(SessionURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer eyJhbGciOiJIUzI1NiJ9.fixture.requirements-session-token")
    }

    private func reply(_ client: RequirementsActionClient, _ operation: String, fields: [String: Any] = [:],
                       key: UUID? = nil) throws -> (kind: String, value: RequirementsReply) {
        var received: RequirementsReply?
        client.send(operation, fields: fields, key: key) { received = $0 }
        let deadline = Date().addingTimeInterval(3)
        while received == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        let value = try XCTUnwrap(received)
        switch value {
        case .success: return ("success", value)
        case .failure: return ("failure", value)
        case .transport: return ("transport", value)
        case .invalid: return ("invalid", value)
        }
    }

    private func descriptor(mint changes: [String: Any] = [:], actions: [String: Any] = [:]) throws -> RequirementsSessionDescriptor {
        var mint = try RequirementsFixtures.mint("banxa-fresh").merging(changes) { $1 }
        mint["requirementsActions"] = try XCTUnwrap(mint["requirementsActions"] as? [String: Any]).merging(actions) { $1 }
        return try RequirementsSessionDescriptor(session: mint, environment: .sandbox)
    }
}

final class RequirementsFixturesManifestTests: XCTestCase {
    static let manifestDigest = "32de87754495673aa11c334360d124bfcc7c68b77910fe81750c37d2e6e38383"

    func testEveryFixtureMatchesTheManifestAndTheManifestMatchesTheContract() throws {
        let manifest = try RequirementsFixtures.data("SHA256SUMS")
        XCTAssertEqual(hex(manifest), Self.manifestDigest)
        let lines = try XCTUnwrap(String(data: manifest, encoding: .utf8)).split(separator: "\n")
        XCTAssertFalse(lines.isEmpty)
        var listed: [String] = []
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            XCTAssertEqual(parts.count, 2, String(line))
            let path = parts[1].trimmingCharacters(in: .whitespaces)
            listed.append(path)
            XCTAssertEqual(hex(try RequirementsFixtures.data(path)), parts[0], path)
        }
        XCTAssertEqual(listed, listed.sorted(), "sorted by path")
        let files = try FileManager.default.subpathsOfDirectory(atPath: RequirementsFixtures.directory.path)
            .filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertEqual(files, listed, "every fixture is listed")
    }

    private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private final class SessionURLProtocol: URLProtocol {
    static var body = Data()
    static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
