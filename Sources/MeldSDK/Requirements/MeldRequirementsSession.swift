import Foundation

/// The requirements session your backend mints with `POST /crypto/onramp/requirements-sessions`, passed
/// through unchanged. It is scoped to one customer and the providers your backend named; its token is
/// never printed.
public struct MeldRequirementsSession: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let id: String
    public let serviceProviders: [String]
    /// When the session's token expires, or nil when the response carries no readable time.
    public let expiresAt: Date?
    let raw: [String: Any]

    public var description: String { "[MeldRequirementsSession REDACTED]" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// Decode the session your backend returns. Throws when it is not a requirements session this SDK can use.
    public static func from(jsonData: Data) throws -> MeldRequirementsSession {
        guard let raw = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any],
              (try? RequirementsSessionDescriptor(session: raw, environment: nil)) != nil,
              let id = raw["id"] as? String
        else { throw MeldRequirementsSessionError.malformed }
        return MeldRequirementsSession(id: id, serviceProviders: (raw["serviceProviders"] as? [String]) ?? [],
                                       expiresAt: RequirementsJSON.date(raw["expiresAt"]), raw: raw)
    }

    public static func from(jsonString: String) throws -> MeldRequirementsSession {
        try from(jsonData: Data(jsonString.utf8))
    }
}

public enum MeldRequirementsSessionError: LocalizedError {
    case malformed
    public var errorDescription: String? {
        "Requirements session JSON is not a session minted by POST /crypto/onramp/requirements-sessions."
    }
}

/// The session's own action endpoint and bearer. Separate from the order descriptor: a session reaches
/// exactly `/crypto/onramp/requirements-sessions/{id}/actions` with READ and RUN_STEP, nothing else.
struct RequirementsSessionDescriptor: CustomStringConvertible {
    static let operations = ["READ": false, "RUN_STEP": true]
    let endpoint: URL
    private let bearer: String
    var description: String { "[RequirementsSessionDescriptor REDACTED]" }

    /// The mint's endpoint is relative and resolves against `environment` (with none, any Meld API host), so a
    /// session minted in another environment cannot be told apart here: Meld refuses it with 401, and `ensureReady`
    /// ends `EXPIRED` after one renewal. An absolute endpoint must still be on that host.
    init(session raw: [String: Any], environment: MeldEnvironment?) throws {
        let bases = (environment.map { [$0] } ?? [.sandbox, .qa, .production])
            .compactMap { URL(string: PaymentActionDescriptor.baseURL($0)) }
        guard let actions = raw["requirementsActions"] as? [String: Any],
              PaymentActionJSON.integer(actions["version"]) == 1,
              let id = raw["id"] as? String, RequirementsJSON.isBase58(id),
              let endpoint = actions["endpoint"] as? String, !endpoint.contains("?"), !endpoint.contains("#"),
              !endpoint.components(separatedBy: "/").contains(where: { $0 == "." || $0 == ".." }),
              let base = bases.first,
              let url = URL(string: endpoint, relativeTo: base)?.absoluteURL,
              url.scheme == "https", let host = url.host, bases.contains(where: { $0.host == host }),
              url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              parts.percentEncodedPath == url.path,
              url.path.components(separatedBy: "/") == ["", "crypto", "onramp", "requirements-sessions", id, "actions"],
              let pointer = actions["bearerTokenPointer"] as? String,
              let bearer = PaymentActionJSON.resolve(pointer, in: raw) as? String, PaymentActionJSON.isBearer(bearer),
              let declarations = actions["operations"] as? [[String: Any]],
              PaymentActionJSON.operations(declarations) == Self.operations
        else { throw PaymentActionError.invalidDescriptor }
        self.endpoint = url
        self.bearer = bearer
    }

    func request(operation: String, fields: [String: Any], key: UUID?) throws -> URLRequest {
        try ActionRequest.post(endpoint: endpoint, bearer: bearer, operations: Self.operations, operation: operation,
                               fields: fields, key: key)
    }
}

/// A rejected input, by key. Values are never echoed.
public struct MeldFieldError: Equatable {
    public let key: String
    /// `REQUIRED`, `INVALID` or `UNSUPPORTED`; an open set.
    public let reason: String
}

enum RequirementsReply {
    case success([String: Any])
    case failure(status: Int, code: String?, fieldErrors: [MeldFieldError])
    case transport
    case invalid
}

/// The session's transport: the order transport's bounded POST with the session's larger READ cap.
final class RequirementsActionClient: CustomStringConvertible {
    static let responseLimit = 262_144
    let descriptor: RequirementsSessionDescriptor
    private let transport: ActionTransport
    var description: String { "[RequirementsActionClient REDACTED]" }

    init(descriptor: RequirementsSessionDescriptor, transport: ActionTransport = URLSessionActionTransport()) {
        self.descriptor = descriptor
        self.transport = transport
    }

    /// Completes on the main queue, unless the returned task is cancelled first.
    @discardableResult
    func send(_ operation: String, fields: [String: Any], key: UUID?,
              completion: @escaping (RequirementsReply) -> Void) -> ActionTransportTask? {
        let request: URLRequest
        do { request = try descriptor.request(operation: operation, fields: fields, key: key) }
        catch { DispatchQueue.main.async { completion(.invalid) }; return nil }
        return transport.post(request, responseLimit: Self.responseLimit) { result in
            switch result {
            case .transportFailed: completion(.transport)
            case .notHTTP: completion(.invalid)
            case let .response(status, body):
                if (200..<300).contains(status) {
                    guard let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                          PaymentActionJSON.integer(json["version"]) == 1 else { completion(.invalid); return }
                    completion(.success(json))
                } else { completion(Self.failure(body, status: status)) }
            }
        }
    }

    func finish() { transport.finish() }

    static func failure(_ body: Data?, status: Int) -> RequirementsReply {
        var code: String?
        if case .action(let known) = PaymentActionFailureCode.decode(body, status: status) { code = known.rawValue }
        var fieldErrors: [MeldFieldError] = []
        if status == 400, code == PaymentActionFailureCode.invalidRequest.rawValue, let body,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let raw = json["fieldErrors"] as? [[String: Any]] {
            let parsed = raw.compactMap { entry -> MeldFieldError? in
                guard let key = entry["key"] as? String, !key.isEmpty, key.utf8.count <= 256,
                      let reason = entry["reason"] as? String, !reason.isEmpty, reason.utf8.count <= 64 else { return nil }
                return MeldFieldError(key: key, reason: reason)
            }
            if parsed.count == raw.count { fieldErrors = parsed }
        }
        return .failure(status: status, code: code, fieldErrors: fieldErrors)
    }
}

enum RequirementsJSON {
    private static let base58 = CharacterSet(charactersIn: "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    static func isBase58(_ value: String) -> Bool {
        (1...64).contains(value.unicodeScalars.count) && value.unicodeScalars.allSatisfy { base58.contains($0) }
    }

    /// ISO-8601 UTC; an unreadable value reads as absent.
    static func date(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }

    /// A page the SDK may open: https on the default port, with a host and no credentials.
    static func page(_ value: Any?) -> URL? {
        guard let raw = value as? String, raw.utf8.count <= 8192, let url = URL(string: raw),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        return url
    }
}
