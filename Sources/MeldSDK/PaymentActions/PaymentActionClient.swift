import CoreFoundation
import Foundation

enum PaymentActionError: Error {
    case invalidDescriptor, invalidRequest, invalidResponse, transport, http(Int), storage, alreadyAttempted
    case action(PaymentActionFailureCode)
}

/// Only the public action error vocabulary is retained; response bodies are never attached.
enum PaymentActionFailureCode: String {
    case invalidRequest = "INVALID_REQUEST", authorizationRequired = "AUTHORIZATION_REQUIRED"
    case stateNotFound = "STATE_NOT_FOUND", requestConflict = "REQUEST_CONFLICT", orderStateChanged = "ORDER_STATE_CHANGED"
    case concurrentStateChange = "CONCURRENT_STATE_CHANGE", operationInFlight = "OPERATION_IN_FLIGHT"
    case providerRejected = "PROVIDER_REJECTED", providerRateLimited = "PROVIDER_RATE_LIMITED"
    case providerUnavailable = "PROVIDER_UNAVAILABLE", invalidProviderResponse = "INVALID_PROVIDER_RESPONSE"
    case outcomeUnknown = "OUTCOME_UNKNOWN"

    var httpStatus: Int {
        switch self {
        case .invalidRequest: return 400
        case .authorizationRequired: return 401
        case .stateNotFound: return 404
        case .requestConflict, .orderStateChanged, .concurrentStateChange: return 409
        case .operationInFlight: return 425
        case .providerRejected: return 422
        case .providerRateLimited: return 429
        case .providerUnavailable, .invalidProviderResponse: return 502
        case .outcomeUnknown: return 503
        }
    }

    static func decode(_ data: Data?, status: Int) -> PaymentActionError {
        guard let data, data.count <= 65536,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              PaymentActionJSON.integer(json["version"]) == 1,
              let raw = json["code"] as? String, let code = Self(rawValue: raw), code.httpStatus == status
        else { return .http(status) }
        return .action(code)
    }
}

struct PaymentActionDescriptor: CustomStringConvertible {
    let endpoint: URL
    private let bearer: String
    let operations: [String: Bool]
    var identity: String { "https://" + (endpoint.host ?? "") + endpoint.path }
    var description: String { "PaymentActionDescriptor[REDACTED]" }

    init(order: MeldOrder, environment: MeldEnvironment) throws {
        guard let raw = order.raw["paymentActions"] as? [String: Any],
              PaymentActionJSON.integer(raw["version"]) == 1,
              let endpoint = raw["endpoint"] as? String,
              let orderID = order.id, !orderID.isEmpty,
              let url = URL(string: endpoint, relativeTo: URL(string: Self.baseURL(environment)))?.absoluteURL,
              url.scheme == "https", url.host == URL(string: Self.baseURL(environment))?.host,
              url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              parts.percentEncodedPath == url.path,
              let pointer = raw["bearerTokenPointer"] as? String,
              let bearer = PaymentActionJSON.resolve(pointer, in: order.raw) as? String,
              PaymentActionJSON.isBearer(bearer),
              let declarations = raw["operations"] as? [[String: Any]], !declarations.isEmpty,
              let operations = PaymentActionJSON.operations(declarations)
        else { throw PaymentActionError.invalidDescriptor }
        let path = url.path.components(separatedBy: "/")
        guard path.count == 8, Array(path.prefix(4)) == ["", "crypto", "order", "headless"],
              ["onramp", "offramp"].contains(path[4]),
              !path[5].isEmpty, path[6] == orderID, path[7] == "actions",
              order.serviceProvider == nil || order.serviceProvider == path[5]
        else { throw PaymentActionError.invalidDescriptor }
        self.endpoint = url
        self.bearer = bearer
        self.operations = operations
    }

    func request(operation: String, fields: [String: Any], key: UUID?) throws -> URLRequest {
        try ActionRequest.post(endpoint: endpoint, bearer: bearer, operations: operations, operation: operation,
                               fields: fields, key: key)
    }

    static func baseURL(_ environment: MeldEnvironment) -> String {
        switch environment {
        case .sandbox: return "https://api-sb.meld.io"
        case .qa: return "https://api-qa.meld.io"
        case .production: return "https://api.meld.io"
        }
    }
}

/// The one way an action request is built: a declared operation, its idempotency rule, a bounded body.
enum ActionRequest {
    static let bodyLimit = 65536

    static func post(endpoint: URL, bearer: String, operations: [String: Bool], operation: String,
                     fields: [String: Any], key: UUID?) throws -> URLRequest {
        guard let required = operations[operation], required == (key != nil),
              fields["version"] == nil, fields["operation"] == nil else { throw PaymentActionError.invalidRequest }
        var body = fields
        body["version"] = 1
        body["operation"] = operation
        guard JSONSerialization.isValidJSONObject(body) else { throw PaymentActionError.invalidRequest }
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= bodyLimit else { throw PaymentActionError.invalidRequest }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        if let key { request.setValue(key.uuidString.lowercased(), forHTTPHeaderField: "X-Idempotency-Key") }
        request.httpBody = data
        return request
    }
}

protocol PaymentActionSending {
    func send(_ operation: String, fields: [String: Any], key: UUID?,
              completion: @escaping (Result<[String: Any], Error>) -> Void)
    func finish()
}

/// Order-scoped transport. No application retries.
final class PaymentActionClient: PaymentActionSending {
    let descriptor: PaymentActionDescriptor
    private let transport: ActionTransport

    init(descriptor: PaymentActionDescriptor, configuration: URLSessionConfiguration = .ephemeral) {
        self.descriptor = descriptor
        self.transport = URLSessionActionTransport(configuration: configuration)
    }

    func send(_ operation: String, fields: [String: Any] = [:], key: UUID? = nil,
              completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let request: URLRequest
        do { request = try descriptor.request(operation: operation, fields: fields, key: key) }
        catch { DispatchQueue.main.async { completion(.failure(PaymentActionError.invalidRequest)) }; return }
        transport.post(request, responseLimit: 65536) { result in
            switch result {
            case .transportFailed: completion(.failure(PaymentActionError.transport))
            case .notHTTP: completion(.failure(PaymentActionError.invalidResponse))
            case let .response(status, body):
                if !(200..<300).contains(status) {
                    completion(.failure(PaymentActionFailureCode.decode(body, status: status)))
                } else if let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                          PaymentActionJSON.integer(json["version"]) == 1 { completion(.success(json)) }
                else { completion(.failure(PaymentActionError.invalidResponse)) }
            }
        }
    }

    /// The raw response to an action the order declares, for a caller that decodes it itself (the web SDK
    /// hosted in a WebView); nil when there is none. Completes on the main queue.
    func relay(_ operation: String, fields: [String: Any], key: UUID?,
               completion: @escaping ((status: Int, body: String?)?) -> Void) {
        let request: URLRequest
        do { request = try descriptor.request(operation: operation, fields: fields, key: key) }
        catch { DispatchQueue.main.async { completion(nil) }; return }
        transport.post(request, responseLimit: 65536) { result in
            guard case let .response(status, body) = result else { completion(nil); return }
            completion((status: status, body: body.flatMap { String(data: $0, encoding: .utf8) }))
        }
    }

    func finish() { transport.finish() }
}

enum ActionTransportResult {
    /// `body` is nil when the response has none or it is over the caller's limit.
    case response(status: Int, body: Data?)
    case transportFailed
    case notHTTP
}

protocol ActionTransportTask: AnyObject {
    func cancel()
}

extension URLSessionTask: ActionTransportTask {}

/// One action POST. Completes on the main queue.
protocol ActionTransport: AnyObject {
    @discardableResult
    func post(_ request: URLRequest, responseLimit: Int,
              completion: @escaping (ActionTransportResult) -> Void) -> ActionTransportTask
    func finish()
}

/// No cookies, disk cache, redirects or response diagnostics.
final class URLSessionActionTransport: ActionTransport {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration, delegate: PaymentActionRedirectPolicy(), delegateQueue: nil)
    }

    @discardableResult
    func post(_ request: URLRequest, responseLimit: Int,
              completion: @escaping (ActionTransportResult) -> Void) -> ActionTransportTask {
        let task = session.dataTask(with: request) { data, response, error in
            let result: ActionTransportResult
            if error != nil { result = .transportFailed }
            else if let response = response as? HTTPURLResponse {
                result = .response(status: response.statusCode, body: data.flatMap { $0.count <= responseLimit ? $0 : nil })
            } else { result = .notHTTP }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
        return task
    }

    func finish() { session.finishTasksAndInvalidate() }
    deinit { session.finishTasksAndInvalidate() }
}

final class PaymentActionRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

}

enum PaymentActionJSON {
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }

    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    static func isBearer(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 16384 && token.unicodeScalars.allSatisfy { $0.value > 32 && $0.value < 127 }
    }

    /// Declared operations and whether each needs an idempotency key; nil when any declaration is malformed or repeated.
    static func operations(_ declarations: [[String: Any]]) -> [String: Bool]? {
        var operations: [String: Bool] = [:]
        for declaration in declarations {
            guard let operation = declaration["operation"] as? String, !operation.isEmpty,
                  let required = boolean(declaration["idempotencyKeyRequired"]), operations[operation] == nil
            else { return nil }
            operations[operation] = required
        }
        return operations
    }

    static func resolve(_ pointer: String, in root: [String: Any]) -> Any? {
        guard pointer.hasPrefix("/"), pointer.utf8.count <= 1024 else { return nil }
        var current: Any = root
        for encoded in pointer.dropFirst().components(separatedBy: "/") {
            guard encoded.range(of: "~(?:[^01]|$)", options: .regularExpression) == nil else { return nil }
            let key = encoded.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let object = current as? [String: Any], let value = object[key] { current = value }
            else if let array = current as? [Any], let index = Int(key), String(index) == key,
                    index >= 0, index < array.count { current = array[index] }
            else { return nil }
        }
        return current
    }
}
