import CoreFoundation
import Foundation

enum PaymentActionError: Error {
    case invalidDescriptor, invalidRequest, invalidResponse, transport, storage, alreadyAttempted
    case headless(MeldHeadlessError)
}

/// Only the public recovery vocabulary is retained; response bodies are never attached.
enum PaymentActionFailure {
    static func decode(_ data: Data?, operation: String) -> PaymentActionError {
        guard let data, data.count <= 65536,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let advice = MeldHeadlessError.decode(json["headlessError"], operation: operation)
        else { return .headless(.fallback(operation)) }
        return .headless(advice)
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
              let bearer = Self.resolve(pointer, in: order.raw) as? String,
              !bearer.isEmpty, bearer.utf8.count <= 16384,
              bearer.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              let declarations = raw["operations"] as? [[String: Any]], !declarations.isEmpty
        else { throw PaymentActionError.invalidDescriptor }
        let path = url.path.components(separatedBy: "/")
        guard path.count == 8, Array(path.prefix(5)) == ["", "crypto", "order", "headless", "onramp"],
              !path[5].isEmpty, path[6] == orderID, path[7] == "actions",
              order.serviceProvider == nil || order.serviceProvider == path[5]
        else { throw PaymentActionError.invalidDescriptor }
        var operations: [String: Bool] = [:]
        for declaration in declarations {
            guard let operation = declaration["operation"] as? String, !operation.isEmpty,
                  let required = declaration["idempotencyKeyRequired"] as? NSNumber,
                  CFGetTypeID(required) == CFBooleanGetTypeID(), operations[operation] == nil
            else { throw PaymentActionError.invalidDescriptor }
            operations[operation] = required.boolValue
        }
        self.endpoint = url
        self.bearer = bearer
        self.operations = operations
    }

    func request(operation: String, fields: [String: Any], key: UUID?) throws -> URLRequest {
        guard let required = operations[operation], required == (key != nil),
              fields["version"] == nil, fields["operation"] == nil else { throw PaymentActionError.invalidRequest }
        var body = fields
        body["version"] = 1
        body["operation"] = operation
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= 65536 else { throw PaymentActionError.invalidRequest }
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

    static func baseURL(_ environment: MeldEnvironment) -> String {
        switch environment {
        case .sandbox: return "https://api-sb.meld.io"
        case .qa: return "https://api-qa.meld.io"
        case .production: return "https://api.meld.io"
        }
    }

    private static func resolve(_ pointer: String, in root: [String: Any]) -> Any? {
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

protocol PaymentActionSending {
    func send(_ operation: String, fields: [String: Any], key: UUID?,
              completion: @escaping (Result<[String: Any], Error>) -> Void)
    func finish()
}

/// Order-scoped transport. No cookies, disk cache, redirects, response diagnostics or application retries.
final class PaymentActionClient: PaymentActionSending {
    let descriptor: PaymentActionDescriptor
    private let session: URLSession

    init(descriptor: PaymentActionDescriptor, configuration: URLSessionConfiguration = .ephemeral) {
        self.descriptor = descriptor
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration, delegate: PaymentActionRedirectPolicy(), delegateQueue: nil)
    }

    func send(_ operation: String, fields: [String: Any] = [:], key: UUID? = nil,
              completion: @escaping (Result<[String: Any], Error>) -> Void) {
        let request: URLRequest
        do { request = try descriptor.request(operation: operation, fields: fields, key: key) }
        catch {
            let failure = PaymentActionError.headless(MeldHeadlessError(category: .invalidRequest, recovery: .correctRequest))
            DispatchQueue.main.async { completion(.failure(failure)) }
            return
        }
        session.dataTask(with: request) { data, response, error in
            let result: Result<[String: Any], Error>
            if error != nil { result = .failure(PaymentActionError.headless(.fallback(operation))) }
            else if let response = response as? HTTPURLResponse {
                if !(200..<300).contains(response.statusCode) {
                    result = .failure(PaymentActionFailure.decode(data, operation: operation))
                }
                else if let data, data.count <= 65536,
                        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        PaymentActionJSON.integer(json["version"]) == 1 { result = .success(json) }
                else { result = .failure(PaymentActionError.headless(.fallback(operation))) }
            } else { result = .failure(PaymentActionError.headless(.fallback(operation))) }
            DispatchQueue.main.async { completion(result) }
        }.resume()
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
}
